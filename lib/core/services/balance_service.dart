import 'package:drift/drift.dart';

import '../db/database.dart';
import 'doc_types.dart';
import 'settings_service.dart';

/// Balances are calculated from documents every time, never stored or typed.
///
/// Customer (what the customer owes us):
///   opening + active sales invoices − active sale returns
///   + refunds paid to them − payments received from them
///
/// Supplier (what we owe the supplier), the mirror image:
///   opening + active purchase invoices − active purchase returns
///   + refunds received from them − payments made to them
///
/// A payment counts when it is active and either not a cheque, or a cheque
/// that has cleared (or is still pending, if the "count pending cheques"
/// setting is on). A bounced cheque never counts, so the debt comes back.
class BalanceService {
  BalanceService(this.db);

  final AppDatabase db;

  /// SQL condition on a `payments` row aliased [p] that is true when it
  /// counts. [countPending] is bound as the variable at that position.
  static String countedPayment(String p) => '''
    $p.status = '${DocStatus.active}' AND (
      $p.method <> '${PaymentMethod.cheque}' OR EXISTS (
        SELECT 1 FROM cheques ch WHERE ch.payment_id = $p.id AND (
          ch.status = '${ChequeStatus.cleared}' OR
          (ch.status = '${ChequeStatus.pending}' AND ?)
        )
      )
    )''';

  Future<bool> _countPending() =>
      SettingsService(db).getBool(SettingKey.countPendingCheques);

  static String _customerSql(String where) => '''
    SELECT cu.id AS id, cu.opening_balance
      + COALESCE((SELECT SUM(s.total) FROM sales_invoices s
                  WHERE s.customer_id = cu.id AND s.status = '${DocStatus.active}'), 0)
      - COALESCE((SELECT SUM(r.total) FROM returns r
                  WHERE r.kind = '${ReturnKind.sale}' AND r.party_id = cu.id
                    AND r.status = '${DocStatus.active}'), 0)
      + COALESCE((SELECT SUM(p.amount) FROM payments p
                  WHERE p.party_type = '${PartyType.customer}' AND p.party_id = cu.id
                    AND p.direction = '${PaymentDirection.outbound}' AND ${countedPayment('p')}), 0)
      - COALESCE((SELECT SUM(p.amount) FROM payments p
                  WHERE p.party_type = '${PartyType.customer}' AND p.party_id = cu.id
                    AND p.direction = '${PaymentDirection.inbound}' AND ${countedPayment('p')}), 0)
      AS balance
    FROM customers cu $where''';

  static String _supplierSql(String where) => '''
    SELECT su.id AS id, su.opening_balance
      + COALESCE((SELECT SUM(pi.total) FROM purchase_invoices pi
                  WHERE pi.supplier_id = su.id AND pi.status = '${DocStatus.active}'), 0)
      - COALESCE((SELECT SUM(r.total) FROM returns r
                  WHERE r.kind = '${ReturnKind.purchase}' AND r.party_id = su.id
                    AND r.status = '${DocStatus.active}'), 0)
      + COALESCE((SELECT SUM(p.amount) FROM payments p
                  WHERE p.party_type = '${PartyType.supplier}' AND p.party_id = su.id
                    AND p.direction = '${PaymentDirection.inbound}' AND ${countedPayment('p')}), 0)
      - COALESCE((SELECT SUM(p.amount) FROM payments p
                  WHERE p.party_type = '${PartyType.supplier}' AND p.party_id = su.id
                    AND p.direction = '${PaymentDirection.outbound}' AND ${countedPayment('p')}), 0)
      AS balance
    FROM suppliers su $where''';

  Set<ResultSetImplementation> get _tables => {
        db.customers,
        db.suppliers,
        db.salesInvoices,
        db.purchaseInvoices,
        db.returns,
        db.payments,
        db.cheques,
        db.appSettings,
      };

  Future<int> customerBalance(int customerId) async {
    final pending = await _countPending();
    final row = await db.customSelect(
      _customerSql('WHERE cu.id = ?'),
      variables: [Variable.withBool(pending), Variable.withBool(pending), Variable.withInt(customerId)],
    ).getSingle();
    return row.read<int>('balance');
  }

  Future<int> supplierBalance(int supplierId) async {
    final pending = await _countPending();
    final row = await db.customSelect(
      _supplierSql('WHERE su.id = ?'),
      variables: [Variable.withBool(pending), Variable.withBool(pending), Variable.withInt(supplierId)],
    ).getSingle();
    return row.read<int>('balance');
  }

  /// Every customer's balance by id; updates when any document changes.
  Stream<Map<int, int>> watchCustomerBalances() async* {
    final pending = await _countPending();
    yield* db
        .customSelect(
          _customerSql(''),
          variables: [Variable.withBool(pending), Variable.withBool(pending)],
          readsFrom: _tables,
        )
        .watch()
        .map((rows) => {for (final r in rows) r.read<int>('id'): r.read<int>('balance')});
  }

  Stream<Map<int, int>> watchSupplierBalances() async* {
    final pending = await _countPending();
    yield* db
        .customSelect(
          _supplierSql(''),
          variables: [Variable.withBool(pending), Variable.withBool(pending)],
          readsFrom: _tables,
        )
        .watch()
        .map((rows) => {for (final r in rows) r.read<int>('id'): r.read<int>('balance')});
  }

  /// What has been paid against one invoice (counted payments linked to it,
  /// and for a purchase the part of a supplier advance it used).
  Future<int> paidOnInvoice(String refType, int invoiceId) async {
    final pending = await _countPending();
    final row = await db.customSelect(
      'SELECT COALESCE(SUM(p.amount), 0) AS paid FROM payments p '
      'WHERE p.invoice_ref_type = ? AND p.invoice_ref_id = ? AND ${countedPayment('p')}',
      variables: [Variable.withString(refType), Variable.withInt(invoiceId), Variable.withBool(pending)],
    ).getSingle();
    var paid = row.read<int>('paid');
    if (refType == RefType.purchaseInvoice) {
      final inv = await (db.select(db.purchaseInvoices)..where((t) => t.id.equals(invoiceId))).getSingleOrNull();
      paid += inv?.advanceUsed ?? 0;
    }
    return paid;
  }
}
