import 'package:drift/drift.dart' show Value;
import 'package:excel/excel.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import '../excel_open.dart';
import '../money.dart';
import '../pdf_import/price_table.dart';
import '../pricing_math.dart';
import '../search_text.dart';
import 'audit_service.dart';
import 'catalog_service.dart';
import 'errors.dart';
import 'price_list_service.dart';
import 'product_service.dart';

/// What will happen to a row of the sheet (blueprint 3.2a).
enum PriceRowAction {
  /// A known product: its price is added.
  known,

  /// A new product: it gets a new Product ID.
  create,

  /// Duplicate, ambiguous or incomplete: stopped for a person to review.
  review,
}

/// One sheet row after checking.
class PriceImportRow {
  PriceImportRow(this.rowNumber, this.code, this.name, this.variant, this.priceText, this.packText,
      {this.codeWasNumber = false, this.details = const {}, this.page, this.presetReason, this.arabicName = ''});

  /// The Arabic name from a column of its own, when the list has one.
  final String arabicName;

  /// A known product whose name has no Arabic yet: the Arabic name is filled in.
  bool fillArabicName = false;

  /// As Excel numbers it (header is row 1).
  final int rowNumber;

  /// The maker's code exactly as text.
  final String code;
  final String name;
  final String? variant;
  final String priceText;
  final String packText;

  /// Excel held the code as a number, so leading zeros may already be lost.
  final bool codeWasNumber;

  /// Optional master data for a new product.
  final Map<String, String> details;

  /// The PDF page the row came from; null for Excel.
  final int? page;

  /// Set when the row was already doubtful as read (a PDF row with a number
  /// outside every column, say). It keeps the row stopped on every check.
  final String? presetReason;

  PriceRowAction action = PriceRowAction.create;
  String? reviewReason;
  int? productId;
  int? price;
  int? packSize;

  bool get ok => action != PriceRowAction.review;

  void stop(String reason) {
    action = PriceRowAction.review;
    reviewReason = reviewReason == null ? reason : '$reviewReason؛ $reason';
  }
}

/// One row typed by hand (blueprint 3.2b).
class PriceEntry {
  const PriceEntry({
    required this.code,
    required this.price,
    this.name = '',
    this.variant,
    this.dimensions,
    this.details = const {},
  });

  final String code;
  final int price;
  final String name;
  final String? variant;
  final String? dimensions;
  final Map<String, String> details;
}

class PriceImportPreview {
  PriceImportPreview(this.brandId, this.rows, this.missingColumns);

  final int? brandId;
  final List<PriceImportRow> rows;

  /// Required columns the sheet does not have; nothing can be imported.
  final List<String> missingColumns;

  int get knownCount => rows.where((r) => r.action == PriceRowAction.known).length;
  int get createCount => rows.where((r) => r.action == PriceRowAction.create).length;
  int get reviewCount => rows.where((r) => r.action == PriceRowAction.review).length;

  /// Known products that get their Arabic name from this list.
  int get arabicNameCount => rows.where((r) => r.ok && r.fillArabicName).length;
  bool get canImport => missingColumns.isEmpty && rows.isNotEmpty;
}

/// Full list import: every file becomes a new version with its own Price List
/// ID. Known codes get a price, new codes get a Product ID, and anything
/// duplicate or ambiguous is stopped for review instead of guessed at.
///
/// Columns: code, name, variant (optional), price, pack size (optional), and
/// optional master data for new products. A sheet may instead have one price
/// column per colour, headed "سعر أبيض", "سعر برجامون", ...
class PriceListImportService {
  PriceListImportService(this.db);

  final AppDatabase db;

  static const _codeHeaders = [
    'كود الشركة', 'كود المورد', 'كود المصنع', 'الكود', 'كود', 'كود الصنف', 'code', 'model', 'manufacturer code',
  ];
  static const _nameHeaders = ['الاسم', 'اسم الصنف', 'الصنف', 'name', 'product name'];
  static const _arabicNameHeaders = [
    'الاسم بالعربي', 'الاسم العربي', 'الاسم بالعربية', 'اسم عربي', 'الاسم عربي', 'arabic name', 'name ar', 'name_ar',
  ];

