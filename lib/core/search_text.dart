import 'digits.dart';

/// Folds the spelling differences people make when typing Arabic, so
/// "اسطوانة" finds "أسطوانه": hamza forms of alef, taa marbuta/haa,
/// alef maqsura/yaa, diacritics and tatweel. Also lowercases Latin and
/// turns Arabic-Indic digits into ASCII.
String foldForSearch(String input) {
  final s = normalizeDigits(input).toLowerCase();
  final out = StringBuffer();
  for (final rune in s.runes) {
    if ((rune >= 0x064B && rune <= 0x0652) || rune == 0x0670 || rune == 0x0640) {
      continue; // diacritics, superscript alef, tatweel
    }
    out.writeCharCode(switch (rune) {
      0x0623 || 0x0625 || 0x0622 || 0x0671 => 0x0627, // أ إ آ ٱ -> ا
      0x0629 => 0x0647, // ة -> ه
      0x0649 => 0x064A, // ى -> ي
      0x0624 => 0x0648, // ؤ -> و
      0x0626 => 0x064A, // ئ -> ي
      _ => rune,
    });
  }
  return out.toString().trim();
}

/// True when every word of [query] appears somewhere in one of [fields].
bool matchesSearch(String query, Iterable<String?> fields) {
  final words = foldForSearch(query).split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  if (words.isEmpty) return true;
  final haystack = foldForSearch(fields.whereType<String>().join(' '));
  return words.every(haystack.contains);
}
