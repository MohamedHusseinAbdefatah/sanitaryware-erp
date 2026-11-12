import 'package:drift/drift.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import '../money.dart';
import 'audit_service.dart';
import 'buying_policy_service.dart';
import 'doc_types.dart';
import 'errors.dart';
import 'numbering_service.dart';
import 'payment_service.dart';
import 'price_list_service.dart';

/// One locked list of an advance, with its brand name.
class AdvanceList {
  const AdvanceList(this.brandName, this.list);

  final String brandName;
  final PriceList list;
}

class AdvanceRow {
  const AdvanceRow(this.advance, this.supplierName, this.lists, this.used);

  final SupplierAdvance advance;
  final String supplierName;
  final List<AdvanceList> lists;

  /// Taken so far by active purchase invoices.
  final int used;

  int get remaining => advance.amount - used;
  bool get open => advance.status == DocStatus.active && remaining > 0;
}

/// Money paid to a supplier ahead, locked to the price lists of the chosen
/// brands in force that day and the supplier's discounts on them. Goods are
/// taken against it later, on purchase invoices, at those locked prices,
/// whatever newer lists or discounts come after. It counts in the
/// supplier's balance from the day it is paid. Admin only.
class SupplierAdvanceService {
  SupplierAdvanceService(this.db);

  final AppDatabase db;

  void _admin(User user) {
    if (!user.isAdmin) throw ValidationException('الدفعات المقدمة للمدير فقط');
  }

  /// The versions of [brandId] in force on [day] (one per list type).
  Future<List<PriceList>> listsInForce(int brandId, DateTime day) async {
    final all = await (db.select(db.priceLists)..where((l) => l.brandId.equals(brandId))).get();
    return all.where((l) => PriceListService.inForce(l, day)).toList();
  }

  Future<SupplierAdvance> create({
    required int supplierId,
    required int amount,
    required List<int> brandIds,
    String method = PaymentMethod.cash,
    ChequeInput? cheque,
    DateTime? date,
    String? note,
    required User user,
  }) {
    return db.transaction(() async {
      _admin(user);
      if (amount <= 0) throw ValidationException('المبلغ يجب أن يكون أكبر من صفر');
      if (brandIds.isEmpty) throw ValidationException('اختر الماركات التي تثبت الدفعة على قوائمها');
      final day = date ?? DateTime.now();
      final locked = <(int, PriceList)>[];
      for (final b in brandIds.toSet()) {
        final brand = await (db.select(db.brands)..where((t) => t.id.equals(b))).getSingle();
        final lists = await listsInForce(b, day);
        if (lists.isEmpty) {
          throw ValidationException('لا توجد قائمة أسعار سارية اليوم لماركة "${brand.name}"؛ لا يمكن تثبيت السعر');
        }
        for (final l in lists) {
          locked.add((b, l));
        }
      }
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
      for (final (b, l) in locked) {
        await db.into(db.supplierAdvanceLists).insert(
            SupplierAdvanceListsCompanion.insert(advanceId: id, brandId: b, priceListId: l.id));
      }
      final advance = await (db.select(db.supplierAdvances)..where((t) => t.id.equals(id))).getSingle();
      await AuditService(db).log(
        action: AuditAction.create,
        entity: 'supplier_advance',
        entityId: id,
        userId: user.id,
        details: '${advance.number} ${formatMoney(amount)}: ${locked.map((e) => 'PL-${e.$2.id}').join('، ')}',
      );
      return advance;
    });
  }

  /// Only while nothing has been taken against it. Its payment is cancelled.
  Future<void> cancel(int id, {required String reason, required User user}) {
    return db.transaction(() async {
      _admin(user);
      if (reason.trim().isEmpty) throw ValidationException('سبب الإلغاء مطلوب');
      final row = await this.row(id);
      if (row.advance.status != DocStatus.active) throw ValidationException('الدفعة ملغاة من قبل');
      if (row.used > 0) {
        throw ValidationException('سُحبت بضاعة على هذه الدفعة؛ ألغِ فواتير الشراء المرتبطة بها أولاً');
      }
      await PaymentService(db).cancelAdvancePayment(row.advance.paymentId, reason: reason, user: user);
      await (db.update(db.supplierAdvances)..where((t) => t.id.equals(id))).write(SupplierAdvancesCompanion(
          status: const Value(DocStatus.cancelled), updatedAt: Value(DateTime.now())));
      await AuditService(db).log(
          action: AuditAction.cancel, entity: 'supplier_advance', entityId: id, userId: user.id, details: reason.trim());
    });
  }

  Future<int> used(int id) async {
    final r = await db.customSelect(
      "SELECT COALESCE(SUM(advance_used), 0) AS u FROM purchase_invoices WHERE advance_id = ? AND status = 'active'",
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

  /// The locked price of [productId] under this advance: its list price in a
  /// locked version and the supplier's discount on that version as it was on
  /// the advance's day. Null when no locked list has the product.
  Future<BuyQuote?> quote(int advanceId, int productId) async {
    final row = await this.row(advanceId);
    final product = await (db.select(db.products)..where((t) => t.id.equals(productId))).getSingle();
    final lists = PriceListService(db);
    // A list of the product's own brand first.
    final ordered = [
      ...row.lists.where((l) => l.list.brandId == product.brandId),
      ...row.lists.where((l) => l.list.brandId != product.brandId),
    ];
    for (final l in ordered) {
      final q = await lists.quoteIn(l.list.id, productId);
      if (q == null) continue;
      final policy = await BuyingPolicyService(db).policyFor(
        supplierId: row.advance.supplierId,
        list: l.list,
        product: product,
        asOf: row.advance.date,
      );
      return BuyQuote(
        quote: q,
        policy: policy,
        vatStatus: l.list.vatStatus,
        vatRateBp: l.list.vatRateBp ?? product.vatRateBp,
      );
    }
    return null;
  }
}