  static final _arabicLetters = RegExp('[ء-ي]');

  /// True when [text] has Arabic letters.
  static bool hasArabic(String text) => _arabicLetters.hasMatch(text);
  static const _variantHeaders = ['اللون', 'colour', 'color', 'variant'];
  static const _priceHeaders = ['السعر', 'سعر القائمة', 'price', 'list price'];
  static const _packHeaders = ['عدد الكرتونة', 'التعبئة', 'العدد داخل الكرتونة', 'pack'];
  static const _detailHeaders = {
    'category': ['التصنيف', 'category'],
    'subcategory': ['التصنيف الفرعي', 'subcategory'],
    'series': ['السلسلة', 'series'],
    'description': ['الوصف', 'description'],
    'dimensions': ['المقاسات', 'الأبعاد', 'dimensions'],
    'finish': ['التشطيب', 'finish'],
    'unit': ['الوحدة', 'unit'],
    'barcode': ['الباركود', 'barcode'],
    'specs': ['المواصفات الفنية', 'technical specs'],
  };

  /// An empty sheet with the expected headers. Every code cell must stay text.
  List<int> template() {
    final excel = Excel.createExcel();
    excel.rename(excel.getDefaultSheet()!, 'قائمة الأسعار');
    final sheet = excel['قائمة الأسعار'];
    sheet.isRTL = true;
    final headers = [
      'كود الشركة', 'الاسم', 'اللون', 'السعر', 'عدد الكرتونة', 'التصنيف', 'التصنيف الفرعي', 'السلسلة',
      'الوصف', 'المقاسات', 'التشطيب', 'الوحدة', 'الباركود', 'المواصفات الفنية',
    ];
    sheet.appendRow([for (final h in headers) TextCellValue(h)]);
    for (var i = 0; i < headers.length; i++) {
      sheet.setColumnWidth(i, i == 1 ? 34 : 16);
    }
    return excel.encode()!;
  }

