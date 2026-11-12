import 'dart:async';

import 'package:drift/drift.dart' show TableUpdateQuery;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/reports/report_excel.dart';
import '../../core/reports/report_table.dart';
import '../../core/services/ledger_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/report_view.dart';

/// Bumped after a manual change to the books (an entry, a closing), so every
/// open accounting view reads them again.
final ledgerRevisionProvider = StateProvider<int>((ref) => 0);

/// Loads something from the ledger and shows it; loads again when [reloadKey]
/// changes, when the books are changed here, or when any document changes.
class LedgerBuilder<T> extends ConsumerStatefulWidget {
  const LedgerBuilder({super.key, required this.load, required this.builder, this.reloadKey});

  final Future<T> Function(LedgerService ledger) load;
  final Widget Function(BuildContext context, T value) builder;
  final Object? reloadKey;

  @override
  ConsumerState<LedgerBuilder<T>> createState() => _LedgerBuilderState<T>();
}

class _LedgerBuilderState<T> extends ConsumerState<LedgerBuilder<T>> {
  Future<T>? _future;
  StreamSubscription<void>? _sub;
  Timer? _debounce;
  T? _last;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _reload();
    final db = ref.read(databaseProvider);
    _sub = db
        .tableUpdates(TableUpdateQuery.onAllTables([
          db.salesInvoices,
          db.purchaseInvoices,
          db.payments,
          db.cheques,
          db.returns,
          db.expenses,
          db.stockMovements,
          db.customers,
          db.suppliers,
          db.accounts,
        ]))
        .listen((_) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 400), () {
        if (mounted) setState(_reload);
      });
    });
  }

  void _reload() {
    _future = widget.load(ref.read(ledgerServiceProvider)).then((v) {
      _loaded = true;
      return _last = v;
    });
  }

  @override
  void didUpdateWidget(covariant LedgerBuilder<T> old) {
    super.didUpdateWidget(old);
    if (old.reloadKey != widget.reloadKey) _reload();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(ledgerRevisionProvider, (_, _) => setState(_reload));
    return FutureBuilder<T>(
      future: _future,
      builder: (context, snap) {
        if (snap.hasError) return Center(child: SelectableText('${snap.error}'));
        // A finished load counts even when its value is null (no closed
        // period, say); only "nothing loaded yet" shows the spinner.
        if (snap.connectionState == ConnectionState.done) return widget.builder(context, snap.data as T);
        if (!_loaded) return const Center(child: CircularProgressIndicator());
        return widget.builder(context, _last as T);
      },
    );
  }
}

/// A line of a financial statement: a label and an amount, with optional
/// comparison, indentation and emphasis.
class StatementLine extends StatelessWidget {
  const StatementLine(
    this.label,
    this.amount, {
    super.key,
    this.compare,
    this.code,
    this.level = 0,
    this.strong = false,
    this.total = false,
    this.onTap,
    this.hint,
  });

  final String label;
  final int? amount;
  final int? compare;
  final String? code;
  final int level;
  final bool strong;
  final bool total;
  final VoidCallback? onTap;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontWeight: total ? FontWeight.w900 : (strong ? FontWeight.w700 : FontWeight.w400),
      fontSize: total ? 15 : 14,
    );
    Widget money(int? v) => SizedBox(
          width: 150,
          child: Text(
            v == null ? '' : formatMoney(v),
            textAlign: TextAlign.end,
            style: style.copyWith(color: v != null && v < 0 ? AppColors.bad : null),
          ),
        );
    final row = Container(
      padding: EdgeInsetsDirectional.fromSTEB(12 + level * 20.0, total ? 10 : 7, 12, total ? 10 : 7),
      decoration: BoxDecoration(
        color: total ? AppColors.canvas : null,
        border: total ? const Border(top: BorderSide(color: AppColors.border)) : null,
      ),
      child: Row(children: [
        if (code != null)
          SizedBox(width: 56, child: Text(code!, style: const TextStyle(color: AppColors.muted, fontSize: 12))),
        Expanded(
          child: Text.rich(TextSpan(children: [
            TextSpan(text: label, style: style.copyWith(color: onTap != null ? AppColors.info : null)),
            if (hint != null) TextSpan(text: '  $hint', style: const TextStyle(color: AppColors.muted, fontSize: 12)),
          ])),
        ),
        money(amount),
        if (compare != null || amount == null) money(compare),
      ]),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}

/// The header of a statement's columns: "this period" and "before".
class StatementHeader extends StatelessWidget {
  const StatementHeader({super.key, required this.current, this.compare});

  final String current;
  final String? compare;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontWeight: FontWeight.w700, color: AppColors.muted, fontSize: 12);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: AppColors.zebra,
      child: Row(children: [
        const Expanded(child: Text('البند', style: style)),
        SizedBox(width: 150, child: Text(current, textAlign: TextAlign.end, style: style)),
        if (compare != null) SizedBox(width: 150, child: Text(compare!, textAlign: TextAlign.end, style: style)),
      ]),
    );
  }
}

/// A page-width scrollable column of cards, centred and not too wide.
class ReportPage extends StatelessWidget {
  const ReportPage({super.key, required this.children, this.maxWidth = 980});

  final List<Widget> children;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final c in children) ...[c, const SizedBox(height: 16)],
          ]),
        ),
      ),
    );
  }
}

/// A white card holding statement lines.
class StatementCard extends StatelessWidget {
  const StatementCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }
}

/// Saves [table] as Excel, with the company name on top.
Future<void> exportTable(BuildContext context, WidgetRef ref, ReportTable table, {DateTime? from, DateTime? to}) async {
  final company = await ref.read(settingsServiceProvider).company();
  if (!context.mounted) return;
  final bytes = reportToExcel(table, from: from, to: to, companyName: company.name);
  await saveExcelFile(context, bytes, table.title);
}

String percentBp(int? bp) => bp == null ? '—' : '${(bp / 100).toStringAsFixed(1)}%';
