import 'package:drift/drift.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import '../db/ledger_setup.dart';
import '../money.dart';
import '../pricing_math.dart';
import '../quantity.dart';
import 'audit_service.dart';
import 'doc_types.dart';
import 'errors.dart';
import 'fifo_service.dart';
import 'numbering_service.dart';
import 'settings_service.dart';
import 'stock_service.dart';

/// Kinds of account.
abstract final class AccountKind {
  static const asset = 'asset';
  static const liability = 'liability';
  static const equity = 'equity';
  static const income = 'income';
  static const expense = 'expense';
  static const all = [asset, liability, equity, income, expense];

  static String label(String k) => switch (k) {
        asset => 'أصول',
        liability => 'التزامات',
        equity => 'حقوق ملكية',
        income => 'إيرادات',
        _ => 'مصروفات',
      };

  /// Assets and expenses grow on the debit side, the rest on the credit side.
  static bool debitNormal(String k) => k == asset || k == expense;
}

/// What a journal line refers to, by account key or id.
class PostLine {
  const PostLine(this.account, {this.debit = 0, this.credit = 0, this.partyType, this.partyId, this.memo});

  /// A system key (cash, ar, ...) or "id:N" for a chosen account.
  final String account;
  final int debit;
  final int credit;
  final String? partyType;
  final int? partyId;
  final String? memo;
}

/// One line of a manual entry, as typed.
class ManualLine {
  const ManualLine({required this.accountId, this.debit = 0, this.credit = 0, this.memo, this.partyType, this.partyId});

  final int accountId;
  final int debit;
  final int credit;
  final String? memo;
  final String? partyType;
  final int? partyId;
}

/// An account with what moved on it.
class AccountBalance {
  const AccountBalance(this.account, {this.openingDebit = 0, this.openingCredit = 0, this.debit = 0, this.credit = 0});

  final Account account;
  final int openingDebit;
  final int openingCredit;
  final int debit;
  final int credit;

  int get opening => openingDebit - openingCredit;
  int get closing => opening + debit - credit;

  /// The closing balance on its normal side (positive when normal).
  int get natural => AccountKind.debitNormal(account.kind) ? closing : -closing;
  int get periodNatural => AccountKind.debitNormal(account.kind) ? debit - credit : credit - debit;
}

/// One line of an account's ledger.
class LedgerLine {
  const LedgerLine(this.entry, this.line, this.balance, this.partyName);

  final JournalEntry entry;
  final JournalLine line;
  final int balance;
  final String? partyName;
}

class StatementSection {
  const StatementSection(this.title, this.rows);

  final String title;

  /// (account, amount on its normal side)
  final List<(Account, int)> rows;
  int get total => rows.fold(0, (s, r) => s + r.$2);
}

class ProfitAndLoss {
  const ProfitAndLoss({
    required this.sales,
    required this.returns,
    required this.cost,
    required this.operating,
    required this.otherIncome,
    required this.otherExpense,
  });

  final StatementSection sales;
  final StatementSection returns;
  final StatementSection cost;
  final StatementSection operating;
  final StatementSection otherIncome;
  final StatementSection otherExpense;

  int get netSales => sales.total - returns.total;
  int get grossProfit => netSales - cost.total;
  int get operatingProfit => grossProfit - operating.total;
  int get netProfit => operatingProfit + otherIncome.total - otherExpense.total;
  int? get grossMarginBp => netSales == 0 ? null : (grossProfit * 10000 / netSales).round();
  int? get netMarginBp => netSales == 0 ? null : (netProfit * 10000 / netSales).round();
}

class BalanceSheet {
  const BalanceSheet({
    required this.currentAssets,
    required this.fixedAssets,
    required this.currentLiabilities,
    required this.longLiabilities,
    required this.equity,
    required this.profitToDate,
  });

  final StatementSection currentAssets;
  final StatementSection fixedAssets;
  final StatementSection currentLiabilities;
  final StatementSection longLiabilities;
  final StatementSection equity;

  /// Income less expenses not yet closed into retained earnings.
  final int profitToDate;

  int get assets => currentAssets.total + fixedAssets.total;
  int get liabilities => currentLiabilities.total + longLiabilities.total;
  int get equityTotal => equity.total + profitToDate;
  bool get balances => assets == liabilities + equityTotal;
}

class CashFlow {
  const CashFlow({
    required this.opening,
    required this.operating,
    required this.investing,
    required this.financing,
  });

  final int opening;

  /// (label, amount): positive comes in, negative goes out.
  final List<(String, int)> operating;
  final List<(String, int)> investing;
  final List<(String, int)> financing;

  int get operatingTotal => operating.fold(0, (s, r) => s + r.$2);
  int get investingTotal => investing.fold(0, (s, r) => s + r.$2);
  int get financingTotal => financing.fold(0, (s, r) => s + r.$2);
  int get net => operatingTotal + investingTotal + financingTotal;
  int get closing => opening + net;
}

class VatReport {
  const VatReport({required this.salesBase, required this.outputVat, required this.inputVat, required this.unverifiedSales});

  /// Sales value on which VAT was charged, without the VAT.
  final int salesBase;
  final int outputVat;
  final int inputVat;

  /// Sales whose VAT basis is not verified: no VAT is assumed on them.
  final int unverifiedSales;
  int get payable => outputVat - inputVat;
}

/// A customer or supplier's open balance split by age.
class AgingRow {
  AgingRow(this.partyId, this.name);

  final int partyId;
  final String name;

  /// Not due yet, 1-30, 31-60, 61-90, over 90 days.
  final buckets = List<int>.filled(5, 0);
  int get total => buckets.fold(0, (s, b) => s + b);
}

