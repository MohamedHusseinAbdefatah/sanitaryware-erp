import 'package:drift/drift.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import '../db/ledger_setup.dart';
import '../money.dart';
import 'audit_service.dart';
import 'balance_service.dart';
import 'doc_types.dart';
import 'errors.dart';
import 'numbering_service.dart';
import 'payment_service.dart';

/// A price list an advance was locked to before version 2.4 (shown for the
/// record only; an advance no longer fixes any price).
class AdvanceList {
  const AdvanceList(this.brandName, this.list);

  final String brandName;
  final PriceList list;
}

class AdvanceRow {
  const AdvanceRow(this.advance, this.supplierName, this.lists, this.used);

  final SupplierAdvance advance;
  final String supplierName;

  /// Before 2.4 only: the lists it was locked to. Empty for new advances.
  final List<AdvanceList> lists;

  /// Taken so far by active allocations.
  final int used;

  int get remaining => advance.amount - used;
  bool get open => advance.status == DocStatus.active && remaining > 0;
}

/// One use of an advance on an invoice, with readable numbers.
class AllocationRow {
  const AllocationRow(this.allocation, this.advanceNumber, this.invoiceNumber, this.invoiceDate);

  final SupplierAdvanceAllocation allocation;
  final String advanceNumber;
  final String invoiceNumber;
  final DateTime invoiceDate;

  bool get active => allocation.status == DocStatus.active;
}

/// A supplier's advances at a glance.
class AdvanceBalance {
  const AdvanceBalance({required this.paid, required this.allocated});

  /// Active advances whose payment counts (a bounced cheque does not).
  final int paid;

  /// Taken by active allocations.
  final int allocated;

  int get remaining => paid - allocated;
}

/// Money paid to a supplier ahead (blueprint, redesigned in 2.4). An advance
/// belongs to the supplier and to no price list: any later purchase invoice
/// of that supplier, of any brand or list, may take part of it. Each use is
/// an allocation row linking one advance to one invoice, so the same money is
/// never used twice and the history is kept. The supplier's balance counts
/// the advance from the day it is paid; an allocation only marks an invoice
/// as paid from it.
class SupplierAdvanceService {
  SupplierAdvanceService(this.db);

  final AppDatabase db;

  void _purchaser(User user) {
    if (!user.can(Perm.purchase)) throw ValidationException('الدفعات المقدمة لصلاحية المشتريات');
  }

  void _owner(User user) {
    if (!user.isAdmin) throw ValidationException('تصحيح الدفعات المقدمة وتوزيعها للمالك فقط');
  }

  /// Records an advance to [supplierId]: amount, date, method and notes. No
  /// price list is chosen.
  Future<SupplierAdvance> create({
    required int supplierId,
    required int amount,
    String method = PaymentMethod.cash,
    ChequeInput? cheque,
    DateTime? date,
    String? note,
    required User user,
  }) {
    return db.transaction(() async {
      _purchaser(user);
      if (amount <= 0) throw ValidationException('المبلغ يجب أن يكون أكبر من صفر');
      final day = date ?? DateTime.now();
      final payment = await PaymentService(db).payLockedAdvance(
        supplierId: supplierId,
        amount: amount,
        method: method,
        cheque: cheque,
        date: day,
        notes: note,
        user: user,
      );
      final id = await db.into(db.supplierAdvances).insert(SupplierAdvancesCompanion.insert(
            number: await NumberingService(db).next('supplier_advance'),
            supplierId: supplierId,
            date: day,
            amount: amount,
            paymentId: payment.id,
            note: Value((note ?? '').trim().isEmpty ? null : note!.trim()),
            createdBy: Value(user.id),
          ));
      await (db.update(db.payments)..where((t) => t.id.equals(payment.id)))
          .write(PaymentsCompanion(invoiceRefId: Value(id)));
      final advance = await (db.select(db.supplierAdvances)..where((t) => t.id.equals(id))).getSingle();
      await AuditService(db).log(
        action: AuditAction.create,
        entity: 'supplier_advance',
        entityId: id,
        userId: user.id,
        details: '${advance.number} ${formatMoney(amount)}',
      );
      return advance;
    });
  }

