/// 2026-10-31 -> "2026/10/31" (local time).
String formatDate(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  final local = t.toLocal();
  return '${local.year}/${two(local.month)}/${two(local.day)}';
}

/// 2026-10-31 18:05 -> "2026/10/31 18:05" (local time).
String formatDateTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  final local = t.toLocal();
  return '${local.year}/${two(local.month)}/${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

const _weekdays = ['الاثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت', 'الأحد'];
const _months = [
  'يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو',
  'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر',
];

/// 2026-11-08 -> "الأحد 8 نوفمبر 2026" (local time).
String formatLongDate(DateTime t) {
  final l = t.toLocal();
  return '${_weekdays[l.weekday - 1]} ${l.day} ${_months[l.month - 1]} ${l.year}';
}

/// Month name, 1-12.
String monthName(int month) => _months[month - 1];
