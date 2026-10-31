import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/dates.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/printing/documents.dart';
import '../../core/printing/print_actions.dart';
import '../../core/providers.dart';
import '../../core/reports/report_excel.dart';
import '../../core/reports/report_table.dart';
import '../../core/services/doc_types.dart';
import '../../core/services/statement_service.dart';
import '../../core/widgets/date_range_bar.dart';
import '../../core/widgets/report_view.dart';

Future<void> showStatement(BuildContext context, {required String partyType, required int partyId}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _StatementDialog(partyType: partyType, partyId: partyId),
  );
}

/// A statement as a table: the opening line, then each document with the
/// running balance. On a customer's account invoices are debit (مدين); on a
/// supplier's account they are credit (دائن), as accountants expect.
ReportTable statementTable(Statement s, {required bool isCustomer, DateTime? from}) {
  final up = isCustomer ? Strings.debit : Strings.credit;
  final down = isCustomer ? Strings.credit : Strings.debit;
  return ReportTable(
    title: '${Strings.statementOf} ${s.partyName}',
    columns: [
      const ReportColumn(Strings.date, ColumnType.date),
      const ReportColumn(Strings.description, ColumnType.text),
      const ReportColumn(Strings.number, ColumnType.text),
      ReportColumn(up, ColumnType.money, sum: true),
      ReportColumn(down, ColumnType.money, sum: true),
      const ReportColumn(Strings.balance, ColumnType.money),
    ],
    rows: [
      [from, Strings.openingLine, '', null, null, s.openingBalance],
      for (final e in s.entries)
        [e.date, e.note == null ? e.kind : '${e.kind} — ${e.note}', e.number, e.increase, e.decrease, e.balance],
    ],
  );
}

class _StatementDialog extends ConsumerStatefulWidget {
  const _StatementDialog({required this.partyType, required this.partyId});

  final String partyType;
  final int partyId;

  @override
  ConsumerState<_StatementDialog> createState() => _StatementDialogState();
}

class _StatementDialogState extends ConsumerState<_StatementDialog> {
  DayRange _range = DayRange.thisYear();
  late Future<Statement> _statement = _load();

  bool get _isCustomer => widget.partyType == PartyType.customer;

  Future<Statement> _load() {
    final service = ref.read(statementServiceProvider);
    return _isCustomer
        ? service.customer(widget.partyId, from: _range.from, to: _range.to)
        : service.supplier(widget.partyId, from: _range.from, to: _range.to);
  }

  Future<void> _export(Statement s) async {
    final company = await ref.read(settingsServiceProvider).company();
    if (!mounted) return;
    final bytes = reportToExcel(
      statementTable(s, isCustomer: _isCustomer, from: _range.from),
      from: _range.from,
      to: _range.to,
      companyName: company.name,
    );
    await saveExcelFile(context, bytes, '${Strings.statementOf} ${s.partyName}');
  }

  Future<void> _print(Statement s) => printDocument(
        context,
        ref,
        name: '${Strings.statementOf} ${s.partyName}',
        build: (company, fonts) => tablePdf(
          statementTable(s, isCustomer: _isCustomer, from: _range.from),
          company,
          fonts,
          from: _range.from,
          to: _range.to,
          footerLines: [
            '${Strings.closingBalance}: ${formatMoney(s.closingBalance)}',
            if (s.pendingCheques.isNotEmpty)
              '${Strings.pendingChequesNotCounted}: '
                  '${s.pendingCheques.map((c) => '${c.chequeNo} (${formatDate(c.dueDate)})').join('، ')}',
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: size.width * 0.9,
        height: size.height * 0.9,
        child: FutureBuilder<Statement>(
          future: _statement,
          builder: (context, snap) {
            final s = snap.data;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                  child: Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        s == null ? Strings.statement : '${Strings.statementOf} ${s.partyName}',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      DateRangeBar(
                        value: _range,
                        onChanged: (r) => setState(() {
                          _range = r;
                          _statement = _load();
                        }),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: s == null ? null : () => _export(s),
                        icon: const Icon(Icons.table_view),
                        label: const Text(Strings.exportExcel),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: s == null ? null : () => _print(s),
                        icon: const Icon(Icons.print_outlined),
                        label: const Text(Strings.print),
                      ),
                      IconButton(
                        tooltip: Strings.close,
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: snap.hasError
                      ? Center(child: Text('${snap.error}'))
                      : s == null
                          ? const Center(child: CircularProgressIndicator())
                          : ReportView(table: statementTable(s, isCustomer: _isCustomer, from: _range.from)),
                ),
                if (s != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                    child: Wrap(
                      spacing: 32,
                      runSpacing: 8,
                      children: [
                        Text(
                          '${Strings.closingBalance}: ${formatMoney(s.closingBalance)}',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        if (s.pendingCheques.isNotEmpty)
                          Text(
                            '${Strings.pendingChequesNotCounted}: '
                            '${s.pendingCheques.map((c) => '${c.chequeNo} (${formatDate(c.dueDate)})').join('، ')}',
                          ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
