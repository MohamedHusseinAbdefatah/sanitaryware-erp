import 'package:flutter/material.dart';

import '../money.dart';

/// A small label above a bold amount, for totals bars.
class AmountLabel extends StatelessWidget {
  const AmountLabel(this.label, this.value, {super.key, this.big = false, this.color});

  final String label;
  final int value;
  final bool big;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        Text(
          formatMoney(value),
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: big ? 22 : 16, color: color),
        ),
      ],
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
