import 'package:flutter/material.dart';

import '../services/doc_types.dart';
import '../theme.dart';

/// Where an invoice stands with its money.
enum PayState { paid, partial, unpaid, overdue, cancelled }

PayState payStateOf({required int total, required int paid, required String status, DateTime? dueDate}) {
  if (status == DocStatus.cancelled) return PayState.cancelled;
  if (total - paid <= 0) return PayState.paid;
  if (dueDate != null && dueDate.isBefore(DateTime.now())) return PayState.overdue;
  return paid > 0 ? PayState.partial : PayState.unpaid;
}

String payStateLabel(PayState s) => switch (s) {
      PayState.paid => 'مدفوعة',
      PayState.partial => 'مدفوعة جزئياً',
      PayState.unpaid => 'غير مدفوعة',
      PayState.overdue => 'متأخرة',
      PayState.cancelled => 'ملغاة',
    };

Widget payStatePill(PayState s) => switch (s) {
      PayState.paid => StatusPill.good(payStateLabel(s)),
      PayState.partial => StatusPill.warn(payStateLabel(s)),
      PayState.unpaid => StatusPill(payStateLabel(s)),
      PayState.overdue => StatusPill.bad(payStateLabel(s)),
      PayState.cancelled => StatusPill.bad(payStateLabel(s)),
    };

/// A figure in the strip above a list.
class SummaryItem {
  const SummaryItem(this.label, this.value, {this.tone, this.icon});

  final String label;
  final String value;
  final Color? tone;
  final IconData? icon;
}

/// A row of small figure cards above a list: totals for what is shown.
class SummaryStrip extends StatelessWidget {
  const SummaryStrip({super.key, required this.items});

  final List<SummaryItem> items;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: LayoutBuilder(builder: (context, c) {
        final perRow = items.length <= 5 && c.maxWidth > 760 ? items.length : 3;
        final w = (c.maxWidth - 12 * (perRow - 1)) / perRow;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final i in items)
              SizedBox(
                width: w,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Row(
                      children: [
                        if (i.icon != null) ...[
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: (i.tone ?? AppColors.brand).withValues(alpha: .10),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(i.icon, size: 20, color: i.tone ?? AppColors.brand),
                          ),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(i.label,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: AppColors.muted, fontSize: 12.5)),
                              Text(i.value,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 17, fontWeight: FontWeight.w700, color: i.tone ?? AppColors.ink)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      }),
    );
  }
}

/// Filter chips with how many rows each one shows.
class CountChips<T> extends StatelessWidget {
  const CountChips({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
  });

  /// (value, label, count)
  final List<(T, String, int)> options;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          for (final (value, label, count) in options)
            ChoiceChip(
              label: Text('$label  $count'),
              selected: value == selected,
              showCheckmark: false,
              onSelected: (_) => onSelected(value),
            ),
        ],
      ),
    );
  }
}
