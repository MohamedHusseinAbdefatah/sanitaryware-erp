import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/db/database.dart';
import '../../core/money.dart';
import '../../core/pricing_math.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/services/doc_types.dart';
import '../../core/services/price_list_service.dart';
import '../../core/services/product_service.dart';
import '../../core/services/stock_entry_service.dart';
import '../../core/services/stock_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/number_fields.dart';
import '../../core/widgets/pickers.dart';

/// Owner: stock entered by hand (old stock bought before the program), with
/// its real cost from a historical price list. Not a purchase: no supplier
/// invoice, no payment.
Future<void> showStockEntries(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _StockEntriesDialog());

final _entriesProvider = StreamProvider.autoDispose<List<StockEntryRow>>(
    (ref) => ref.watch(stockEntryServiceProvider).watchRows());

class _StockEntriesDialog extends ConsumerWidget {
  const _StockEntriesDialog();

  Future<void> _cancel(BuildContext context, WidgetRef ref, StockEntry e) async {
    final reason = await askReason(context, title: 'إلغاء الإدخال ${e.number}');
    if (reason == null || !context.mounted) return;
    await runGuarded(context, () async {
      await ref.read(stockEntryServiceProvider).cancel(e.id, reason: reason, user: ref.read(currentUserProvider)!);
      return true;
    });
  }

  Future<void> _show(BuildContext context, WidgetRef ref, StockEntryRow r) async {
    final lines = await ref.read(stockEntryServiceProvider).lines(r.entry.id);
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${r.entry.number} — شراء ${formatDate(r.entry.effectiveDate)}'),
        content: SizedBox(
          width: 760,
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Text('سُجل في البرنامج ${formatDateTime(r.entry.createdAt)} · ${r.locationName}'
                  '${r.listLabel == null ? '' : ' · من القائمة ${r.listLabel}'}'
                  '${r.supplierName == null ? '' : ' · المورد ${r.supplierName}'}\nالسبب: ${r.entry.reason}'),
              const SizedBox(height: 10),
              DataTable(
                columnSpacing: 18,
                columns: const [
                  DataColumn(label: Text('الصنف')),
                  DataColumn(label: Text('الموديل')),
                  DataColumn(label: Text('الكمية'), numeric: true),
                  DataColumn(label: Text('سعر القائمة'), numeric: true),
                  DataColumn(label: Text('الخصم'), numeric: true),
                  DataColumn(label: Text('التكلفة'), numeric: true),
                  DataColumn(label: Text('الإجمالي'), numeric: true),
                ],
                rows: [
                  for (final l in lines)
                    DataRow(cells: [
                      DataCell(Text('${l.productName}\n${l.productCode}${l.brandName == null ? '' : ' · ${l.brandName}'}')),
                      DataCell(Text(l.modelNo ?? '')),
                      DataCell(Text(formatQty(l.line.qty))),
                      DataCell(Text(l.line.listPrice == null ? '—' : formatMoney(l.line.listPrice!))),
                      DataCell(Text([
                        if (l.line.discountBp != 0) '${l.line.discountBp / 100}%',
                        if (l.line.discountAmount != 0) formatMoney(l.line.discountAmount),
                      ].join(' + '))),
                      DataCell(Text(formatMoney(l.line.unitCost))),
                      DataCell(Text(formatMoney(l.line.lineTotal))),
                    ]),
                ],
              ),
            ]),
          ),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(_entriesProvider);
    return AlertDialog(
      title: const Text('إدخال مخزون يدوي (بدون فاتورة شراء)'),
      content: SizedBox(
        width: 860,
        height: 520,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const InfoNote(
            'لتسجيل مخزون موجود بالفعل (مثلاً بضاعة اشتُريت في 2024 وتُدخل الآن). لا تُنشأ فاتورة شراء ولا دفعة '
            'ولا يتغير رصيد أي مورد؛ تدخل القيمة رصيد أول المدة في الحسابات. يُحفظ تاريخ الشراء الأصلي وقائمة '
            'الأسعار والخصم والتكلفة لكل صنف، وتُحسب تكلفة المخزون منها.',
          ),
          const SizedBox(height: 10),
          Expanded(
            child: rows.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
              data: (list) => list.isEmpty
                  ? const Center(child: Text('لا توجد إدخالات يدوية بعد', style: TextStyle(color: AppColors.muted)))
                  : ListView.separated(
                        itemCount: list.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final r = list[i];
                          final cancelled = r.entry.status == DocStatus.cancelled;
                          return ListTile(
                            onTap: () => _show(context, ref, r),
                            leading: Icon(Icons.move_to_inbox_outlined, color: cancelled ? AppColors.muted : AppColors.brand),
                            title: Text(
                              '${r.entry.number} · ${r.lineCount} صنف · ${formatMoney(r.entry.total)}${cancelled ? ' (ملغى)' : ''}',
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            subtitle: Text('تاريخ الشراء ${formatDate(r.entry.effectiveDate)} · سُجل ${formatDate(r.entry.createdAt)}'
                                '${r.listLabel == null ? '' : ' · ${r.listLabel}'} · ${r.entry.reason}'),
                            trailing: cancelled
                                ? null
                                : TextButton(onPressed: () => _cancel(context, ref, r.entry), child: const Text('إلغاء')),
                          );
                        },
                      ),
            ),
          ),
        ]),
      ),
      actions: [
        FilledButton.icon(
          onPressed: () => showDialog<void>(context: context, builder: (_) => const _NewEntryDialog()),
          icon: const Icon(Icons.add),
          label: const Text('إدخال جديد'),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق')),
      ],
    );
  }
}

