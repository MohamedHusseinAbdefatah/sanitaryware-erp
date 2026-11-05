import 'package:drift/drift.dart';

import '../db/database.dart';
import '../search_text.dart';
import 'errors.dart';

/// Categories, brands and units: short lists with add and rename.
class CatalogService {
  CatalogService(this.db);

  final AppDatabase db;

  /// Main categories, without subcategories.
  Stream<List<Category>> watchCategories() => (db.select(db.categories)
        ..where((t) => t.parentId.isNull())
        ..orderBy([(t) => OrderingTerm(expression: t.nameAr)]))
      .watch();

  /// Categories and subcategories together.
  Stream<List<Category>> watchAllCategories() =>
      (db.select(db.categories)..orderBy([(t) => OrderingTerm(expression: t.nameAr)])).watch();

  /// Subcategories only.
  Stream<List<Category>> watchSubcategories() => (db.select(db.categories)
        ..where((t) => t.parentId.isNotNull())
        ..orderBy([(t) => OrderingTerm(expression: t.nameAr)]))
      .watch();

  Stream<List<Brand>> watchBrands() =>
      (db.select(db.brands)..orderBy([(t) => OrderingTerm(expression: t.name)])).watch();

  Stream<List<Unit>> watchUnits() =>
      (db.select(db.units)..orderBy([(t) => OrderingTerm(expression: t.id)])).watch();

  /// The usual units for a sanitaryware shop; only meters allow fractions.
  Future<void> seedDefaultUnits() async {
    if ((await db.select(db.units).get()).isNotEmpty) return;
    for (final (name, decimal) in [
      ('قطعة', false),
      ('كرتونة', false),
      ('طقم', false),
      ('متر', true),
    ]) {
      await db.into(db.units).insert(
            UnitsCompanion.insert(nameAr: name, allowDecimal: Value(decimal)),
          );
    }
  }

  /// A category, or a subcategory when [parentId] is given. A name must be
  /// unique under its own parent.
  Future<int> saveCategory({int? id, required String name, int? parentId}) async {
    final n = await _checkName(name, (await db.select(db.categories).get())
        .where((c) => c.id != id && c.parentId == parentId)
        .map((c) => c.nameAr));
    if (id == null) {
      return db.into(db.categories).insert(CategoriesCompanion.insert(nameAr: n, parentId: Value(parentId)));
    }
    await (db.update(db.categories)..where((t) => t.id.equals(id))).write(
      CategoriesCompanion(nameAr: Value(n), updatedAt: Value(DateTime.now())),
    );
    return id;
  }

  Future<int> saveBrand({int? id, required String name}) async {
    final n = await _checkName(name, (await db.select(db.brands).get())
        .where((b) => b.id != id)
        .map((b) => b.name));
    if (id == null) {
      return db.into(db.brands).insert(BrandsCompanion.insert(name: n));
    }
    await (db.update(db.brands)..where((t) => t.id.equals(id))).write(
      BrandsCompanion(name: Value(n), updatedAt: Value(DateTime.now())),
    );
    return id;
  }

  Future<int> saveUnit({int? id, required String name, required bool allowDecimal}) async {
    final n = await _checkName(name, (await db.select(db.units).get())
        .where((u) => u.id != id)
        .map((u) => u.nameAr));
    if (id == null) {
      return db.into(db.units).insert(
            UnitsCompanion.insert(nameAr: n, allowDecimal: Value(allowDecimal)),
          );
    }
    await (db.update(db.units)..where((t) => t.id.equals(id))).write(
      UnitsCompanion(
        nameAr: Value(n),
        allowDecimal: Value(allowDecimal),
        updatedAt: Value(DateTime.now()),
      ),
    );
    return id;
  }

  Future<String> _checkName(String name, Iterable<String> others) async {
    final n = name.trim();
    if (n.isEmpty) throw ValidationException('الاسم مطلوب');
    final folded = foldForSearch(n);
    if (others.any((o) => foldForSearch(o) == folded)) {
      throw ValidationException('الاسم "$n" موجود من قبل');
    }
    return n;
  }
}
