import 'package:flutter/material.dart';

import '../dates.dart';
import '../l10n/strings.dart';

/// A whole-day range; null ends mean open-ended.
class DayRange {
  const DayRange(this.from, this.to);

  final DateTime? from;
  final DateTime? to;

  static DayRange today() {
    final n = DateTime.now();
    final d = DateTime(n.year, n.month, n.day);
    return DayRange(d, d);
  }

  static DayRange thisMonth() {
    final n = DateTime.now();
    return DayRange(DateTime(n.year, n.month), DateTime(n.year, n.month, n.day));
  }

  static DayRange lastMonth() {
    final n = DateTime.now();
    return DayRange(DateTime(n.year, n.month - 1), DateTime(n.year, n.month, 0));
  }

  static DayRange thisYear() {
    final n = DateTime.now();
    return DayRange(DateTime(n.year), DateTime(n.year, n.month, n.day));
  }

  static const all = DayRange(null, null);

  // Value equality: ranges are used as provider keys.
  @override
  bool operator ==(Object other) => other is DayRange && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);

  String get label => from == null && to == null
      ? Strings.allTime
      : '${from == null ? '…' : formatDate(from!)} — ${to == null ? '…' : formatDate(to!)}';
}

/// Quick presets plus a custom range picker.
class DateRangeBar extends StatelessWidget {
  const DateRangeBar({super.key, required this.value, required this.onChanged, this.allowAll = true});

  final DayRange value;
  final ValueChanged<DayRange> onChanged;
  final bool allowAll;

  Future<void> _custom(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: value.from != null && value.to != null
          ? DateTimeRange(start: value.from!, end: value.to!)
          : null,
    );
    if (picked != null) onChanged(DayRange(picked.start, picked.end));
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final (label, make) in [
          (Strings.today, DayRange.today),
          (Strings.thisMonth, DayRange.thisMonth),
          (Strings.lastMonth, DayRange.lastMonth),
          (Strings.thisYear, DayRange.thisYear),
        ])
          ActionChip(label: Text(label), onPressed: () => onChanged(make())),
        if (allowAll) ActionChip(label: const Text(Strings.allTime), onPressed: () => onChanged(DayRange.all)),
        OutlinedButton.icon(
          onPressed: () => _custom(context),
          icon: const Icon(Icons.date_range, size: 18),
          label: Text(value.label),
        ),
      ],
    );
  }
}