  /// What is left of [supplierId]'s advances.
  Future<AdvanceBalance> balance(int supplierId) async {
    final pending = await BalanceService(db).countPendingCheques();
    final row = await db.customSelect(
      '''
      SELECT
        COALESCE((SELECT SUM(a.amount) FROM supplier_advances a JOIN payments p ON p.id = a.payment_id
                  WHERE a.supplier_id = ? AND a.status = '${DocStatus.active}' AND ${BalanceService.countedPayment('p')}), 0) AS paid,
        COALESCE((SELECT SUM(x.amount) FROM supplier_advance_allocations x
                  JOIN supplier_advances a ON a.id = x.advance_id
                  WHERE a.supplier_id = ? AND x.status = '${DocStatus.active}'), 0) AS allocated
      ''',
      variables: [Variable.withInt(supplierId), Variable.withBool(pending), Variable.withInt(supplierId)],
    ).getSingle();
    return AdvanceBalance(paid: row.read<int>('paid'), allocated: row.read<int>('allocated'));
  }

  /// The supplier's active advances whose payment counts (not a bounced or,
  /// unless the setting says so, a pending cheque).
  Future<Set<int>> _countedAdvanceIds(int supplierId) async {
    final pending = await BalanceService(db).countPendingCheques();
    final rows = await db.customSelect(
      "SELECT a.id AS id FROM supplier_advances a JOIN payments p ON p.id = a.payment_id "
      "WHERE a.supplier_id = ? AND a.status = '${DocStatus.active}' AND ${BalanceService.countedPayment('p')}",
      variables: [Variable.withInt(supplierId), Variable.withBool(pending)],
    ).get();
    return {for (final r in rows) r.read<int>('id')};
  }

  /// Takes [amount] from [supplierId]'s open advances, oldest first, for the
  /// purchase invoice [invoiceId]. Partial amounts are fine; more than what is
  /// left of the advances, or than what is left to pay on the invoice, is
  /// refused. Returns the allocation rows made.
  Future<List<int>> allocate({
    required int invoiceId,
    required int amount,
    String? note,
    required User user,
  }) {
    return db.transaction(() async {
      _purchaser(user);
      await refuseReadOnly(db, user.id);
      if (amount <= 0) throw ValidationException('المبلغ المخصوم من الدفعة يجب أن يكون أكبر من صفر');
      final inv = await (db.select(db.purchaseInvoices)..where((t) => t.id.equals(invoiceId))).getSingleOrNull();
      if (inv == null) throw ValidationException('فاتورة الشراء غير موجودة');
      if (inv.status != DocStatus.active) throw ValidationException('الفاتورة ${inv.number} ملغاة');
      await refuseLocked(db, inv.date);
      final left = inv.total - await BalanceService(db).paidOnInvoice(RefType.purchaseInvoice, invoiceId);
      if (amount > left) {
        throw ValidationException('المبلغ أكبر من المتبقي على الفاتورة ${inv.number} (${formatMoney(left)})');
      }
      final available = (await balance(inv.supplierId)).remaining;
      if (amount > available) {
        throw ValidationException(
            'المبلغ أكبر من رصيد الدفعات المقدمة المتاح لهذا المورد (${formatMoney(available)})');
      }
      final counted = await _countedAdvanceIds(inv.supplierId);
      final open = (await rows(supplierId: inv.supplierId)).where((r) => r.open && counted.contains(r.advance.id)).toList()
        ..sort((a, b) => a.advance.date.compareTo(b.advance.date) != 0
            ? a.advance.date.compareTo(b.advance.date)
            : a.advance.id - b.advance.id);
      var rest = amount;
      final made = <int>[];
      final day = inv.date;
      for (final r in open) {
        if (rest == 0) break;
        final take = r.remaining < rest ? r.remaining : rest;
        made.add(await db.into(db.supplierAdvanceAllocations).insert(SupplierAdvanceAllocationsCompanion.insert(
              advanceId: r.advance.id,
              invoiceId: invoiceId,
              amount: take,
              date: day,
              note: Value((note ?? '').trim().isEmpty ? null : note!.trim()),
              createdBy: Value(user.id),
            )));
        rest -= take;
        await AuditService(db).log(
          action: AuditAction.create,
          entity: 'advance_allocation',
          entityId: made.last,
          userId: user.id,
          details: 'من ${r.advance.number} على ${inv.number}: ${formatMoney(take)}',
        );
      }
      // A bounced or uncounted cheque can leave the open rows short of the balance.
      if (rest > 0) throw ValidationException('رصيد الدفعات المقدمة لا يكفي (${formatMoney(amount - rest)} فقط)');
      await syncInvoice(invoiceId);
      return made;
    });
  }