class _EntryLine {
  _EntryLine(this.row);

  final ProductRow row;
  final qty = TextEditingController(text: '1');
  final listPrice = TextEditingController();
  final discountPercent = TextEditingController();
  final discountAmount = TextEditingController();

  /// Typed when there is no list price.
  final cost = TextEditingController();

  int? get qtyValue => parseQty(qty.text, allowDecimal: row.unitAllowsDecimal);
  int? get listValue => listPrice.text.trim().isEmpty ? null : parseMoney(listPrice.text);
  int? get bpValue {
    final t = discountPercent.text.trim().replaceAll('%', '');
    if (t.isEmpty) return 0;
    final v = double.tryParse(t);
    return v == null || v < 0 || v > 100 ? null : (v * 100).round();
  }

  int get amountValue => moneyOrZero(discountAmount);

  int? get unitCost {
    final list = listValue;
    if (list == null) return cost.text.trim().isEmpty ? null : parseMoney(cost.text);
    final bp = bpValue;
    if (bp == null) return null;
    return applyDiscount(list, bp) - amountValue;
  }

  int? get total {
    final q = qtyValue, c = unitCost;
    return q == null || c == null ? null : lineAmount(q, c);
  }

  void dispose() {
    for (final c in [qty, listPrice, discountPercent, discountAmount, cost]) {
      c.dispose();
    }
  }
}

class _NewEntryDialog extends ConsumerStatefulWidget {
  const _NewEntryDialog();

  @override
  ConsumerState<_NewEntryDialog> createState() => _NewEntryDialogState();
}

