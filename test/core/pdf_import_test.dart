import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:sanitaryware_erp/core/pdf_import/pdf_layout.dart';
import 'package:sanitaryware_erp/core/pdf_import/pdf_reader.dart';
import 'package:sanitaryware_erp/core/pdf_import/price_table.dart';
import 'package:sanitaryware_erp/core/services/catalog_service.dart';
import 'package:sanitaryware_erp/core/services/price_list_import_service.dart';
import 'package:sanitaryware_erp/core/services/price_list_service.dart';
import 'package:sanitaryware_erp/core/services/product_service.dart';

import '../support/fixture.dart';

/// Characters of [text] laid left to right from [x] on a line at [y].
List<PdfChar> _chars(String text, double x, double y, {double width = 5, double height = 10}) => [
      for (var i = 0; i < text.length; i++)
        PdfChar(text[i], x + i * width, y + height, x + (i + 1) * width, y),
    ];

/// A line of words, each centred where given.
PdfLine _line(double y, List<(String, double)> words) => PdfLine(y, [
      for (final (t, c) in words) PdfWord(t, c - t.length * 2.5, c + t.length * 2.5),
    ]);

PdfPageLines _page(int n, List<PdfLine> lines) =>
    PdfPageLines(n, lines, lines.fold(0, (s, l) => s + l.text.replaceAll(' ', '').length) + 20);

