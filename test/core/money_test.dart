import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/money.dart';

void main() {
  group('formatMoney', () {
    test('formats piastres as pounds with grouping', () {
      expect(formatMoney(0), '0.00');
      expect(formatMoney(5), '0.05');
      expect(formatMoney(100), '1.00');
      expect(formatMoney(123456), '1,234.56');
      expect(formatMoney(100000000), '1,000,000.00');
      expect(formatMoney(-50), '-0.50');
    });
  });

  group('parseMoney', () {
    test('parses typed amounts to piastres', () {
      expect(parseMoney('12'), 1200);
      expect(parseMoney('12.5'), 1250);
      expect(parseMoney('1,200.50'), 120050);
      expect(parseMoney('.5'), 50);
      expect(parseMoney('-5'), -500);
    });

    test('parses Arabic digits and separators', () {
      expect(parseMoney('٣٫٥٠'), 350);
      expect(parseMoney('١٢٣'), 12300);
    });

    test('rejects invalid input', () {
      expect(parseMoney(''), isNull);
      expect(parseMoney('abc'), isNull);
      expect(parseMoney('1.234'), isNull);
      expect(parseMoney('1.2.3'), isNull);
      expect(parseMoney('.'), isNull);
      expect(parseMoney('99999999999999999999'), isNull);
    });

    test('round trip', () {
      for (final v in [0, 1, 99, 100, 12345, 99999999]) {
        expect(parseMoney(formatMoney(v)), v);
      }
    });
  });
}
