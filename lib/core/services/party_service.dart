import 'package:drift/drift.dart';

import '../db/database.dart';
import '../search_text.dart';
import 'audit_service.dart';
import 'errors.dart';
import 'product_service.dart';

class CustomerInput {
  const CustomerInput({
    required this.name,
    this.phone,
    this.address,
    this.openingBalance = 0,
    this.creditLimit = 0,
    this.priceLevel = PriceLevel.retail,
    this.notes,
    this.isActive = true,
  });

  final String name;
  final String? phone;
  final String? address;
  final int openingBalance;
  final int creditLimit;
  final String priceLevel;
  final String? notes;
  final bool isActive;
}

class SupplierInput {
  const SupplierInput({
    required this.name,
    this.phone,
    this.address,
    this.openingBalance = 0,
    this.notes,
    this.isActive = true,
  });

  final String name;
  final String? phone;
  final String? address;
  final int openingBalance;
  final String? notes;
  final bool isActive;
}

/// Customers and suppliers. Balances are calculated from documents
/// (phase 3), never typed in; only the opening balance is entered here.
class PartyService {
  PartyService(this.db);

  final AppDatabase db;

  Stream<List<Customer>> watchCustomers({String search = '', bool activeOnly = false}) {
    return (db.select(db.customers)..orderBy([(t) => OrderingTerm(expression: t.name)]))
        .watch()
        .map((all) => all
            .where((c) => !activeOnly || c.isActive)
            .where((c) => matchesSearch(search, [c.name, c.phone, c.address]))
            .toList());
  }

  Stream<List<Supplier>> watchSuppliers({String search = ''}) {
    return (db.select(db.suppliers)..orderBy([(t) => OrderingTerm(expression: t.name)]))
        .watch()
        .map((all) => all
            .where((s) => matchesSearch(search, [s.name, s.phone, s.address]))
            .toList());
  }

  Future<Customer> customer(int id) =>
      (db.select(db.customers)..where((t) => t.id.equals(id))).getSingle();

  Future<int> saveCustomer(CustomerInput input, {int? id, int? userId}) {
    return db.transaction(() async {
      final name = _required(input.name);
      if (!PriceLevel.all.contains(input.priceLevel)) {
        throw ArgumentError.value(input.priceLevel, 'priceLevel');
      }
      if (input.creditLimit < 0) throw ValidationException('حد الائتمان لا يمكن أن يكون سالباً');
      final companion = CustomersCompanion(
        name: Value(name),
        phone: Value(_blankToNull(input.phone)),
        address: Value(_blankToNull(input.address)),
        openingBalance: Value(input.openingBalance),
        creditLimit: Value(input.creditLimit),
        priceLevel: Value(input.priceLevel),
        notes: Value(_blankToNull(input.notes)),
        isActive: Value(input.isActive),
      );
      final savedId = id == null
          ? await db.into(db.customers).insert(companion)
          : await _update(db.customers, id, companion.copyWith(updatedAt: Value(DateTime.now())));
      await AuditService(db).log(
        action: id == null ? AuditAction.create : AuditAction.update,
        entity: 'customer',
        entityId: savedId,
        userId: userId,
      );
      return savedId;
    });
  }

  Future<int> saveSupplier(SupplierInput input, {int? id, int? userId}) {
    return db.transaction(() async {
      final companion = SuppliersCompanion(
        name: Value(_required(input.name)),
        phone: Value(_blankToNull(input.phone)),
        address: Value(_blankToNull(input.address)),
        openingBalance: Value(input.openingBalance),
        notes: Value(_blankToNull(input.notes)),
        isActive: Value(input.isActive),
      );
      final savedId = id == null
          ? await db.into(db.suppliers).insert(companion)
          : await _update(db.suppliers, id, companion.copyWith(updatedAt: Value(DateTime.now())));
      await AuditService(db).log(
        action: id == null ? AuditAction.create : AuditAction.update,
        entity: 'supplier',
        entityId: savedId,
        userId: userId,
      );
      return savedId;
    });
  }

  Future<int> _update<T extends Table, D>(
    TableInfo<T, D> table,
    int id,
    Insertable<D> companion,
  ) async {
    final idColumn = table.columnsByName['id']! as GeneratedColumn<int>;
    await (db.update(table)..where((_) => idColumn.equals(id))).write(companion);
    return id;
  }

  static String _required(String name) {
    final n = name.trim();
    if (n.isEmpty) throw ValidationException('الاسم مطلوب');
    return n;
  }

  static String? _blankToNull(String? s) =>
      (s == null || s.trim().isEmpty) ? null : s.trim();
}