/// The double-entry ledger. Every document's entry is built from the
/// document itself (see [sync]); triggers queue each changed document, and
/// [catchUp] builds what is queued before anything is read from the ledger.
class LedgerService {
  LedgerService(this.db);

  final AppDatabase db;

  final _ids = <String, int>{};

  /// Accounts kept by documents alone, so they always match the customer and
  /// supplier statements, the cheques and the stock.
  static const documentOnlyKeys = {
    'ar',
    'ap',
    'inventory',
    'cheques_in',
    'cheques_out',
    'customer_advances',
    'supplier_advances',
  };

  // ------------------------------------------------------------- accounts

  Future<int> _account(String key) async {
    if (key.startsWith('id:')) return int.parse(key.substring(3));
    final cached = _ids[key];
    if (cached != null) return cached;
    final a = await (db.select(db.accounts)..where((t) => t.systemKey.equals(key))).getSingleOrNull();
    if (a == null) throw StateError('No account for $key');
    return _ids[key] = a.id;
  }

  /// The expense account of an expense category, made the first time.
  Future<int> expenseAccount(int categoryId) async {
    final key = 'expense:$categoryId';
    final found = await (db.select(db.accounts)..where((t) => t.systemKey.equals(key))).getSingleOrNull();
    if (found != null) return found.id;
    final category = await (db.select(db.expenseCategories)..where((t) => t.id.equals(categoryId))).getSingle();
    final group = await (db.select(db.accounts)..where((t) => t.systemKey.equals('expenses_group'))).getSingle();
    final codes = (await (db.select(db.accounts)..where((t) => t.parentId.equals(group.id))).get())
        .map((a) => int.tryParse(a.code) ?? 0)
        .where((c) => c >= 5201 && c < 5299);
    final next = codes.isEmpty ? 5201 : codes.reduce((a, b) => a > b ? a : b) + 1;
    return db.into(db.accounts).insert(AccountsCompanion.insert(
          code: '$next',
          nameAr: category.nameAr,
          kind: AccountKind.expense,
          parentId: Value(group.id),
          systemKey: Value(key),
        ));
  }

  Stream<List<Account>> watchAccounts() =>
      (db.select(db.accounts)..orderBy([(a) => OrderingTerm.asc(a.code)])).watch();

  Future<List<Account>> accounts() => (db.select(db.accounts)..orderBy([(a) => OrderingTerm.asc(a.code)])).get();

  /// Adds an account under [parentId]; the code must be new.
  Future<int> addAccount({
    required String code,
    required String name,
    required int parentId,
    bool isGroup = false,
    String? note,
    required User user,
  }) async {
    if (!user.can(Perm.accounts)) throw ValidationException('دليل الحسابات لصلاحية المحاسبة');
    if (code.trim().isEmpty || name.trim().isEmpty) throw ValidationException('اكتب الكود والاسم');
    final parent = await (db.select(db.accounts)..where((a) => a.id.equals(parentId))).getSingle();
    if (!parent.isGroup) throw ValidationException('الحساب الأب يجب أن يكون حساباً رئيسياً');
    final same = await (db.select(db.accounts)..where((a) => a.code.equals(code.trim()))).getSingleOrNull();
    if (same != null) throw ValidationException('الكود ${code.trim()} مستخدم للحساب ${same.nameAr}');
    final id = await db.into(db.accounts).insert(AccountsCompanion.insert(
          code: code.trim(),
          nameAr: name.trim(),
          kind: parent.kind,
          parentId: Value(parentId),
          isGroup: Value(isGroup),
          note: Value((note ?? '').trim().isEmpty ? null : note!.trim()),
        ));
    await AuditService(db).log(action: AuditAction.create, entity: 'account', entityId: id, userId: user.id, details: '$code $name');
    return id;
  }

  Future<void> renameAccount(int id, String name, {required User user}) async {
    if (!user.can(Perm.accounts)) throw ValidationException('دليل الحسابات لصلاحية المحاسبة');
    if (name.trim().isEmpty) throw ValidationException('اكتب الاسم');
    await (db.update(db.accounts)..where((a) => a.id.equals(id)))
        .write(AccountsCompanion(nameAr: Value(name.trim()), updatedAt: Value(DateTime.now())));
    await AuditService(db).log(action: AuditAction.update, entity: 'account', entityId: id, userId: user.id, details: name);
  }

  // -------------------------------------------------------------- posting

  /// Builds every queued entry. Call before reading the ledger.
  Future<void> catchUp() async {
    while (true) {
      final batch = await (db.select(db.ledgerQueue)..limit(300)).get();
      if (batch.isEmpty) return;
      await db.transaction(() async {
        for (final q in batch) {
          await sync(q.refType, q.refId);
          await (db.delete(db.ledgerQueue)
                ..where((t) => t.refType.equals(q.refType) & t.refId.equals(q.refId)))
              .go();
        }
      });
    }
  }

  /// Rebuilds the whole ledger from the documents (a check, or after a
  /// restore). Manual entries are kept.
  Future<void> rebuild() async {
    await enqueueEverything(db);
    await catchUp();
  }

  Future<bool> _countPending() => SettingsService(db).getBool(SettingKey.countPendingCheques);

