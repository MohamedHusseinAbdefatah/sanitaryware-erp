import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/pricing_math.dart';
import 'package:sanitaryware_erp/core/services/catalog_service.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/price_list_service.dart';
import 'package:sanitaryware_erp/core/services/product_service.dart';

import '../support/fixture.dart';

/// Blueprint 3.3: versions, periods and price history.
void main() {
  late Shop shop;
  late PriceListService lists;
  late int duravit;
  late Product basin;

  setUp(() async {
    shop = await Shop.open();
    lists = PriceListService(shop.db);
    duravit = await CatalogService(shop.db).saveBrand(name: 'Duravit');
    basin = await ProductService(shop.db).create(
      ProductInput(nameAr: 'حوض', manufacturerCode: '0123-A', brandId: duravit),
    );
  });
  tearDown(() => shop.close());

  PriceListHeader header(String type, DateTime from, {DateTime? to}) => PriceListHeader(
        name: '$type ${from.year}',
        brandId: duravit,
        listType: type,
        effectiveFrom: from,
        effectiveTo: to,
      );

  Future<int> version(String type, DateTime from, int price, {bool close = true}) async => (await lists.createVersion(
        header(type, from),
        rows: [PriceRowInput(name: 'حوض', price: price, manufacturerCode: '0123-A', productId: basin.id)],
        user: shop.admin,
        closePrevious: close,
      ))
          .id;

  test('V1 ends June 30 when V2 starts July 1; each date gets its own version', () async {
    final v1 = await version('سيراميك', DateTime(2026, 1, 1), 100000);
    final v2 = await version('سيراميك', DateTime(2026, 7, 1), 120000);
    expect(v2, isNot(v1));

    final first = await (shop.db.select(shop.db.priceLists)..where((l) => l.id.equals(v1))).getSingle();
    expect(first.effectiveTo, DateTime(2026, 6, 30));
    final second = await (shop.db.select(shop.db.priceLists)..where((l) => l.id.equals(v2))).getSingle();
    expect(second.versionNo, 2);
    expect(second.effectiveTo, isNull);

    Future<PriceQuote> on(DateTime d) async => (await lists.quotesFor(basin.id, asOf: d)).single;
    expect((await on(DateTime(2026, 6, 30))).priceListId, v1);
    expect((await on(DateTime(2026, 6, 30))).price, 100000);
    expect((await on(DateTime(2026, 7, 1))).priceListId, v2);
    expect((await on(DateTime(2026, 7, 1))).price, 120000);
    expect(await lists.quotesFor(basin.id, asOf: DateTime(2025, 12, 31)), isEmpty);
  });

  test('old versions are never overwritten or erased: the history keeps every price', () async {
    await version('سيراميك', DateTime(2026, 1, 1), 100000);
    await version('سيراميك', DateTime(2026, 7, 1), 120000);
    final history = await lists.history(basin.id);
    expect(history.map((h) => h.item.price), [120000, 100000]);
  });

  test('a product priced in a version cannot be changed in it; that takes a new version', () async {
    final v1 = await version('سيراميك', DateTime(2026, 1, 1), 100000);
    await expectLater(
      lists.addEntries(v1, [PriceRowInput(name: 'حوض', price: 110000, productId: basin.id)], user: shop.admin),
      throwsA(isA<ValidationException>()),
    );
    expect((await lists.items(v1)).single.price, 100000);
  });

  test('a new version cannot start before an existing one', () async {
    await version('سيراميك', DateTime(2026, 7, 1), 120000);
    await expectLater(version('سيراميك', DateTime(2026, 1, 1), 90000), throwsA(isA<ValidationException>()));
  });

  test('a list sent again on the same day replaces the first from that day', () async {
    final v1 = await version('سيراميك', DateTime(2026, 7, 1), 120000);
    final v2 = await version('سيراميك', DateTime(2026, 7, 1), 132000);
    final q = (await lists.quotesFor(basin.id, asOf: DateTime(2026, 7, 1))).single;
    expect(q.priceListId, v2);
    expect(q.price, 132000);
    // V1 stays on record.
    expect((await lists.history(basin.id)).map((h) => h.list.id), containsAll([v1, v2]));
  });

  test('more than one list for a brand: Ceramic and Bathtubs stand apart, and the person chooses', () async {
    final ceramic = await version('سيراميك', DateTime(2026, 1, 1), 100000);
    final tubs = await version('بانيوهات', DateTime(2026, 7, 1), 200000);
    final first = await (shop.db.select(shop.db.priceLists)..where((l) => l.id.equals(ceramic))).getSingle();
    expect(first.effectiveTo, isNull, reason: 'another list type must not close this one');
    final quotes = await lists.quotesFor(basin.id, asOf: DateTime(2026, 8, 1));
    expect(quotes.map((q) => q.priceListId).toSet(), {ceramic, tubs});
  });

  test('a version for a few products leaves the rest of the earlier list in force', () async {
    final other = await ProductService(shop.db)
        .create(ProductInput(nameAr: 'مرحاض', manufacturerCode: 'B-9', brandId: duravit));
    final full = (await lists.createVersion(
      header('سيراميك', DateTime(2026, 1, 1)),
      rows: [
        PriceRowInput(name: 'حوض', price: 100000, productId: basin.id),
        PriceRowInput(name: 'مرحاض', price: 300000, productId: other.id),
      ],
      user: shop.admin,
    ))
        .id;
    final partial = await version('سيراميك', DateTime(2026, 7, 1), 120000, close: false);

    final day = DateTime(2026, 8, 1);
    expect((await lists.quotesFor(basin.id, asOf: day)).single.priceListId, partial);
    expect((await lists.quotesFor(other.id, asOf: day)).single.priceListId, full);
  });

  test('the record holds type, currency, dates, source, row count and VAT status', () async {
    final id = (await lists.createVersion(
      PriceListHeader(
        name: 'ديورافيت',
        brandId: duravit,
        listType: 'سيراميك',
        effectiveFrom: DateTime(2026, 1, 1),
        vatStatus: VatStatus.inclusive,
        vatRateBp: 1400,
        sourceFile: 'file.xlsx',
        sourcePages: '3-9',
      ),
      rows: [PriceRowInput(name: 'حوض', price: 100000, productId: basin.id)],
      user: shop.admin,
      rowCountOnSource: 7,
    ))
        .id;
    final l = await (shop.db.select(shop.db.priceLists)..where((t) => t.id.equals(id))).getSingle();
    expect(l.brandId, duravit);
    expect(l.currency, 'EGP');
    expect(l.sourceFile, 'file.xlsx');
    expect(l.sourcePages, '3-9');
    expect(l.rowCount, 7);
    expect(l.vatStatus, VatStatus.inclusive);
    expect(l.vatRateBp, 1400);
    expect(l.importDate.isAfter(DateTime(2020)), isTrue);
  });

  test('VAT stays unverified until someone records it from the source', () async {
    final id = await version('سيراميك', DateTime(2026, 1, 1), 100000);
    var l = await (shop.db.select(shop.db.priceLists)..where((t) => t.id.equals(id))).getSingle();
    expect(l.vatStatus, VatStatus.unverified);
    await lists.setVat(id, vatStatus: VatStatus.exclusive, vatRateBp: 1400, user: shop.admin);
    l = await (shop.db.select(shop.db.priceLists)..where((t) => t.id.equals(id))).getSingle();
    expect(l.vatStatus, VatStatus.exclusive);
    expect(l.vatRateBp, 1400);
  });

  test('a currency with no exchange rate is refused, not guessed at', () async {
    await expectLater(
      lists.createVersion(
        PriceListHeader(name: 'x', brandId: duravit, listType: 'x', effectiveFrom: DateTime(2026), currency: 'EUR'),
        rows: [PriceRowInput(name: 'حوض', price: 1, productId: basin.id)],
        user: shop.admin,
      ),
      throwsA(isA<ValidationException>()),
    );
  });

  test('a withdrawn version prices nothing but stays on record', () async {
    final id = await version('سيراميك', DateTime(2026, 1, 1), 100000);
    await lists.withdraw(id, reason: 'خطأ', user: shop.admin);
    expect(await lists.quotesFor(basin.id, asOf: DateTime(2026, 2, 1)), isEmpty);
    expect((await lists.history(basin.id)).single.item.price, 100000);
  });

  test('only the admin manages lists', () async {
    await expectLater(
      lists.createVersion(header('x', DateTime(2026)), rows: const [], user: shop.cashier),
      throwsA(isA<ValidationException>()),
    );
  });
}
