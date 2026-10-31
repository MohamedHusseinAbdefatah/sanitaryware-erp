/// Turns Arabic-Indic digits and Arabic separators into plain ASCII,
/// so "٣٫٥٠" becomes "3.50".
String normalizeDigits(String input) {
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

/// Parses typed text into a whole number scaled by 10^[decimals], e.g.
/// "12.5" with 2 decimals -> 1250. Accepts Arabic digits, thousands commas
/// and a leading minus. Returns null for empty text, letters, more than
/// [decimals] decimal places, or more than [maxWholeDigits] whole digits
/// (which keeps the result far from int overflow).
int? parseScaled(
  String input, {
  required int decimals,
  required int maxWholeDigits,
}) {
  var s = normalizeDigits(input.trim());
  if (s.isEmpty) return null;

  s = s.replaceAll(',', '').replaceAll(' ', '');
  final negative = s.startsWith('-');
  if (negative) s = s.substring(1);

  final parts = s.split('.');
  if (parts.length > 2) return null;

  final wholeText = parts[0];
  final fracText = parts.length == 2 ? parts[1] : '';
  if (wholeText.isEmpty && fracText.isEmpty) return null;
  if (fracText.length > decimals) return null;
  if (wholeText.length > maxWholeDigits) return null;

  final digits = RegExp(r'^\d+$');
  if (wholeText.isNotEmpty && !digits.hasMatch(wholeText)) return null;
  if (fracText.isNotEmpty && !digits.hasMatch(fracText)) return null;

  var scale = 1;
  for (var i = 0; i < decimals; i++) {
    scale *= 10;
  }
  final whole = wholeText.isEmpty ? 0 : int.parse(wholeText);
  final frac = fracText.isEmpty ? 0 : int.parse(fracText.padRight(decimals, '0'));
  final value = whole * scale + frac;
  return negative ? -value : value;
}

/// Groups the digits of a non-negative whole number with commas: 1234567 -> "1,234,567".
String groupThousands(int value) {
  final text = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    if (i > 0 && (text.length - i) % 3 == 0) buffer.write(',');
    buffer.write(text[i]);
  }
  return buffer.toString();
}
