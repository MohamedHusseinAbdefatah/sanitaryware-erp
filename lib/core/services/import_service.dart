import 'package:excel/excel.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import '../excel_open.dart';
import '../money.dart';
import '../quantity.dart';
import '../search_text.dart';
import 'audit_service.dart';
import 'catalog_service.dart';
import 'errors.dart';
import 'party_service.dart';
import 'product_service.dart';

enum ImportKind {
  products('الأصناف'),
  customers('العملاء'),
  suppliers('الموردون');

  const ImportKind(this.title);
  final String title;
}

/// A column the import understands: the first header is the one written
/// in the template; the others are spellings people commonly use.
class _Field {
  const _Field(this.key, this.headers, {this.required = false});
  final String key;
  final List<String> headers;
  final bool required;
}

const _fields = {
  ImportKind.products: [
    _Field('code', ['الكود', 'كود', 'كود الصنف', 'code'], required: true),
    _Field('manufacturerCode', ['كود الشركة', 'manufacturer code']),
    _Field('name', ['اسم الصنف', 'الاسم', 'الصنف', 'name'], required: true),
    _Field('category', ['التصنيف', 'الفئة', 'category']),
    _Field('brand', ['الماركة', 'brand']),
    _Field('unit', ['الوحدة', 'unit']),
    _Field('variant', ['اللون', 'color', 'variant']),
    _Field('minStock', ['حد الطلب']),
    _Field('opening', ['رصيد أول المدة', 'الرصيد', 'الكمية']),
    // The actual cost of the opening stock, not a list price.
    _Field('openingCost', ['تكلفة رصيد أول المدة', 'سعر التكلفة', 'التكلفة', 'cost']),
  ],
  ImportKind.customers: [
    _Field('name', ['اسم العميل', 'الاسم', 'العميل', 'name'], required: true),
    _Field('phone', ['التليفون', 'تليفون', 'الهاتف', 'الموبايل', 'phone']),
    _Field('address', ['العنوان', 'address']),
    _Field('opening', ['رصيد أول المدة', 'الرصيد']),
    _Field('creditLimit', ['حد الائتمان']),
    _Field('priceLevel', ['فئة السعر']),
  ],
  ImportKind.suppliers: [
    _Field('name', ['اسم المورد', 'الاسم', 'المورد', 'name'], required: true),
    _Field('phone', ['التليفون', 'تليفون', 'الهاتف', 'الموبايل', 'phone']),
    _Field('address', ['العنوان', 'address']),
    _Field('opening', ['رصيد أول المدة', 'الرصيد']),
  ],
};

/// One sheet row after checking. [errors] empty means it will be imported.
class ImportRow {
  ImportRow(this.rowNumber, this.values);

  /// As Excel numbers it (header is row 1, first data row is 2...).
  final int rowNumber;
  final Map<String, String> values;
  final errors = <String>[];

  bool get ok => errors.isEmpty;

  /// Parsed values ready to save, filled in when the row is valid.
  Object? input;
  int openingQty = 0;
  int? openingCost;
  String? categoryName;
  String? brandName;
}

class ImportPreview {
  ImportPreview(this.kind, this.rows, this.missingColumns, this.columnTitles);

  final ImportKind kind;
  final List<ImportRow> rows;

  /// Required columns the sheet does not have; nothing can be imported.
  final List<String> missingColumns;

  /// Field key -> the template header, for showing the preview.
  final Map<String, String> columnTitles;

  int get okCount => rows.where((r) => r.ok).length;
  int get errorCount => rows.length - okCount;
  bool get canImport => missingColumns.isEmpty && okCount > 0;
}

/// Brings the client's existing product, customer and supplier lists in
/// from Excel: template, preview with an error per row, then one
/// all-or-nothing save of the rows that passed.
class ImportService {
  ImportService(this.db);

  final AppDatabase db;

  static List<String> fieldKeys(ImportKind kind) => [for (final f in _fields[kind]!) f.key];

  static String header(ImportKind kind, String key) =>
      _fields[kind]!.firstWhere((f) => f.key == key).headers.first;

  /// An empty sheet with the expected headers.
  List<int> template(ImportKind kind) {
    final excel = Excel.createExcel();
    final sheetName = kind.title;
    excel.rename(excel.getDefaultSheet()!, sheetName);
    final sheet = excel[sheetName];
    sheet.isRTL = true;
    sheet.appendRow([for (final f in _fields[kind]!) TextCellValue(f.headers.first)]);
    for (var i = 0; i < _fields[kind]!.length; i++) {
      sheet.setColumnWidth(i, i < 2 ? 28 : 16);
    }
    return excel.encode()!;
  }