class _NewEntryDialogState extends ConsumerState<_NewEntryDialog> {
  final _lines = <_EntryLine>[];
  final _reason = TextEditingController(text: 'مخزون قديم قبل البرنامج');
  final _notes = TextEditingController();
  final _defaultDiscount = TextEditingController();
  DateTime _date = DateTime.now();
  int? _listId;
  int? _supplierId;
  int _locationId = mainLocationId;
  int _searchKey = 0;
  bool _saving = false;
  late final Future<List<PriceListSummary>> _lists = ref.read(priceListServiceProvider).summaries();

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    _reason.dispose();
    _notes.dispose();
    _defaultDiscount.dispose();
    super.dispose();
  }

  int get _total => _lines.fold(0, (s, l) => s + (l.total ?? 0));

  Future<void> _fillFromList(_EntryLine line) async {
    final listId = _listId;
    if (listId == null) return;
    final (price, bp) = await ref.read(stockEntryServiceProvider).priceIn(listId, line.row.product.id);
    if (!mounted) return;
    setState(() {
      line.listPrice.text = price == null ? '' : formatMoney(price).replaceAll(',', '');
      final typed = _defaultDiscount.text.trim();
      line.discountPercent.text = typed.isNotEmpty ? typed : (bp == 0 ? '' : '${bp / 100}');
    });
  }

  void _add(ProductRow row) {
    if (_lines.any((l) => l.row.product.id == row.product.id)) {
      showToast(context, 'الصنف موجود بالفعل؛ عدّل كميته', kind: ToastKind.warning);
      return;
    }
    final line = _EntryLine(row);
    setState(() {
      _lines.add(line);
      _searchKey++;
    });
    _fillFromList(line);
  }

  void _setList(int? id) {
    setState(() => _listId = id);
    for (final l in _lines) {
      _fillFromList(l);
    }
  }

  Future<void> _save({bool allowDuplicate = false}) async {
    if (_lines.isEmpty) {
      await showMessage(context, 'أضف صنفاً واحداً على الأقل');
      return;
    }
    for (final l in _lines) {
      if (l.qtyValue == null || l.qtyValue! <= 0 || l.unitCost == null) {
        await showMessage(context, 'راجع الكمية والتكلفة للصنف "${l.row.product.nameAr}"');
        return;
      }
    }
    setState(() => _saving = true);
    DuplicateStockEntryException? duplicate;
    final saved = await runGuarded<StockEntry?>(context, () async {
      try {
        return await ref.read(stockEntryServiceProvider).enter(
              StockEntryInput(
                lines: [
                  for (final l in _lines)
                    StockEntryLineInput(
                      productId: l.row.product.id,
                      qty: l.qtyValue!,
                      listPrice: l.listValue,
                      unitCost: l.listValue == null ? l.unitCost : null,
                      discountBp: l.bpValue ?? 0,
                      discountAmount: l.amountValue,
                    ),
                ],
                effectiveDate: _date,
                reason: _reason.text,
                priceListId: _listId,
                supplierId: _supplierId,
                locationId: _locationId,
                notes: _notes.text,
                allowDuplicate: allowDuplicate,
              ),
              user: ref.read(currentUserProvider)!,
            );
      } on DuplicateStockEntryException catch (e) {
        duplicate = e;
        return null;
      }
    });
    if (!mounted) return;
    setState(() => _saving = false);
    final dup = duplicate;
    if (dup != null) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('إدخال مكرر؟'),
          content: Text('${dup.message}\n\nهل هذا مخزون مختلف فعلاً؟'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('رجوع')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('نعم، أدخله')),
          ],
        ),
      );
      if (go == true && mounted) await _save(allowDuplicate: true);
      return;
    }
    if (saved == null) return;
    showToast(context, 'تم الإدخال ${saved.number}: ${formatMoney(saved.total)}');
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final suppliers = ref.watch(activeSuppliersProvider).valueOrNull ?? const <Supplier>[];
    final size = MediaQuery.sizeOf(context);
    return AlertDialog(
      title: const Text('إدخال مخزون يدوي'),
      content: SizedBox(
        width: size.width * 0.85,
        height: size.height * 0.75,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
            OutlinedButton.icon(
              onPressed: () async {
                final d = await showDatePicker(
                  context: context,
                  initialDate: _date,
                  firstDate: DateTime(2000),
                  lastDate: DateTime.now(),
                  helpText: 'تاريخ الشراء الأصلي',
                );
                if (d != null) setState(() => _date = d);
              },
              icon: const Icon(Icons.event),
              label: Text('تاريخ الشراء الأصلي ${formatDate(_date)}'),
            ),
            SizedBox(
              width: 360,
              child: FutureBuilder<List<PriceListSummary>>(
                future: _lists,
                builder: (context, snap) {
                  final lists = (snap.data ?? const <PriceListSummary>[])
                      .where((s) => s.list.status != PriceListStatus.withdrawn)
                      .toList();
                  return DropdownButtonFormField<int?>(
                    isExpanded: true,
                    initialValue: _listId,
                    decoration: const InputDecoration(labelText: 'قائمة الأسعار التاريخية (اختياري)', isDense: true),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('بدون — أكتب التكلفة')),
                      for (final s in lists)
                        DropdownMenuItem(
                          value: s.list.id,
                          child: Text(
                            '${s.brandName ?? ''} ${s.list.listType} V${s.list.versionNo} · '
                            '${formatDate(s.list.effectiveFrom)}${s.list.effectiveTo == null ? '' : ' ← ${formatDate(s.list.effectiveTo!)}'}'
                            '${s.list.status == PriceListStatus.inactive ? ' (موقوفة)' : ''}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _setList,
                  );
                },
              ),
            ),
            SizedBox(
              width: 150,
              child: TextField(
                controller: _defaultDiscount,
                decoration: const InputDecoration(labelText: 'خصم لكل الأصناف %', isDense: true),
                onChanged: (v) => setState(() {
                  for (final l in _lines) {
                    l.discountPercent.text = v;
                  }
                }),
              ),
            ),
            LocationDropdown(value: _locationId, onChanged: (v) => setState(() => _locationId = v)),
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<int?>(
                isExpanded: true,
                initialValue: _supplierId,
                decoration: const InputDecoration(labelText: 'اشتُري من (للسجل فقط)', isDense: true),
                items: [
                  const DropdownMenuItem(value: null, child: Text('—')),
                  for (final s in suppliers) DropdownMenuItem(value: s.id, child: Text(s.name)),
                ],
                onChanged: (v) => setState(() => _supplierId = v),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          ProductSearchField(key: ValueKey(_searchKey), autofocus: false, onSelected: _add),
          const SizedBox(height: 8),
          if (_lines.isNotEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Row(children: [
                Expanded(flex: 5, child: Text('الصنف', style: TextStyle(fontWeight: FontWeight.bold))),
                Expanded(flex: 2, child: Text('الكمية', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold))),
                Expanded(flex: 2, child: Text('سعر القائمة', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold))),
                Expanded(flex: 2, child: Text('خصم %', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold))),
                Expanded(flex: 2, child: Text('خصم مبلغ/وحدة', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold))),
                Expanded(flex: 2, child: Text('التكلفة', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold))),
                Expanded(flex: 2, child: Text('الإجمالي', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold))),
                SizedBox(width: 40),
              ]),
            ),
          Expanded(
            child: _lines.isEmpty
                ? const Center(child: Text('ابحث عن صنف لإضافته', style: TextStyle(color: AppColors.muted)))
                : ListView.separated(
                      itemCount: _lines.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final l = _lines[i];
                        Widget box(TextEditingController c, {String? hint}) => Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: TextField(
                                controller: c,
                                textAlign: TextAlign.center,
                                decoration: InputDecoration(isDense: true, hintText: hint),
                                onChanged: (_) => setState(() {}),
                              ),
                            );
                        final cost = l.unitCost;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(children: [
                            Expanded(
                              flex: 5,
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(l.row.product.nameAr, style: const TextStyle(fontWeight: FontWeight.w600)),
                                Text(
                                  [
                                    l.row.product.code,
                                    if ((l.row.product.modelNo ?? '').isNotEmpty) 'موديل ${l.row.product.modelNo}',
                                    if (l.row.brandName != null) l.row.brandName!,
                                    'المخزون ${formatQty(l.row.stock)}',
                                  ].join(' · '),
                                  style: const TextStyle(fontSize: 12, color: AppColors.muted),
                                ),
                              ]),
                            ),
                            Expanded(flex: 2, child: box(l.qty)),
                            Expanded(flex: 2, child: box(l.listPrice, hint: '—')),
                            Expanded(flex: 2, child: box(l.discountPercent, hint: '%')),
                            Expanded(flex: 2, child: box(l.discountAmount, hint: '0')),
                            Expanded(
                              flex: 2,
                              child: l.listValue == null
                                  ? box(l.cost, hint: 'اكتب التكلفة')
                                  : Text(cost == null ? '—' : formatMoney(cost),
                                      textAlign: TextAlign.center,
                                      style: TextStyle(color: cost != null && cost < 0 ? AppColors.bad : null)),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(l.total == null ? '—' : formatMoney(l.total!),
                                  textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold)),
                            ),
                            IconButton(
                              tooltip: 'حذف السطر',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => setState(() => _lines.removeAt(i).dispose()),
                            ),
                          ]),
                        );
                      },
                    ),
          ),
          const Divider(),
          Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: 320,
              child: TextField(controller: _reason, decoration: const InputDecoration(labelText: 'سبب الإدخال (مطلوب)', isDense: true)),
            ),
            SizedBox(
              width: 260,
              child: TextField(controller: _notes, decoration: const InputDecoration(labelText: 'ملاحظات', isDense: true)),
            ),
            Text('إجمالي قيمة المخزون التاريخي: ${formatMoney(_total)}',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: AppColors.brand)),
          ]),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton.icon(
          onPressed: _saving ? null : () => _save(),
          icon: const Icon(Icons.save),
          label: const Text('حفظ الإدخال'),
        ),
      ],
    );
  }
}