  /// Builds (or voids) the entry of one document from its current state.
  Future<void> sync(String refType, int refId) async {
    final built = await _build(refType, refId);
    final existing = await (db.select(db.journalEntries)
          ..where((e) => e.refType.equals(refType) & e.refId.equals(refId)))
        .getSingleOrNull();
    if (built == null) {
      if (existing != null && existing.status != 'void') {
        await (db.update(db.journalEntries)..where((e) => e.id.equals(existing.id)))
            .write(JournalEntriesCompanion(status: const Value('void'), updatedAt: Value(DateTime.now())));
      }
      return;
    }
    final (date, number, memo, projectId, lines) = built;
    final kept = lines.where((l) => l.debit != 0 || l.credit != 0).toList();
    final dr = kept.fold(0, (s, l) => s + l.debit);
    final cr = kept.fold(0, (s, l) => s + l.credit);
    if (dr != cr) throw StateError('Unbalanced entry for $refType $refId: $dr / $cr');
    int entryId;
    if (existing == null) {
      entryId = await db.into(db.journalEntries).insert(JournalEntriesCompanion.insert(
            number: number,
            date: date,
            source: 'auto',
            refType: Value(refType),
            refId: Value(refId),
            memo: Value(memo),
          ));
    } else {
      entryId = existing.id;
      await (db.update(db.journalEntries)..where((e) => e.id.equals(entryId))).write(JournalEntriesCompanion(
          date: Value(date), memo: Value(memo), status: const Value('posted'), updatedAt: Value(DateTime.now())));
      await (db.delete(db.journalLines)..where((l) => l.entryId.equals(entryId))).go();
    }
    for (final l in kept) {
      await db.into(db.journalLines).insert(JournalLinesCompanion.insert(
            entryId: entryId,
            accountId: await _account(l.account),
            debit: Value(l.debit),
            credit: Value(l.credit),
            partyType: Value(l.partyType),
            partyId: Value(l.partyId),
            projectId: Value(projectId),
            memo: Value(l.memo),
          ));
    }
  }

