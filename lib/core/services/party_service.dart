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
    this.categoryId,
    this.discountBp = 0,
    this.notes,
    this.isActive = true,
    this.email,
    this.taxNumber,
    this.paymentTermsDays,
  });

  final String name;
  final String? phone;
  final String? address;
  final int openingBalance;
  final int creditLimit;

  /// Null leaves what is saved; empty text clears it.
  final String? email;
  final String? taxNumber;

  /// Days from a credit invoice to its due date (0 = due at once); null
  /// leaves what is saved.
  final int? paymentTermsDays;

  /// The old fixed level; used only to pick the starting category when
  /// [categoryId] is not given.
  final String priceLevel;

  /// The customer category (retail, wholesale, projects, engineers...).
  final int? categoryId;

  /// Usual discount in basis points (1000 = 10%).
  final int discountBp;
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
    this.email,
    this.taxNumber,
    this.leadTimeDays,
  });

  final String name;
  final String? phone;
  final String? address;
  final int openingBalance;
  final String? notes;
  final bool isActive;

  /// Null leaves what is saved; empty text clears it.
  final String? email;
  final String? taxNumber;

  /// Usual days from ordering to delivery (0 = not known); null leaves what
  /// is saved.
  final int? leadTimeDays;
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
            .where((c) => matchesSearch(search, [c.name, c.phone, c.address, c.email, c.taxNumber]))
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
      if (input.discountBp < 0 || input.discountBp > 10000) {
        throw ValidationException('نسبة الخصم يجب أن تكون بين 0 و 100');
      }
      if (input.creditLimit < 0) throw ValidationException('حد الائتمان لا يمكن أن يكون سالباً');
      final terms = input.paymentTermsDays;
      if (terms != null && (terms < 0 || terms > 365)) {
        throw ValidationException('مدة السداد بين 0 و 365 يوماً');
      }
      final categoryId = input.categoryId ??
          AppDatabase.starterCategories.indexWhere((c) => c.$3 == input.priceLevel) + 1;
      final category =
          await (db.select(db.customerCategories)..where((c) => c.id.equals(categoryId))).getSingleOrNull();
      if (category == null) throw ValidationException('اختر فئة العميل');
      final companion = CustomersCompanion(
        categoryId: Value(categoryId),
        name: Value(name),
        phone: Value(_blankToNull(input.phone)),
        address: Value(_blankToNull(input.address)),
        openingBalance: Value(input.openingBalance),
        creditLimit: Value(input.creditLimit),
        priceLevel: Value(input.priceLevel),
        discountBp: Value(input.discountBp),
        notes: Value(_blankToNull(input.notes)),
        isActive: Value(input.isActive),
        email: input.email == null ? const Value.absent() : Value(_blankToNull(input.email)),
        taxNumber: input.taxNumber == null ? const Value.absent() : Value(_blankToNull(input.taxNumber)),
        paymentTermsDays: terms == null ? const Value.absent() : Value(terms),
      );
      final before = id == null
          ? null
          : await (db.select(db.customers)..where((t) => t.id.equals(id))).getSingle();
      final savedId = id == null
          ? await db.into(db.customers).insert(companion)
          : await _update(db.customers, id, companion.copyWith(updatedAt: Value(DateTime.now())));
      final after = await (db.select(db.customers)..where((t) => t.id.equals(savedId))).getSingle();
      await AuditService(db).log(
        action: id == null ? AuditAction.create : AuditAction.update,
        entity: 'customer',
        entityId: savedId,
        userId: userId,
        details: before == null ? null : auditChanges(before.toJson(), after.toJson()),
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
        email: input.email == null ? const Value.absent() : Value(_blankToNull(input.email)),
        taxNumber: input.taxNumber == null ? const Value.absent() : Value(_blankToNull(input.taxNumber)),
        leadTimeDays: input.leadTimeDays == null ? const Value.absent() : Value(input.leadTimeDays!.clamp(0, 365)),
      );
      final before = id == null
          ? null
          : await (db.select(db.suppliers)..where((t) => t.id.equals(id))).getSingle();
      final savedId = id == null
          ? await db.into(db.suppliers).insert(companion)
          : await _update(db.suppliers, id, companion.copyWith(updatedAt: Value(DateTime.now())));
      final after = await (db.select(db.suppliers)..where((t) => t.id.equals(savedId))).getSingle();
      await AuditService(db).log(
        action: id == null ? AuditAction.create : AuditAction.update,
        entity: 'supplier',
        entityId: savedId,
        userId: userId,
        details: before == null ? null : auditChanges(before.toJson(), after.toJson()),
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

  // ------------------------------------------------------------- contacts

  /// The people to deal with at a customer, in the order added.
  Stream<List<CustomerContact>> watchContacts(int customerId) => (db.select(db.customerContacts)
        ..where((t) => t.customerId.equals(customerId))
        ..orderBy([(t) => OrderingTerm(expression: t.id)]))
      .watch();

  Future<int> saveContact({
    int? id,
    required int customerId,
    required String name,
    String? role,
    String? phone,
    String? email,
    int? userId,
  }) async {
    final companion = CustomerContactsCompanion(
      customerId: Value(customerId),
      name: Value(_required(name)),
      role: Value(_blankToNull(role)),
      phone: Value(_blankToNull(phone)),
      email: Value(_blankToNull(email)),
    );
    final savedId = id == null
        ? await db.into(db.customerContacts).insert(companion)
        : (await (db.update(db.customerContacts)..where((t) => t.id.equals(id))).write(companion), id).$2;
    await AuditService(db).log(
      action: id == null ? AuditAction.create : AuditAction.update,
      entity: 'customer_contact',
      entityId: savedId,
      userId: userId,
      details: '${name.trim()} (عميل $customerId)',
    );
    return savedId;
  }

  Future<void> deleteContact(int id, {int? userId}) async {
    await (db.delete(db.customerContacts)..where((t) => t.id.equals(id))).go();
    await AuditService(db).log(action: AuditAction.update, entity: 'customer_contact', entityId: id, userId: userId, details: 'حذف');
  }

  // --------------------------------------------------------------- delete

  /// What a customer or supplier is used in ("2 فاتورة بيع، 1 دفعة"); empty
  /// when nothing, so it can be deleted.
  Future<String> usage({required bool customer, required int id}) async {
    final checks = customer
        ? const {
            "SELECT COUNT(*) AS n FROM sales_invoices WHERE customer_id = ?": 'فاتورة بيع',
            "SELECT COUNT(*) AS n FROM sales_orders WHERE customer_id = ?": 'أمر بيع أو عرض سعر',
            "SELECT COUNT(*) AS n FROM payments WHERE party_type = 'customer' AND party_id = ?": 'دفعة',
            "SELECT COUNT(*) AS n FROM reservations WHERE customer_id = ?": 'حجز',
            "SELECT COUNT(*) AS n FROM projects WHERE customer_id = ?": 'مشروع',
          }
        : const {
            "SELECT COUNT(*) AS n FROM purchase_invoices WHERE supplier_id = ?": 'فاتورة شراء',
            "SELECT COUNT(*) AS n FROM purchase_orders WHERE supplier_id = ?": 'أمر شراء',
            "SELECT COUNT(*) AS n FROM payments WHERE party_type = 'supplier' AND party_id = ?": 'دفعة',
            "SELECT COUNT(*) AS n FROM supplier_advances WHERE supplier_id = ?": 'دفعة مقدمة',
            "SELECT COUNT(*) AS n FROM cost_layers WHERE supplier_id = ?": 'رصيد مخزون',
            "SELECT COUNT(*) AS n FROM sales_invoice_items WHERE direct_supplier_id = ?": 'توريد مباشر',
            "SELECT COUNT(*) AS n FROM stock_entries WHERE supplier_id = ?": 'إدخال مخزون',
          };
    final parts = <String>[];
    for (final e in checks.entries) {
      try {
        final n = (await db.customSelect(e.key, variables: [Variable.withInt(id)]).getSingle()).read<int>('n');
        if (n > 0) parts.add('$n ${e.value}');
      } on Object {
        // A table an older database does not have.
      }
    }
    return parts.join('، ');
  }

  /// Deletes a customer or supplier entered by mistake, for good. Only one
  /// with no dealings at all (no invoice, order, payment, advance, stock or
  /// project); one with dealings is switched off instead. Its opening
  /// balance entry leaves the books with it; its contacts, the supplier
  /// discounts set for it, and a lead's link to it go too.
  Future<void> deleteParty({required bool customer, required int id, String reason = '', int? userId}) {
    return db.transaction(() async {
      final used = await usage(customer: customer, id: id);
      if (used.isNotEmpty) {
        throw ValidationException('لا يُحذف لأنه مستخدم في: $used. يمكن إيقافه بدلاً من ذلك.');
      }
      final String name;
      if (customer) {
        final c = await (db.select(db.customers)..where((t) => t.id.equals(id))).getSingle();
        name = c.name;
        await (db.delete(db.customerContacts)..where((t) => t.customerId.equals(id))).go();
        await db.customStatement('UPDATE leads SET customer_id = NULL WHERE customer_id = ?', [id]);
        await (db.delete(db.customers)..where((t) => t.id.equals(id))).go();
      } else {
        final s = await (db.select(db.suppliers)..where((t) => t.id.equals(id))).getSingle();
        name = s.name;
        await (db.delete(db.buyingPolicies)..where((t) => t.supplierId.equals(id))).go();
        await db.customStatement('UPDATE project_boq_lines SET preferred_supplier_id = NULL WHERE preferred_supplier_id = ?', [id]);
        await (db.delete(db.suppliers)..where((t) => t.id.equals(id))).go();
      }
      // The opening balance entry is rebuilt from nothing: it is voided.
      await db.customStatement('INSERT OR IGNORE INTO ledger_queue (ref_type, ref_id) VALUES (?, ?)',
          [customer ? 'customer_opening' : 'supplier_opening', id]);
      await AuditService(db).log(
        action: AuditAction.delete,
        entity: customer ? 'customer' : 'supplier',
        entityId: id,
        userId: userId,
        details: name,
        reason: reason.trim().isEmpty ? null : reason.trim(),
      );
    });
  }
}
