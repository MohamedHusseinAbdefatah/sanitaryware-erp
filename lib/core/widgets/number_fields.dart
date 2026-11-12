import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../money.dart';
import '../quantity.dart';

/// Text field for an amount in pounds; read the value with [parseMoney].
class MoneyField extends StatelessWidget {
  const MoneyField({
    super.key,
    required this.controller,
    required this.label,
    this.required = false,
    this.allowNegative = false,
    this.onChanged,
    this.dense = false,
  });

  final TextEditingController controller;
  final String label;
  final bool required;
  final bool allowNegative;
  final ValueChanged<String>? onChanged;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      textAlign: TextAlign.center,
      decoration: InputDecoration(
        labelText: dense ? null : label,
        isDense: dense,
        hintText: dense ? label : null,
        contentPadding: dense ? const EdgeInsets.symmetric(horizontal: 6, vertical: 9) : null,
      ),
      onChanged: onChanged,
      validator: (text) {
        if ((text ?? '').trim().isEmpty) return required ? Strings.required : null;
        final v = parseMoney(text!);
        if (v == null) return Strings.invalidAmount;
        if (v < 0 && !allowNegative) return Strings.invalidAmount;
        return null;
      },
    );
  }
}

/// Text field for a quantity; read the value with [parseQty].
class QtyField extends StatelessWidget {
  const QtyField({
    super.key,
    required this.controller,
    required this.label,
    required this.allowDecimal,
    this.required = false,
    this.onChanged,
    this.dense = false,
    this.focusNode,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final bool allowDecimal;
  final bool required;
  final ValueChanged<String>? onChanged;
  final bool dense;
  final FocusNode? focusNode;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      textAlign: TextAlign.center,
      decoration: InputDecoration(
        labelText: dense ? null : label,
        isDense: dense,
        hintText: dense ? label : null,
        contentPadding: dense ? const EdgeInsets.symmetric(horizontal: 6, vertical: 9) : null,
      ),
      onChanged: onChanged,
      onFieldSubmitted: onSubmitted,
      validator: (text) {
        if ((text ?? '').trim().isEmpty) return required ? Strings.required : null;
        final v = parseQty(text!, allowDecimal: allowDecimal);
        if (v == null || v < 0) {
          return allowDecimal ? Strings.invalidQty : Strings.wholeQtyOnly;
        }
        return null;
      },
    );
  }
}

/// An invoice discount typed as an amount or as a percent of [subtotal].
/// The document always saves the amount; [discountAmount] works it out.
class DiscountField extends StatelessWidget {
  const DiscountField({
    super.key,
    required this.controller,
    required this.label,
    required this.percent,
    required this.subtotal,
    required this.onModeChanged,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final bool percent;
  final int subtotal;
  final ValueChanged<bool> onModeChanged;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final amount = discountAmount(controller.text, percent: percent, subtotal: subtotal);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TextFormField(
            controller: controller,
            textAlign: TextAlign.center,
            decoration: InputDecoration(
              labelText: percent ? '$label %' : label,
              helperText: percent && amount != null && amount > 0 ? '= ${formatMoney(amount)}' : null,
            ),
            onChanged: onChanged,
            validator: (text) {
              if ((text ?? '').trim().isEmpty) return null;
              final v = discountAmount(text!, percent: percent, subtotal: subtotal);
              if (v == null) return percent ? 'من 0 إلى 100' : Strings.invalidAmount;
              if (v > subtotal) return 'أكبر من الإجمالي';
              return null;
            },
          ),
        ),
        const SizedBox(width: 4),
        SegmentedButton<bool>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const [
            ButtonSegment(value: false, label: Text('ج.م'), tooltip: 'مبلغ'),
            ButtonSegment(value: true, label: Text('%'), tooltip: 'نسبة من الإجمالي'),
          ],
          selected: {percent},
          onSelectionChanged: (s) => onModeChanged(s.first),
        ),
      ],
    );
  }
}

/// The discount in piastres: the amount typed, or [subtotal] times the
/// percent typed, rounded to the piastre. Empty is 0; null when not valid.
int? discountAmount(String text, {required bool percent, required int subtotal}) {
  final t = text.trim();
  if (t.isEmpty) return 0;
  if (!percent) {
    final v = parseMoney(t);
    return v == null || v < 0 ? null : v;
  }
  final p = double.tryParse(t.replaceAll(',', '.').replaceAll('%', ''));
  if (p == null || p < 0 || p > 100) return null;
  final bp = (p * 100).round();
  return (subtotal * bp + 5000) ~/ 10000;
}

/// Parses an optional money field: empty means 0.
int moneyOrZero(TextEditingController c) =>
    c.text.trim().isEmpty ? 0 : (parseMoney(c.text) ?? 0);

/// Parses an optional quantity field: empty means 0.
int qtyOrZero(TextEditingController c) =>
    c.text.trim().isEmpty ? 0 : (parseQty(c.text) ?? 0);