  Future<(DateTime, String, String?, int?, List<PostLine>)?> _build(String type, int id) async {
    switch (type) {
      case 'sales_invoice':
        final inv = await (db.select(db.salesInvoices)..where((t) => t.id.equals(id))).getSingleOrNull();
        if (inv == null || inv.status != DocStatus.active) return null;
        final items = await (db.select(db.salesInvoiceItems)..where((t) => t.invoiceId.equals(id))).get();
        // VAT is split out only when the price is known to include it.
        final vat = items
            .where((i) => i.vatStatus == VatStatus.inclusive)
            .fold(0, (s, i) => s + (i.vatAmount ?? 0));
        final cost = items.fold(0, (s, i) => s + i.costTotal);
        final party = inv.customerId;
        return (inv.date, inv.number, 'فاتورة بيع ${inv.number}', inv.projectId, [
          PostLine('ar', debit: inv.total, partyType: party == null ? null : PartyType.customer, partyId: party),
          PostLine('sales', credit: inv.total - vat),
          PostLine('vat_out', credit: vat),
          PostLine('cogs', debit: cost),
          PostLine('inventory', credit: cost),
        ]);
      case 'purchase_invoice':
        final inv = await (db.select(db.purchaseInvoices)..where((t) => t.id.equals(id))).getSingleOrNull();
        if (inv == null || inv.status != DocStatus.active) return null;
        final items = await (db.select(db.purchaseInvoiceItems)..where((t) => t.invoiceId.equals(id))).get();
        final stock = items.fold(0, (s, i) => s + i.netTotal + i.extraCostShare);
        const sup = PartyType.supplier;
        return (inv.date, inv.number, 'فاتورة شراء ${inv.number}', inv.projectId, [
          PostLine('inventory', debit: stock),
          PostLine('ap', credit: inv.total, partyType: sup, partyId: inv.supplierId),
          PostLine('purchase_costs', credit: stock - inv.total),
          // Taken against a supplier advance: the advance settles the debt.
          PostLine('ap', debit: inv.advanceUsed, partyType: sup, partyId: inv.supplierId, memo: 'من الدفعة المقدمة'),
          PostLine('supplier_advances', credit: inv.advanceUsed),
        ]);
      case 'return':
        final r = await (db.select(db.returns)..where((t) => t.id.equals(id))).getSingleOrNull();
        if (r == null || r.status != DocStatus.active) return null;
        if (r.kind == ReturnKind.sale) {
          final moves = await (db.select(db.stockMovements)
                ..where((m) =>
                    m.refType.equals(RefType.returnDoc) &
                    m.refId.equals(id) &
                    m.type.equals(StockMovementType.saleReturn)))
              .get();
          final cost = moves.fold(0, (s, m) => s + lineAmount(m.qty, m.unitCost));
          return (r.date, r.number, 'مرتجع بيع ${r.number}', null, [
            PostLine('sales_returns', debit: r.total),
            PostLine('ar', credit: r.total, partyType: r.partyId == null ? null : PartyType.customer, partyId: r.partyId),
            PostLine('inventory', debit: cost),
            PostLine('cogs', credit: cost),
          ]);
        }
        var cost = await FifoService(db).costOf('purchase_return', id);
        if (cost == 0) {
          final moves = await (db.select(db.stockMovements)
                ..where((m) => m.refType.equals(RefType.returnDoc) & m.refId.equals(id)))
              .get();
          cost = moves.fold(0, (s, m) => s - lineAmount(m.qty, m.unitCost));
        }
        final diff = r.total - cost;
        return (r.date, r.number, 'مرتجع شراء ${r.number}', null, [
          PostLine('ap', debit: r.total, partyType: PartyType.supplier, partyId: r.partyId),
          PostLine('inventory', credit: cost),
          PostLine('purchase_variance', credit: diff > 0 ? diff : 0, debit: diff < 0 ? -diff : 0),
        ]);
      case 'payment':
        final p = await (db.select(db.payments)..where((t) => t.id.equals(id))).getSingleOrNull();
        if (p == null || p.status != DocStatus.active) return null;
        final cheque = await (db.select(db.cheques)..where((c) => c.paymentId.equals(id))).getSingleOrNull();
        final inbound = p.direction == PaymentDirection.inbound;
        String money;
        if (p.method == PaymentMethod.cheque) {
          if (cheque == null) return null;
          if (cheque.status == ChequeStatus.cleared) {
            money = 'bank';
          } else if (cheque.status == ChequeStatus.pending && await _countPending()) {
            money = inbound ? 'cheques_in' : 'cheques_out';
          } else {
            return null; // bounced, cancelled, or pending not counted yet
          }
        } else {
          money = p.method == PaymentMethod.bank ? 'bank' : 'cash';
        }
        final isCustomer = p.partyType == PartyType.customer;
        final party = p.partyId <= 0 ? null : p.partyId;
        final String other;
        if (isCustomer) {
          other = inbound && p.invoiceRefType == RefType.salesOrder ? 'customer_advances' : 'ar';
        } else {
          other = !inbound && (p.invoiceRefType == RefType.purchaseOrder || p.invoiceRefType == RefType.supplierAdvance)
              ? 'supplier_advances'
              : 'ap';
        }
        final partyType = other == 'ar' || other == 'ap' || other.endsWith('advances') ? p.partyType : null;
        final memo = '${inbound ? 'تحصيل' : 'دفع'} ${p.number}';
        return (p.date, p.number, memo, null, [
          if (inbound) ...[
            PostLine(money, debit: p.amount),
            PostLine(other, credit: p.amount, partyType: partyType, partyId: party),
          ] else ...[
            PostLine(other, debit: p.amount, partyType: partyType, partyId: party),
            PostLine(money, credit: p.amount),
          ],
        ]);
      case 'expense':
        final e = await (db.select(db.expenses)..where((t) => t.id.equals(id))).getSingleOrNull();
        if (e == null || e.status != DocStatus.active) return null;
        final account = e.purchaseInvoiceId != null ? 'purchase_costs' : 'id:${await expenseAccount(e.categoryId)}';
        return (e.date, 'EX-$id', e.description ?? 'مصروف', e.projectId, [
          PostLine(account, debit: e.amount),
          PostLine(e.method == PaymentMethod.bank ? 'bank' : 'cash', credit: e.amount),
        ]);
      case 'stock_movement':
        final m = await (db.select(db.stockMovements)..where((t) => t.id.equals(id))).getSingleOrNull();
        if (m == null) return null;
        if (m.type == StockMovementType.opening) {
          final v = lineAmount(m.qty, m.unitCost);
          return (m.date, 'OPN-$id', 'مخزون أول المدة', null, [
            PostLine('inventory', debit: v),
            PostLine('opening', credit: v),
          ]);
        }
        if (m.type != StockMovementType.adjustment) return null;
        if (m.qty > 0) {
          final v = lineAmount(m.qty, m.unitCost);
          return (m.date, 'ADJ-$id', 'تسوية مخزون: ${m.note ?? ''}', null, [
            PostLine('inventory', debit: v),
            PostLine('stock_gain', credit: v),
          ]);
        }
        var v = await FifoService(db).costOf('adjustment', id);
        if (v == 0) v = -lineAmount(m.qty, m.unitCost);
        return (m.date, 'ADJ-$id', 'تسوية مخزون: ${m.note ?? ''}', null, [
          PostLine('stock_loss', debit: v),
          PostLine('inventory', credit: v),
        ]);
      case 'customer_opening':
        final c = await (db.select(db.customers)..where((t) => t.id.equals(id))).getSingleOrNull();
        if (c == null || c.openingBalance == 0) return null;
        final ob = c.openingBalance;
        return (c.createdAt, 'OB-C$id', 'رصيد أول المدة: ${c.name}', null, [
          PostLine('ar', debit: ob > 0 ? ob : 0, credit: ob < 0 ? -ob : 0, partyType: PartyType.customer, partyId: id),
          PostLine('opening', credit: ob > 0 ? ob : 0, debit: ob < 0 ? -ob : 0),
        ]);
      case 'supplier_opening':
        final s = await (db.select(db.suppliers)..where((t) => t.id.equals(id))).getSingleOrNull();
        if (s == null || s.openingBalance == 0) return null;
        final ob = s.openingBalance;
        return (s.createdAt, 'OB-S$id', 'رصيد أول المدة: ${s.name}', null, [
          PostLine('ap', credit: ob > 0 ? ob : 0, debit: ob < 0 ? -ob : 0, partyType: PartyType.supplier, partyId: id),
          PostLine('opening', debit: ob > 0 ? ob : 0, credit: ob < 0 ? -ob : 0),
        ]);
    }
    return null;
  }

  // ------------------------------------------------------- manual entries

