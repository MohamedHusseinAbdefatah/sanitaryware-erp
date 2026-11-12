// Renders the main screens of the real app, with the real Arabic font and
// icons, into docs/screenshots/*.png for the user guide.
//
//   flutter test tool/docs/screenshots_test.dart
//
// It lives outside test/ so normal test runs do not rewrite the images.
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sanitaryware_erp/app.dart';
import 'package:sanitaryware_erp/core/auth/session.dart';
import 'package:sanitaryware_erp/core/backup/backup_service.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/l10n/strings.dart';
import 'package:sanitaryware_erp/core/providers.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/router.dart';
import 'package:sanitaryware_erp/core/services/buying_policy_service.dart';
import 'package:sanitaryware_erp/core/services/catalog_service.dart';
import 'package:sanitaryware_erp/core/widgets/number_fields.dart';
import 'package:sanitaryware_erp/core/widgets/pickers.dart';
import 'package:sanitaryware_erp/core/services/party_service.dart';
import 'package:sanitaryware_erp/core/services/payment_service.dart';
import 'package:sanitaryware_erp/core/pricing_math.dart';
import 'package:sanitaryware_erp/core/services/price_list_service.dart';
import 'package:sanitaryware_erp/core/services/product_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_service.dart';
import 'package:sanitaryware_erp/core/services/sales_service.dart';
import 'package:sanitaryware_erp/core/services/selling_policy_service.dart';
import 'package:sanitaryware_erp/core/services/settings_service.dart';

import '../../test/support/fixture.dart';

const _size = Size(1280, 800);
final _out = Directory('docs/screenshots');

Future<void> _loadFonts() async {
  final cairo = FontLoader('Cairo')
    ..addFont(rootBundle.load('assets/fonts/Cairo-Regular.ttf'))
    ..addFont(rootBundle.load('assets/fonts/Cairo-Bold.ttf'));
  await cairo.load();
  // The Material icons font ships inside the Flutter SDK.
  final flutterRoot = File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
  final iconsFile = File('$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf');
  final icons = FontLoader('MaterialIcons')
    ..addFont(iconsFile.readAsBytes().then((b) => ByteData.sublistView(b)));
  await icons.load();
}

