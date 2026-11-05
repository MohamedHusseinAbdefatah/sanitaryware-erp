import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/db/database.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/services/discount_service.dart';
import '../../core/services/price_list_import_service.dart';
import '../../core/services/price_list_service.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/report_view.dart';

String _date(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Supplier price lists: every edition is kept, a new one is imported from
/// Excel, and optional supplier discounts are managed from here.
class PriceListsScreen extends ConsumerStatefulWidget {
  const PriceListsScreen({super.key});

  @override
  ConsumerState<PriceListsScreen> createState() => _PriceListsScreenState();
}

class _PriceListsScreenState extends ConsumerState<PriceListsScreen> {
  late Future<List<PriceListSummary>> _future;

  @override
  void initState() {
    super.initState();
    _future = ref.read(priceListServiceProvider).summaries();
  }

  void _reload() {
    setState(() => _future = ref.read(priceListServiceProvider).summaries());
  }

  Future<void> _import() async {
    final done = await showDialog<bool>(context: context, builder: (_) => const _ImportDialog());
    if (done == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('قوائم الأسعار', style: theme.textTheme.headlineSmall),
              OutlinedButton.icon(
                onPressed: () => saveExcelFile(
                  context,
                  ref.read(priceListImportServiceProvider).template(),
                  'نموذج قائمة أسعار',
                ),
                icon: const Icon(Icons.download_outlined),
                label: const Text('تحميل النموذج'),
              ),
              OutlinedButton.icon(
                onPressed: () => showDialog<void>(context: context, builder: (_) => const _DiscountsDialog()),
                icon: const Icon(Icons.percent),
                label: const Text('خصومات الموردين'),
              ),
              FilledButton.icon(
                onPressed: _import,
                icon: const Icon(Icons.upload_file_outlined),
                label: const Text('استيراد قائمة'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: FutureBuilder<List<PriceListSummary>>(
              future: _future,
              builder: (context, snap) {
                if (snap.hasError) return Center(child: Text('${snap.error}'));
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final lists = snap.data!;
                if (lists.isEmpty) {
                  return const Center(child: Text('لا توجد قوائم أسعار بعد. استورد قائمة المورد من ملف Excel.'));
                }
                return ListView.separated(
                  itemCount: lists.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final s = lists[i];
                    return Card(
                      child: ListTile(
                        title: Text('${s.supplierName} — ${s.list.name}'),
                        subtitle: Text(
                          'سارية من ${_date(s.list.effectiveDate)} · ${s.items} صنف · '
                          'مطابق للأصناف: ${s.matched} · '
                          '${s.list.vatIncluded ? 'شامل الضريبة' : 'بدون ضريبة'}',
                        ),
                        trailing: Switch(
                          value: s.list.isActive,
                          onChanged: (v) async {
                            await ref.read(priceListServiceProvider).setActive(s.list.id, v);
                            _reload();
                          },
                        ),
                        onTap: () => showDialog<void>(context: context, builder: (_) => _ItemsDialog(summary: s)),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemsDialog extends ConsumerWidget {
  const _ItemsDialog({required this.summary});

  final PriceListSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size = MediaQuery.sizeOf(context);
    return AlertDialog(
      title: Text('${summary.supplierName} — ${summary.list.name}'),
      content: SizedBox(
        width: size.width * 0.8,
        height: size.height * 0.65,
        child: FutureBuilder<List<PriceListItem>>(
          future: ref.read(priceListServiceProvider).items(summary.list.id),
          builder: (context, snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final items = snap.data!;
            return SingleChildScrollView(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columnSpacing: 16,
                  headingRowHeight: 36,
                  dataRowMinHeight: 32,
                  columns: const [
                    DataColumn(label: Text('الكود')),
                    DataColumn(label: Text('الاسم')),
                    DataColumn(label: Text('اللون')),
                    DataColumn(label: Text('السعر'), numeric: true),
                    DataColumn(label: Text('الكرتونة'), numeric: true),
                    DataColumn(label: Text('مطابق')),
                  ],
                  rows: [
                    for (final i in items.take(500))
                      DataRow(cells: [
                        DataCell(Text(i.supplierCode)),
                        DataCell(Text(i.name)),
                        DataCell(Text(i.colour ?? '')),
                        DataCell(Text(formatMoney(i.price))),
                        DataCell(Text(i.packSize == null ? '' : '${i.packSize}')),
                        DataCell(Icon(
                          i.productId == null ? Icons.remove : Icons.check_circle,
                          size: 18,
                          color: i.productId == null ? null : Colors.green.shade700,
                        )),
                      ]),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      actions: [
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق')),
      ],
    );
  }
}

class _ImportDialog extends ConsumerStatefulWidget {
  const _ImportDialog();

  @override
  ConsumerState<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends ConsumerState<_ImportDialog> {
  final _name = TextEditingController();
  late Future<List<Supplier>> _suppliers;
  int? _supplierId;
  DateTime _date0 = DateTime.now();
  bool _vat = false;
  String? _fileName;
  PriceImportPreview? _preview;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final db = ref.read(databaseProvider);
    _suppliers = (db.select(db.suppliers)..where((s) => s.isActive.equals(true))).get();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx']);
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;
    final preview = await runGuarded(
      context,
      () async => ref.read(priceListImportServiceProvider).preview(await File(path).readAsBytes()),
    );
    if (preview == null || !mounted) return;
    setState(() {
      _preview = preview;
      _fileName = picked!.files.single.name;
    });
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date0,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => _date0 = d);
  }

  bool get _ready =>
      _supplierId != null && _name.text.trim().isNotEmpty && (_preview?.canImport ?? false) && !_busy;

  Future<void> _save() async {
    setState(() => _busy = true);
    final result = await runGuarded(
      context,
      () => ref.read(priceListImportServiceProvider).import(
            _preview!,
            user: ref.read(currentUserProvider)!,
            supplierId: _supplierId!,
            name: _name.text,
            effectiveDate: _date0,
            vatIncluded: _vat,
          ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (result != null) {
      showToast(context, 'تم حفظ القائمة: ${result.rows} سطر، مطابق للأصناف: ${result.matched}');
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = _preview;
    final bad = p?.rows.where((r) => !r.ok).take(8).toList() ?? const [];
    return AlertDialog(
      title: const Text('استيراد قائمة أسعار'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FutureBuilder<List<Supplier>>(
                future: _suppliers,
                builder: (context, snap) => DropdownButtonFormField<int>(
                  initialValue: _supplierId,
                  decoration: const InputDecoration(labelText: 'المورد'),
                  items: [
                    for (final s in snap.data ?? const <Supplier>[])
                      DropdownMenuItem(value: s.id, child: Text(s.name)),
                  ],
                  onChanged: (v) => setState(() => _supplierId = v),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'اسم القائمة (مثال: ديورافيت أغسطس 2026)'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _pickDate,
                    icon: const Icon(Icons.event),
                    label: Text('سارية من ${_date(_date0)}'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _vat,
                      onChanged: (v) => setState(() => _vat = v ?? false),
                      title: const Text('الأسعار شاملة الضريبة'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _pick,
                icon: const Icon(Icons.upload_file_outlined),
                label: Text(_fileName ?? 'اختر ملف Excel'),
              ),
              if (p != null) ...[
                const SizedBox(height: 12),
                if (p.missingColumns.isNotEmpty)
                  Text('أعمدة ناقصة: ${p.missingColumns.join('، ')}',
                      style: TextStyle(color: scheme.error, fontWeight: FontWeight.bold))
                else ...[
                  Text('صفوف جاهزة: ${p.okCount}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  if (p.errorCount > 0) Text('صفوف بها أخطاء: ${p.errorCount}', style: TextStyle(color: scheme.error)),
                  for (final r in bad)
                    Text('صف ${r.rowNumber}: ${r.errors.join('، ')}', style: TextStyle(color: scheme.error)),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(
          onPressed: _ready ? _save : null,
          child: Text('حفظ${p == null ? '' : ' (${p.okCount})'}'),
        ),
      ],
    );
  }
}

class _DiscountsDialog extends ConsumerStatefulWidget {
  const _DiscountsDialog();

  @override
  ConsumerState<_DiscountsDialog> createState() => _DiscountsDialogState();
}

class _DiscountsDialogState extends ConsumerState<_DiscountsDialog> {
  late Future<List<DiscountRuleRow>> _future;

  @override
  void initState() {
    super.initState();
    _future = ref.read(discountServiceProvider).rules();
  }

  void _reload() => setState(() => _future = ref.read(discountServiceProvider).rules());

  static String _scopeLabel(String scope) => switch (scope) {
        DiscountScope.brand => 'ماركة',
        DiscountScope.category => 'تصنيف',
        DiscountScope.product => 'صنف',
        _ => 'كل أصناف المورد',
      };

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return AlertDialog(
      title: const Text('خصومات الموردين (اختيارية)'),
      content: SizedBox(
        width: 560,
        height: size.height * 0.55,
        child: FutureBuilder<List<DiscountRuleRow>>(
          future: _future,
          builder: (context, snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final rules = snap.data!;
            if (rules.isEmpty) {
              return const Center(
                child: Text('لا توجد خصومات. بدون خصم تكون التكلفة هي سعر القائمة.'),
              );
            }
            return ListView(
              children: [
                for (final r in rules)
                  ListTile(
                    title: Text('${r.supplierName}: ${r.rule.percentBp / 100}%'),
                    subtitle: Text(
                      '${_scopeLabel(r.rule.scope)}${r.targetName.isEmpty ? '' : ' — ${r.targetName}'}',
                    ),
                    trailing: Switch(
                      value: r.rule.isActive,
                      onChanged: (v) async {
                        await ref.read(discountServiceProvider).setActive(r.rule.id, v);
                        _reload();
                      },
                    ),
                  ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            final added = await showDialog<bool>(context: context, builder: (_) => const _AddDiscountDialog());
            if (added == true) _reload();
          },
          child: const Text('إضافة خصم'),
        ),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق')),
      ],
    );
  }
}

class _AddDiscountDialog extends ConsumerStatefulWidget {
  const _AddDiscountDialog();

  @override
  ConsumerState<_AddDiscountDialog> createState() => _AddDiscountDialogState();
}

class _AddDiscountDialogState extends ConsumerState<_AddDiscountDialog> {
  final _percent = TextEditingController();
  final _code = TextEditingController();
  late Future<List<Object>> _lookups;
  int? _supplierId;
  String _scope = DiscountScope.supplier;
  int? _targetId;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final db = ref.read(databaseProvider);
    _lookups = Future.wait<Object>([
      (db.select(db.suppliers)..where((s) => s.isActive.equals(true))).get(),
      db.select(db.brands).get(),
      db.select(db.categories).get(),
    ]);
  }

  @override
  void dispose() {
    _percent.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final text = _percent.text.trim().replaceAll(',', '.');
    final value = double.tryParse(text);
    if (_supplierId == null || value == null) {
      await showMessage(context, 'اختر المورد وأدخل نسبة الخصم');
      return;
    }
    setState(() => _busy = true);
    final db = ref.read(databaseProvider);
    final ok = await runGuarded(context, () async {
      int? productId;
      if (_scope == DiscountScope.product) {
        final code = _code.text.trim();
        final p = await (db.select(db.products)..where((t) => t.code.equals(code))).getSingleOrNull();
        productId = p?.id;
      }
      await ref.read(discountServiceProvider).addRule(
            supplierId: _supplierId!,
            scope: _scope,
            percentBp: (value * 100).round(),
            brandId: _scope == DiscountScope.brand ? _targetId : null,
            categoryId: _scope == DiscountScope.category ? _targetId : null,
            productId: productId,
          );
      return true;
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok == true) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('إضافة خصم'),
      content: SizedBox(
        width: 460,
        child: FutureBuilder<List<Object>>(
          future: _lookups,
          builder: (context, snap) {
            if (!snap.hasData) return const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()));
            final suppliers = snap.data![0] as List<Supplier>;
            final brands = snap.data![1] as List<Brand>;
            final categories = snap.data![2] as List<Category>;
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<int>(
                    initialValue: _supplierId,
                    decoration: const InputDecoration(labelText: 'المورد'),
                    items: [for (final s in suppliers) DropdownMenuItem(value: s.id, child: Text(s.name))],
                    onChanged: (v) => setState(() => _supplierId = v),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _scope,
                    decoration: const InputDecoration(labelText: 'ينطبق على'),
                    items: const [
                      DropdownMenuItem(value: DiscountScope.supplier, child: Text('كل أصناف المورد')),
                      DropdownMenuItem(value: DiscountScope.brand, child: Text('ماركة')),
                      DropdownMenuItem(value: DiscountScope.category, child: Text('تصنيف')),
                      DropdownMenuItem(value: DiscountScope.product, child: Text('صنف (بالكود)')),
                    ],
                    onChanged: (v) => setState(() {
                      _scope = v ?? DiscountScope.supplier;
                      _targetId = null;
                    }),
                  ),
                  if (_scope == DiscountScope.brand) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      initialValue: _targetId,
                      decoration: const InputDecoration(labelText: 'الماركة'),
                      items: [for (final b in brands) DropdownMenuItem(value: b.id, child: Text(b.name))],
                      onChanged: (v) => setState(() => _targetId = v),
                    ),
                  ],
                  if (_scope == DiscountScope.category) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      initialValue: _targetId,
                      decoration: const InputDecoration(labelText: 'التصنيف'),
                      items: [for (final c in categories) DropdownMenuItem(value: c.id, child: Text(c.nameAr))],
                      onChanged: (v) => setState(() => _targetId = v),
                    ),
                  ],
                  if (_scope == DiscountScope.product) ...[
                    const SizedBox(height: 12),
                    TextField(controller: _code, decoration: const InputDecoration(labelText: 'كود الصنف')),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: _percent,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'نسبة الخصم %', hintText: '21'),
                  ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('حفظ')),
      ],
    );
  }
}