  /// A manual entry: capital, loans, drawings, depreciation, fixed assets,
  /// corrections. Not for sales, purchases or expenses (their screens post
  /// them). Admin only; it must balance.
  Future<JournalEntry> addManual({
    required DateTime date,
    required String memo,
    required List<ManualLine> lines,
    int? projectId,
    required User user,
  }) {
    return db.transaction(() async {
      if (!user.can(Perm.accounts)) throw ValidationException('القيود اليدوية لصلاحية المحاسبة');
      if (memo.trim().isEmpty) throw ValidationException('اكتب بيان القيد');
      final used = lines.where((l) => l.debit != 0 || l.credit != 0).toList();
      if (used.length < 2) throw ValidationException('القيد يحتاج سطرين على الأقل');
      for (final l in used) {
        if (l.debit < 0 || l.credit < 0) throw ValidationException('المبالغ لا تكون سالبة');
        if (l.debit != 0 && l.credit != 0) throw ValidationException('السطر يكون مديناً أو دائناً، لا الاثنين');
        final a = await (db.select(db.accounts)..where((t) => t.id.equals(l.accountId))).getSingle();
        if (a.isGroup) throw ValidationException('لا يُقيد على حساب رئيسي: ${a.nameAr}');
        if (!a.isActive) throw ValidationException('الحساب ${a.nameAr} موقوف');
        if (documentOnlyKeys.contains(a.systemKey)) {
          throw ValidationException(
              'الحساب ${a.nameAr} يتحرك من المستندات فقط (الفواتير والدفعات والمرتجعات وتسويات المخزون) '
              'حتى يبقى مطابقاً لكشوف الحساب والمخزون');
        }
      }
      final dr = used.fold(0, (s, l) => s + l.debit);
      final cr = used.fold(0, (s, l) => s + l.credit);
      if (dr != cr) {
        throw ValidationException('القيد غير متوازن: المدين ${formatMoney(dr)} والدائن ${formatMoney(cr)}');
      }
      await _checkOpen(date);
      final id = await db.into(db.journalEntries).insert(JournalEntriesCompanion.insert(
            number: await NumberingService(db).next('journal'),
            date: date,
            source: 'manual',
            memo: Value(memo.trim()),
            createdBy: Value(user.id),
          ));
      for (final l in used) {
        await db.into(db.journalLines).insert(JournalLinesCompanion.insert(
              entryId: id,
              accountId: l.accountId,
              debit: Value(l.debit),
              credit: Value(l.credit),
              memo: Value(l.memo),
              partyType: Value(l.partyType),
              partyId: Value(l.partyId),
              projectId: Value(projectId),
            ));
      }
      final entry = await (db.select(db.journalEntries)..where((e) => e.id.equals(id))).getSingle();
      await AuditService(db).log(
          action: AuditAction.create,
          entity: 'journal',
          entityId: id,
          userId: user.id,
          details: '${entry.number} ${formatMoney(dr)}: ${memo.trim()}');
      return entry;
    });
  }

  /// Voids a manual entry (it stays on record). Entries from documents are
  /// voided by cancelling their document.
  Future<void> voidManual(int entryId, {required String reason, required User user}) {
    return db.transaction(() async {
      if (!user.can(Perm.accounts)) throw ValidationException('القيود اليدوية لصلاحية المحاسبة');
      if (reason.trim().isEmpty) throw ValidationException('سبب الإلغاء مطلوب');
      final e = await (db.select(db.journalEntries)..where((t) => t.id.equals(entryId))).getSingle();
      if (e.source != 'manual') throw ValidationException('هذا القيد من مستند؛ يُلغى بإلغاء المستند نفسه');
      if (e.status == 'void') throw ValidationException('القيد ملغى من قبل');
      await _checkOpen(e.date);
      await (db.update(db.journalEntries)..where((t) => t.id.equals(entryId))).write(JournalEntriesCompanion(
          status: const Value('void'),
          memo: Value('${e.memo ?? ''}\nسبب الإلغاء: ${reason.trim()}'),
          updatedAt: Value(DateTime.now())));
      await AuditService(db).log(
          action: AuditAction.cancel, entity: 'journal', entityId: entryId, userId: user.id, details: reason.trim());
    });
  }

  // -------------------------------------------------------- period closing

  Future<DateTime?> lockedUntil() async {
    final v = await SettingsService(db).get(booksLockedUntilKey);
    final n = v == null ? null : int.tryParse(v);
    return n == null || n < 0 ? null : DateTime.fromMillisecondsSinceEpoch(n * 1000);
  }

  Future<void> _checkOpen(DateTime date) async {
    final until = await lockedUntil();
    if (until != null && !date.isAfter(until)) {
      throw ValidationException('الفترة حتى ${until.year}/${until.month}/${until.day} مقفلة؛ لا يُضاف أو يُلغى فيها شيء');
    }
  }

  /// Closes the books up to the end of [day]: nothing dated on or before it
  /// can be added or cancelled. Admin only.
  Future<void> closeUntil(DateTime day, {required User user}) async {
    if (!user.can(Perm.accounts)) throw ValidationException('إقفال الفترات لصلاحية المحاسبة');
    final end = DateTime(day.year, day.month, day.day, 23, 59, 59);
    final before = await lockedUntil();
    if (before != null && !end.isAfter(before)) {
      throw ValidationException('الفترة مقفلة حتى ${before.year}/${before.month}/${before.day} بالفعل');
    }
    await catchUp();
    await SettingsService(db).set(booksLockedUntilKey, '${end.millisecondsSinceEpoch ~/ 1000}');
    await AuditService(db).log(
        action: AuditAction.update, entity: 'period', entityId: 0, userId: user.id,
        details: 'إقفال حتى ${end.year}/${end.month}/${end.day}');
  }

  /// Opens the books again from [day] on, with a reason. Admin only.
  Future<void> reopenFrom(DateTime day, {required String reason, required User user}) async {
    if (!user.isAdmin) throw ValidationException('إعادة فتح الفترات للمدير فقط');
    if (reason.trim().isEmpty) throw ValidationException('سبب إعادة الفتح مطلوب');
    final before = await lockedUntil();
    if (before == null) throw ValidationException('لا توجد فترة مقفلة');
    final until = DateTime(day.year, day.month, day.day).subtract(const Duration(seconds: 1));
    await SettingsService(db)
        .set(booksLockedUntilKey, '${until.isBefore(DateTime(2000)) ? -1 : until.millisecondsSinceEpoch ~/ 1000}');
    await AuditService(db).log(
        action: AuditAction.update, entity: 'period', entityId: 0, userId: user.id,
        details: 'إعادة فتح من ${day.year}/${day.month}/${day.day}: ${reason.trim()}');
  }

