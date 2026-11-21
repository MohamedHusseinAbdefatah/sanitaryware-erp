import 'package:flutter/material.dart';

import '../money.dart';
import '../theme.dart';

/// A small label above a bold amount, for totals bars.
class AmountLabel extends StatelessWidget {
  const AmountLabel(this.label, this.value, {super.key, this.big = false, this.color});

  final String label;
  final int value;
  final bool big;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final figure = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: big ? AppColors.brandDark : AppColors.muted)),
        Text(
          formatMoney(value),
          style: TextStyle(
              fontWeight: FontWeight.w800, fontSize: big ? 22 : 16, color: color ?? (big ? AppColors.brand : AppColors.ink)),
        ),
      ],
    );
    if (!big) return figure;
    // The amount that matters most stands out in a tinted box.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.brandSoft,
        borderRadius: AppRadius.mdAll,
        border: Border.all(color: AppColors.brand.withValues(alpha: .25)),
      ),
      child: figure,
    );
  }
}

/// "Label ........ amount" on one line, for the totals under a document.
class TotalRow extends StatelessWidget {
  const TotalRow(this.label, this.amount, {super.key, this.bold = false, this.color});

  final String label;
  final int amount;
  final bool bold;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontWeight: bold ? FontWeight.bold : null,
      fontSize: bold ? 16 : null,
      color: color,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 8),
          Text(formatMoney(amount), style: style),
        ],
      ),
    );
  }
}