  /// Reads the file and decides what happens to each row of it, for [brandId].
  Future<PriceImportPreview> preview(List<int> bytes, {required int brandId}) async {
    final Excel excel;
    try {
      excel = openExcel(bytes);
    } on Object {
      throw ValidationException('الملف ليس ملف Excel صالحاً (xlsx). افتحه في Excel واحفظه من جديد ثم حاول مرة أخرى.');
    }
    final sheet = excel.tables.values.where((t) => t.maxRows > 0).firstOrNull;
    if (sheet == null) return PriceImportPreview(brandId, [], ['الاسم', 'السعر']);

    final all = sheet.rows;
    final headerIndex = all.indexWhere((r) => r.any((c) => _text(c?.value).isNotEmpty));
    if (headerIndex < 0) return PriceImportPreview(brandId, [], ['الاسم', 'السعر']);

    int? codeCol, nameCol, arabicCol, variantCol, priceCol, packCol;
    final variantPriceCols = <int, String>{}; // column -> variant
    final detailCols = <String, int>{};
    final header = all[headerIndex];
    for (var i = 0; i < header.length; i++) {
      final raw = _text(header[i]?.value);
      final h = foldForSearch(raw);
      if (h.isEmpty) continue;
      bool isOne(List<String> aliases) => aliases.any((a) => foldForSearch(a) == h);
      if (codeCol == null && isOne(_codeHeaders)) {
        codeCol = i;
      } else if (arabicCol == null && isOne(_arabicNameHeaders)) {
        arabicCol = i;
      } else if (nameCol == null && isOne(_nameHeaders)) {
        nameCol = i;
      } else if (variantCol == null && isOne(_variantHeaders)) {
        variantCol = i;
      } else if (priceCol == null && isOne(_priceHeaders)) {
        priceCol = i;
      } else if (packCol == null && isOne(_packHeaders)) {
        packCol = i;
      } else if (raw.startsWith('سعر ') && raw.substring(4).trim().isNotEmpty) {
        variantPriceCols[i] = raw.substring(4).trim();
      } else {
        for (final e in _detailHeaders.entries) {
          if (!detailCols.containsKey(e.key) && isOne(e.value)) detailCols[e.key] = i;
        }
      }
    }
    final missing = <String>[
      if (nameCol == null && arabicCol == null) 'الاسم',
      if (priceCol == null && variantPriceCols.isEmpty) 'السعر',
    ];
    if (missing.isNotEmpty) return PriceImportPreview(brandId, [], missing);

    String at(List<Data?> cells, int? col) =>
        col == null || col >= cells.length ? '' : _text(cells[col]?.value);

    final rows = <PriceImportRow>[];
    for (var r = headerIndex + 1; r < all.length; r++) {
      final cells = all[r];
      final code = at(cells, codeCol);
      final arabic = at(cells, arabicCol);
      final listName = at(cells, nameCol);
      // With no name of its own the row is known by its Arabic name.
      final name = listName.isEmpty ? arabic : listName;
      final sheetVariant = at(cells, variantCol);
      final pack = at(cells, packCol);
      final numeric = codeCol != null &&
          codeCol < cells.length &&
          (cells[codeCol]?.value is IntCellValue || cells[codeCol]?.value is DoubleCellValue);
      final details = {for (final e in detailCols.entries) e.key: at(cells, e.value)};
      // The other-language name of a new product is kept as its description.
      if (arabic.isNotEmpty && listName.isNotEmpty && listName != arabic && (details['description'] ?? '').isEmpty) {
        details['description'] = listName;
      }
      final prices = <String?, String>{
        if (priceCol != null) (sheetVariant.isEmpty ? null : sheetVariant): at(cells, priceCol),
        for (final e in variantPriceCols.entries) e.value: at(cells, e.key),
      };
      if (name.isEmpty && code.isEmpty && prices.values.every((v) => v.isEmpty)) continue;
      for (final e in prices.entries) {
        // A colour-price column left empty means "not made in that colour".
        if (e.value.isEmpty && prices.length > 1) continue;
        rows.add(PriceImportRow(r + 1, code, name, e.key, e.value, pack,
            codeWasNumber: numeric,
            details: details,
            arabicName: hasArabic(arabic) ? arabic : (arabicCol == null && hasArabic(listName) ? listName : '')));
      }
    }
    await _classify(rows, brandId);
    return PriceImportPreview(brandId, rows, const []);
  }

  /// Turns a price table read from a PDF into the same preview as an Excel
  /// file. [include] is the columns to take (by label as read); [rename]
  /// gives a column its colour name. With one column, or a column named only
  /// "السعر", the rows get no colour; otherwise the column's name is the colour.
  Future<PriceImportPreview> previewPdf(
    PdfPriceTable table, {
    required int brandId,
    required Set<String> include,
    Map<String, String> rename = const {},
  }) async {
    if (include.isEmpty) return PriceImportPreview(brandId, [], ['عمود السعر']);
    String? variantOf(String label) {
      if (include.length == 1) return null;
      final name = (rename[label] ?? label).trim();
      return name.isEmpty || name == genericPriceLabel ? null : name;
    }

    final rows = <PriceImportRow>[];
    for (final (i, r) in table.rows.indexed) {
      for (final label in include) {
        final text = r.prices[label];
        if (text == null) continue;
        rows.add(PriceImportRow(
          i + 1,
          r.code,
          r.name,
          variantOf(label),
          text.replaceAll(',', ''),
          '',
          page: r.page,
          presetReason: r.issue,
        ));
      }
    }
    await _classify(rows, brandId);
    return PriceImportPreview(brandId, rows, const []);
  }