void main() {
  group('layout', () {
    test('characters become lines top to bottom and words split on gaps', () {
      final lines = layoutLines([
        ..._chars('WC-100', 10, 100),
        ..._chars('2400', 80, 100.5),
        ..._chars('Basin', 10, 80),
      ]);
      expect(lines.map((l) => l.text), ['WC-100 2400', 'Basin']);
      expect(lines.first.words.last.center, closeTo(90, .01));
    });

    test('Arabic letters drawn left to right are put back in reading order', () {
      // A PDF keeps "أبيض" as drawn on the page, from its last letter.
      final lines = layoutLines(_chars('ضيبأ', 10, 50));
      expect(lines.single.text, 'أبيض');
    });
  });

  group('price table', () {
    test('header columns name the prices; measures are not prices', () {
      final table = extractPriceTable([
        _page(3, [
          _line(700, [('Code', 40), ('Description', 150), ('White', 300), ('Pergamon', 380)]),
          _line(680, [('WC-100', 40), ('Toilet', 130), ('Set', 160), ('2,400', 300), ('2,650', 380)]),
          _line(660, [('BS-55', 40), ('Basin', 130), ('460', 200), ('X', 215), ('550', 230), ('900', 300)]),
        ]),
      ]);
      expect(table.columns.map((c) => c.label), containsAll(['أبيض', 'برجامون']));
      expect(table.rows, hasLength(2));
      final wc = table.rows.first;
      expect(wc.code, 'WC-100');
      expect(wc.name, 'Toilet Set');
      expect(wc.page, 3);
      expect(wc.prices, {'أبيض': '2,400', 'برجامون': '2,650'});
      expect(wc.issue, isNull);
      // "460 X 550" is a size, so only the White price is read.
      expect(table.rows[1].prices, {'أبيض': '900'});
      expect(table.rows[1].issue, isNull);
    });

    test('a price under no column stops the row instead of being dropped', () {
      final table = extractPriceTable([
        _page(1, [
          _line(700, [('Code', 40), ('White', 300)]),
          _line(680, [('WC-100', 40), ('Toilet', 130), ('2400', 300), ('777', 500)]),
          _line(660, [('WC-200', 40), ('Toilet', 130), ('2500', 300)]),
        ]),
      ]);
      expect(table.rows.first.prices, {'أبيض': '2400'});
      expect(table.rows.first.issue, contains('777'));
      expect(table.rows[1].issue, isNull);
    });

    test('a page with no readable header gets numbered columns from aligned prices', () {
      final table = extractPriceTable([
        _page(1, [
          _line(680, [('A-1001', 40), ('1200', 300), ('1300', 380)]),
          _line(660, [('A-1002', 40), ('1250', 302), ('1350', 378)]),
        ]),
      ]);
      expect(table.columns.map((c) => c.label), ['$numberedPrefix' '1', '$numberedPrefix' '2']);
      expect(table.rows.first.prices.values, ['1200', '1300']);
    });

    test('a page with no text is a scanned page', () {
      final table = extractPriceTable([const PdfPageLines(1, [], 0), const PdfPageLines(2, [], 3)]);
      expect(table.scannedPages, [1, 2]);
      expect(table.allScanned, isTrue);
      expect(table.rows, isEmpty);
    });

    test('the same row printed twice is read once', () {
      final row = _line(680, [('WC-100', 40), ('2400', 300)]);
      final table = extractPriceTable([
        _page(1, [_line(700, [('Code', 40), ('Price', 300)]), row]),
        _page(2, [_line(700, [('Code', 40), ('Price', 300)]), row]),
      ]);
      expect(table.rows, hasLength(1));
    });
  });

  group('into the price list', () {
    late Shop shop;
    late PriceListImportService imports;
    late int brand;

    setUp(() async {
      shop = await Shop.open();
      imports = PriceListImportService(shop.db);
      brand = await CatalogService(shop.db).saveBrand(name: 'Sanipure');
    });
    tearDown(() => shop.close());

    PdfPriceTable table() => PdfPriceTable(
          columns: [PdfPriceColumn('أبيض', 2), PdfPriceColumn('برجامون', 1), PdfPriceColumn('${unnamedPrefix}1', 1)],
          rows: [
            PdfPriceRow(page: 4, code: 'WC-100', name: 'Toilet', prices: {'أبيض': '2,400', 'برجامون': '2650'}),
            PdfPriceRow(
              page: 5,
              code: 'BS-55',
              name: 'Basin',
              prices: {'أبيض': '900', '${unnamedPrefix}1': '550'},
              issue: 'رقم 777 لا يقع تحت عمود سعر',
            ),
          ],
          pagesRead: const [4, 5],
          scannedPages: const [],
        );

    test('each chosen column is a colour; doubtful rows wait for review with their page', () async {
      final known = await ProductService(shop.db).create(
        ProductInput(nameAr: 'طقم', manufacturerCode: 'WC-100', brandId: brand, variant: 'أبيض'),
      );
      final preview = await imports.previewPdf(table(), brandId: brand, include: {'أبيض', 'برجامون'});
      expect(preview.rows, hasLength(3));
      final white = preview.rows.firstWhere((r) => r.code == 'WC-100' && r.variant == 'أبيض');
      expect(white.productId, known.id);
      expect(white.price, 240000);
      expect(preview.rows.firstWhere((r) => r.variant == 'برجامون').action, PriceRowAction.create);
      final basin = preview.rows.firstWhere((r) => r.code == 'BS-55');
      expect(basin.ok, isFalse);
      expect(basin.reviewReason, contains('777'));

      final result = await imports.import(
        preview,
        header: PriceListHeader(
          name: 'سانيبور نوفمبر',
          brandId: brand,
          listType: 'أطقم',
          effectiveFrom: DateTime(2026, 11, 1),
          sourceFile: 'sanipure.pdf',
          sourcePages: '4-5',
        ),
        user: shop.admin,
      );
      expect(result.review, 1);
      final queue = await PriceListService(shop.db).reviewQueue(listId: result.id);
      expect(queue.single.sourceRow, 5);
      expect(queue.single.reviewReason, contains('777'));
    });

    test('one chosen column means no colour', () async {
      final preview = await imports.previewPdf(table(), brandId: brand, include: {'أبيض'});
      expect(preview.rows.map((r) => r.variant), everyElement(isNull));
      expect(preview.rows, hasLength(2));
    });

    test('a renamed column takes its new name as the colour', () async {
      final preview = await imports.previewPdf(
        table(),
        brandId: brand,
        include: {'أبيض', '${unnamedPrefix}1'},
        rename: {'${unnamedPrefix}1': 'أسود'},
      );
      expect(preview.rows.where((r) => r.variant == 'أسود').single.code, 'BS-55');
    });

    test('nothing chosen cannot be imported', () async {
      final preview = await imports.previewPdf(table(), brandId: brand, include: const {});
      expect(preview.canImport, isFalse);
    });
  });

  // Reads a real PDF through PDFium; the library comes with the Windows build.
  final dll = File('${Directory.current.path}/build/windows/x64/runner/Release/pdfium.dll');
  test('a text PDF is read through PDFium', () async {
    PdfTextReader.useModule(dll.path);
    final doc = pw.Document()
      ..addPage(pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (_) => pw.Column(children: [
          pw.Row(children: [
            pw.SizedBox(width: 120, child: pw.Text('Code')),
            pw.SizedBox(width: 200, child: pw.Text('Description')),
            pw.SizedBox(width: 80, child: pw.Text('Price')),
          ]),
          for (final (code, name, price) in [('WC-100', 'Toilet', '2,400'), ('BS-55', 'Basin', '900')])
            pw.Row(children: [
              pw.SizedBox(width: 120, child: pw.Text(code)),
              pw.SizedBox(width: 200, child: pw.Text(name)),
              pw.SizedBox(width: 80, child: pw.Text(price)),
            ]),
        ]),
      ));
    final dir = await Directory.systemTemp.createTemp('pdf_import');
    final file = File('${dir.path}/list.pdf');
    await file.writeAsBytes(await doc.save());
    try {
      expect(await const PdfTextReader().pageCount(file), 1);
      final table = extractPriceTable(await const PdfTextReader().read(file));
      expect(table.rows.map((r) => (r.code, r.prices.values.single)), [('WC-100', '2,400'), ('BS-55', '900')]);
    } finally {
      await dir.delete(recursive: true);
    }
  }, skip: dll.existsSync() ? false : 'pdfium.dll is made by "flutter build windows"');
}
