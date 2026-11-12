import 'package:drift/drift.dart' show Variable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/db/database.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/search_text.dart';
import '../../core/services/stock_service.dart';
import '../../core/services/product_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/list_kit.dart';
import '../../core/widgets/pickers.dart';
import '../products/products_screen.dart';

/// A stock count at one place (blueprint 5.1): what the books say, what
/// was counted, the difference and its value; posting turns the
/// differences into adjustments with the count's note as the reason.
Future<void> showStockCount(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _StockCountDialog());

class _StockCountDialog extends ConsumerStatefulWidget {
  const _StockCountDialog();

  @override
  ConsumerState<_StockCountDialog> createState() => _StockCountDialogState();
}

class _Line {
  _Line(this.row);

  final ProductRow row;
  final counted = TextEditingController();
}

class _StockCountDialogState extends ConsumerState<_StockCountDialog> {
  int _locationId = mainLocationId;
  int? _categoryId;
  String _search = '';
  bool _heldOnly = true;
  final _note = TextEditingController(text: 'جرد دوري');
  List<_Line>? _lines;
  Map<int, int> _books = const {};
  Map<int, int> _costs = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final l in _lines ?? const <_Line>[]) {
      l.counted.dispose();
    }
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final db = ref.read(databaseProvider);
    final rows = await ref.read(productServiceProvider).watchList(includeInactive: false).first;
    final books = {
      for (final r in await db.customSelect(
        'SELECT product_id AS p, SUM(qty) AS q FROM stock_movements WHERE location_id = ? GROUP BY product_id',
        variables: [Variable.withInt(_locationId)],
      ).get())
        r.read<int>('p'): r.read<int>('q'),
    };
    final costs = <int, int>{
      for (final r in await db.customSelect('SELECT product_id AS p, unit_cost AS c FROM cost_layers ORDER BY received_at, id').get())
        r.read<int>('p'): r.read<int>('c'),
    };
    if (!mounted) return;
    setState(() {
      _lines = [for (final r in rows) _Line(r)];
      _books = books;
      _costs = costs;
    });
  }

  int? _countedOf(_Line l) =>
      l.counted.text.trim().isEmpty ? null : parseQty(l.counted.text, allowDecimal: l.row.unitAllowsDecimal);

  Future<void> _post() async {
    final counted = <int, int>{};
    for (final l in _lines!) {
      final c = _countedOf(l);
      if (c != null) counted[l.row.product.id] = c;
    }
    if (counted.isEmpty) {
      await showMessage(context, 'لم تُدخل أي كمية معدودة بعد');
      return;
    }
    final diffs = counted.entries.where((e) => e.value != (_books[e.key] ?? 0)).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('اعتماد الجرد'),
        content: Text('تم عدّ ${counted.length} صنف، منها $diffs بفرق عن الدفاتر.\n'
            'ستُسجل الفروق كتسويات مخزون بسبب: ${_note.text.trim()}\nلا يمكن التراجع إلا بتسوية عكسية.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('رجوع')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('اعتماد')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final n = await runGuarded(
      context,
      () => ref.read(stockServiceProvider).postCount(
            locationId: _locationId,
            counted: counted,
            note: _note.text,
            userId: ref.read(currentUserProvider)?.id,
          ),
    );
    if (n != null && mounted) {
      Navigator.pop(context);
      showToast(context, n == 0 ? 'الجرد مطابق للدفاتر' : 'تم اعتماد الجرد وتسوية $n صنف');
    }
  }

  @override
  Widget build(BuildContext context) {
    final seesCost = ref.watch(currentUserProvider)?.seesCost ?? false;
    final categories = ref.watch(categoriesProvider).valueOrNull ?? const <Category>[];
    final size = MediaQuery.sizeOf(context);
    final all = _lines;
    final shown = all == null
        ? const <_Line>[]
        : all
            .where((l) =>
                (!_heldOnly || (_books[l.row.product.id] ?? 0) != 0 || l.counted.text.isNotEmpty) &&
                (_categoryId == null || l.row.product.categoryId == _categoryId) &&
                matchesSearch(_search, [l.row.product.code, l.row.product.nameAr, l.row.product.barcode, l.row.brandName]))
            .toList();
    var countedN = 0, diffN = 0, value = 0;
    for (final l in all ?? const <_Line>[]) {
      final c = _countedOf(l);
      if (c == null) continue;
      countedN++;
      final d = c - (_books[l.row.product.id] ?? 0);
      if (d != 0) diffN++;
      value += lineAmount(d, _costs[l.row.product.id] ?? 0);
    }
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: size.width * .9,
        height: size.height * .9,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              const Text('جرد المخزون', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              LocationDropdown(
                value: _locationId,
                onChanged: (v) {
                  setState(() {
                    _locationId = v;
                    _lines = null;
                  });
                  _load();
                },
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  onChanged: (v) => setState(() => _search = v),
                  decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search), hintText: 'بحث'),
                ),
              ),
              FilterMenu(
                icon: Icons.category_outlined,
                allLabel: 'كل التصنيفات',
                value: _categoryId,
                options: [for (final c in categories) (c.id, c.nameAr)],
                onChanged: (v) => setState(() => _categoryId = v),
              ),
              FilterChip(
                label: const Text('الأصناف التي لها رصيد فقط'),
                selected: _heldOnly,
                onSelected: (v) => setState(() => _heldOnly = v),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Wrap(spacing: 8, children: [
              StatusPill('تم عدّ $countedN'),
              diffN == 0 ? const StatusPill.good('لا فروق') : StatusPill.warn('بفرق $diffN'),
              if (seesCost)
                value < 0
                    ? StatusPill.bad('عجز بقيمة ${formatMoney(-value)}')
                    : (value > 0 ? StatusPill.good('زيادة بقيمة ${formatMoney(value)}') : const StatusPill('الأثر 0.00')),
            ]),
          ),
          const SizedBox(height: 8),
          Container(
            color: AppColors.canvas,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(children: [
              const Expanded(flex: 5, child: Text('الصنف', style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.muted))),
              const Expanded(flex: 2, child: Text('رصيد الدفاتر', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.muted))),
              const Expanded(flex: 2, child: Text('المعدود فعلاً', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.muted))),
              const Expanded(flex: 2, child: Text('الفرق', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.muted))),
              if (seesCost)
                const Expanded(flex: 2, child: Text('القيمة', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.muted))),
            ]),
          ),
          Expanded(
            child: all == null
                ? const Center(child: CircularProgressIndicator())
                : shown.isEmpty
                    ? const Center(child: Text('لا أصناف بهذا الاختيار', style: TextStyle(color: AppColors.muted)))
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        itemCount: shown.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final l = shown[i];
                          final books = _books[l.row.product.id] ?? 0;
                          final c = _countedOf(l);
                          final d = c == null ? null : c - books;
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(children: [
                              Expanded(
                                flex: 5,
                                child: TitleCell(l.row.product.nameAr,
                                    subtitle: [l.row.product.code, if (l.row.unitName != null) l.row.unitName!].join('  ·  ')),
                              ),
                              Expanded(flex: 2, child: Text(formatQty(books), textAlign: TextAlign.center)),
                              Expanded(
                                flex: 2,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  child: TextField(
                                    controller: l.counted,
                                    textAlign: TextAlign.center,
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    onChanged: (_) => setState(() {}),
                                    decoration: const InputDecoration(isDense: true, hintText: 'لم يُعد'),
                                  ),
                                ),
                              ),
                              Expanded(
                                flex: 2,
                                child: Text(
                                  d == null ? '' : (d > 0 ? '+${formatQty(d)}' : formatQty(d)),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: d == null || d == 0 ? AppColors.muted : (d < 0 ? AppColors.bad : AppColors.good),
                                  ),
                                ),
                              ),
                              if (seesCost)
                                Expanded(
                                  flex: 2,
                                  child: Text(
                                    d == null || d == 0 ? '' : formatMoney(lineAmount(d, _costs[l.row.product.id] ?? 0)),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                            ]),
                          );
                        },
                      ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _note,
                  decoration: const InputDecoration(isDense: true, labelText: 'بيان الجرد (يظهر كسبب للتسويات)'),
                ),
              ),
              const SizedBox(width: 12),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق بدون اعتماد')),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: all == null ? null : _post,
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('اعتماد الجرد'),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