  Future<void> _classify(List<PriceImportRow> rows, int brandId) async {
    final products = await (db.select(db.products)..where((t) => t.brandId.equals(brandId))).get();
    final byKey = <String, List<Product>>{};
    final byId = <String, Product>{};
    // Some makers' lists have no codes at all: then the exact name identifies
    // the product within its brand and colour.
    final byName = <String, List<Product>>{};
    for (final p in products) {
      if (p.matchKey.isNotEmpty) (byKey[p.matchKey] ??= []).add(p);
      byId[matchKeyOf(p.code)] = p;
      (byName['${foldForSearch(p.nameAr)}|${variantKeyOf(p.variant)}'] ??= []).add(p);
    }
    String rowKey(PriceImportRow r) {
      final code = matchKeyOf(r.code);
      return code.isNotEmpty
          ? '$code|${variantKeyOf(r.variant)}'
          : 'name:${foldForSearch(r.name)}|${variantKeyOf(r.variant)}';
    }

    final counts = <String, int>{};
    for (final r in rows) {
      counts[rowKey(r)] = (counts[rowKey(r)] ?? 0) + 1;
    }
    for (final r in rows) {
      final key = matchKeyOf(r.code);
      if (r.presetReason != null) r.stop(r.presetReason!);
      r.price = _parsePrice(r.priceText);
      if (r.priceText.isEmpty) {
        r.stop('السعر غير موجود');
      } else if (r.price == null || r.price! < 0) {
        r.price = null;
        r.stop('السعر "${r.priceText}" غير صحيح');
      }
      if (r.packText.isNotEmpty) {
        r.packSize = int.tryParse(r.packText);
        if (r.packSize == null || r.packSize! <= 0) {
          r.packSize = null;
          r.stop('عدد الكرتونة "${r.packText}" غير صحيح');
        }
      }
      if (key.isEmpty && r.name.isEmpty) {
        r.stop('بدون كود وبدون اسم');
        continue;
      }
      if ((counts[rowKey(r)] ?? 0) > 1) {
        r.stop(key.isEmpty ? 'الاسم مكرر في الملف بدون كود' : 'الكود مكرر في الملف');
        continue;
      }
      if (key.isEmpty) {
        final named = byName['${foldForSearch(r.name)}|${variantKeyOf(r.variant)}'] ?? const <Product>[];
        if (named.length > 1) {
          r.stop('الاسم يطابق أكثر من صنف');
        } else if (named.length == 1) {
          r.productId = named.single.id;
          if (r.action != PriceRowAction.review) r.action = PriceRowAction.known;
        }
        continue;
      }
      final same = byKey[key] ?? const <Product>[];
      final exact = same.where((p) => variantKeyOf(p.variant) == variantKeyOf(r.variant)).toList();
      if (exact.length > 1) {
        r.stop('الكود يطابق أكثر من صنف');
      } else if (exact.length == 1) {
        r.productId = exact.single.id;
        if (r.action != PriceRowAction.review) r.action = PriceRowAction.known;
      } else if (same.isNotEmpty) {
        // The code exists under another colour. A row or a product without a
        // colour could be either one, so a person decides.
        if (variantKeyOf(r.variant).isEmpty || same.any((p) => variantKeyOf(p.variant).isEmpty)) {
          r.stop('الكود موجود بلون مختلف؛ حدد الصنف');
        }
      } else if (byId[key] != null) {
        r.productId = byId[key]!.id;
        if (r.action != PriceRowAction.review) r.action = PriceRowAction.known;
      } else if (r.codeWasNumber) {
        r.stop('الكود مخزن كرقم في Excel وقد تكون أصفاره البادئة فُقدت');
      } else if (r.name.isEmpty) {
        r.stop('الاسم مطلوب لإنشاء صنف جديد');
      }
    }
    // A known product named only in another language takes the list's Arabic
    // name. An Arabic name already there is never changed.
    final byProductId = {for (final p in products) p.id: p};
    for (final r in rows) {
      final p = r.productId == null ? null : byProductId[r.productId];
      r.fillArabicName = p != null && r.arabicName.isNotEmpty && !hasArabic(p.nameAr);
    }
  }

