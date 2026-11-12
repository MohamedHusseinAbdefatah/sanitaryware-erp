import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../dates.dart';
import '../db/database.dart';
import '../money.dart';
import '../theme.dart';

/// One column of a document's lines table.
class DocColumn {
  const DocColumn(this.title, {this.flex = 1, this.numeric = false});

  final String title;
  final int flex;
  final bool numeric;
}

/// A posted document (invoice, return...) shown as a sheet, in the manner of
/// a big ERP: a trail back to its list with the actions, a status bar, then
/// the sheet itself with its party, details, lines, totals and payments.
class DocumentView extends StatelessWidget {
  const DocumentView({
    super.key,
    required this.backLabel,
    required this.backPath,
    required this.kind,
    required this.number,
    this.actions = const [],
    required this.steps,
    required this.step,
    this.cancelled = false,
    this.cancelNote,
    required this.partyLabel,
    required this.partyName,
    this.partyPath,
    this.partyDetail,
    this.facts = const [],
    required this.columns,
    required this.rows,
    required this.totals,
    this.notes,
    this.payments = const [],
    this.below = const [],
  });

  final String backLabel;
  final String backPath;

  /// "فاتورة بيع", "فاتورة شراء"...
  final String kind;
  final String number;
  final List<Widget> actions;

  /// The stages it goes through, and where it stands now.
  final List<String> steps;
  final int step;
  final bool cancelled;
  final String? cancelNote;

  final String partyLabel;
  final String partyName;
  final String? partyPath;
  final String? partyDetail;

  /// Label and value pairs beside the party: date, numbers, who made it.
  final List<(String, String)> facts;
  final List<DocColumn> columns;
  final List<List<Widget>> rows;

  /// (label, amount, bold)
  final List<(String, int, bool)> totals;
  final String? notes;
  final List<PaymentLine> payments;
  final List<Widget> below;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 24, 24),
      children: [
        // Trail and actions.
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 8,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton.icon(
                  onPressed: () => context.go(backPath),
                  icon: const Icon(Icons.arrow_forward, size: 18),
                  label: Text(backLabel),
                ),
                const Icon(Icons.chevron_left, size: 18, color: AppColors.muted),
                Text(number, style: const TextStyle(color: AppColors.muted)),
              ],
            ),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ),
        const SizedBox(height: 10),
        // Status bar.
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 8),
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: cancelled
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(color: AppColors.badBg, borderRadius: BorderRadius.circular(20)),
                    child: Text('ملغاة${cancelNote == null ? '' : ' — $cancelNote'}',
                        style: const TextStyle(color: AppColors.bad, fontWeight: FontWeight.w700)),
                  )
                : _StatusBar(steps: steps, step: step),
          ),
        ),
        const SizedBox(height: 10),
        // The sheet.
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(kind, style: const TextStyle(color: AppColors.muted)),
                    Text(number,
                        style: theme.textTheme.headlineMedium!.copyWith(
                          fontWeight: FontWeight.w700,
                          color: cancelled ? AppColors.muted : AppColors.ink,
                          decoration: cancelled ? TextDecoration.lineThrough : null,
                        )),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 48,
                      runSpacing: 16,
                      children: [
                        SizedBox(
                          width: 320,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(partyLabel, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                              partyPath == null
                                  ? Text(partyName, style: theme.textTheme.titleMedium)
                                  : InkWell(
                                      onTap: () => context.go(partyPath!),
                                      child: Text(partyName,
                                          style: theme.textTheme.titleMedium!.copyWith(color: AppColors.brand)),
                                    ),
                              if (partyDetail != null && partyDetail!.isNotEmpty)
                                Text(partyDetail!, style: const TextStyle(color: AppColors.muted)),
                            ],
                          ),
                        ),
                        for (final (k, v) in facts)
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(k, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                              Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
                            ],
                          ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _Lines(columns: columns, rows: rows),
                    const SizedBox(height: 16),
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      runSpacing: 16,
                      children: [
                        SizedBox(
                          width: 420,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (notes != null && notes!.trim().isNotEmpty) ...[
                                const Text('ملاحظات', style: TextStyle(color: AppColors.muted, fontSize: 13)),
                                Text(notes!),
                                const SizedBox(height: 12),
                              ],
                              if (payments.isNotEmpty) ...[
                                const Text('المدفوعات على هذه الفاتورة',
                                    style: TextStyle(color: AppColors.muted, fontSize: 13)),
                                const SizedBox(height: 4),
                                for (final p in payments)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 2),
                                    child: Row(
                                      children: [
                                        Icon(p.cancelled ? Icons.block : Icons.check_circle_outline,
                                            size: 16, color: p.cancelled ? AppColors.bad : AppColors.good),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(
                                            '${p.number} · ${formatDate(p.date)} · ${p.method}',
                                            style: TextStyle(
                                                decoration: p.cancelled ? TextDecoration.lineThrough : null),
                                          ),
                                        ),
                                        Text(formatMoney(p.amount), style: const TextStyle(fontWeight: FontWeight.w700)),
                                      ],
                                    ),
                                  ),
                              ],
                            ],
                          ),
                        ),
                        SizedBox(
                          width: 340,
                          child: Column(
                            children: [
                              for (final (label, amount, bold) in totals)
                                Container(
                                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                                  decoration: bold
                                      ? BoxDecoration(color: AppColors.canvas, borderRadius: BorderRadius.circular(8))
                                      : null,
                                  child: Row(
                                    children: [
                                      Expanded(
                                          child: Text(label,
                                              style: TextStyle(
                                                  fontWeight: bold ? FontWeight.w700 : FontWeight.normal,
                                                  color: bold ? AppColors.ink : AppColors.muted))),
                                      Text(formatMoney(amount),
                                          style: TextStyle(
                                              fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
                                              fontSize: bold ? 16 : 14)),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    ...below,
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A payment shown on its invoice.
class PaymentLine {
  const PaymentLine({
    required this.number,
    required this.date,
    required this.method,
    required this.amount,
    this.cancelled = false,
  });

  final String number;
  final DateTime date;
  final String method;
  final int amount;
  final bool cancelled;

  factory PaymentLine.of(Payment p, String methodLabel) => PaymentLine(
        number: p.number,
        date: p.date,
        method: methodLabel,
        amount: p.amount,
        cancelled: p.status == 'cancelled',
      );
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.steps, required this.step});

  final List<String> steps;
  final int step;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < steps.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              color: i == step ? AppColors.brand : null,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (i < step) const Icon(Icons.check, size: 14, color: AppColors.good),
                  if (i < step) const SizedBox(width: 4),
                  Text(
                    steps[i],
                    style: TextStyle(
                      fontWeight: i == step ? FontWeight.w700 : FontWeight.normal,
                      color: i == step ? Colors.white : (i < step ? AppColors.ink : AppColors.muted),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Lines extends StatelessWidget {
  const _Lines({required this.columns, required this.rows});

  final List<DocColumn> columns;
  final List<List<Widget>> rows;

  Widget _cell(DocColumn c, Widget child) => Expanded(
        flex: c.flex,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Align(alignment: c.numeric ? Alignment.center : AlignmentDirectional.centerStart, child: child),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            color: AppColors.canvas,
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(children: [
              for (final c in columns)
                _cell(c, Text(c.title, style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.muted, fontSize: 13))),
            ]),
          ),
          for (var r = 0; r < rows.length; r++)
            Container(
              color: r.isOdd ? AppColors.zebra : null,
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(children: [for (var i = 0; i < columns.length; i++) _cell(columns[i], rows[r][i])]),
            ),
        ],
      ),
    );
  }
}