  // --------------------------------------------------------------- reading

  /// Every account with its movements before [from] and between [from] and
  /// [to] (both days included), posted entries only.
  Future<List<AccountBalance>> balances({DateTime? from, DateTime? to}) async {
    await catchUp();
    final fromS = from == null ? null : DateTime(from.year, from.month, from.day).millisecondsSinceEpoch ~/ 1000;
    final toS = to == null ? null : DateTime(to.year, to.month, to.day, 23, 59, 59).millisecondsSinceEpoch ~/ 1000;
    final rows = await db.customSelect(
      '''
      SELECT l.account_id AS a,
        SUM(CASE WHEN ? IS NOT NULL AND e.date < ? THEN l.debit ELSE 0 END) AS od,
        SUM(CASE WHEN ? IS NOT NULL AND e.date < ? THEN l.credit ELSE 0 END) AS oc,
        SUM(CASE WHEN (? IS NULL OR e.date >= ?) AND (? IS NULL OR e.date <= ?) THEN l.debit ELSE 0 END) AS d,
        SUM(CASE WHEN (? IS NULL OR e.date >= ?) AND (? IS NULL OR e.date <= ?) THEN l.credit ELSE 0 END) AS c
      FROM journal_lines l JOIN journal_entries e ON e.id = l.entry_id
      WHERE e.status = 'posted'
      GROUP BY l.account_id
      ''',
      variables: [
        for (var i = 0; i < 2; i++) ...[Variable<int>(fromS), Variable<int>(fromS)],
        for (var i = 0; i < 2; i++) ...[
          Variable<int>(fromS),
          Variable<int>(fromS),
          Variable<int>(toS),
          Variable<int>(toS),
        ],
      ],
    ).get();
    final byId = {for (final r in rows) r.read<int>('a'): r};
    return [
      for (final a in await accounts())
        AccountBalance(
          a,
          openingDebit: byId[a.id]?.read<int>('od') ?? 0,
          openingCredit: byId[a.id]?.read<int>('oc') ?? 0,
          debit: byId[a.id]?.read<int>('d') ?? 0,
          credit: byId[a.id]?.read<int>('c') ?? 0,
        ),
    ];
  }

  /// Sums each heading from the accounts under it.
  static Map<int, AccountBalance> rollUp(List<AccountBalance> rows) {
    final byId = {for (final r in rows) r.account.id: r};
    final children = <int, List<int>>{};
    for (final r in rows) {
      if (r.account.parentId != null) (children[r.account.parentId!] ??= []).add(r.account.id);
    }
    final out = <int, AccountBalance>{};
    AccountBalance total(int id) {
      final done = out[id];
      if (done != null) return done;
      final r = byId[id]!;
      var od = r.openingDebit, oc = r.openingCredit, d = r.debit, c = r.credit;
      for (final k in children[id] ?? const <int>[]) {
        final t = total(k);
        od += t.openingDebit;
        oc += t.openingCredit;
        d += t.debit;
        c += t.credit;
      }
      return out[id] = AccountBalance(r.account, openingDebit: od, openingCredit: oc, debit: d, credit: c);
    }

    for (final r in rows) {
      total(r.account.id);
    }
    return out;
  }

  /// One account's lines between two days, with the running balance.
  Future<(int, List<LedgerLine>)> ledger(int accountId, {DateTime? from, DateTime? to}) async {
    await catchUp();
    final account = await (db.select(db.accounts)..where((a) => a.id.equals(accountId))).getSingle();
    final all = await (db.select(db.journalLines).join([
      innerJoin(db.journalEntries, db.journalEntries.id.equalsExp(db.journalLines.entryId)),
    ])
          ..where(db.journalLines.accountId.equals(accountId) & db.journalEntries.status.equals('posted'))
          ..orderBy([OrderingTerm.asc(db.journalEntries.date), OrderingTerm.asc(db.journalEntries.id)]))
        .get();
    final names = <String, String>{
      for (final c in await db.select(db.customers).get()) '${PartyType.customer}:${c.id}': c.name,
      for (final s in await db.select(db.suppliers).get()) '${PartyType.supplier}:${s.id}': s.name,
    };
    final fromD = from == null ? null : DateTime(from.year, from.month, from.day);
    final toD = to == null ? null : DateTime(to.year, to.month, to.day, 23, 59, 59);
    final sign = AccountKind.debitNormal(account.kind) ? 1 : -1;
    var running = 0;
    var opening = 0;
    final out = <LedgerLine>[];
    for (final r in all) {
      final e = r.readTable(db.journalEntries);
      final l = r.readTable(db.journalLines);
      running += sign * (l.debit - l.credit);
      if (fromD != null && e.date.isBefore(fromD)) {
        opening = running;
        continue;
      }
      if (toD != null && e.date.isAfter(toD)) break;
      out.add(LedgerLine(e, l, running, l.partyType == null ? null : names['${l.partyType}:${l.partyId}']));
    }
    return (opening, out.reversed.toList());
  }