  /// Saves the file as one new version. Known rows get their price, new rows
  /// get a new Product ID, stopped rows wait in the review queue.
  Future<PriceListResult> import(
    PriceImportPreview preview, {
    required PriceListHeader header,
    required User user,
  }) {
    return db.transaction(() async {
      if (!user.can(Perm.catalog)) throw ValidationException('الاستيراد لصلاحية الأصناف والأسعار');
      if (!preview.canImport) throw ValidationException('لا توجد صفوف للاستيراد');
      if (preview.brandId != header.brandId) throw ValidationException('الملف فُحص لماركة مختلفة؛ أعد اختيار الملف');
      // Check again: the products may have changed since the preview.
      await _classifyAgain(preview);
      var created = 0;
      final inputs = <PriceRowInput>[];
      final named = <int>{};
      for (final r in preview.rows) {
        int? productId = r.productId;
        if (r.action == PriceRowAction.create) {
          productId = (await _createProduct(r, header.brandId, user)).id;
          created++;
        } else if (r.ok && r.fillArabicName && productId != null && named.add(productId)) {
          final before = await (db.select(db.products)..where((t) => t.id.equals(productId!))).getSingle();
          await (db.update(db.products)..where((t) => t.id.equals(productId!))).write(ProductsCompanion(
              nameAr: Value(r.arabicName),
              description: Value(before.description ?? before.nameAr),
              updatedAt: Value(DateTime.now())));
          await AuditService(db).log(
            action: AuditAction.update,
            entity: 'product',
            entityId: productId,
            userId: user.id,
            details: 'الاسم العربي من قائمة الأسعار: ${before.nameAr} -> ${r.arabicName}',
          );
        }
        inputs.add(PriceRowInput(
          name: r.name,
          price: r.price,
          manufacturerCode: r.code,
          variant: r.variant,
          packSize: r.packSize,
          productId: r.action == PriceRowAction.review ? null : productId,
          reviewReason: r.reviewReason,
          sourceRow: r.page ?? r.rowNumber,
        ));
      }
      final saved = await PriceListService(db).createVersion(
        header,
        rows: inputs,
        user: user,
        rowCountOnSource: preview.rows.length,
      );
      return PriceListResult(
        saved.id,
        rows: saved.rows,
        matched: saved.matched - created,
        created: created,
        review: saved.review,
      );
    });
  }

  /// Enters a product or a small group without a file, into version [listId]
  /// or into [newVersion], which leaves the earlier list open for everything
  /// else. A code that is new makes a product; one that is duplicate or
  /// ambiguous is refused on the spot, since the person is right there.
  Future<PriceListResult> enterRows(
    List<PriceEntry> entries, {
    required int brandId,
    int? listId,
    PriceListHeader? newVersion,
    required User user,
  }) {
    return db.transaction(() async {
      if (!user.can(Perm.purchase)) throw ValidationException('قوائم الأسعار لصلاحية المشتريات');
      if (entries.isEmpty) throw ValidationException('أضف صنفاً واحداً على الأقل');
      if ((listId == null) == (newVersion == null)) throw ArgumentError('Give a version or a new version');
      if (newVersion != null && newVersion.brandId != brandId) throw ArgumentError('brand mismatch');
      if (listId != null) {
        final list = await (db.select(db.priceLists)..where((l) => l.id.equals(listId))).getSingleOrNull();
        if (list == null) throw ValidationException('القائمة غير موجودة');
        if (list.brandId != brandId) throw ValidationException('القائمة المختارة ليست لهذه الماركة');
      }
      final rows = [
        for (final (i, e) in entries.indexed)
          PriceImportRow(
            i + 1,
            e.code.trim(),
            e.name.trim(),
            (e.variant ?? '').trim().isEmpty ? null : e.variant!.trim(),
            '${e.price / 100}',
            '',
            details: {...e.details, if ((e.dimensions ?? '').trim().isNotEmpty) 'dimensions': e.dimensions!.trim()},
          ),
      ];
      await _classify(rows, brandId);
      final stopped = rows.where((r) => !r.ok).toList();
      if (stopped.isNotEmpty) {
        throw ValidationException(stopped.map((r) => '${r.code}: ${r.reviewReason}').join('\n'));
      }
      var created = 0;
      final inputs = <PriceRowInput>[];
      for (var i = 0; i < rows.length; i++) {
        final r = rows[i];
        var productId = r.productId;
        var name = r.name;
        if (r.action == PriceRowAction.create) {
          final p = await _createProduct(r, brandId, user);
          productId = p.id;
          created++;
        } else if (name.isEmpty) {
          name = (await (db.select(db.products)..where((t) => t.id.equals(productId!))).getSingle()).nameAr;
        }
        inputs.add(PriceRowInput(
          name: name,
          price: entries[i].price,
          manufacturerCode: r.code,
          variant: r.variant,
          productId: productId,
        ));
      }
      final prices = PriceListService(db);
      if (listId != null) {
        await prices.addEntries(listId, inputs, user: user);
        return PriceListResult(listId, rows: inputs.length, matched: inputs.length - created, created: created);
      }
      final saved = await prices.createVersion(newVersion!, rows: inputs, user: user, closePrevious: false);
      return PriceListResult(saved.id, rows: inputs.length, matched: inputs.length - created, created: created);
    });
  }