  Future<ImportPreview> preview(ImportKind kind, List<int> bytes) async {
    final Excel excel;
    try {
      excel = openExcel(bytes);
    } on Object {
      throw ValidationException('الملف ليس ملف Excel صالحاً (xlsx). افتحه في Excel واحفظه من جديد ثم حاول مرة أخرى.');
    }
    final sheet = excel.tables.values.where((t) => t.maxRows > 0).firstOrNull;
    final fields = _fields[kind]!;
    final titles = {for (final f in fields) f.key: f.headers.first};
    if (sheet == null) return ImportPreview(kind, [], [for (final f in fields.where((f) => f.required)) f.headers.first], titles);

    // The header is the first row with any text in it.
    final allRows = sheet.rows;
    final headerIndex = allRows.indexWhere((r) => r.any((c) => _text(c?.value).isNotEmpty));
    final columnOf = <String, int>{};
    if (headerIndex >= 0) {
      final header = allRows[headerIndex];
      for (var i = 0; i < header.length; i++) {
        final h = foldForSearch(_text(header[i]?.value));
        if (h.isEmpty) continue;
        for (final f in fields) {
          if (!columnOf.containsKey(f.key) && f.headers.any((alias) => foldForSearch(alias) == h)) {
            columnOf[f.key] = i;
            break;
          }
        }
      }
    }
    final missing = [for (final f in fields.where((f) => f.required && !columnOf.containsKey(f.key))) f.headers.first];

    final rows = <ImportRow>[];
    for (var r = headerIndex + 1; r < allRows.length && headerIndex >= 0; r++) {
      final cells = allRows[r];
      final values = <String, String>{
        for (final e in columnOf.entries)
          e.key: e.value < cells.length ? _text(cells[e.value]?.value) : '',
      };
      if (values.values.every((v) => v.isEmpty)) continue;
      rows.add(ImportRow(r + 1, values));
    }

    if (missing.isEmpty) {
      switch (kind) {
        case ImportKind.products:
          await _checkProducts(rows);
        case ImportKind.customers:
          await _checkCustomers(rows);
        case ImportKind.suppliers:
          await _checkSuppliers(rows);
      }
    }
    return ImportPreview(kind, rows, missing, titles);
  }

  /// Saves every valid row in one transaction; returns how many.
  Future<int> import(ImportPreview preview, {required User user}) {
    return db.transaction(() async {
      if (!user.isAdmin) throw ValidationException('الاستيراد للمدير فقط');
      if (!preview.canImport) throw ValidationException('لا توجد صفوف صالحة للاستيراد');
      final rows = preview.rows.where((r) => r.ok).toList();
      switch (preview.kind) {
        case ImportKind.products:
          final catalog = CatalogService(db);
          final categories = {for (final c in await db.select(db.categories).get()) foldForSearch(c.nameAr): c.id};
          final brands = {for (final b in await db.select(db.brands).get()) foldForSearch(b.name): b.id};
          final products = ProductService(db);
          for (final row in rows) {
            int? categoryId;
            if (row.categoryName != null) {
              categoryId = categories[foldForSearch(row.categoryName!)] ??=
                  await catalog.saveCategory(name: row.categoryName!);
            }
            int? brandId;
            if (row.brandName != null) {
              brandId = brands[foldForSearch(row.brandName!)] ??= await catalog.saveBrand(name: row.brandName!);
            }
            final p = row.input! as ProductInput;
            await products.create(
              ProductInput(
                code: p.code,
                manufacturerCode: p.manufacturerCode,
                variant: p.variant,
                nameAr: p.nameAr,
                categoryId: categoryId,
                brandId: brandId,
                unitId: p.unitId,
                minStock: p.minStock,
              ),
              openingQty: row.openingQty,
              openingCost: row.openingCost,
              userId: user.id,
            );
          }
        case ImportKind.customers:
          for (final row in rows) {
            await PartyService(db).saveCustomer(row.input! as CustomerInput, userId: user.id);
          }
        case ImportKind.suppliers:
          for (final row in rows) {
            await PartyService(db).saveSupplier(row.input! as SupplierInput, userId: user.id);
          }
      }
      await AuditService(db).log(
        action: AuditAction.create,
        entity: 'import',
        userId: user.id,
        details: '${preview.kind.title}: ${rows.length}',
      );
      return rows.length;
    });
  }