  /// Owner only: undoes one allocation (a mistake). The invoice is again
  /// owed that much; the advance has it back. Kept on record as cancelled.
  Future<void> cancelAllocation(int allocationId, {required String reason, required User user}) {
    return db.transaction(() async {
      _owner(user);
      if (reason.trim().isEmpty) throw ValidationException('اكتب سبب التصحيح');
      final a = await (db.select(db.supplierAdvanceAllocations)..where((t) => t.id.equals(allocationId)))
          .getSingleOrNull();
      if (a == null) throw ValidationException('التوزيع غير موجود');
      if (a.status != DocStatus.active) throw ValidationException('هذا التوزيع ملغى من قبل');
      final inv = await (db.select(db.purchaseInvoices)..where((t) => t.id.equals(a.invoiceId))).getSingle();
      await refuseLocked(db, inv.date);
      await (db.update(db.supplierAdvanceAllocations)..where((t) => t.id.equals(allocationId)))
          .write(const SupplierAdvanceAllocationsCompanion(status: Value(DocStatus.cancelled)));
      await syncInvoice(a.invoiceId);
      await AuditService(db).log(
        action: AuditAction.correct,
        entity: 'advance_allocation',
        entityId: allocationId,
        userId: user.id,
        details: 'الفاتورة ${inv.number}',
        oldValue: formatMoney(a.amount),
        newValue: '0',
        reason: reason.trim(),
      );
    });
  }

  /// Owner only: changes how much an invoice takes from advances, in one
  /// step (its allocations are replaced, the old ones kept as cancelled).
  Future<void> correctInvoiceAllocation(int invoiceId, int newAmount, {required String reason, required User user}) {
    return db.transaction(() async {
      _owner(user);
      if (reason.trim().isEmpty) throw ValidationException('اكتب سبب التصحيح');
      if (newAmount < 0) throw ValidationException('المبلغ لا يكون سالباً');
      final inv = await (db.select(db.purchaseInvoices)..where((t) => t.id.equals(invoiceId))).getSingle();
      await refuseLocked(db, inv.date);
      final before = inv.advanceUsed;
      await (db.update(db.supplierAdvanceAllocations)
            ..where((t) => t.invoiceId.equals(invoiceId) & t.status.equals(DocStatus.active)))
          .write(const SupplierAdvanceAllocationsCompanion(status: Value(DocStatus.cancelled)));
      await syncInvoice(invoiceId);
      if (newAmount > 0) await allocate(invoiceId: invoiceId, amount: newAmount, note: reason, user: user);
      await AuditService(db).log(
        action: AuditAction.correct,
        entity: 'advance_allocation',
        entityId: invoiceId,
        userId: user.id,
        details: 'الخصم من الدفعات المقدمة على الفاتورة ${inv.number}',
        oldValue: formatMoney(before),
        newValue: formatMoney(newAmount),
        reason: reason.trim(),
      );
    });
  }

  /// Keeps the invoice's `advance_used` equal to its active allocations.
  Future<void> syncInvoice(int invoiceId) async {
    final r = await db.customSelect(
      "SELECT COALESCE(SUM(amount), 0) AS s FROM supplier_advance_allocations WHERE invoice_id = ? AND status = 'active'",
      variables: [Variable.withInt(invoiceId)],
    ).getSingle();
    final used = r.read<int>('s');
    final inv = await (db.select(db.purchaseInvoices)..where((t) => t.id.equals(invoiceId))).getSingle();
    if (inv.advanceUsed != used) {
      await (db.update(db.purchaseInvoices)..where((t) => t.id.equals(invoiceId)))
          .write(PurchaseInvoicesCompanion(advanceUsed: Value(used), updatedAt: Value(DateTime.now())));
    }
  }

  /// When an invoice is cancelled, what it took goes back to the advances.
  Future<void> releaseInvoice(int invoiceId) async {
    await (db.update(db.supplierAdvanceAllocations)
          ..where((t) => t.invoiceId.equals(invoiceId) & t.status.equals(DocStatus.active)))
        .write(const SupplierAdvanceAllocationsCompanion(status: Value(DocStatus.cancelled)));
  }