  Future<void> _classifyAgain(PriceImportPreview preview) async {
    for (final r in preview.rows) {
      r
        ..action = PriceRowAction.create
        ..reviewReason = null
        ..productId = null;
    }
    await _classify(preview.rows, preview.brandId!);
  }

  Future<Product> _createProduct(PriceImportRow r, int brandId, User user) async {
    final catalog = CatalogService(db);
    String? d(String key) {
      final v = (r.details[key] ?? '').trim();
      return v.isEmpty ? null : v;
    }

    final categories = await db.select(db.categories).get();
    int? categoryId, subcategoryId;
    final categoryName = d('category');
    if (categoryName != null) {
      categoryId = categories
              .where((c) => c.parentId == null && foldForSearch(c.nameAr) == foldForSearch(categoryName))
              .firstOrNull
              ?.id ??
          await catalog.saveCategory(name: categoryName);
    }
    final subName = d('subcategory');
    if (subName != null && categoryId != null) {
      subcategoryId = categories
              .where((c) => c.parentId == categoryId && foldForSearch(c.nameAr) == foldForSearch(subName))
              .firstOrNull
              ?.id ??
          await catalog.saveCategory(name: subName, parentId: categoryId);
    }
    final units = await db.select(db.units).get();
    final unitName = d('unit');
    final unit = (unitName == null
            ? null
            : units.where((u) => foldForSearch(u.nameAr) == foldForSearch(unitName)).firstOrNull) ??
        units.firstOrNull;
    return ProductService(db).create(
      ProductInput(
        nameAr: r.arabicName.isNotEmpty ? r.arabicName : r.name,
        manufacturerCode: r.code,
        brandId: brandId,
        variant: r.variant,
        categoryId: categoryId,
        subcategoryId: subcategoryId,
        unitId: unit?.id,
        series: d('series'),
        description: d('description'),
        dimensions: d('dimensions'),
        finish: d('finish'),
        barcode: d('barcode'),
        technicalSpecs: d('specs'),
      ),
      userId: user.id,
    );
  }

  /// "2400" -> 240000, "50,00" -> 5000 (comma as the decimal mark when it
  /// is followed by one or two digits), "2,400" -> 240000.
  static int? _parsePrice(String text) {
    var s = text.trim();
    if (s.isEmpty) return null;
    if (RegExp(r'^\d+,\d{1,2}$').hasMatch(s)) s = s.replaceFirst(',', '.');
    return parseMoney(s);
  }

  static String _text(CellValue? value) {
    return switch (value) {
      null => '',
      TextCellValue v => v.value.text ?? v.value.toString(),
      IntCellValue v => '${v.value}',
      DoubleCellValue v => v.value
          .toStringAsFixed(3)
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), ''),
      _ => value.toString(),
    }.trim();
  }
}
