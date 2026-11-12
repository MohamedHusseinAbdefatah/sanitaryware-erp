import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/widgets/number_fields.dart';

/// The invoice discount can be typed as an amount or as a percent of the
/// subtotal; the invoice always saves the amount.
void main() {
  test('an amount is taken as typed', () {
    expect(discountAmount('150', percent: false, subtotal: 100000), 15000);
    expect(discountAmount('', percent: false, subtotal: 100000), 0);
    expect(discountAmount('-5', percent: false, subtotal: 100000), isNull);
  });

  test('a percent is of the subtotal, rounded to the piastre', () {
    expect(discountAmount('10', percent: true, subtotal: 123456), 12346); // 1,234.56 -> 123.46
    expect(discountAmount('2.5', percent: true, subtotal: 100000), 2500);
    expect(discountAmount('5%', percent: true, subtotal: 100000), 5000);
    expect(discountAmount('100', percent: true, subtotal: 100000), 100000);
    expect(discountAmount('101', percent: true, subtotal: 100000), isNull);
    expect(discountAmount('x', percent: true, subtotal: 100000), isNull);
  });
}