  /// Only while nothing has been taken from it. Its payment is cancelled.
  Future<void> cancel(int id, {required String reason, required User user}) {
    return db.transaction(() async {
      _purchaser(user);
      if (reason.trim().isEmpty) throw ValidationException('سبب الإلغاء مطلوب');
      final row = await this.row(id);
      if (row.advance.status != DocStatus.active) throw ValidationException('الدفعة ملغاة من قبل');
      if (row.used > 0) {
        throw ValidationException('خُصم من هذه الدفعة على فواتير شراء؛ صحّح التوزيع أو ألغِ الفواتير أولاً');
      }
      await PaymentService(db).cancelAdvancePayment(row.advance.paymentId, reason: reason, user: user);
      await (db.update(db.supplierAdvances)..where((t) => t.id.equals(id))).write(SupplierAdvancesCompanion(
          status: const Value(DocStatus.cancelled), updatedAt: Value(DateTime.now())));
      await AuditService(db).log(
          action: AuditAction.cancel, entity: 'supplier_advance', entityId: id, userId: user.id, details: reason.trim());
    });
  }

  /// Taken from advance [id] by active allocations.
  Future<int> used(int id) async {
    final r = await db.customSelect(
      "SELECT COALESCE(SUM(amount), 0) AS u FROM supplier_advance_allocations WHERE advance_id = ? AND status = 'active'",
      variables: [Variable.withInt(id)],
    ).getSingle();
    return r.read<int>('u');
  }

  Future<AdvanceRow> row(int id) async {
    final a = await (db.select(db.supplierAdvances)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (a == null) throw ValidationException('الدفعة المقدمة غير موجودة');
    return _row(a);
  }

  Future<AdvanceRow> _row(SupplierAdvance a) async {
    final supplier = await (db.select(db.suppliers)..where((t) => t.id.equals(a.supplierId))).getSingle();
    final rows = await (db.select(db.supplierAdvanceLists).join([
      innerJoin(db.priceLists, db.priceLists.id.equalsExp(db.supplierAdvanceLists.priceListId)),
      innerJoin(db.brands, db.brands.id.equalsExp(db.supplierAdvanceLists.brandId)),
    ])
          ..where(db.supplierAdvanceLists.advanceId.equals(a.id)))
        .get();
    return AdvanceRow(
      a,
      supplier.name,
      [for (final r in rows) AdvanceList(r.readTable(db.brands).name, r.readTable(db.priceLists))],
      await used(a.id),
    );
  }

  /// Every advance of [supplierId] (or all), newest first.
  Future<List<AdvanceRow>> rows({int? supplierId, bool openOnly = false}) async {
    final all = await (db.select(db.supplierAdvances)
          ..where((t) => supplierId == null ? const Constant(true) : t.supplierId.equals(supplierId))
          ..orderBy([(t) => OrderingTerm.desc(t.id)]))
        .get();
    final result = [for (final a in all) await _row(a)];
    return openOnly ? result.where((r) => r.open).toList() : result;
  }

  /// The uses of advances, for one advance, one invoice or one supplier.
  Future<List<AllocationRow>> allocations({int? advanceId, int? invoiceId, int? supplierId}) async {
    final q = db.select(db.supplierAdvanceAllocations).join([
      innerJoin(db.supplierAdvances, db.supplierAdvances.id.equalsExp(db.supplierAdvanceAllocations.advanceId)),
      innerJoin(db.purchaseInvoices, db.purchaseInvoices.id.equalsExp(db.supplierAdvanceAllocations.invoiceId)),
    ]);
    if (advanceId != null) q.where(db.supplierAdvanceAllocations.advanceId.equals(advanceId));
    if (invoiceId != null) q.where(db.supplierAdvanceAllocations.invoiceId.equals(invoiceId));
    if (supplierId != null) q.where(db.supplierAdvances.supplierId.equals(supplierId));
    q.orderBy([OrderingTerm.desc(db.supplierAdvanceAllocations.id)]);
    return [
      for (final r in await q.get())
        AllocationRow(
          r.readTable(db.supplierAdvanceAllocations),
          r.readTable(db.supplierAdvances).number,
          r.readTable(db.purchaseInvoices).number,
          r.readTable(db.purchaseInvoices).date,
        ),
    ];
  }
}

/// The setting holding the last closed day (seconds since 1970); see
/// ledger_setup.dart. Nothing dated on or before it may change.
Future<void> refuseLocked(AppDatabase db, DateTime date) async {
  final row = await (db.select(db.appSettings)..where((t) => t.keyName.equals(booksLockedUntilKey))).getSingleOrNull();
  final until = int.tryParse(row?.val ?? '');
  if (until == null || until < 0) return;
  if (date.millisecondsSinceEpoch ~/ 1000 <= until) {
    throw ValidationException('هذا التاريخ داخل فترة مقفلة؛ لا يُعدّل فيها شيء. يمكن للمدير إعادة فتح الفترة من المحاسبة.');
  }
}
