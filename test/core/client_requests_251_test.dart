// 2.5.1: the client's requests of 21 Nov 2026.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:sanitaryware_erp/core/pricing_math.dart';
import 'package:sanitaryware_erp/core/printing/documents.dart';
import 'package:sanitaryware_erp/core/printing/pdf_fonts.dart';
import 'package:sanitaryware_erp/core/printing/test_page.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/services/buying_policy_service.dart';
import 'package:sanitaryware_erp/core/services/price_list_service.dart';
import 'package:sanitaryware_erp/core/services/product_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_order_service.dart';
import 'package:sanitaryware_erp/core/services/settings_service.dart';

import '../support/fixture.dart';

ByteData _font(String name) => ByteData.sublistView(File('assets/fonts/$name').readAsBytesSync());

void main() {
  group('duplicate codes with invisible characters', () {
    test('vowel marks, tatweel and invisible marks do not change the match key', () {
      expect(matchKeyOf('00123-Aِ'), matchKeyOf('00123-A'));
      expect(matchKeyOf('00123-ِA'), '00123-A');
      expect(matchKeyOf('‏00123ـ-a​'), '00123-A');
      expect(matchKeyOf('Kَ310ّ427'), 'K310427');
      // Real characters still count.
      expect(matchKeyOf('00123-B'), isNot(matchKeyOf('00123-A')));
    });

    test('a code typed with a kasra is refused as a duplicate', () async {
      final shop = await Shop.open();
      addTearDown(shop.close);
      await expectLater(
        ProductService(shop.db).create(ProductInput(
            manufacturerCode: 'M1ِ', nameAr: 'نسخة', brandId: shop.brandId, unitId: shop.mixer.unitId)),
        throwsA(anything),
      );
    });

    test('keys saved by an older version are brought up to date on start', () async {
      final shop = await Shop.open();
      addTearDown(shop.close);
      // As 2.5.0 stored it: the kasra kept in the key.
      await shop.db.customStatement(
          "UPDATE products SET manufacturer_code = 'M1ِ', match_key = 'M1ِ' WHERE id = ?", [shop.mixer.id]);
      await shop.db.refreshMatchKeys();
      final p = await (shop.db.select(shop.db.products)..where((t) => t.id.equals(shop.mixer.id))).getSingle();
      expect(p.matchKey, 'M1');
      expect(p.manufacturerCode, 'M1ِ', reason: 'the code as typed is kept');
    });
  });

  group('buying discount by list category (فاخر، اقتصادي)', () {
    test('a supplier with no recorded discount is priced by the list category; its own discount wins', () async {
      final shop = await Shop.open();
      addTearDown(shop.close);
      final lists = PriceListService(shop.db);
      final luxury = await lists.saveCategory(name: 'فاخر', buyingDiscountBp: 1000, user: shop.admin);
      final economy = await lists.saveCategory(name: 'اقتصادي', buyingDiscountBp: 2500, user: shop.admin);
      final buying = BuyingPolicyService(shop.db);

      // The mixer's list (500.00) as فاخر: 10% off.
      await lists.setListCategory(shop.priceListId, luxury, user: shop.admin);
      var q = (await buying.quotes(shop.mixer.id, supplierId: shop.supplierId)).single;
      expect(q.netCost, 45000);
      expect(q.fromCategory, isTrue);

      // The same list moved to اقتصادي: 25% off.
      await lists.setListCategory(shop.priceListId, economy, user: shop.admin);
      q = (await buying.quotes(shop.mixer.id, supplierId: shop.supplierId)).single;
      expect(q.netCost, 37500);

      // The supplier's own recorded discount (30%) comes before the category.
      await buying.add(
        BuyingPolicyInput(supplierId: shop.supplierId, brandId: shop.brandId, priceListId: shop.priceListId, baseDiscountBp: 3000),
        user: shop.admin,
      );
      q = (await buying.quotes(shop.mixer.id, supplierId: shop.supplierId)).single;
      expect(q.netCost, 35000);
      expect(q.fromCategory, isFalse);
    });

    test('a list with no category and no supplier discount invents no cost', () async {
      final shop = await Shop.open();
      addTearDown(shop.close);
      final q = (await BuyingPolicyService(shop.db).quotes(shop.mixer.id, supplierId: shop.supplierId)).single;
      expect(q.netCost, isNull);
    });
  });

  group('printing', () {
    late PdfFonts fonts;
    setUp(() => fonts = PdfFonts.fromBytes(regular: _font('Cairo-Regular.ttf'), bold: _font('Cairo-Bold.ttf')));
    void expectPdf(Uint8List bytes) => expect(String.fromCharCodes(bytes.take(5)), '%PDF-');

    /// Writes the PDF when PDF_OUT_DIR is set, so it can be looked at.
    void keep(String name, Uint8List bytes) {
      final dir = Platform.environment['PDF_OUT_DIR'];
      if (dir != null) File('$dir/$name.pdf').writeAsBytesSync(bytes);
    }

    test('a purchase order prints for the supplier (no prices) and for the shop (with prices)', () async {
      final shop = await Shop.open();
      addTearDown(shop.close);
      final orders = PurchaseOrderService(shop.db);
      final id = await orders.createDraft(
        supplierId: shop.supplierId,
        lines: [
          PoLineInput(productId: shop.mixer.id, qty: qtyOf(10)),
          PoLineInput(productId: shop.pipe.id, qty: 25500),
        ],
        expectedDate: DateTime(2026, 12, 1),
        notes: 'للمشروع',
        user: shop.admin,
      );
      final draft = await orders.detail(id);
      await orders.approve(id, manualCosts: {for (final l in draft.lines) l.line.id: 30000}, user: shop.admin);
      final d = await orders.detail(id);
      const company = PrintCompany(name: 'Instalux');
      final forSupplier = await purchaseOrderPdf(d, company, fonts, withPrices: false, supplierPhone: '0100');
      final internal = await purchaseOrderPdf(d, company, fonts, withPrices: true);
      expectPdf(forSupplier);
      expectPdf(internal);
      keep('po_supplier', forSupplier);
      keep('po_internal', internal);
      expect(internal.length, greaterThan(forSupplier.length), reason: 'the internal copy carries the prices');
    });

    test('the test page lays out inside a printer margin at the foot of the page', () async {
      // A printer that cannot print the last 2 cm of the sheet.
      final printer = PdfPageFormat.a4.copyWith(marginBottom: 2 * PdfPageFormat.cm, marginTop: 0.5 * PdfPageFormat.cm);
      final bytes = await buildTestPage(
        fonts: fonts,
        company: const CompanyInfo(name: 'Instalux', address: 'القاهرة', phone: '0100'),
        printedAt: DateTime(2026, 11, 21, 17, 12),
        printer: printer,
      );
      expectPdf(bytes);
      keep('test_page', bytes);
    });
  });
}
