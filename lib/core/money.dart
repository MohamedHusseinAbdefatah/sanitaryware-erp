// Money is always an integer number of piastres (100 piastres = 1 EGP).
// Never use double for money.

// Largest whole-pound part accepted (13 digits), so int.parse never overflows.
const _maxPoundDigits = 13;

/// 123456 -> "1,234.56", -50 -> "-0.50"
String formatMoney(int piastres) {
  final negative = piastres < 0;
  final abs = piastres.abs();
  final pounds = (abs ~/ 100).toString();
  final cents = (abs % 100).toString().padLeft(2, '0');

  final buffer = StringBuffer();
  for (var i = 0; i < pounds.length; i++) {
    if (i > 0 && (pounds.length - i) % 3 == 0) buffer.write(',');
    buffer.write(pounds[i]);
  }
  return '${negative ? '-' : ''}$buffer.$cents';
}

/// Parses what a person types, e.g. "12.5", "1,200.50" or Arabic digits
/// "٣٫٥٠". Returns piastres, or null if the text is not a valid amount
/// (more than 2 decimals, letters, empty).
int? parseMoney(String input) {
  var s = _normalize(input.trim());
  if (s.isEmpty) return null;

  s = s.replaceAll(',', '').replaceAll(' ', '');
  final negative = s.startsWith('-');
  if (negative) s = s.substring(1);

  final parts = s.split('.');
  if (parts.length > 2) return null;

  final wholeText = parts[0];
  final fracText = parts.length == 2 ? parts[1] : '';
  if (wholeText.isEmpty && fracText.isEmpty) return null;
  if (fracText.length > 2) return null;
  if (wholeText.length > _maxPoundDigits) return null;

  final digits = RegExp(r'^\d+$');
  if (wholeText.isNotEmpty && !digits.hasMatch(wholeText)) return null;
  if (fracText.isNotEmpty && !digits.hasMatch(fracText)) return null;

  final whole = wholeText.isEmpty ? 0 : int.parse(wholeText);
  final cents = fracText.isEmpty ? 0 : int.parse(fracText.padRight(2, '0'));
  final value = whole * 100 + cents;
  return negative ? -value : value;
}

/// Turns Arabic-Indic digits and Arabic separators into plain ASCII.
String _normalize(String input) {
  final out = StringBuffer();
  for (final rune in input.runes) {
    if (rune >= 0x0660 && rune <= 0x0669) {
      out.writeCharCode(0x30 + (rune - 0x0660));
    } else if (rune >= 0x06F0 && rune <= 0x06F9) {
      out.writeCharCode(0x30 + (rune - 0x06F0));
    } else if (rune == 0x066B) {
      out.write('.');
    } else if (rune == 0x066C) {
      out.write(',');
    } else {
      out.writeCharCode(rune);
    }
  }
  return out.toString();
}
