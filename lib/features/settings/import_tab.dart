import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/l10n/strings.dart';
import '../../core/providers.dart';
import '../../core/services/import_service.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/report_view.dart';

/// Bring the client's existing lists in from Excel: template, preview with
/// errors per row, then import the rows that passed.
class ImportTab extends ConsumerWidget {
  const ImportTab({super.key});

  Future<void> _choose(BuildContext context, WidgetRef ref, ImportKind kind) async {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx']);
    final path = picked?.files.single.path;
    if (path == null || !context.mounted) return;
    final preview = await runGuarded(
      context,
      () async => ImportService(ref.read(databaseProvider)).preview(kind, await File(path).readAsBytes()),
    );
    if (preview == null || !context.mounted) return;
    await showDialog<void>(context: context, builder: (_) => _PreviewDialog(preview: preview));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(Strings.importIntro),
        const SizedBox(height: 16),
        for (final kind in ImportKind.values)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(width: 160, child: Text(kind.title, style: theme.textTheme.titleMedium)),
                  OutlinedButton.icon(
                    onPressed: () => saveExcelFile(
                      context,
                      ImportService(ref.read(databaseProvider)).template(kind),
                      '${Strings.importTemplate} ${kind.title}',
                    ),
                    icon: const Icon(Icons.download_outlined),
                    label: const Text(Strings.downloadTemplate),
                  ),
                  FilledButton.icon(
                    onPressed: () => _choose(context, ref, kind),
                    icon: const Icon(Icons.upload_file_outlined),
                    label: const Text(Strings.chooseExcelFile),
                  ),
                  Text(
                    ImportService.fieldKeys(kind).map((k) => ImportService.header(kind, k)).join(' · '),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _PreviewDialog extends ConsumerStatefulWidget {
  const _PreviewDialog({required this.preview});

  final ImportPreview preview;

  @override
  ConsumerState<_PreviewDialog> createState() => _PreviewDialogState();
}

class _PreviewDialogState extends ConsumerState<_PreviewDialog> {
  bool _errorsOnly = false;
  bool _busy = false;

  Future<void> _import() async {
    setState(() => _busy = true);
    final count = await runGuarded(
      context,
      () => ImportService(ref.read(databaseProvider)).import(widget.preview, user: ref.read(currentUserProvider)!),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (count != null) {
      showToast(context, '${Strings.imported} $count');
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.preview;
    final scheme = Theme.of(context).colorScheme;
    final keys = ImportService.fieldKeys(p.kind);
    final rows = _errorsOnly ? p.rows.where((r) => !r.ok).toList() : p.rows;
    final size = MediaQuery.sizeOf(context);
    return AlertDialog(
      title: Text('${Strings.importPreview}: ${p.kind.title}'),
      content: SizedBox(
        width: size.width * 0.85,
        height: size.height * 0.7,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (p.missingColumns.isNotEmpty)
              Text(
                '${Strings.missingColumns}: ${p.missingColumns.join('، ')}',
                style: TextStyle(color: scheme.error, fontWeight: FontWeight.bold),
              )
            else
              Wrap(
                spacing: 24,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('${Strings.rowsReady}: ${p.okCount}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text('${Strings.rowsWithErrors}: ${p.errorCount}', style: TextStyle(color: scheme.error)),
                  FilterChip(
                    label: const Text(Strings.errorsOnly),
                    selected: _errorsOnly,
                    onSelected: (v) => setState(() => _errorsOnly = v),
                  ),
                ],
              ),
            const SizedBox(height: 8),
            Expanded(
              child: SingleChildScrollView(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columnSpacing: 16,
                    headingRowHeight: 36,
                    dataRowMinHeight: 32,
                    dataRowMaxHeight: 64,
                    columns: [
                      const DataColumn(label: Text(Strings.excelRow), numeric: true),
                      for (final k in keys) DataColumn(label: Text(ImportService.header(p.kind, k))),
                      const DataColumn(label: Text(Strings.status)),
                    ],
                    rows: [
                      for (final r in rows.take(1000))
                        DataRow(
                          color: WidgetStatePropertyAll(r.ok ? null : scheme.errorContainer.withValues(alpha: 0.35)),
                          cells: [
                            DataCell(Text('${r.rowNumber}')),
                            for (final k in keys) DataCell(Text(r.values[k] ?? '')),
                            DataCell(
                              r.ok
                                  ? Icon(Icons.check_circle, color: Colors.green.shade700, size: 18)
                                  : ConstrainedBox(
                                      constraints: const BoxConstraints(maxWidth: 360),
                                      child: Text(r.errors.join('، '), style: TextStyle(color: scheme.error)),
                                    ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (p.rows.length > 1000) const Text(Strings.previewLimited),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.cancel)),
        FilledButton(
          onPressed: p.canImport && !_busy ? _import : null,
          child: Text('${Strings.importRows} (${p.okCount})'),
        ),
      ],
    );
  }
}
