import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../reports/report_table.dart';
import 'data_list.dart';
import 'feedback.dart';

/// Shows a [ReportTable]: header, rows, and a bold totals row at the bottom.
class ReportView extends StatelessWidget {
  const ReportView({super.key, required this.table});

  final ReportTable table;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final columns = table.columns;
    int flexOf(ReportColumn c) => c.type == ColumnType.text ? 3 : 2;
    bool numeric(ReportColumn c) => c.type != ColumnType.text;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (table.subtitle != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(table.subtitle!, style: theme.textTheme.bodySmall),
          ),
        Expanded(
          child: DataList<List<Object?>>(
            rows: table.rows,
            emptyText: Strings.noData,
            columns: [
              for (var i = 0; i < columns.length; i++)
                DataListColumn(
                  columns[i].title,
                  flex: flexOf(columns[i]),
                  numeric: numeric(columns[i]),
                  (row) => _value(context, row[i], columns[i].type),
                ),
            ],
          ),
        ),
        if (table.hasTotals && table.rows.isNotEmpty)
          Container(
            color: theme.colorScheme.surfaceContainerHigh,
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                for (var i = 0; i < columns.length; i++)
                  Expanded(
                    flex: flexOf(columns[i]),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        ReportTable.display(table.totals[i], columns[i].type),
                        textAlign: numeric(columns[i]) ? TextAlign.center : TextAlign.start,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  static Widget _value(BuildContext context, Object? value, ColumnType type) {
    final negative = value is int && value < 0 && type == ColumnType.money;
    return Text(
      ReportTable.display(value, type),
      style: negative ? TextStyle(color: Theme.of(context).colorScheme.error) : null,
    );
  }
}

/// Asks where to save [bytes] as an .xlsx file and writes it.
Future<void> saveExcelFile(BuildContext context, List<int> bytes, String suggestedName) async {
  final safe = suggestedName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '-');
  await runGuarded(context, () async {
    var path = await FilePicker.saveFile(
      dialogTitle: Strings.exportExcel,
      fileName: '$safe.xlsx',
      type: FileType.custom,
      allowedExtensions: const ['xlsx'],
      bytes: Platform.isWindows ? null : Uint8List.fromList(bytes),
    );
    if (path == null) return;
    if (!path.toLowerCase().endsWith('.xlsx')) path = '$path.xlsx';
    await File(path).writeAsBytes(bytes, flush: true);
    if (context.mounted) showToast(context, '${Strings.savedTo} $path');
  });
}
