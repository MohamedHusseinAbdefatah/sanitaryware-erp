import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/services/purchase_plan_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/feedback.dart';

/// Opens purchase planning (blueprint 4.1).
Future<void> showPurchasePlan(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _PurchasePlanDialog());

/// What to buy now: for each product the stock, what is promised and on
/// order, sales over 30 / 60 / 90 days and the suggested quantity, with every
/// supplier's cost side by side. The person accepts, changes or drops lines
/// and saves them as draft purchase orders (one per supplier) to approve.
class _PurchasePlanDialog extends ConsumerStatefulWidget {
  const _PurchasePlanDialog();

  @override
  ConsumerState<_PurchasePlanDialog> createState() => _PurchasePlanDialogState();
}

class _PurchasePlanDialogState extends ConsumerState<_PurchasePlanDialog> {
  List<PlanRow>? _rows;
  final _qty = <int, TextEditingController>{};
  final _safety = TextEditingController();
  bool _all = false;
  String _search = '';

  PurchasePlanService get _service => PurchasePlanService(ref.read(databaseProvider));

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _qty.values) {
      c.dispose();
    }
    _safety.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final days = await _service.safetyDays();
    final rows = await _service.build(onlyNeeded: !_all);
    if (!mounted) return;
    for (final c in _qty.values) {
      c.dispose();
    }
    _qty.clear();
    for (final r in rows) {
      r.selected = r.suggested > 0;
      _qty[r.productId] = TextEditingController(text: r.qty == 0 ? '' : formatQty(r.qty));
    }
    setState(() {
      _safety.text = '$days';
      _rows = rows;
    });
  }

  Future<void> _saveSafety() async {
    final d = int.tryParse(_safety.text.trim());
    if (d == null) {
      await showMessage(context, 'اكتب عدد أيام صحيحاً');
      return;
    }
    await runGuarded(context, () => _service.setSafetyDays(d));
    await _load();
  }

  Future<void> _save() async {
    final rows = _rows ?? const <PlanRow>[];
    for (final r in rows.where((r) => r.selected)) {
      final q = parseQty(_qty[r.productId]!.text, allowDecimal: r.unitAllowsDecimal);
      if (q == null || q < 0) {
        await showMessage(context, 'كمية غير صحيحة: ${r.name}');
        return;
      }
      r.qty = q;
    }
    final ids = await runGuarded(context, () => _service.saveDrafts(rows, user: ref.read(currentUserProvider)!));
    if (ids == null || !mounted) return;
    Navigator.pop(context);
    showToast(context, 'تم حفظ ${ids.length} أمر شراء كمسودة للمراجعة والاعتماد');
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final rows = _rows;
    final shown = rows == null
        ? const <PlanRow>[]
        : rows.where((r) => _search.isEmpty || r.name.contains(_search) || r.code.contains(_search)).toList();
    final chosen = (rows ?? const <PlanRow>[]).where((r) => r.selected).toList();
    var total = 0;
    for (final r in chosen) {
      final q = parseQty(_qty[r.productId]?.text ?? '', allowDecimal: r.unitAllowsDecimal) ?? 0;
      total += lineAmount(q, r.unitCost);
    }
    final suppliers = {for (final r in chosen) r.supplierId}.whereType<int>().length;
    const head = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.muted);

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: size.width * .95,
        height: size.height * .9,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              const Icon(Icons.insights_outlined, color: AppColors.brand),
              const Text('تخطيط الشراء', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              SizedBox(
                width: 220,
                child: TextField(
                  decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search), hintText: 'بحث بالاسم أو الكود'),
                  onChanged: (v) => setState(() => _search = v.trim()),
                ),
              ),
              SizedBox(
                width: 170,
                child: TextField(
                  controller: _safety,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: 'أيام مخزون الأمان',
                    suffixIcon: IconButton(tooltip: 'تطبيق', icon: const Icon(Icons.check), onPressed: _saveSafety),
                  ),
                  onSubmitted: (_) => _saveSafety(),
                ),
              ),
              FilterChip(
                label: const Text('كل الأصناف المتحركة'),
                selected: _all,
                onSelected: (v) {
                  setState(() => _all = v);
                  _load();
                },
              ),
            ]),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Text(
              'المقترح = (متوسط البيع اليومي آخر 90 يوماً × (مدة توريد المورد + أيام الأمان)، وليس أقل من حد الطلب) + المحجوز − الرصيد المتاح للبيع − الوارد على أوامر شراء. '
              'عدّل الكمية أو المورد أو ألغِ الاختيار، ثم احفظ: يُنشأ أمر شراء مسودة لكل مورد، ولا يُلزم بشيء حتى يُعتمد.',
              style: TextStyle(fontSize: 12, color: AppColors.muted),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            child: Row(children: const [
              SizedBox(width: 40),
              Expanded(flex: 4, child: Text('الصنف', style: head)),
              Expanded(child: Text('المتاح', style: head)),
              Expanded(child: Text('محجوز', style: head)),
              Expanded(child: Text('وارد', style: head)),
              Expanded(child: Text('حد الطلب', style: head)),
              Expanded(flex: 2, child: Text('بيع 30 / 60 / 90 يوم', style: head)),
              Expanded(child: Text('المقترح', style: head)),
              SizedBox(width: 100, child: Text('الكمية', style: head)),
              Expanded(flex: 4, child: Text('المورد (التكلفة الصافية ومدة التوريد)', style: head)),
              Expanded(flex: 2, child: Text('التكلفة التقديرية', style: head)),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: rows == null
                ? const Center(child: CircularProgressIndicator())
                : shown.isEmpty
                    ? const Center(
                        child: Text('لا يوجد ما يلزم طلبه الآن. فعّل "كل الأصناف المتحركة" لعرض كل الأصناف.',
                            style: TextStyle(color: AppColors.muted)))
                    : ListView.builder(
                        itemCount: shown.length,
                        itemBuilder: (context, i) => _line(shown[i], i),
                      ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
            child: Row(children: [
              Text('${chosen.length} صنف من $suppliers مورد  ·  التكلفة التقديرية ${formatMoney(total)}',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const Spacer(),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق')),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: chosen.isEmpty ? null : _save,
                icon: const Icon(Icons.playlist_add_check),
                label: const Text('حفظ كأوامر شراء مسودة'),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _line(PlanRow r, int i) {
    final q = parseQty(_qty[r.productId]?.text ?? '', allowDecimal: r.unitAllowsDecimal) ?? 0;
    return Container(
      color: i.isOdd ? Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: .35) : null,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      child: Row(children: [
        SizedBox(
          width: 40,
          child: Checkbox(value: r.selected, onChanged: (v) => setState(() => r.selected = v ?? false)),
        ),
        Expanded(
          flex: 4,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r.name, overflow: TextOverflow.ellipsis),
            Text(r.code, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
          ]),
        ),
        Expanded(child: Text(formatQty(r.available))),
        Expanded(child: Text(r.reserved == 0 ? '—' : formatQty(r.reserved))),
        Expanded(child: Text(r.onOrder == 0 ? '—' : formatQty(r.onOrder))),
        Expanded(child: Text(r.minStock == 0 ? '—' : formatQty(r.minStock))),
        Expanded(flex: 2, child: Text('${formatQty(r.sold30)} / ${formatQty(r.sold60)} / ${formatQty(r.sold90)}')),
        Expanded(
            child: Text(formatQty(r.suggested),
                style: TextStyle(fontWeight: FontWeight.w700, color: r.suggested > 0 ? AppColors.brand : null))),
        SizedBox(
          width: 100,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: TextField(
              controller: _qty[r.productId],
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(isDense: true),
              onChanged: (_) => setState(() => r.selected = true),
            ),
          ),
        ),
        Expanded(
          flex: 4,
          child: r.offers.isEmpty
              ? const Text('لا يوجد مورد بخصم مسجل لهذه الماركة', style: TextStyle(fontSize: 12, color: AppColors.bad))
              : DropdownButton<int>(
                  value: r.supplierId,
                  isExpanded: true,
                  isDense: true,
                  underline: const SizedBox(),
                  items: [
                    for (final o in r.offers)
                      DropdownMenuItem(
                        value: o.supplierId,
                        child: Text(
                          '${o.supplierName} — ${o.netCost == null ? 'بلا خصم مسجل' : formatMoney(o.netCost!)}'
                          '${o.leadTimeDays > 0 ? ' · ${o.leadTimeDays} يوم' : ''}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(() {
                    r.supplierId = v;
                    // The lead time changed, so does the suggestion.
                    _qty[r.productId]!.text = r.suggested == 0 ? '' : formatQty(r.suggested);
                  }),
                ),
        ),
        Expanded(
          flex: 2,
          child: Text(
            '${formatMoney(lineAmount(q, r.unitCost))}${r.costIsEstimate ? ' (آخر تكلفة)' : ''}',
            style: TextStyle(fontSize: 12, color: r.costIsEstimate ? AppColors.warn : null),
          ),
        ),
      ]),
    );
  }
}
