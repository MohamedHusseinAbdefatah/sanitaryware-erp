import 'package:drift/drift.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import '../money.dart';
import 'audit_service.dart';
import 'balance_service.dart';
import 'doc_types.dart';
import 'errors.dart';
import 'numbering_service.dart';

class ChequeInput {
  const ChequeInput({required this.number, required this.dueDate, this.bank});

  final String number;
  final DateTime dueDate;
  final String? bank;
}

class PaymentInput {
  const PaymentInput({
    required this.partyId,
    required this.amount,
    this.method = PaymentMethod.cash,
    this.cheque,
    this.invoiceId,
    this.date,
    this.notes,
  });

  final int partyId;
  final int amount;
  final String method;

  /// Required when [method] is a cheque.
  final ChequeInput? cheque;

  /// Links the payment to one of the party's invoices; null means "on account".
  final int? invoiceId;
  final DateTime? date;
  final String? notes;
}

class PaymentRow {
  const PaymentRow(this.payment, this.partyName, this.cheque);
  final Payment payment;
  final String partyName;
  final Cheque? cheque;
}

class ChequeRow {
  const ChequeRow(this.cheque, this.payment, this.partyName);
  final Cheque cheque;
  final Payment payment;
  final String partyName;

  bool get isReceived => payment.direction == PaymentDirection.inbound;
}

/// Money received from customers and paid to suppliers, with cheques.
class PaymentService {
  PaymentService(this.db);

  final AppDatabase db;

  /// From a customer. Anyone may receive.
  Future<Payment> receive(PaymentInput input, {int? userId}) => _post(
        input,
        direction: PaymentDirection.inbound,
        partyType: PartyType.customer,
        userId: userId,
      );

  /// To a supplier. Admin only (enforced by the screen and here).
  Future<Payment> pay(PaymentInput input, {required User user}) async {
    if (!user.can(Perm.payOut)) throw ValidationException('الدفع للموردين لصلاحية المحاسبة');
    return _post(
      input,
      direction: PaymentDirection.outbound,
      partyType: PartyType.supplier,
      userId: user.id,
    );
  }

  Future<Payment> _post(
    PaymentInput input, {
    required String direction,
    required String partyType,
    int? userId,
    String? orderRefType,
    int? orderRefId,
  }) {
    return db.transaction(() async {
      await refuseReadOnly(db, userId);
      if (input.amount <= 0) throw ValidationException('المبلغ يجب أن يكون أكبر من صفر');
      final partyName = await _partyName(partyType, input.partyId);
      if (partyName == null) throw ValidationException('اختر ${partyType == PartyType.customer ? 'العميل' : 'المورد'}');

      final cheque = input.cheque;
      if (input.method == PaymentMethod.cheque) {
        if (cheque == null || cheque.number.trim().isEmpty) {
          throw ValidationException('رقم الشيك مطلوب');
        }
      } else if (input.method != PaymentMethod.cash && input.method != PaymentMethod.bank) {
        throw ArgumentError.value(input.method, 'method');
      }

      String? refType = orderRefType;
      if (input.invoiceId != null) {
        refType = partyType == PartyType.customer ? RefType.salesInvoice : RefType.purchaseInvoice;
        final remaining = await invoiceRemaining(refType, input.invoiceId!, partyId: input.partyId);
        if (input.amount > remaining) {
          throw ValidationException(
            'المبلغ أكبر من المتبقي على الفاتورة (${formatMoney(remaining)}). '
            'سجّل الزيادة كدفعة تحت الحساب بدون ربط بفاتورة.',
          );
        }
      }

      final id = await db.into(db.payments).insert(PaymentsCompanion.insert(
            number: await NumberingService(db).next('payment'),
            date: input.date ?? DateTime.now(),
            direction: direction,
            partyType: partyType,
            partyId: input.partyId,
            amount: input.amount,
            method: input.method,
            invoiceRefType: Value(refType),
            invoiceRefId: Value(input.invoiceId ?? orderRefId),
            notes: Value(_blankToNull(input.notes)),
            createdBy: Value(userId),
          ));
      if (input.method == PaymentMethod.cheque) {
        await db.into(db.cheques).insert(ChequesCompanion.insert(
              paymentId: id,
              chequeNo: cheque!.number.trim(),
              bank: Value(_blankToNull(cheque.bank)),
              dueDate: cheque.dueDate,
            ));
      }
      final payment = await (db.select(db.payments)..where((t) => t.id.equals(id))).getSingle();
      await AuditService(db).log(
        action: AuditAction.create,
        entity: 'payment',
        entityId: id,
        userId: userId,
        details: '${payment.number} $partyName ${formatMoney(input.amount)}',
      );
      return payment;
    });
  }

