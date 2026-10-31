/// 2026-10-31 18:05 -> "2026/10/31 18:05" (local time).
String formatDateTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  final local = t.toLocal();
  return '${local.year}/${two(local.month)}/${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
