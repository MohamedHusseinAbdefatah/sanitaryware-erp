import 'digits.dart';

// Money is always an integer number of piastres (100 piastres = 1 EGP).
// Never use double for money.

/// 123456 -> "1,234.56", -50 -> "-0.50"
String formatMoney(int piastres) {
  final negative = piastres < 0;
  final abs = piastres.abs();
  final pounds = groupThousands(abs ~/ 100);
  final cents = (abs % 100).toString().padLeft(2, '0');
  return '${negative ? '-' : ''}$pounds.$cents';
}

/// Parses what a person types, e.g. "12.5", "1,200.50" or Arabic digits
/// "٣٫٥٠". Returns piastres, or null if the text is not a valid amount
/// (more than 2 decimals, letters, empty, absurdly long).
int? parseMoney(String input) =>
    parseScaled(input, decimals: 2, maxWholeDigits: 13);