  /// An advance from a customer against a sales order. It counts in the
  /// customer's balance at once (they are owed credit until invoices use it).
  Future<Payment> receiveAdvance(
    int salesOrderId, {
    required int amount,
    String method = PaymentMethod.cash,
    ChequeInput? cheque,
    String? notes,
    int? userId,
  }) async {
    final order = await (db.select(db.salesOrders)..where((t) => t.id.equals(salesOrderId))).getSingleOrNull();
    if (order == null) throw ValidationException('أمر البيع غير موجود');
    if (order.status == 'cancelled') throw ValidationException('أمر البيع ملغي');
    return _post(
      PaymentInput(partyId: order.customerId, amount: amount, method: method, cheque: cheque, notes: notes),
      direction: PaymentDirection.inbound,
      partyType: PartyType.customer,
      userId: userId,
      orderRefType: RefType.salesOrder,
      orderRefId: salesOrderId,
    );
  }

  /// An advance to a supplier against a purchase order. Admin only.
  Future<Payment> payAdvance(
    int purchaseOrderId, {
    required int amount,
    String method = PaymentMethod.cash,
    ChequeInput? cheque,
    String? notes,
    required User user,
  }) async {
    if (!user.can(Perm.payOut)) throw ValidationException('الدفع للموردين لصلاحية المحاسبة');
    final order =
        await (db.select(db.purchaseOrders)..where((t) => t.id.equals(purchaseOrderId))).getSingleOrNull();
    if (order == null) throw ValidationException('أمر الشراء غير موجود');
    if (order.status == 'cancelled') throw ValidationException('أمر الشراء ملغي');
    return _post(
      PaymentInput(partyId: order.supplierId, amount: amount, method: method, cheque: cheque, notes: notes),
      direction: PaymentDirection.outbound,
      partyType: PartyType.supplier,
      userId: user.id,
      orderRefType: RefType.purchaseOrder,
      orderRefId: purchaseOrderId,
    );
  }

  /// The payment of a supplier advance locked to price lists. Admin only;
  /// the advance service links it to its advance.
  Future<Payment> payLockedAdvance({
    required int supplierId,
    required int amount,
    String method = PaymentMethod.cash,
    ChequeInput? cheque,
    DateTime? date,
    String? notes,
    required User user,
  }) {
    if (!user.can(Perm.payOut)) throw ValidationException('الدفع للموردين لصلاحية المحاسبة');
    return _post(
      PaymentInput(partyId: supplierId, amount: amount, method: method, cheque: cheque, date: date, notes: notes),
      direction: PaymentDirection.outbound,
      partyType: PartyType.supplier,
      userId: user.id,
      orderRefType: RefType.supplierAdvance,
      orderRefId: 0,
    );
  }

  /// Every payment linked to one invoice (cancelled ones too), oldest first.
  Future<List<Payment>> onInvoice(String refType, int invoiceId) => (db.select(db.payments)
        ..where((t) => t.invoiceRefType.equals(refType) & t.invoiceRefId.equals(invoiceId))
        ..orderBy([(t) => OrderingTerm.asc(t.date), (t) => OrderingTerm.asc(t.id)]))
      .get();

  /// Advances paid so far against an order (counted payments only).
  Future<int> advancesOn(String orderRefType, int orderId) =>
      BalanceService(db).paidOnInvoice(orderRefType, orderId);

