import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/quantity.dart';

void main() {
  group('formatQty', () {
    test('drops trailing zeros and groups thousands', () {
      expect(formatQty(0), '0');
      expect(formatQty(2000), '2');
      expect(formatQty(1500), '1.5');
      expect(formatQty(1250), '1.25');
      expect(formatQty(1), '0.001');
      expect(formatQty(1234000), '1,234');
      expect(formatQty(-250), '-0.25');
    });
  });

  group('parseQty', () {
    test('parses typed quantities to thousandths', () {
      expect(parseQty('2'), 2000);
      expect(parseQty('1.5'), 1500);
      expect(parseQty('0.125'), 125);
      expect(parseQty('١٫٢٥'), 1250);
      expect(parseQty('-3'), -3000);
    });

    test('rejects invalid input', () {
      expect(parseQty(''), isNull);
      expect(parseQty('abc'), isNull);
      expect(parseQty('1.2345'), isNull);
      expect(parseQty('9999999999'), isNull);
    });

    test('whole-unit products reject fractions', () {
      expect(parseQty('3', allowDecimal: false), 3000);
      expect(parseQty('3.0', allowDecimal: false), 3000);
      expect(parseQty('1.5', allowDecimal: false), isNull);
    });

    test('round trip', () {
      for (final v in [0, 1, 999, 1000, 1500, 123456789]) {
        expect(parseQty(formatQty(v)), v);
      }
    });
  });

  group('lineAmount', () {
    test('whole quantities are exact', () {
      expect(lineAmount(qtyOf(3), 12550), 37650);
    });

    test('fractional quantities round once to the nearest piastre', () {
      // 1.5 m x 10.00 EGP = 15.00 EGP
      expect(lineAmount(1500, 1000), 1500);
      // 0.333 m x 10.00 EGP = 3.33 EGP
      expect(lineAmount(333, 1000), 333);
      // 0.005 x 1.00 EGP = 0.005 EGP -> 0.01 (half rounds up)
      expect(lineAmount(5, 100), 1);
      // 0.004 x 1.00 EGP = 0.004 EGP -> 0.00
      expect(lineAmount(4, 100), 0);
    });

    test('negative quantities round symmetrically', () {
      expect(lineAmount(-5, 100), -1);
      expect(lineAmount(-1500, 1000), -1500);
    });
  });
}
