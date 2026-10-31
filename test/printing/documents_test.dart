import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/printing/documents.dart';
import 'package:sanitaryware_erp/core/printing/pdf_fonts.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/reports/report_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_service.dart';
import 'package:sanitaryware_erp/core/services/sales_service.dart';
import 'package:sanitaryware_erp/core/services/statement_service.dart';
import 'package:sanitaryware_erp/features/parties/statement_dialog.dart';

import '../support/fixture.dart';

ByteData _font(String name) => ByteData.sublistView(File('assets/fonts/$name').readAsBytesSync());

void main() {
  late Shop shop;
  late PdfFonts fonts;
  const company = PrintCompany(name: 'معرض النيل للأدوات الصحية', address: 'المنصورة', phone: '0100');

  /// Writes the PDF next to the test output when PDF_OUT_DIR is set, so it
  /// can be looked at.
  void keep(String name, Uint8List bytes) {
    final dir = Platform.environment['PDF_OUT_DIR'];
    if (dir != null) File('$dir/$name.pdf').writeAsBytesSync(bytes);
  }

  void expectPdf(Uint8List bytes) => expect(String.fromCharCodes(bytes.take(5)), '%PDF-');

  setUp(() async {
    shop = await Shop.open();
    fonts = PdfFonts.fromBytes(regular: _font('Cairo-Regular.ttf'), bold: _font('Cairo-Bold.ttf'));
    await PurchaseService(shop.db).post(
      PurchaseInput(
        supplierId: shop.supplierId,
        supplierInvoiceNo: 'INV-77',
        lines: [
          PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(40), unitCost: 40000),
          PurchaseLineInput(productId: shop.pipe.id, qty: qtyOf(100), unitCost: 2000),
        ],
        paidAmount: 500000,
      ),
      user: shop.admin,
    );
  });

  tearDown(() => shop.close());

  test('sales invoice, also cancelled and with many lines', () async {
    final sales = SalesService(shop.db);
    final inv = await sales.post(
      SaleInput(
        customerId: shop.customerId,
        lines: [
          for (var i = 0; i < 35; i++) // enough for a second page
            SaleLineInput(productId: i.isEven ? shop.mixer.id : shop.pipe.id, qty: i.isEven ? qtyOf(1) : 2500,
                unitPrice: i.isEven ? 50000 : 3500, discount: i == 0 ? 1000 : 0),
        ],
        discount: 500,
        paidAmount: 100000,
      ),
      userId: shop.admin.id,
    );
    final bytes = await salesInvoicePdf(await sales.detail(inv.id), company, fonts);
    expectPdf(bytes);
    keep('sales_invoice', bytes);

    await sales.cancel(inv.id, reason: 'تجربة', user: shop.admin);
    final cancelled = await salesInvoicePdf(await sales.detail(inv.id), company, fonts);
    expectPdf(cancelled);
    keep('sales_invoice_cancelled', cancelled);
  });

  test('purchase invoice', () async {
    final service = PurchaseService(shop.db);
    final id = (await service.watchList().first).single.invoice.id;
    final bytes = await purchaseInvoicePdf(await service.detail(id), company, fonts);
    expectPdf(bytes);
    keep('purchase_invoice', bytes);
  });

  test('receipt', () async {
    final bytes = await receiptPdf(
      ReceiptData(
        number: 'R-000002',
        date: DateTime(2026, 10, 31, 12),
        received: true,
        partyName: 'عميل',
        amount: 125050,
        method: PaymentMethod.cheque,
        chequeNo: '123456',
        bank: 'البنك الأهلي',
        dueDate: DateTime(2026, 11, 30),
        forWhat: 'فاتورة بيع S-000012',
      ),
      company,
      fonts,
    );
    expectPdf(bytes);
    keep('receipt', bytes);
  });

  test('statement and a wide report', () async {
    await SalesService(shop.db).post(
      SaleInput(
        customerId: shop.customerId,
        lines: [SaleLineInput(productId: shop.mixer.id, qty: qtyOf(2), unitPrice: 50000)],
      ),
      userId: shop.admin.id,
    );
    final s = await StatementService(shop.db).customer(shop.customerId);
    final statement = await tablePdf(statementTable(s, isCustomer: true), company, fonts);
    expectPdf(statement);
    keep('statement', statement);

    final report = await ReportService(shop.db).salesByProduct();
    final bytes = await tablePdf(report, company, fonts, from: DateTime(2026, 10), to: DateTime(2026, 10, 31));
    expectPdf(bytes);
    keep('report_landscape', bytes);
  });
}