  /// Moves advances taken on an order onto the invoice it produced, oldest
  /// first, as long as each whole advance still fits in what the invoice has
  /// left to pay. The party's balance does not change (the money was already
  /// counted); the invoice now shows it as paid. An advance too big for the
  /// rest of the invoice stays on the order. Returns the amount applied.
  Future<int> applyAdvances({
    required String orderRefType,
    required int orderId,
    required String invoiceRefType,
    required int invoiceId,
    required int invoiceTotal,
  }) async {
    final onInvoice = await (db.select(db.payments)
          ..where((t) =>
              t.invoiceRefType.equals(invoiceRefType) &
              t.invoiceRefId.equals(invoiceId) &
              t.status.equals(DocStatus.active)))
        .get();
    var remaining = invoiceTotal - onInvoice.fold<int>(0, (a, p) => a + p.amount);
    final advances = await (db.select(db.payments)
          ..where((t) =>
              t.invoiceRefType.equals(orderRefType) &
              t.invoiceRefId.equals(orderId) &
              t.status.equals(DocStatus.active))
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();
    var applied = 0;
    for (final a in advances) {
      if (a.amount > remaining) continue;
      await (db.update(db.payments)..where((t) => t.id.equals(a.id))).write(PaymentsCompanion(
        invoiceRefType: Value(invoiceRefType),
        invoiceRefId: Value(invoiceId),
        updatedAt: Value(DateTime.now()),
      ));
      remaining -= a.amount;
      applied += a.amount;
    }
    return applied;
  }

  /// Invoice total minus what has already been paid against it. Throws if
  /// the invoice is not the party's or is cancelled.
  Future<int> invoiceRemaining(String refType, int invoiceId, {required int partyId}) async {
    final int total;
    if (refType == RefType.salesInvoice) {
      final inv = await (db.select(db.salesInvoices)..where((t) => t.id.equals(invoiceId))).getSingle();
      if (inv.customerId != partyId) throw ValidationException('الفاتورة ليست لهذا العميل');
      if (inv.status != DocStatus.active) throw ValidationException('الفاتورة ملغاة');
      total = inv.total;
    } else {
      final inv = await (db.select(db.purchaseInvoices)..where((t) => t.id.equals(invoiceId))).getSingle();
      if (inv.supplierId != partyId) throw ValidationException('الفاتورة ليست لهذا المورد');
      if (inv.status != DocStatus.active) throw ValidationException('الفاتورة ملغاة');
      total = inv.total;
    }
    return total - await BalanceService(db).paidOnInvoice(refType, invoiceId);
  }

  /// Set only by the advance service while it cancels its own payment.
  bool _cancellingAdvance = false;

  /// Cancels the payment of a supplier advance; only the advance service.
  Future<void> cancelAdvancePayment(int paymentId, {required String reason, required User user}) async {
    _cancellingAdvance = true;
    try {
      await cancel(paymentId, reason: reason, user: user);
    } finally {
      _cancellingAdvance = false;
    }
  }

  /// Admin only. The payment stays on record as cancelled; a cheque with it
  /// is cancelled too.
  Future<void> cancel(int paymentId, {required String reason, required User user}) {
    return db.transaction(() async {
      if (!user.can(Perm.payOut)) throw ValidationException('إلغاء المدفوعات لصلاحية المحاسبة');
      if (reason.trim().isEmpty) throw ValidationException('سبب الإلغاء مطلوب');
      final p = await (db.select(db.payments)..where((t) => t.id.equals(paymentId))).getSingle();
      if (p.status == DocStatus.cancelled) throw ValidationException('الدفعة ${p.number} ملغاة من قبل');
      if (p.invoiceRefType == RefType.supplierAdvance && !_cancellingAdvance) {
        throw ValidationException('هذه دفعة مقدمة بسعر قائمة؛ تُلغى من شاشة الدفعات المقدمة للمورد');
      }
      final note = 'سبب الإلغاء: ${reason.trim()}';
      await (db.update(db.payments)..where((t) => t.id.equals(paymentId))).write(PaymentsCompanion(
            status: const Value(DocStatus.cancelled),
            notes: Value(p.notes == null ? note : '${p.notes}\n$note'),
            updatedAt: Value(DateTime.now()),
          ));
      await (db.update(db.cheques)..where((t) => t.paymentId.equals(paymentId))).write(
        ChequesCompanion(status: const Value(ChequeStatus.cancelled), updatedAt: Value(DateTime.now())),
      );
      await AuditService(db).log(
        action: AuditAction.cancel,
        entity: 'payment',
        entityId: paymentId,
        userId: user.id,
        details: '${p.number}: ${reason.trim()}',
      );
    });
  }

  /// Pending → cleared: the money is in (or out of) the bank.
  Future<void> clearCheque(int chequeId, {required User user}) =>
      _setCheque(chequeId, ChequeStatus.cleared, user: user);

  /// Pending → bounced: the payment stops counting, so the debt returns.
  Future<void> bounceCheque(int chequeId, {required String reason, required User user}) async {
    if (reason.trim().isEmpty) throw ValidationException('سبب الرفض مطلوب');
    return _setCheque(chequeId, ChequeStatus.bounced, user: user, reason: reason.trim());
  }

  Future<void> _setCheque(int chequeId, String status, {required User user, String? reason}) {
    return db.transaction(() async {
      if (!user.can(Perm.payOut)) throw ValidationException('تحديث حالة الشيكات لصلاحية المحاسبة');
      final ch = await (db.select(db.cheques)..where((t) => t.id.equals(chequeId))).getSingle();
      if (ch.status != ChequeStatus.pending) {
        throw ValidationException('الشيك ${ch.chequeNo} ليس تحت التحصيل');
      }
      await (db.update(db.cheques)..where((t) => t.id.equals(chequeId))).write(
        ChequesCompanion(status: Value(status), updatedAt: Value(DateTime.now())),
      );
      await AuditService(db).log(
        action: AuditAction.update,
        entity: 'cheque',
        entityId: chequeId,
        userId: user.id,
        details: '${ch.chequeNo}: $status${reason == null ? '' : ' — $reason'}',
      );
    });
  }

  /// Newest first. [direction] filters received or paid.
  Stream<List<PaymentRow>> watchPayments({String? direction, DateTime? from, DateTime? to}) {
    final query = db.select(db.payments).join([
      leftOuterJoin(db.customers,
          db.customers.id.equalsExp(db.payments.partyId) & db.payments.partyType.equals(PartyType.customer)),
      leftOuterJoin(db.suppliers,
          db.suppliers.id.equalsExp(db.payments.partyId) & db.payments.partyType.equals(PartyType.supplier)),
      leftOuterJoin(db.cheques, db.cheques.paymentId.equalsExp(db.payments.id)),
    ]);
    if (direction != null) query.where(db.payments.direction.equals(direction));
    if (from != null) {
      query.where(db.payments.date.isBiggerOrEqualValue(DateTime(from.year, from.month, from.day)));
    }
    if (to != null) {
      query.where(db.payments.date.isSmallerThanValue(DateTime(to.year, to.month, to.day + 1)));
    }
    query.orderBy([OrderingTerm.desc(db.payments.id)]);
    return query.watch().map((rows) => [
          for (final r in rows)
            PaymentRow(
              r.readTable(db.payments),
              r.readTableOrNull(db.customers)?.name ??
                  r.readTableOrNull(db.suppliers)?.name ??
                  'نقدي',
              r.readTableOrNull(db.cheques),
            ),
        ]);
  }

  /// The cheque register, by due date (earliest first).
  Stream<List<ChequeRow>> watchCheques({String? status}) {
    final query = db.select(db.cheques).join([
      innerJoin(db.payments, db.payments.id.equalsExp(db.cheques.paymentId)),
      leftOuterJoin(db.customers,
          db.customers.id.equalsExp(db.payments.partyId) & db.payments.partyType.equals(PartyType.customer)),
      leftOuterJoin(db.suppliers,
          db.suppliers.id.equalsExp(db.payments.partyId) & db.payments.partyType.equals(PartyType.supplier)),
    ]);
    if (status != null) query.where(db.cheques.status.equals(status));
    query.orderBy([OrderingTerm(expression: db.cheques.dueDate)]);
    return query.watch().map((rows) => [
          for (final r in rows)
            ChequeRow(
              r.readTable(db.cheques),
              r.readTable(db.payments),
              r.readTableOrNull(db.customers)?.name ?? r.readTableOrNull(db.suppliers)?.name ?? '',
            ),
        ]);
  }

  /// Active invoices of a party that still have something left to pay,
  /// oldest first, with the remaining amount.
  Future<List<(int id, String number, DateTime date, int remaining)>> openInvoices(
    String partyType,
    int partyId,
  ) async {
    final refType = partyType == PartyType.customer ? RefType.salesInvoice : RefType.purchaseInvoice;
    final List<(int, String, DateTime, int)> invoices = partyType == PartyType.customer
        ? [
            for (final i in await (db.select(db.salesInvoices)
                  ..where((t) => t.customerId.equals(partyId) & t.status.equals(DocStatus.active))
                  ..orderBy([(t) => OrderingTerm(expression: t.id)]))
                .get())
              (i.id, i.number, i.date, i.total),
          ]
        : [
            for (final i in await (db.select(db.purchaseInvoices)
                  ..where((t) => t.supplierId.equals(partyId) & t.status.equals(DocStatus.active))
                  ..orderBy([(t) => OrderingTerm(expression: t.id)]))
                .get())
              (i.id, i.number, i.date, i.total),
          ];
    final balances = BalanceService(db);
    final result = <(int, String, DateTime, int)>[];
    for (final (id, number, date, total) in invoices) {
      final remaining = total - await balances.paidOnInvoice(refType, id);
      if (remaining > 0) result.add((id, number, date, remaining));
    }
    return result;
  }

  Future<String?> _partyName(String partyType, int id) async {
    if (partyType == PartyType.customer) {
      final c = await (db.select(db.customers)..where((t) => t.id.equals(id))).getSingleOrNull();
      if (c != null && !c.isActive) throw ValidationException('العميل "${c.name}" موقوف');
      return c?.name;
    }
    final s = await (db.select(db.suppliers)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (s != null && !s.isActive) throw ValidationException('المورد "${s.name}" موقوف');
    return s?.name;
  }

  static String? _blankToNull(String? s) =>
      (s == null || s.trim().isEmpty) ? null : s.trim();
}
