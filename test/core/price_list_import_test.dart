import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/price_list_import_service.dart';

import '../support/fixture.dart';

List<int> sheet(List<List<Object>> rows) {
  final excel = Excel.createExcel();
  final s = excel[excel.getDefaultSheet()!];
  for (final r in rows) {
    s.appendRow([
      for (final v in r)
        v is int ? IntCellValue(v) : (v is double ? DoubleCellValue(v) : TextCellValue('$v')),
    ]);
  }
  return excel.encode()!;
}

void main() {
  late Shop shop;
  late PriceListImportService svc;

  setUp(() async {
    shop = await Shop.open();
    svc = PriceListImportService(shop.db);
  });
  tearDown(() => shop.db.close());

  test('the template reads back with the expected columns and no rows', () {
    final p = svc.preview(svc.template());
    expect(p.missingColumns, isEmpty);
    expect(p.rows, isEmpty);
  });

  test('single price column, with colour and pack size', () {
    final p = svc.preview(sheet([
      ['الكود', 'الاسم', 'اللون', 'السعر', 'عدد الكرتونة'],
      ['M1', 'خلاط', 'أبيض', 2400, 12],
      ['X9', 'حوض', '', '50,00', ''],
    ]));
    expect(p.errorCount, 0, reason: p.rows.expand((r) => r.errors).join(' | '));
    expect(p.rows[0].input!.price, 240000);
    expect(p.rows[0].input!.packSize, 12);
    expect(p.rows[0].input!.colour, 'أبيض');
    expect(p.rows[1].input!.price, 5000);
  });

  test('one price column per colour becomes one line per colour', () {
    final p = svc.preview(sheet([
      ['الكود', 'الاسم', 'سعر أبيض', 'سعر برجامون'],
      ['C1', 'مرحاض', 2575, 2675],
      ['C2', 'حوض', 1325, ''],
    ]));
    expect(p.errorCount, 0);
    expect(p.rows.length, 3);
    expect(p.rows.map((r) => r.colour), ['أبيض', 'برجامون', 'أبيض']);
    expect(p.rows[1].input!.price, 267500);
  });

  test('problems are listed per row and only good rows import', () async {
    final p = svc.preview(sheet([
      ['الكود', 'الاسم', 'السعر'],
      ['M1', 'خلاط', 100],
      ['M1', 'خلاط مكرر', 100],
      ['', '', 'abc'],
      ['Z', 'بدون سعر', ''],
    ]));
    expect(p.okCount, 1);
    expect(p.errorCount, 3);
    final r = await svc.import(p,
        user: shop.admin, supplierId: shop.supplierId, name: 'قائمة', effectiveDate: DateTime(2026, 7, 1));
    expect(r.rows, 1);
    expect(r.matched, 1); // M1 is the shop's mixer
    final items = await shop.db.select(shop.db.priceListItems).get();
    expect(items.single.price, 10000);
  });

  test('a sheet without name or price cannot be imported; cashier cannot import', () async {
    final bad = svc.preview(sheet([
      ['الكود', 'اللون'],
      ['M1', 'أبيض'],
    ]));
    expect(bad.canImport, isFalse);
    expect(bad.missingColumns, containsAll(['الاسم', 'السعر']));
    final ok = svc.preview(sheet([
      ['الاسم', 'السعر'],
      ['خلاط', 5],
    ]));
    await expectLater(
        svc.import(ok,
            user: shop.cashier, supplierId: shop.supplierId, name: 'x', effectiveDate: DateTime(2026, 1, 1)),
        throwsA(isA<ValidationException>()));
  });

  test('a file that is not Excel is refused', () {
    expect(() => svc.preview([1, 2, 3]), throwsA(isA<ValidationException>()));
  });
}
