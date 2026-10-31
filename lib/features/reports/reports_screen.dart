import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/providers.dart';
import '../../core/reports/report_excel.dart';
import '../../core/reports/report_service.dart';
import '../../core/reports/report_table.dart';
import '../../core/widgets/date_range_bar.dart';
import '../../core/widgets/report_view.dart';

/// Admin only (the section is). Report list on the side, the chosen report
/// with its filters, table, totals and Excel export on the rest.
class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  ReportKind _kind = ReportKind.dailySales;
  DayRange _range = DayRange.thisMonth();
  int? _categoryId;
  late Future<ReportTable> _table = _build();
  List<Category> _categories = const [];

  @override
  void initState() {
    super.initState();
    ref.read(catalogServiceProvider).watchCategories().first.then((c) {
      if (mounted) setState(() => _categories = c);
    });
  }

  Future<ReportTable> _build() => ref.read(reportServiceProvider).build(
        _kind,
        from: _kind.dated ? _range.from : null,
        to: _kind.dated ? _range.to : null,
        categoryId: _kind.byCategory ? _categoryId : null,
      );

  void _refresh() {
    setState(() {
      _table = _build();
    });
  }

  Future<void> _export(ReportTable table) async {
    final company = await ref.read(settingsServiceProvider).company();
    if (!mounted) return;
    final bytes = reportToExcel(
      table,
      from: _kind.dated ? _range.from : null,
      to: _kind.dated ? _range.to : null,
      companyName: company.name,
    );
    await saveExcelFile(context, bytes, table.title);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 230,
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 16),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text(Strings.reports, style: theme.textTheme.titleLarge),
              ),
              for (final k in ReportKind.values)
                ListTile(
                  dense: true,
                  title: Text(k.title),
                  selected: k == _kind,
                  onTap: () {
                    _kind = k;
                    _refresh();
                  },
                ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: FutureBuilder<ReportTable>(
            future: _table,
            builder: (context, snap) {
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
                        Text(_kind.title, style: theme.textTheme.headlineSmall),
                        if (_kind.dated)
                          DateRangeBar(
                            value: _range,
                            onChanged: (r) {
                              _range = r;
                              _refresh();
                            },
                          ),
                        if (_kind.byCategory)
                          SizedBox(
                            width: 220,
                            child: DropdownButtonFormField<int?>(
                              key: ValueKey('cat-${_categories.length}'),
                              initialValue: _categoryId,
                              isDense: true,
                              decoration: const InputDecoration(
                                labelText: Strings.category,
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: [
                                const DropdownMenuItem(value: null, child: Text(Strings.all)),
                                for (final c in _categories) DropdownMenuItem(value: c.id, child: Text(c.nameAr)),
                              ],
                              onChanged: (v) {
                                _categoryId = v;
                                _refresh();
                              },
                            ),
                          ),
                        IconButton(tooltip: Strings.refresh, onPressed: _refresh, icon: const Icon(Icons.refresh)),
                        FilledButton.tonalIcon(
                          onPressed: snap.data == null ? null : () => _export(snap.data!),
                          icon: const Icon(Icons.table_view),
                          label: const Text(Strings.exportExcel),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: snap.hasError
                        ? Center(child: Text('${snap.error}'))
                        : snap.connectionState != ConnectionState.done
                            ? const Center(child: CircularProgressIndicator())
                            : ReportView(table: snap.data!),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