  /// Entries, newest first, optionally only manual ones.
  Future<List<(JournalEntry, List<(JournalLine, Account)>)>> entries({
    DateTime? from,
    DateTime? to,
    bool manualOnly = false,
    int limit = 400,
  }) async {
    await catchUp();
    final q = db.select(db.journalEntries)
      ..where((e) {
        Expression<bool> w = const Constant(true);
        if (manualOnly) w = w & e.source.equals('manual');
        if (from != null) w = w & e.date.isBiggerOrEqualValue(DateTime(from.year, from.month, from.day));
        if (to != null) w = w & e.date.isSmallerOrEqualValue(DateTime(to.year, to.month, to.day, 23, 59, 59));
        return w;
      })
      ..orderBy([(e) => OrderingTerm.desc(e.date), (e) => OrderingTerm.desc(e.id)])
      ..limit(limit);
    final list = await q.get();
    final accounts = {for (final a in await this.accounts()) a.id: a};
    final out = <(JournalEntry, List<(JournalLine, Account)>)>[];
    for (final e in list) {
      final lines = await (db.select(db.journalLines)..where((l) => l.entryId.equals(e.id))).get();
      out.add((e, [for (final l in lines) (l, accounts[l.accountId]!)]));
    }
    return out;
  }

  StatementSection _section(String title, Map<int, AccountBalance> rolled, List<AccountBalance> rows,
      bool Function(Account) pick, {bool period = true}) {
    return StatementSection(title, [
      for (final r in rows)
        if (!r.account.isGroup && pick(r.account))
          (r.account, period ? r.periodNatural : r.natural),
    ].where((x) => x.$2 != 0).toList());
  }

  bool _under(Account a, String parentCode, Map<int, Account> byId) {
    var p = a.parentId;
    while (p != null) {
      final parent = byId[p];
      if (parent == null) return false;
      if (parent.code == parentCode) return true;
      p = parent.parentId;
    }
    return false;
  }

  Future<ProfitAndLoss> profitAndLoss({DateTime? from, DateTime? to}) async {
    final rows = await balances(from: from, to: to);
    final byId = {for (final r in rows) r.account.id: r.account};
    final rolled = rollUp(rows);
    bool key(Account a, String k) => a.systemKey == k;
    return ProfitAndLoss(
      sales: _section('المبيعات', rolled, rows, (a) => key(a, 'sales')),
      returns: _section('مرتجعات المبيعات', rolled, rows, (a) => key(a, 'sales_returns'))
          .let((s) => StatementSection(s.title, [for (final r in s.rows) (r.$1, -r.$2)])),
      cost: _section('تكلفة المبيعات', rolled, rows, (a) => _under(a, '51', byId)),
      operating: _section('المصروفات التشغيلية', rolled, rows, (a) => _under(a, '52', byId)),
      otherIncome: _section('إيرادات أخرى', rolled, rows,
          (a) => a.kind == AccountKind.income && !key(a, 'sales') && !key(a, 'sales_returns')),
      otherExpense: _section('مصروفات أخرى', rolled, rows,
          (a) => a.kind == AccountKind.expense && !_under(a, '51', byId) && !_under(a, '52', byId)),
    );
  }

  Future<BalanceSheet> balanceSheet({DateTime? asOf}) async {
    final rows = await balances(to: asOf);
    final byId = {for (final r in rows) r.account.id: r.account};
    final rolled = rollUp(rows);
    final profit = rows
        .where((r) => !r.account.isGroup && (r.account.kind == AccountKind.income || r.account.kind == AccountKind.expense))
        .fold(0, (s, r) => s + (r.account.kind == AccountKind.income ? r.periodNatural : -r.periodNatural));
    return BalanceSheet(
      currentAssets: _section('الأصول المتداولة', rolled, rows,
          (a) => a.kind == AccountKind.asset && !_under(a, '12', byId)),
      fixedAssets: _section('الأصول الثابتة', rolled, rows, (a) => _under(a, '12', byId)),
      currentLiabilities: _section('الالتزامات المتداولة', rolled, rows,
          (a) => a.kind == AccountKind.liability && !_under(a, '22', byId)),
      longLiabilities: _section('التزامات طويلة الأجل', rolled, rows, (a) => _under(a, '22', byId)),
      equity: _section('حقوق الملكية', rolled, rows, (a) => a.kind == AccountKind.equity),
      profitToDate: profit,
    );
  }

  /// Money in and out of the cash box, the bank and the cheque accounts,
  /// by what it was for: operating, investing (fixed assets), financing
  /// (capital, drawings, loans).
  Future<CashFlow> cashFlow({required DateTime from, required DateTime to}) async {
    await catchUp();
    final accounts = {for (final a in await this.accounts()) a.id: a};
    final cashKeys = {'cash', 'bank', 'cheques_in', 'cheques_out'};
    final cashIds = {for (final a in accounts.values) if (cashKeys.contains(a.systemKey)) a.id};
    final opening = (await balances(from: from, to: to))
        .where((b) => cashIds.contains(b.account.id))
        .fold(0, (s, b) => s + b.opening);
    final entries = await this.entries(from: from, to: to, limit: 1000000);
    final buckets = <String, Map<String, int>>{'operating': {}, 'investing': {}, 'financing': {}};
    for (final (e, lines) in entries) {
      if (e.status != 'posted') continue;
      final cash = lines.where((l) => cashIds.contains(l.$1.accountId)).fold(0, (s, l) => s + l.$1.debit - l.$1.credit);
      if (cash == 0) continue;
      final others = lines.where((l) => !cashIds.contains(l.$1.accountId)).toList();
      if (others.isEmpty) continue; // between cash accounts
      final main = others.first.$2;
      final label = switch (main.systemKey) {
        'ar' => 'تحصيل من العملاء',
        'customer_advances' => 'دفعات مقدمة من العملاء',
        'ap' => 'مدفوعات للموردين',
        'supplier_advances' => 'دفعات مقدمة للموردين',
        'purchase_costs' => 'مصاريف نقل مشتريات',
        _ => main.nameAr,
      };
      final section = main.code.startsWith('12')
          ? 'investing'
          : (main.kind == AccountKind.equity || main.code.startsWith('22') ? 'financing' : 'operating');
      final group = section == 'operating' && main.kind == AccountKind.expense ? 'مصروفات تشغيلية' : label;
      buckets[section]![group] = (buckets[section]![group] ?? 0) + cash;
    }
    List<(String, int)> list(String k) =>
        [for (final e in buckets[k]!.entries) (e.key, e.value)]..sort((a, b) => a.$2.compareTo(b.$2));
    return CashFlow(
        opening: opening, operating: list('operating'), investing: list('investing'), financing: list('financing'));
  }