/// A small, realistic shop: two suppliers, a few products, customers with
/// balances, sales, a payment and a pending cheque.
Future<(Shop, SalesInvoice)> _shopWithData() async {
  final shop = await Shop.open(customerCreditLimit: 2000000);
  final db = shop.db;
  await SettingsService(db).saveCompany(
    const CompanyInfo(name: 'معرض النيل للأدوات الصحية', address: 'شارع الجمهورية، المنصورة', phone: '0501234567'),
  );
  final catalog = CatalogService(db);
  final mixers = await catalog.saveCategory(name: 'خلاطات');
  final basins = await catalog.saveCategory(name: 'أحواض');
  final pipes = await catalog.saveCategory(name: 'مواسير');
  final grohe = await catalog.saveBrand(name: 'Grohe');
  final units = await db.select(db.units).get();
  final piece = units.firstWhere((u) => u.nameAr == 'قطعة').id;
  final meter = units.firstWhere((u) => u.nameAr == 'متر').id;
  final products = ProductService(db);
  await products.update(
    shop.mixer.id,
    ProductInput(code: 'M1', manufacturerCode: 'M1', nameAr: 'خلاط حوض جروهي كروم', categoryId: mixers, brandId: grohe,
        unitId: piece, minStock: qtyOf(5)),
  );
  await products.update(
    shop.pipe.id,
    ProductInput(code: 'P1', manufacturerCode: 'P1', nameAr: 'ماسورة بولي بروبلين 25 مم', categoryId: pipes, unitId: meter,
        minStock: qtyOf(50)),
  );
  final basin = await products.create(
    ProductInput(code: 'B10', manufacturerCode: 'B10', nameAr: 'حوض معلق أبيض 60 سم', categoryId: basins, unitId: piece),
    openingQty: qtyOf(12),
    openingCost: 90000,
  );
  await products.create(
    ProductInput(code: 'M2', manufacturerCode: 'M2', nameAr: 'خلاط مطبخ جروهي', categoryId: mixers, brandId: grohe,
        unitId: piece, minStock: qtyOf(3)),
    openingQty: qtyOf(2),
    openingCost: 150000,
  );

  final parties = PartyService(db);
  await parties.saveCustomer(
    const CustomerInput(name: 'عميل نقدي معروف', phone: '01001234567', priceLevel: PriceLevel.retail),
    id: shop.customerId,
  );
  final contractor = await parties.saveCustomer(const CustomerInput(
    name: 'شركة النور للمقاولات',
    phone: '01112223334',
    address: 'طلخا',
    priceLevel: PriceLevel.contractor,
    creditLimit: 5000000,
    openingBalance: 250000,
  ));
  await parties.saveSupplier(const SupplierInput(name: 'مورد'), id: shop.supplierId);

  // Customer categories with their usual discounts, and one special discount.
  final selling = SellingPolicyService(db);
  for (final (id, name, bp) in const [(2, 'جملة', 1000), (3, 'مشروعات ومقاولون', 1500), (4, 'مهندسين', 1200)]) {
    await selling.saveCategory(CustomerCategoryInput(name: name, discountBp: bp), id: id, user: shop.admin);
  }
  final brandId = (await db.select(db.brands).get()).first.id;
  await selling.add(
    SellingPolicyInput(customerCategoryId: 4, brandId: brandId, discountBp: 1500, maxDiscountBp: 2000, note: 'اتفاق المهندسين'),
    user: shop.admin,
  );
  final supplier = await parties.saveSupplier(const SupplierInput(name: 'الشركة المصرية للخلاطات', phone: '0223334455'));

  await PurchaseService(db).post(
    PurchaseInput(
      supplierId: supplier,
      supplierInvoiceNo: 'INV-5521',
      lines: [
        PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(20), unitCost: 95000),
        PurchaseLineInput(productId: shop.pipe.id, qty: qtyOf(300), unitCost: 2200),
      ],
      paidAmount: 1000000,
    ),
    user: shop.admin,
  );
  // A new list arrives, then more stock at the new price.
  await PriceListService(db).createVersion(
    PriceListHeader(
      name: 'قائمة جروهي يوليو',
      brandId: shop.brandId,
      listType: 'عام',
      effectiveFrom: DateTime.now(),
      sourceFile: 'grohe_july.xlsx',
      vatStatus: VatStatus.inclusive,
      vatRateBp: 1400,
    ),
    rows: [
      PriceRowInput(name: 'خلاط حوض جروهي كروم', price: 125000, manufacturerCode: 'M1', productId: shop.mixer.id),
      PriceRowInput(name: 'ماسورة بولي بروبلين 25 مم', price: 3500, manufacturerCode: 'P1', productId: shop.pipe.id),
    ],
    user: shop.admin,
  );
  await PurchaseService(db).post(
    PurchaseInput(
      supplierId: supplier,
      lines: [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(8), unitCost: 100000)],
    ),
    user: shop.admin,
  );
  final sales = SalesService(db);
  await sales.post(
    SaleInput(
      lines: [SaleLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitPrice: 125000)],
      paidAmount: 125000,
    ),
    userId: shop.admin.id,
  );
  final credit = await sales.post(
    SaleInput(
      customerId: contractor,
      lines: [
        SaleLineInput(productId: shop.mixer.id, qty: qtyOf(4), unitPrice: 110000),
        SaleLineInput(productId: shop.pipe.id, qty: 62500, unitPrice: 2800),
        SaleLineInput(productId: basin.id, qty: qtyOf(3), unitPrice: 120000),
      ],
      discount: 5000,
      paidAmount: 300000,
    ),
    userId: shop.admin.id,
  );
  await PaymentService(db).receive(PaymentInput(
    partyId: contractor,
    amount: 200000,
    method: PaymentMethod.cheque,
    cheque: ChequeInput(number: '458812', bank: 'البنك الأهلي', dueDate: DateTime.now().add(const Duration(days: 4))),
  ));
  // The supplier's agreed discount on the list in force, for the purchase screen.
  final inForce = (await PriceListService(db).quotesFor(shop.mixer.id)).single.priceListId;
  await BuyingPolicyService(db).add(
    BuyingPolicyInput(supplierId: supplier, brandId: shop.brandId, priceListId: inForce, baseDiscountBp: 2000),
    user: shop.admin,
  );
  return (shop, credit);
}