  Future<void> _checkProducts(List<ImportRow> rows) async {
    final existing = {for (final p in await db.select(db.products).get()) p.code.toLowerCase()};
    final units = await db.select(db.units).get();
    final seen = <String>{};
    for (final row in rows) {
      final v = row.values;
      final code = (v['code'] ?? '').trim();
      final name = (v['name'] ?? '').trim();
      if (code.isEmpty) row.errors.add('الكود فارغ');
      if (name.isEmpty) row.errors.add('الاسم فارغ');
      if (code.isNotEmpty && existing.contains(code.toLowerCase())) row.errors.add('الكود موجود في البرنامج');
      if (code.isNotEmpty && !seen.add(code.toLowerCase())) row.errors.add('الكود مكرر في الملف');

      Unit? unit = units.isEmpty ? null : units.first;
      final unitName = (v['unit'] ?? '').trim();
      if (unitName.isNotEmpty) {
        unit = units.where((u) => foldForSearch(u.nameAr) == foldForSearch(unitName)).firstOrNull;
        if (unit == null) row.errors.add('الوحدة "$unitName" غير معرفة؛ أضفها من شاشة الوحدات');
      }
      final allowDecimal = unit?.allowDecimal ?? false;

      int qty(String key, String label) {
        final text = (v[key] ?? '').trim();
        if (text.isEmpty) return 0;
        final q = parseQty(text, allowDecimal: allowDecimal);
        if (q == null || q < 0) {
          row.errors.add('$label غير صحيح: "$text"${allowDecimal ? '' : ' (رقم صحيح لهذه الوحدة)'}');
          return 0;
        }
        return q;
      }

      final input = ProductInput(
        code: code,
        manufacturerCode: (v['manufacturerCode'] ?? '').trim().isEmpty ? code : v['manufacturerCode']!.trim(),
        variant: (v['variant'] ?? '').trim().isEmpty ? null : v['variant']!.trim(),
        nameAr: name,
        unitId: unit?.id,
        minStock: qty('minStock', 'حد الطلب'),
      );
      row.openingQty = qty('opening', 'رصيد أول المدة');
      final costText = (v['openingCost'] ?? '').trim();
      if (costText.isNotEmpty) {
        final c = parseMoney(costText);
        if (c == null || c < 0) {
          row.errors.add('تكلفة رصيد أول المدة غير صحيحة: "$costText"');
        } else {
          row.openingCost = c;
        }
      }
      if (row.openingQty > 0 && costText.isEmpty) {
        row.errors.add('رصيد أول المدة يحتاج التكلفة الفعلية؛ لا تُفترض تكلفة');
      }
      final category = (v['category'] ?? '').trim();
      final brand = (v['brand'] ?? '').trim();
      row.categoryName = category.isEmpty ? null : category;
      row.brandName = brand.isEmpty ? null : brand;
      if (row.ok) row.input = input;
    }
  }

  Future<void> _checkCustomers(List<ImportRow> rows) async {
    final existing = {for (final c in await db.select(db.customers).get()) foldForSearch(c.name)};
    final seen = <String>{};
    for (final row in rows) {
      final v = row.values;
      final name = (v['name'] ?? '').trim();
      _checkName(row, name, existing, seen);
      final opening = _money(row, v['opening'], 'رصيد أول المدة', allowNegative: true);
      final limit = _money(row, v['creditLimit'], 'حد الائتمان');
      final levelText = foldForSearch(v['priceLevel'] ?? '');
      final level = switch (levelText) {
        '' || 'قطاعي' || 'retail' => PriceLevel.retail,
        'جمله' || 'wholesale' => PriceLevel.wholesale,
        'مقاولين' || 'مقاول' || 'contractor' => PriceLevel.contractor,
        _ => null,
      };
      if (level == null) row.errors.add('فئة السعر "${v['priceLevel']}" غير معروفة (قطاعي، جملة، مقاولين)');
      if (row.ok) {
        row.input = CustomerInput(
          name: name,
          phone: _phone(v['phone']),
          address: v['address'],
          openingBalance: opening,
          creditLimit: limit,
          priceLevel: level!,
        );
      }
    }
  }

  Future<void> _checkSuppliers(List<ImportRow> rows) async {
    final existing = {for (final s in await db.select(db.suppliers).get()) foldForSearch(s.name)};
    final seen = <String>{};
    for (final row in rows) {
      final v = row.values;
      final name = (v['name'] ?? '').trim();
      _checkName(row, name, existing, seen);
      final opening = _money(row, v['opening'], 'رصيد أول المدة', allowNegative: true);
      if (row.ok) {
        row.input = SupplierInput(name: name, phone: _phone(v['phone']), address: v['address'], openingBalance: opening);
      }
    }
  }

  void _checkName(ImportRow row, String name, Set<String> existing, Set<String> seen) {
    if (name.isEmpty) {
      row.errors.add('الاسم فارغ');
      return;
    }
    final folded = foldForSearch(name);
    if (existing.contains(folded)) row.errors.add('الاسم موجود في البرنامج');
    if (!seen.add(folded)) row.errors.add('الاسم مكرر في الملف');
  }

  int _money(ImportRow row, String? text, String label, {bool allowNegative = false}) {
    final t = (text ?? '').trim();
    if (t.isEmpty) return 0;
    final m = parseMoney(t);
    if (m == null || (m < 0 && !allowNegative)) {
      row.errors.add('$label غير صحيح: "$t"');
      return 0;
    }
    return m;
  }

  /// Excel drops the leading zero of a phone typed as a number:
  /// 1001234567 is really 01001234567.
  static String? _phone(String? text) {
    final t = (text ?? '').trim();
    if (t.isEmpty) return null;
    if (RegExp(r'^1\d{9}$').hasMatch(t)) return '0$t';
    return t;
  }

  /// A cell's value as text. Whole numbers come out without ".0".
  static String _text(CellValue? value) {
    return switch (value) {
      null => '',
      TextCellValue v => v.value.text ?? v.value.toString(),
      IntCellValue v => '${v.value}',
      // Rounded to 3 places: Excel keeps 35.1 as 35.0999999...
      DoubleCellValue v => v.value
          .toStringAsFixed(3)
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), ''),
      _ => value.toString(),
    }.trim();
  }
}
