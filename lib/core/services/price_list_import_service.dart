import 'package:excel/excel.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import '../money.dart';
import '../search_text.dart';
import 'errors.dart';
import 'price_list_service.dart';

/// One sheet row after checking. [errors] empty means it will be imported.
class PriceImportRow {
  PriceImportRow(this.rowNumber, this.code, this.name, this.colour, this.priceText, this.packText);

  /// As Excel numbers it (header is row 1).
  final int rowNumber;
  final String code;
  final String name;
  final String? colour;
  final String priceText;
  final String packText;
  final errors = <String>[];
  PriceRowInput? input;

  bool get ok => errors.isEmpty;
}

class PriceImportPreview {
  PriceImportPreview(this.rows, this.missingColumns);

  final List<PriceImportRow> rows;

  /// Required columns the sheet does not have; nothing can be imported.
  final List<String> missingColumns;

  int get okCount => rows.where((r) => r.ok).length;
  int get errorCount => rows.length - okCount;
  bool get canImport => missingColumns.isEmpty && okCount > 0;
}

/// Reads a supplier's price list from Excel into a new price list.
///
/// Columns: code, name, colour (optional), price, pack size (optional).
/// A sheet may instead have one price column per colour, headed
/// "سعر أبيض", "سعر برجامون", ...: each becomes its own line.
class PriceListImportService {
  PriceListImportService(this.db);

  final AppDatabase db;

  static const _codeHeaders = ['الكود', 'كود', 'كود الصنف', 'code', 'model'];
  static const _nameHeaders = ['الاسم', 'اسم الصنف', 'الوصف', 'الصنف', 'name', 'description'];
  static const _colourHeaders = ['اللون', 'colour', 'color'];
  static const _priceHeaders = ['السعر', 'price'];
  static const _packHeaders = ['عدد الكرتونة', 'التعبئة', 'العدد داخل الكرتونة', 'pack'];

  /// An empty sheet with the expected headers.
  List<int> template() {
    final excel = Excel.createExcel();
    excel.rename(excel.getDefaultSheet()!, 'قائمة الأسعار');
    final sheet = excel['قائمة الأسعار'];
    sheet.isRTL = true;
    sheet.appendRow([
      for (final h in ['الكود', 'الاسم', 'اللون', 'السعر', 'عدد الكرتونة']) TextCellValue(h),
    ]);
    for (var i = 0; i < 5; i++) {
      sheet.setColumnWidth(i, i == 1 ? 34 : 16);
    }
    return excel.encode()!;
  }

  PriceImportPreview preview(List<int> bytes) {
    final Excel excel;
    try {
      excel = Excel.decodeBytes(bytes);
    } on Object {
      throw ValidationException('الملف ليس ملف Excel صالحاً (xlsx)');
    }
    final sheet = excel.tables.values.where((t) => t.maxRows > 0).firstOrNull;
    if (sheet == null) return PriceImportPreview([], ['الاسم', 'السعر']);

    final all = sheet.rows;
    final headerIndex = all.indexWhere((r) => r.any((c) => _text(c?.value).isNotEmpty));
    if (headerIndex < 0) return PriceImportPreview([], ['الاسم', 'السعر']);

    int? codeCol, nameCol, colourCol, priceCol, packCol;
    final colourPriceCols = <int, String>{}; // column -> colour
    final header = all[headerIndex];
    for (var i = 0; i < header.length; i++) {
      final raw = _text(header[i]?.value);
      final h = foldForSearch(raw);
      if (h.isEmpty) continue;
      bool isOne(List<String> aliases) => aliases.any((a) => foldForSearch(a) == h);
      if (codeCol == null && isOne(_codeHeaders)) {
        codeCol = i;
      } else if (nameCol == null && isOne(_nameHeaders)) {
        nameCol = i;
      } else if (colourCol == null && isOne(_colourHeaders)) {
        colourCol = i;
      } else if (priceCol == null && isOne(_priceHeaders)) {
        priceCol = i;
      } else if (packCol == null && isOne(_packHeaders)) {
        packCol = i;
      } else if (raw.startsWith('سعر ') && raw.substring(4).trim().isNotEmpty) {
        colourPriceCols[i] = raw.substring(4).trim();
      }
    }
    final missing = <String>[
      if (nameCol == null) 'الاسم',
      if (priceCol == null && colourPriceCols.isEmpty) 'السعر',
    ];
    if (missing.isNotEmpty) return PriceImportPreview([], missing);

    String at(List<Data?> cells, int? col) =>
        col == null || col >= cells.length ? '' : _text(cells[col]?.value);

    final rows = <PriceImportRow>[];
    final seen = <String>{};
    for (var r = headerIndex + 1; r < all.length; r++) {
      final cells = all[r];
      final code = at(cells, codeCol);
      final name = at(cells, nameCol);
      final sheetColour = at(cells, colourCol);
      final pack = at(cells, packCol);
      final prices = <String?, String>{
        if (priceCol != null) (sheetColour.isEmpty ? null : sheetColour): at(cells, priceCol),
        for (final e in colourPriceCols.entries) e.value: at(cells, e.key),
      };
      if (name.isEmpty && code.isEmpty && prices.values.every((v) => v.isEmpty)) continue;
      for (final e in prices.entries) {
        // A colour-price column left empty means "not made in that colour".
        if (e.value.isEmpty && prices.length > 1) continue;
        final row = PriceImportRow(r + 1, code, name, e.key, e.value, pack);
        _check(row, seen);
        rows.add(row);
      }
    }
    return PriceImportPreview(rows, const []);
  }

  void _check(PriceImportRow row, Set<String> seen) {
    if (row.name.isEmpty) row.errors.add('الاسم مطلوب');
    final price = _parsePrice(row.priceText);
    if (row.priceText.isEmpty) {
      row.errors.add('السعر مطلوب');
    } else if (price == null) {
      row.errors.add('السعر "${row.priceText}" غير صحيح');
    }
    int? pack;
    if (row.packText.isNotEmpty) {
      pack = int.tryParse(row.packText);
      if (pack == null || pack <= 0) row.errors.add('عدد الكرتونة "${row.packText}" غير صحيح');
    }
    if (row.code.isNotEmpty) {
      final key = '${row.code.toLowerCase()}|${row.colour ?? ''}';
      if (!seen.add(key)) row.errors.add('الكود مكرر في الملف');
    }
    if (row.ok) {
      row.input = PriceRowInput(
        name: row.name,
        price: price!,
        supplierCode: row.code,
        colour: row.colour,
        packSize: pack,
      );
    }
  }

  /// Saves every valid row as one new price list.
  Future<PriceListResult> import(
    PriceImportPreview preview, {
    required User user,
    required int supplierId,
    required String name,
    required DateTime effectiveDate,
    int? brandId,
    bool vatIncluded = false,
    String? note,
  }) {
    return db.transaction(() async {
      if (!user.isAdmin) throw ValidationException('الاستيراد للمدير فقط');
      if (!preview.canImport) throw ValidationException('لا توجد صفوف صالحة للاستيراد');
      return PriceListService(db).create(
        supplierId: supplierId,
        name: name,
        effectiveDate: effectiveDate,
        brandId: brandId,
        vatIncluded: vatIncluded,
        note: note,
        rows: [for (final r in preview.rows.where((r) => r.ok)) r.input!],
      );
    });
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