void main() {
  late Shop shop;
  late SalesInvoice creditInvoice;
  final boundary = GlobalKey();

  setUpAll(() async {
    await _loadFonts();
    await _out.create(recursive: true);
  });

  setUp(() async {
    final made = await _shopWithData();
    shop = made.$1;
    creditInvoice = made.$2;
  });

  tearDown(() => shop.close());

  Future<void> settle(WidgetTester tester, [int rounds = 10]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpApp(WidgetTester tester, {User? user}) async {
    tester.view.physicalSize = _size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(shop.db),
            databaseFileProvider.overrideWithValue(File('unused.sqlite')),
            backupServiceProvider.overrideWithValue(BackupService(dir: Directory('unused'))),
            setupNeededProvider.overrideWith((ref) => false),
            currentUserProvider.overrideWith((ref) => user),
          ],
          child: const App(),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> shot(WidgetTester tester, String name) async {
    await settle(tester, 4);
    final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    // Image encoding and file writes need real time, not the test's fake clock.
    await tester.runAsync(() async {
      final image = await render.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${_out.path}/$name.png').writeAsBytes(data!.buffer.asUint8List());
    });
  }

  GoRouter router(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(App))).read(routerProvider);

  Future<void> go(WidgetTester tester, String path) async {
    router(tester).go(path);
    await settle(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  }

  testWidgets('login', (tester) async {
    await pumpApp(tester);
    await shot(tester, '01_login');
    await unmount(tester);
  });

  testWidgets('admin screens', (tester) async {
    await pumpApp(tester, user: shop.admin);
    await shot(tester, '02_dashboard');

    await go(tester, '/inventory');
    await shot(tester, '15_inventory');

    await go(tester, '/products');
    await shot(tester, '03_products');

    await tester.tap(find.byType(PopupMenuButton<void Function()>).at(1));
    await settle(tester);
    await tester.tap(find.text('المخزون حسب السعر').last);
    await settle(tester);
    await shot(tester, '14_stock_by_price');
    await tester.tap(find.text(Strings.close).last);
    await settle(tester);

    await go(tester, '/price-lists');
    await shot(tester, '13_price_lists');
    await tester.tap(find.text('خصومات البيع'));
    await settle(tester);
    await shot(tester, '16_selling_discounts');

    // A purchase: supplier, two products at the agreed discount, one priced
    // above it by the supplier, and transport.
    await go(tester, '/purchases/new');
    await tester.enterText(find.widgetWithText(TextField, Strings.supplier), 'المصرية');
    await settle(tester);
    await tester.tap(find.text('الشركة المصرية للخلاطات').last);
    await settle(tester);
    final search = find.descendant(of: find.byType(ProductSearchField), matching: find.byType(TextField));
    for (final code in ['M1', 'P1']) {
      await tester.enterText(search, code);
      await settle(tester);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
    }
    await tester.enterText(find.byType(QtyField).at(0), '10');
    await tester.enterText(find.byType(QtyField).at(1), '200');
    await tester.enterText(find.byType(MoneyField).at(1), '30');
    await tester.enterText(find.widgetWithText(TextFormField, 'نقل وتحميل'), '450');
    await tester.enterText(find.widgetWithText(TextField, Strings.supplierInvoiceNo), 'INV-5602');
    await settle(tester);
    await shot(tester, '17_purchase_entry');

    await go(tester, '/sales/new');
    await tester.enterText(find.byType(TextField).at(1), 'M1');
    await settle(tester);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.enterText(find.byType(TextField).at(1), 'P1');
    await settle(tester);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextFormField, '1').last, '12.5');
    await settle(tester);
    await shot(tester, '04_sale_entry');

    await tester.tap(find.text('${Strings.save} (Ctrl+S)'));
    await settle(tester);
    await shot(tester, '15_sale_review');
    await tester.tap(find.text(Strings.cancel).last);
    await settle(tester);

    await go(tester, '/sales/${creditInvoice.id}');
    await shot(tester, '05_sale_view');

    await tester.tap(find.text(Strings.receivePayment));
    await settle(tester);
    await shot(tester, '06_receive_payment');
    await tester.tap(find.text(Strings.cancel).last);
    await settle(tester);

    await go(tester, '/customers');
    await shot(tester, '07_customers');

    await tester.tap(find.byType(PopupMenuButton<VoidCallback>).first); // the contractor (sorted first)
    await settle(tester);
    await tester.tap(find.text(Strings.statement).last);
    await settle(tester);
    await tester.tap(find.text(Strings.allTime));
    await settle(tester);
    await shot(tester, '08_statement');
    await tester.tap(find.byTooltip(Strings.close));
    await settle(tester);

    await go(tester, '/payments');
    await tester.tap(find.text(Strings.cheques));
    await settle(tester);
    await shot(tester, '09_cheques');

    await go(tester, '/returns/new?kind=sale&invoice=${creditInvoice.id}');
    await tester.enterText(find.widgetWithText(TextFormField, Strings.returnQty).first, '1');
    await settle(tester);
    await shot(tester, '10_return');

    await go(tester, '/reports');
    await shot(tester, '11_reports');

    await go(tester, '/settings');
    await shot(tester, '12_settings');
    await unmount(tester);
  });
}
