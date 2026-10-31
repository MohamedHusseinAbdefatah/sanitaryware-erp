import 'package:drift/drift.dart';

import '../db/database.dart';
import 'balance_service.dart';
import 'doc_types.dart';
import 'settings_service.dart';

/// One line of an account statement. [increase] raises the balance (an
/// invoice), [decrease] lowers it (a payment or a return).
class StatementEntry {
  const StatementEntry({
    required this.date,
    required this.kind,
    required this.number,
    required this.increase,
    required this.decrease,
    required this.balance,
    this.note,
  });

  final DateTime date;
  final String kind;
  final String number;
  final int increase;
  final int decrease;

  /// Running balance after this line.
  final int balance;
  final String? note;
}

class Statement {
  const Statement({
    required this.partyName,
    required this.openingBalance,
    required this.entries,
    required this.pendingCheques,
  });

  final String partyName;

  /// Balance before the first day of the range (includes the party's
  /// opening balance and everything earlier).
  final int openingBalance;
  final List<StatementEntry> entries;

  /// Cheques not counted yet (pending, when pending cheques do not count).
  final List<Cheque> pendingCheques;

  int get closingBalance => entries.isEmpty ? openingBalance : entries.last.balance;
  int get totalIncrease => entries.fold(0, (s, e) => s + e.increase);
  int get totalDecrease => entries.fold(0, (s, e) => s + e.decrease);
}

typedef _Raw = ({DateTime date, int order, String kind, String number, int increase, int decrease, String? note});

/// Customer and supplier statements. They use exactly the documents the
/// balance uses, so the closing balance always equals the live balance.
class StatementService {
  StatementService(this.db);

  final AppDatabase db;

  Future<Statement> customer(int customerId, {DateTime? from, DateTime? to}) async {
    final c = await (db.select(db.customers)..where((t) => t.id.equals(customerId))).getSingle();
    final raw = <_Raw>[
      for (final s in await (db.select(db.salesInvoices)
            ..where((t) => t.customerId.equals(customerId) & t.status.equals(DocStatus.active)))
          .get())
        (date: s.date, order: s.id, kind: 'فاتورة بيع', number: s.number, increase: s.total, decrease: 0, note: null),
      for (final r in await (db.select(db.returns)
            ..where((t) =>
                t.kind.equals(ReturnKind.sale) & t.partyId.equals(customerId) & t.status.equals(DocStatus.active)))
          .get())
        (date: r.date, order: r.id, kind: 'مرتجع بيع', number: r.number, increase: 0, decrease: r.total, note: null),
      ...await _payments(PartyType.customer, customerId),
    ];
    return _build(c.name, c.openingBalance, raw, from, to, PartyType.customer, customerId);
  }

  Future<Statement> supplier(int supplierId, {DateTime? from, DateTime? to}) async {
    final s = await (db.select(db.suppliers)..where((t) => t.id.equals(supplierId))).getSingle();
    final raw = <_Raw>[
      for (final p in await (db.select(db.purchaseInvoices)
            ..where((t) => t.supplierId.equals(supplierId) & t.status.equals(DocStatus.active)))
          .get())
        (
          date: p.date,
          order: p.id,
          kind: 'فاتورة شراء',
          number: p.number,
          increase: p.total,
          decrease: 0,
          note: p.supplierInvoiceNo,
        ),
      for (final r in await (db.select(db.returns)
            ..where((t) =>
                t.kind.equals(ReturnKind.purchase) & t.partyId.equals(supplierId) & t.status.equals(DocStatus.active)))
          .get())
        (date: r.date, order: r.id, kind: 'مرتجع شراء', number: r.number, increase: 0, decrease: r.total, note: null),
      ...await _payments(PartyType.supplier, supplierId),
    ];
    return _build(s.name, s.openingBalance, raw, from, to, PartyType.supplier, supplierId);
  }

  /// Counted payments of a party. Money towards us lowers a customer's
  /// balance; money we pay lowers a supplier's. Refunds go the other way.
  Future<List<_Raw>> _payments(String partyType, int partyId) async {
    final pending = await SettingsService(db).getBool(SettingKey.countPendingCheques);
    final rows = await db.customSelect(
      '''
      SELECT p.*, ch.cheque_no AS cheque_no FROM payments p
      LEFT JOIN cheques ch ON ch.payment_id = p.id
      WHERE p.party_type = ? AND p.party_id = ? AND ${BalanceService.countedPayment('p')}
      ''',
      variables: [Variable.withString(partyType), Variable.withInt(partyId), Variable.withBool(pending)],
    ).get();
    final lowering = partyType == PartyType.customer ? PaymentDirection.inbound : PaymentDirection.outbound;
    return [
      for (final r in rows)
        () {
          final p = db.payments.map(r.data);
          final chequeNo = r.readNullable<String>('cheque_no');
          final lowers = p.direction == lowering;
          final kind = p.invoiceRefType == RefType.returnDoc
              ? 'رد قيمة مرتجع'
              : lowers
                  ? (partyType == PartyType.customer ? 'سداد من العميل' : 'دفعة للمورد')
                  : 'رد نقدية';
          return (
            date: p.date,
            order: p.id,
            kind: chequeNo == null ? kind : '$kind (شيك $chequeNo)',
            number: p.number,
            increase: lowers ? 0 : p.amount,
            decrease: lowers ? p.amount : 0,
            note: p.notes,
          );
        }(),
    ];
  }

  Future<Statement> _build(
    String name,
    int opening,
    List<_Raw> raw,
    DateTime? from,
    DateTime? to,
    String partyType,
    int partyId,
  ) async {
    // Oldest first; a document dated the same moment keeps its creation order.
    raw.sort((a, b) {
      final d = a.date.compareTo(b.date);
      return d != 0 ? d : a.order.compareTo(b.order);
    });
    final start = from == null ? null : DateTime(from.year, from.month, from.day);
    final end = to == null ? null : DateTime(to.year, to.month, to.day + 1);
    var running = opening;
    var openingInRange = opening;
    final entries = <StatementEntry>[];
    for (final e in raw) {
      running += e.increase - e.decrease;
      if (start != null && e.date.isBefore(start)) {
        openingInRange = running;
        continue;
      }
      if (end != null && !e.date.isBefore(end)) continue;
      entries.add(StatementEntry(
        date: e.date,
        kind: e.kind,
        number: e.number,
        increase: e.increase,
        decrease: e.decrease,
        balance: running,
        note: e.note,
      ));
    }

    final pending = await SettingsService(db).getBool(SettingKey.countPendingCheques);
    final cheques = pending
        ? <Cheque>[]
        : [
            for (final r in await (db.select(db.cheques).join([
              innerJoin(db.payments, db.payments.id.equalsExp(db.cheques.paymentId)),
            ])
                  ..where(db.payments.partyType.equals(partyType) &
                      db.payments.partyId.equals(partyId) &
                      db.payments.status.equals(DocStatus.active) &
                      db.cheques.status.equals(ChequeStatus.pending))
                  ..orderBy([OrderingTerm(expression: db.cheques.dueDate)]))
                .get())
              r.readTable(db.cheques),
          ];
    return Statement(partyName: name, openingBalance: openingInRange, entries: entries, pendingCheques: cheques);
  }
}