  Future<VatReport> vat({required DateTime from, required DateTime to}) async {
    await catchUp();
    final f = DateTime(from.year, from.month, from.day).millisecondsSinceEpoch ~/ 1000;
    final t = DateTime(to.year, to.month, to.day, 23, 59, 59).millisecondsSinceEpoch ~/ 1000;
    final r = await db.customSelect(
      '''
      SELECT
        COALESCE(SUM(CASE WHEN i.vat_status = '${VatStatus.inclusive}' THEN i.net_total - COALESCE(i.vat_amount, 0) END), 0) AS base,
        COALESCE(SUM(CASE WHEN i.vat_status = '${VatStatus.inclusive}' THEN COALESCE(i.vat_amount, 0) END), 0) AS vat,
        COALESCE(SUM(CASE WHEN i.vat_status IS NULL OR i.vat_status <> '${VatStatus.inclusive}' THEN i.net_total END), 0) AS other
      FROM sales_invoice_items i JOIN sales_invoices s ON s.id = i.invoice_id
      WHERE s.status = 'active' AND s.date >= ? AND s.date <= ?
      ''',
      variables: [Variable.withInt(f), Variable.withInt(t)],
    ).getSingle();
    final input = (await balances(from: from, to: to))
        .where((b) => b.account.systemKey == 'vat_in')
        .fold(0, (s, b) => s + b.debit - b.credit);
    return VatReport(
      salesBase: r.read<int>('base'),
      outputVat: r.read<int>('vat'),
      inputVat: input,
      unverifiedSales: r.read<int>('other'),
    );
  }

  /// Open balances by age. A party's balance is matched to its newest
  /// invoices (payments settle the oldest first), so each row adds up to the
  /// balance on its statement. Suppliers age by due date when one is set.
  Future<List<AgingRow>> aging({required bool customers, DateTime? asOf}) async {
    await catchUp();
    final today = asOf ?? DateTime.now();
    final lines = await db.customSelect(
      customers
          ? "SELECT l.party_id AS p, SUM(l.debit - l.credit) AS b FROM journal_lines l "
              "JOIN journal_entries e ON e.id = l.entry_id JOIN accounts a ON a.id = l.account_id "
              "WHERE e.status = 'posted' AND a.system_key = 'ar' AND l.party_id IS NOT NULL GROUP BY l.party_id"
          : "SELECT l.party_id AS p, SUM(l.credit - l.debit) AS b FROM journal_lines l "
              "JOIN journal_entries e ON e.id = l.entry_id JOIN accounts a ON a.id = l.account_id "
              "WHERE e.status = 'posted' AND a.system_key = 'ap' AND l.party_id IS NOT NULL GROUP BY l.party_id",
    ).get();
    final names = customers
        ? {for (final c in await db.select(db.customers).get()) c.id: c.name}
        : {for (final s in await db.select(db.suppliers).get()) s.id: s.name};
    final out = <AgingRow>[];
    for (final l in lines) {
      final party = l.read<int>('p');
      var left = l.read<int>('b');
      if (left <= 0) continue;
      final row = AgingRow(party, names[party] ?? '');
      final docs = customers
          ? (await (db.select(db.salesInvoices)
                    ..where((s) => s.customerId.equals(party) & s.status.equals(DocStatus.active))
                    ..orderBy([(s) => OrderingTerm.desc(s.date)]))
                  .get())
              .map((s) => (s.date, s.total))
          : (await (db.select(db.purchaseInvoices)
                    ..where((s) => s.supplierId.equals(party) & s.status.equals(DocStatus.active))
                    ..orderBy([(s) => OrderingTerm.desc(s.date)]))
                  .get())
              .map((s) => (s.dueDate ?? s.date, s.total - s.advanceUsed));
      for (final (date, amount) in docs) {
        if (left <= 0) break;
        final take = amount < left ? amount : left;
        left -= take;
        final days = DateTime(today.year, today.month, today.day).difference(DateTime(date.year, date.month, date.day)).inDays;
        final bucket = days <= 0 ? 0 : days <= 30 ? 1 : days <= 60 ? 2 : days <= 90 ? 3 : 4;
        row.buckets[bucket] += take;
      }
      // What no invoice explains (an opening balance, say) is the oldest.
      if (left > 0) row.buckets[4] += left;
      out.add(row);
    }
    out.sort((a, b) => b.total.compareTo(a.total));
    return out;
  }

  /// Income, expenses and profit for each of the last [months] months.
  Future<List<(DateTime, int, int, int)>> monthly({int months = 12}) async {
    final now = DateTime.now();
    final out = <(DateTime, int, int, int)>[];
    for (var i = months - 1; i >= 0; i--) {
      final start = DateTime(now.year, now.month - i);
      final end = DateTime(start.year, start.month + 1, 0);
      final p = await profitAndLoss(from: start, to: end);
      out.add((start, p.netSales, p.cost.total + p.operating.total + p.otherExpense.total, p.netProfit));
    }
    return out;
  }
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
