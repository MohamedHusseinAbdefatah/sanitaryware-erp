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

/// Parses an optional money field: empty means 0.
int moneyOrZero(TextEditingController c) =>
    c.text.trim().isEmpty ? 0 : (parseMoney(c.text) ?? 0);

/// Parses an optional quantity field: empty means 0.
int qtyOrZero(TextEditingController c) =>
    c.text.trim().isEmpty ? 0 : (parseQty(c.text) ?? 0);
