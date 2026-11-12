import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/db/database.dart';
import '../../core/error_log.dart';
import '../../core/money.dart';
import '../../core/pdf_import/pdf_reader.dart';
import '../../core/pdf_import/price_table.dart';
import '../../core/pricing_math.dart';
import '../../core/providers.dart';
import '../../core/services/buying_policy_service.dart';
import '../../core/services/errors.dart';
import '../../core/services/price_list_import_service.dart';
import '../../core/services/price_list_service.dart';
import '../../core/services/product_service.dart';
import '../../core/services/selling_policy_service.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/pickers.dart';
import '../../core/widgets/report_view.dart';
import 'list_type_field.dart';

part 'pdf_import_dialog.dart';
part 'selling_discounts_tab.dart';

String _date(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _percent(int bp) => '${(bp / 100).toStringAsFixed(bp % 100 == 0 ? 0 : 2)}%';

/// Percent text -> basis points; null if not a number from 0 to 100.
int? _bp(String text) {
  final v = double.tryParse(text.trim().replaceAll(',', '.'));
  if (v == null || v < 0 || v > 100) return null;
  return (v * 100).round();
}

String _statusLabel(String status) => switch (status) {
      PriceListStatus.pendingReview => 'قيد المراجعة',
      PriceListStatus.withdrawn => 'مسحوبة',
      _ => 'معتمدة',
    };

final _summariesProvider = StreamProvider.autoDispose<List<PriceListSummary>>(
    (ref) => ref.watch(priceListServiceProvider).watchSummaries());

final _brandsProvider =
    StreamProvider.autoDispose<List<Brand>>((ref) => ref.watch(catalogServiceProvider).watchBrands());

/// Blueprint section 3: price list versions, the review queue, and the buying
/// and selling policies, which are kept apart from one another.
class PriceListsScreen extends StatelessWidget {
  const PriceListsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: const [
          TabBar(tabs: [
            Tab(text: 'قوائم الأسعار'),
            Tab(text: 'قيد المراجعة'),
            Tab(text: 'سياسات الشراء'),
            Tab(text: 'خصومات البيع'),
          ]),
          Expanded(
            child: TabBarView(children: [
              _VersionsTab(),
              _ReviewTab(),
              _BuyingTab(),
              _SellingDiscountsTab(),
            ]),
          ),
        ],
      ),
    );
  }
}

class _VersionsTab extends ConsumerWidget {
  const _VersionsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lists = ref.watch(_summariesProvider);
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
                onPressed: () => showDialog<void>(context: context, builder: (_) => const _EntryDialog()),
                icon: const Icon(Icons.edit_note),
                label: const Text('إدخال صنف أو مجموعة أصناف'),
              ),
              FilledButton.icon(
                onPressed: () => showDialog<void>(context: context, builder: (_) => const _ImportDialog()),
                icon: const Icon(Icons.upload_file_outlined),
                label: const Text('استيراد قائمة كاملة'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => showDialog<void>(context: context, builder: (_) => const _PdfImportDialog()),
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: const Text('استيراد من PDF'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: lists.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
              data: (rows) => rows.isEmpty
                  ? const Center(child: Text('لا توجد قوائم أسعار بعد. استورد قائمة كاملة أو أدخل صنفاً.'))
                  : ListView.separated(
                      itemCount: rows.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) => _VersionCard(summary: rows[i]),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VersionCard extends ConsumerWidget {
  const _VersionCard({required this.summary});

  final PriceListSummary summary;

  Future<void> _setVat(BuildContext context) =>
      showDialog<void>(context: context, builder: (_) => _VatDialog(list: summary.list));

  /// At go-live: stock entered before this list was loaded came in at this list.
  Future<void> _assignStock(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('المخزون غير المحدد'),
        content: const Text('هل دخل كل المخزون غير المحدد لأصناف هذه القائمة بأسعارها؟ سيُسجل ذلك في سجل العمليات.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('نعم')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final n = await runGuarded(
      context,
      () => ref
          .read(stockPriceServiceProvider)
          .assignAllUnknownFrom(summary.list.id, user: ref.read(currentUserProvider)!),
    );
    if (n != null && context.mounted) showToast(context, 'تم تحديد القائمة لعدد $n صنف');
  }

  Future<void> _withdraw(BuildContext context, WidgetRef ref) async {
    final reason = await _askText(context, 'سحب القائمة', 'سبب السحب');
    if (reason == null || !context.mounted) return;
    await runGuarded(context, () async {
      await ref
          .read(priceListServiceProvider)
          .withdraw(summary.list.id, reason: reason, user: ref.read(currentUserProvider)!);
      return true;
    });
  }

  /// Opens the PDF this version was read from, kept beside the database.
  Future<void> _openSource(BuildContext context, File pdf) async {
    if (!await pdf.exists()) {
      if (context.mounted) await showMessage(context, 'لم يعد ملف المصدر موجوداً في مجلد البيانات');
      return;
    }
    await Process.run('explorer', [pdf.path]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = summary.list;
    final pdf = (l.sourceFile ?? '').toLowerCase().endsWith('.pdf')
        ? _sourcePdf(ref.read(databaseFileProvider), l.id)
        : null;
    final period = 'من ${_date(l.effectiveFrom)}${l.effectiveTo == null ? ' (مفتوحة)' : ' إلى ${_date(l.effectiveTo!)}'}';
    return Card(
      child: ListTile(
        title: Text('PL-${l.id} · ${summary.brandName ?? 'بدون ماركة'} · ${l.listType} · V${l.versionNo} — ${l.name}'),
        subtitle: Text(
          '$period · ${l.currency} · استيراد ${_date(l.importDate)}'
          '${l.sourceFile == null ? '' : ' · المصدر: ${l.sourceFile}'}'
          '${l.sourcePages == null ? '' : ' صفحات ${l.sourcePages}'}\n'
          'الصفوف ${l.rowCount} · معتمد ${summary.matched} · قيد المراجعة ${summary.review} · '
          '${VatStatus.label(l.vatStatus)}${l.vatRateBp == null ? '' : ' ${_percent(l.vatRateBp!)}'} · '
          '${_statusLabel(l.status)}',
        ),
        isThreeLine: true,
        onTap: () => showDialog<void>(context: context, builder: (_) => _ItemsDialog(summary: summary)),
        trailing: PopupMenuButton<void Function()>(
          onSelected: (a) => a(),
          itemBuilder: (_) => [
            if (l.status == PriceListStatus.pendingReview)
              PopupMenuItem(
                value: () => showDialog<void>(context: context, builder: (_) => _ApprovePendingDialog(list: l)),
                child: const Text('مراجعة واعتماد'),
              ),
            if (pdf != null)
              PopupMenuItem(value: () => _openSource(context, pdf), child: const Text('فتح ملف المصدر')),
            PopupMenuItem(value: () => _setVat(context), child: const Text('تسجيل الضريبة بعد التحقق')),
            PopupMenuItem(value: () => _assignStock(context, ref), child: const Text('المخزون غير المحدد من هذه القائمة')),
            if (l.status != PriceListStatus.withdrawn)
              PopupMenuItem(value: () => _withdraw(context, ref), child: const Text('سحب القائمة')),
          ],
        ),
      ),
    );
  }
}

Future<String?> _askText(BuildContext context, String title, String label) async {
  final c = TextEditingController();
  final v = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true, decoration: InputDecoration(labelText: label)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(
          onPressed: () {
            if (c.text.trim().isNotEmpty) Navigator.pop(context, c.text.trim());
          },
          child: const Text('حفظ'),
        ),
      ],
    ),
  );
  c.dispose();
  return v;
}

class _ItemsDialog extends ConsumerWidget {
  const _ItemsDialog({required this.summary});

  final PriceListSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size = MediaQuery.sizeOf(context);
    final l = summary.list;
    return AlertDialog(
      title: Text('PL-${l.id} — ${l.listType} V${l.versionNo}'),
      content: SizedBox(
        width: size.width * 0.8,
        height: size.height * 0.65,
        child: FutureBuilder<List<PriceListItem>>(
          future: ref.read(priceListServiceProvider).items(l.id),
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
                    DataColumn(label: Text('كود الشركة')),
                    DataColumn(label: Text('الاسم')),
                    DataColumn(label: Text('اللون')),
                    DataColumn(label: Text('السعر'), numeric: true),
                    DataColumn(label: Text('الكرتونة'), numeric: true),
                    DataColumn(label: Text('الحالة')),
                  ],
                  rows: [
                    for (final i in items.take(1000))
                      DataRow(cells: [
                        DataCell(Text(i.manufacturerCode)),
                        DataCell(Text(i.name)),
                        DataCell(Text(i.variant ?? '')),
                        DataCell(Text(i.price == null ? '—' : formatMoney(i.price!))),
                        DataCell(Text(i.packSize == null ? '' : '${i.packSize}')),
                        DataCell(Text(switch (i.status) {
                          PriceRowStatus.review => 'مراجعة: ${i.reviewReason ?? ''}',
                          PriceRowStatus.skipped => 'مستبعد: ${i.reviewReason ?? ''}',
                          _ => 'معتمد',
                        })),
                      ]),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق'))],
    );
  }
}

/// VAT status and rate fields, used wherever a list's VAT is recorded.
class _VatFields extends StatelessWidget {
  const _VatFields({required this.status, required this.rate, required this.onStatus});

  final String status;
  final TextEditingController rate;
  final ValueChanged<String> onStatus;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: status,
            decoration: const InputDecoration(labelText: 'حالة الضريبة حسب المصدر'),
            items: [
              for (final s in VatStatus.all) DropdownMenuItem(value: s, child: Text(VatStatus.label(s))),
            ],
            onChanged: (v) => onStatus(v ?? VatStatus.unverified),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 130,
          child: TextField(
            controller: rate,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'نسبة الضريبة %'),
          ),
        ),
      ],
    );
  }
}

class _VatDialog extends ConsumerStatefulWidget {
  const _VatDialog({required this.list});

  final PriceList list;

  @override
  ConsumerState<_VatDialog> createState() => _VatDialogState();
}

class _VatDialogState extends ConsumerState<_VatDialog> {
  late String _status = widget.list.vatStatus;
  late final _rate = TextEditingController(
      text: widget.list.vatRateBp == null ? '' : (widget.list.vatRateBp! / 100).toString());

  @override
  void dispose() {
    _rate.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final ok = await runGuarded(context, () async {
      await ref.read(priceListServiceProvider).setVat(
            widget.list.id,
            vatStatus: _status,
            vatRateBp: _rate.text.trim().isEmpty ? null : _bp(_rate.text),
            user: ref.read(currentUserProvider)!,
          );
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('الضريبة بعد التحقق من المصدر'),
      content: SizedBox(
        width: 460,
        child: _VatFields(status: _status, rate: _rate, onStatus: (v) => setState(() => _status = v)),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(onPressed: _save, child: const Text('حفظ')),
      ],
    );
  }
}

class _ApprovePendingDialog extends ConsumerStatefulWidget {
  const _ApprovePendingDialog({required this.list});

  final PriceList list;

  @override
  ConsumerState<_ApprovePendingDialog> createState() => _ApprovePendingDialogState();
}

class _ApprovePendingDialogState extends ConsumerState<_ApprovePendingDialog> {
  late int? _brandId = widget.list.brandId;
  late String _status = widget.list.vatStatus;
  final _rate = TextEditingController();

  @override
  void dispose() {
    _rate.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_brandId == null) {
      await showMessage(context, 'اختر الماركة');
      return;
    }
    final ok = await runGuarded(context, () async {
      await ref.read(priceListServiceProvider).approvePending(
            widget.list.id,
            brandId: _brandId!,
            vatStatus: _status,
            vatRateBp: _rate.text.trim().isEmpty ? null : _bp(_rate.text),
            user: ref.read(currentUserProvider)!,
          );
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final brands = ref.watch(_brandsProvider).valueOrNull ?? const <Brand>[];
    return AlertDialog(
      title: const Text('مراجعة قائمة مرحّلة'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.list.note ?? ''),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              isExpanded: true,
              key: ValueKey(brands.length),
              initialValue: _brandId,
              decoration: const InputDecoration(labelText: 'الماركة'),
              items: [for (final b in brands) DropdownMenuItem(value: b.id, child: Text(b.name))],
              onChanged: (v) => setState(() => _brandId = v),
            ),
            const SizedBox(height: 12),
            _VatFields(status: _status, rate: _rate, onStatus: (v) => setState(() => _status = v)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(onPressed: _save, child: const Text('اعتماد')),
      ],
    );
  }
}

/// Blueprint 3.2a: a whole file becomes a new version.
class _ImportDialog extends ConsumerStatefulWidget {
  const _ImportDialog();

  @override
  ConsumerState<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends ConsumerState<_ImportDialog> {
  final _name = TextEditingController();
  final _type = TextEditingController();
  final _pages = TextEditingController();
  final _rate = TextEditingController();
  int? _brandId;
  DateTime _from = DateTime.now();
  DateTime? _to;
  String _vat = VatStatus.unverified;
  String? _fileName;
  PriceImportPreview? _preview;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_name, _type, _pages, _rate]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pick() async {
    if (_brandId == null) {
      await showMessage(context, 'اختر الماركة أولاً: الأكواد تُطابق داخل الماركة');
      return;
    }
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx']);
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;
    final preview = await runGuarded(
      context,
      () async => ref.read(priceListImportServiceProvider).preview(await File(path).readAsBytes(), brandId: _brandId!),
    );
    if (preview == null || !mounted) return;
    setState(() {
      _preview = preview;
      _fileName = picked!.files.single.name;
    });
  }

  Future<void> _pickDate(bool from) async {
    final d = await showDatePicker(
      context: context,
      initialDate: (from ? _from : _to) ?? _from,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => from ? _from = d : _to = d);
  }

  bool get _ready =>
      _brandId != null &&
      _name.text.trim().isNotEmpty &&
      _type.text.trim().isNotEmpty &&
      (_preview?.canImport ?? false) &&
      !_busy;

  Future<void> _save() async {
    setState(() => _busy = true);
    final result = await runGuarded(
      context,
      () => ref.read(priceListImportServiceProvider).import(
            _preview!,
            header: PriceListHeader(
              name: _name.text,
              brandId: _brandId!,
              listType: _type.text,
              effectiveFrom: _from,
              effectiveTo: _to,
              vatStatus: _vat,
              vatRateBp: _rate.text.trim().isEmpty ? null : _bp(_rate.text),
              sourceFile: _fileName,
              sourcePages: _pages.text,
            ),
            user: ref.read(currentUserProvider)!,
          ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (result != null) {
      showToast(context,
          'PL-${result.id}: أسعار لأصناف معروفة ${result.matched}، أصناف جديدة ${result.created}، قيد المراجعة ${result.review}');
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brands = ref.watch(_brandsProvider).valueOrNull ?? const <Brand>[];
    final p = _preview;
    final stopped = p?.rows.where((r) => !r.ok).take(8).toList() ?? const [];
    return AlertDialog(
      title: const Text('استيراد قائمة كاملة (إصدار جديد)'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<int>(
                isExpanded: true,
                initialValue: _brandId,
                decoration: const InputDecoration(labelText: 'الماركة'),
                items: [for (final b in brands) DropdownMenuItem(value: b.id, child: Text(b.name))],
                onChanged: (v) => setState(() {
                  _brandId = v;
                  _preview = null;
                  _fileName = null;
                }),
              ),
              const SizedBox(height: 12),
              ListTypeField(brandId: _brandId, controller: _type, onChanged: () => setState(() {})),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'اسم القائمة (مثال: ديورافيت يوليو 2026)'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _pickDate(true),
                    icon: const Icon(Icons.event),
                    label: Text('سارية من ${_date(_from)}'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _pickDate(false),
                    icon: const Icon(Icons.event_busy),
                    label: Text(_to == null ? 'حتى: مفتوحة' : 'حتى ${_date(_to!)}'),
                  ),
                  const Chip(label: Text('العملة: EGP')),
                ],
              ),
              const SizedBox(height: 12),
              _VatFields(status: _vat, rate: _rate, onStatus: (v) => setState(() => _vat = v)),
              const SizedBox(height: 12),
              TextField(controller: _pages, decoration: const InputDecoration(labelText: 'صفحات المصدر (اختياري)')),
              const SizedBox(height: 12),
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
                  Text('أصناف معروفة يضاف سعرها: ${p.knownCount}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text('أصناف جديدة تأخذ رقم صنف جديد: ${p.createCount}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  if (p.arabicNameCount > 0)
                    Text('أصناف موجودة بلا اسم عربي يُضاف لها الاسم العربي من الملف: ${p.arabicNameCount}',
                        style: TextStyle(color: scheme.primary, fontWeight: FontWeight.bold)),
                  if (p.reviewCount > 0)
                    Text('صفوف متوقفة للمراجعة: ${p.reviewCount}', style: TextStyle(color: scheme.error)),
                  for (final r in stopped)
                    Text('صف ${r.rowNumber}: ${r.reviewReason}', style: TextStyle(color: scheme.error)),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(onPressed: _ready ? _save : null, child: const Text('حفظ الإصدار')),
      ],
    );
  }
}

class _EntryRow {
  final code = TextEditingController();
  final name = TextEditingController();
  final variant = TextEditingController();
  final price = TextEditingController();
  final dimensions = TextEditingController();

  void dispose() {
    for (final c in [code, name, variant, price, dimensions]) {
      c.dispose();
    }
  }
}

/// Blueprint 3.2b: one product or a small group, with no file. The row goes
/// into an existing version, or a new one under its own date; a new one leaves
/// the rest of the earlier list in force.
class _EntryDialog extends ConsumerStatefulWidget {
  const _EntryDialog();

  @override
  ConsumerState<_EntryDialog> createState() => _EntryDialogState();
}

class _EntryDialogState extends ConsumerState<_EntryDialog> {
  int? _brandId;
  int? _listId; // null = a new version
  final _type = TextEditingController();
  final _name = TextEditingController();
  DateTime _from = DateTime.now();
  final _rows = <_EntryRow>[_EntryRow()];

  @override
  void dispose() {
    _type.dispose();
    _name.dispose();
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_brandId == null) {
      await showMessage(context, 'اختر الماركة');
      return;
    }
    final entries = <PriceEntry>[];
    for (final r in _rows) {
      final price = parseMoney(r.price.text);
      if (r.code.text.trim().isEmpty || price == null) {
        await showMessage(context, 'أدخل كود الشركة وسعر القائمة لكل صف');
        return;
      }
      entries.add(PriceEntry(
        code: r.code.text,
        name: r.name.text,
        variant: r.variant.text,
        price: price,
        dimensions: r.dimensions.text,
      ));
    }
    final ok = await runGuarded(context, () async {
      await ref.read(priceListImportServiceProvider).enterRows(
            entries,
            brandId: _brandId!,
            listId: _listId,
            newVersion: _listId != null
                ? null
                : PriceListHeader(
                    name: _name.text.trim().isEmpty ? _type.text : _name.text,
                    brandId: _brandId!,
                    listType: _type.text,
                    effectiveFrom: _from,
                    sourceFile: 'إدخال يدوي',
                  ),
            user: ref.read(currentUserProvider)!,
          );
      return true;
    });
    if (ok == true && mounted) {
      showToast(context, 'تم الحفظ');
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final brands = ref.watch(_brandsProvider).valueOrNull ?? const <Brand>[];
    final lists = (ref.watch(_summariesProvider).valueOrNull ?? const <PriceListSummary>[])
        .where((s) => s.list.brandId == _brandId && s.list.status == PriceListStatus.active)
        .toList();
    return AlertDialog(
      title: const Text('إدخال صنف أو مجموعة أصناف'),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<int>(
                isExpanded: true,
                initialValue: _brandId,
                decoration: const InputDecoration(labelText: 'الماركة'),
                items: [for (final b in brands) DropdownMenuItem(value: b.id, child: Text(b.name))],
                onChanged: (v) => setState(() {
                  _brandId = v;
                  _listId = null;
                }),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int?>(
                isExpanded: true,
                key: ValueKey('list-$_brandId-${lists.length}'),
                initialValue: _listId,
                decoration: const InputDecoration(labelText: 'القائمة / الإصدار'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('إصدار جديد بتاريخ جديد')),
                  for (final s in lists)
                    DropdownMenuItem(
                      value: s.list.id,
                      child: Text('PL-${s.list.id} ${s.list.listType} V${s.list.versionNo} (من ${_date(s.list.effectiveFrom)})'),
                    ),
                ],
                onChanged: (v) => setState(() => _listId = v),
              ),
              if (_listId == null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _type,
                        decoration: const InputDecoration(labelText: 'نوع القائمة (مثال: سيراميك)'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final d = await showDatePicker(
                          context: context,
                          initialDate: _from,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100),
                        );
                        if (d != null) setState(() => _from = d);
                      },
                      icon: const Icon(Icons.event),
                      label: Text('ساري من ${_date(_from)}'),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              for (final r in _rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextField(controller: r.code, decoration: const InputDecoration(labelText: 'كود الشركة')),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 3,
                        child: TextField(controller: r.name, decoration: const InputDecoration(labelText: 'الاسم (للصنف الجديد)')),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(controller: r.variant, decoration: const InputDecoration(labelText: 'اللون')),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(controller: r.dimensions, decoration: const InputDecoration(labelText: 'المقاسات')),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(controller: r.price, decoration: const InputDecoration(labelText: 'سعر القائمة')),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: _rows.length == 1
                            ? null
                            : () => setState(() {
                                  _rows.remove(r);
                                  r.dispose();
                                }),
                      ),
                    ],
                  ),
                ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () => setState(() => _rows.add(_EntryRow())),
                  icon: const Icon(Icons.add),
                  label: const Text('صف آخر'),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(onPressed: _save, child: const Text('حفظ')),
      ],
    );
  }
}

class _ReviewTab extends ConsumerStatefulWidget {
  const _ReviewTab();

  @override
  ConsumerState<_ReviewTab> createState() => _ReviewTabState();
}

class _ReviewTabState extends ConsumerState<_ReviewTab> {
  late Future<List<PriceListItem>> _future = ref.read(priceListServiceProvider).reviewQueue();

  void _reload() => setState(() => _future = ref.read(priceListServiceProvider).reviewQueue());

  Future<int?> _priceIfMissing(PriceListItem item) async {
    if (item.price != null) return item.price;
    final text = await _askText(context, 'سعر الصف', 'سعر القائمة من المصدر');
    if (text == null) return null;
    final p = parseMoney(text);
    if (p == null && mounted) await showMessage(context, 'السعر غير صحيح');
    return p;
  }

  Future<void> _match(PriceListItem item) async {
    final row = await showDialog<ProductRow>(context: context, builder: (_) => const _PickProductDialog());
    if (row == null || !mounted) return;
    final price = await _priceIfMissing(item);
    if (price == null || !mounted) return;
    final ok = await runGuarded(context, () async {
      await ref
          .read(priceListServiceProvider)
          .resolveMatch(item.id, row.product.id, price: price, user: ref.read(currentUserProvider)!);
      return true;
    });
    if (ok == true) _reload();
  }

  Future<void> _create(PriceListItem item) async {
    final price = await _priceIfMissing(item);
    if (price == null || !mounted) return;
    final units = await ref.read(catalogServiceProvider).watchUnits().first;
    if (!mounted) return;
    final ok = await runGuarded(context, () async {
      await ref.read(priceListServiceProvider).resolveCreate(item.id,
          price: price, unitId: units.firstOrNull?.id, user: ref.read(currentUserProvider)!);
      return true;
    });
    if (ok == true) _reload();
  }

  Future<void> _skip(PriceListItem item) async {
    final reason = await _askText(context, 'استبعاد الصف', 'سبب الاستبعاد');
    if (reason == null || !mounted) return;
    final ok = await runGuarded(context, () async {
      await ref
          .read(priceListServiceProvider)
          .resolveSkip(item.id, reason: reason, user: ref.read(currentUserProvider)!);
      return true;
    });
    if (ok == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    // Rows of a PDF list point to a page; rows of an Excel file to a row.
    final pdfLists = {
      for (final s in ref.watch(_summariesProvider).valueOrNull ?? const <PriceListSummary>[])
        if ((s.list.sourceFile ?? '').toLowerCase().endsWith('.pdf')) s.list.id,
    };
    return Padding(
      padding: const EdgeInsets.all(24),
      child: FutureBuilder<List<PriceListItem>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final items = snap.data!;
          if (items.isEmpty) return const Center(child: Text('لا توجد صفوف متوقفة للمراجعة'));
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final item = items[i];
              return ListTile(
                title: Text('PL-${item.priceListId} · ${item.manufacturerCode} — ${item.name}'
                    '${item.variant == null ? '' : ' (${item.variant})'}'),
                subtitle: Text(
                    '${item.reviewReason ?? ''} · السعر: ${item.price == null ? 'غير موجود' : formatMoney(item.price!)}'
                    '${item.sourceRow == null ? '' : ' · ${pdfLists.contains(item.priceListId) ? 'صفحة' : 'صف'} ${item.sourceRow}'}'),
                trailing: Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton(onPressed: () => _match(item), child: const Text('ربط بصنف')),
                    OutlinedButton(onPressed: () => _create(item), child: const Text('صنف جديد')),
                    TextButton(onPressed: () => _skip(item), child: const Text('استبعاد')),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _PickProductDialog extends StatelessWidget {
  const _PickProductDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('اختر الصنف'),
      content: SizedBox(
        width: 620,
        height: 380,
        child: Align(
          alignment: Alignment.topCenter,
          child: ProductSearchField(onSelected: (r) => Navigator.pop(context, r)),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء'))],
    );
  }
}

class _BuyingTab extends ConsumerStatefulWidget {
  const _BuyingTab();

  @override
  ConsumerState<_BuyingTab> createState() => _BuyingTabState();
}

class _BuyingTabState extends ConsumerState<_BuyingTab> {
  late Future<List<BuyingPolicyRow>> _future = ref.read(buyingPolicyServiceProvider).rows();

  void _reload() => setState(() => _future = ref.read(buyingPolicyServiceProvider).rows());

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('مورد + ماركة + قائمة، ثم النطاق: الصنف قبل التصنيف قبل الكل. لا تأثير لها على سعر البيع.'),
              ),
              FilledButton.icon(
                onPressed: () async {
                  final added = await showDialog<bool>(
                      context: context, builder: (_) => const _PolicyDialog());
                  if (added == true) _reload();
                },
                icon: const Icon(Icons.add),
                label: const Text('سياسة شراء'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: FutureBuilder<List<BuyingPolicyRow>>(
              future: _future,
              builder: (context, snap) {
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final rows = snap.data!;
                if (rows.isEmpty) {
                  return const Center(child: Text('لا توجد سياسات شراء. بدون سياسة تبقى التكلفة غير محددة ولا يُفترض خصم.'));
                }
                return ListView(
                  children: [
                    for (final r in rows)
                      ListTile(
                        title: Text('${r.supplierName} · ${r.brandName ?? 'بدون ماركة'} · ${r.listLabel ?? 'بدون قائمة'}'),
                        subtitle: Text('${PolicyScope.label(r.policy.scope)}'
                            '${r.targetName.isEmpty ? '' : ' — ${r.targetName}'} · '
                            'أساسي ${_percent(r.policy.baseDiscountBp)} + إضافي ${_percent(r.policy.extraDiscountBp)}'
                            '${r.policy.note == null ? '' : ' · ${r.policy.note}'}'),
                        leading: r.incomplete
                            ? IconButton(
                                tooltip: 'حدد الماركة والقائمة',
                                icon: const Icon(Icons.warning_amber),
                                onPressed: () async {
                                  await showDialog<void>(
                                      context: context, builder: (_) => _CompletePolicyDialog(policy: r.policy));
                                  _reload();
                                },
                              )
                            : null,
                        trailing: Switch(
                          value: r.policy.isActive,
                          onChanged: (v) async {
                            final ok = await runGuarded(context, () async {
                              await ref
                                  .read(buyingPolicyServiceProvider)
                                  .setActive(r.policy.id, v, user: ref.read(currentUserProvider)!);
                              return true;
                            });
                            if (ok == true) _reload();
                          },
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Adds a buying policy. (Selling discounts have their own form, by customer
/// category.)
class _PolicyDialog extends ConsumerStatefulWidget {
  const _PolicyDialog();

  bool get buying => true;

  @override
  ConsumerState<_PolicyDialog> createState() => _PolicyDialogState();
}

class _PolicyDialogState extends ConsumerState<_PolicyDialog> {
  int? _supplierId, _brandId, _listId, _categoryId;
  ProductRow? _product;
  String _scope = PolicyScope.all;
  final _a = TextEditingController();
  final _b = TextEditingController();
  final _c = TextEditingController();
  final _note = TextEditingController();

  @override
  void dispose() {
    for (final c in [_a, _b, _c, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final user = ref.read(currentUserProvider)!;
    if (_brandId == null || _listId == null || (widget.buying && _supplierId == null)) {
      await showMessage(context, widget.buying ? 'اختر المورد والماركة والقائمة' : 'اختر الماركة والقائمة');
      return;
    }
    final a = _a.text.trim().isEmpty ? 0 : _bp(_a.text);
    final b = _b.text.trim().isEmpty ? null : _bp(_b.text);
    final c = _c.text.trim().isEmpty ? null : _bp(_c.text);
    if (a == null || (_b.text.trim().isNotEmpty && b == null) || (_c.text.trim().isNotEmpty && c == null)) {
      await showMessage(context, 'النسب يجب أن تكون بين 0 و 100');
      return;
    }
    final ok = await runGuarded(context, () async {
      await ref.read(buyingPolicyServiceProvider).add(
            BuyingPolicyInput(
              supplierId: _supplierId!,
              brandId: _brandId!,
              priceListId: _listId!,
              scope: _scope,
              categoryId: _categoryId,
              productId: _product?.product.id,
              baseDiscountBp: a,
              extraDiscountBp: b ?? 0,
              note: _note.text,
            ),
            user: user,
          );
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final brands = ref.watch(_brandsProvider).valueOrNull ?? const <Brand>[];
    final lists = (ref.watch(_summariesProvider).valueOrNull ?? const <PriceListSummary>[])
        .where((s) => s.list.brandId == _brandId && s.list.status != PriceListStatus.withdrawn)
        .toList();
    final suppliers = ref.watch(activeSuppliersProvider).valueOrNull ?? const <Supplier>[];
    final catalog = ref.watch(catalogServiceProvider);
    return AlertDialog(
      title: Text(widget.buying ? 'سياسة شراء' : 'سياسة بيع'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.buying) ...[
                DropdownButtonFormField<int>(
                  isExpanded: true,
                  initialValue: _supplierId,
                  decoration: const InputDecoration(labelText: 'المورد'),
                  items: [for (final s in suppliers) DropdownMenuItem(value: s.id, child: Text(s.name))],
                  onChanged: (v) => setState(() => _supplierId = v),
                ),
                const SizedBox(height: 12),
              ],
              DropdownButtonFormField<int>(
                isExpanded: true,
                initialValue: _brandId,
                decoration: const InputDecoration(labelText: 'الماركة'),
                items: [for (final b in brands) DropdownMenuItem(value: b.id, child: Text(b.name))],
                onChanged: (v) => setState(() {
                  _brandId = v;
                  _listId = null;
                }),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                isExpanded: true,
                key: ValueKey('list-$_brandId-${lists.length}'),
                initialValue: _listId,
                decoration: const InputDecoration(labelText: 'قائمة الأسعار'),
                items: [
                  for (final s in lists)
                    DropdownMenuItem(value: s.list.id, child: Text('PL-${s.list.id} ${s.list.listType} V${s.list.versionNo}')),
                ],
                onChanged: (v) => setState(() => _listId = v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: _scope,
                decoration: const InputDecoration(labelText: 'النطاق'),
                items: [
                  for (final s in PolicyScope.values) DropdownMenuItem(value: s, child: Text(PolicyScope.label(s))),
                ],
                onChanged: (v) => setState(() {
                  _scope = v ?? PolicyScope.all;
                  _categoryId = null;
                  _product = null;
                }),
              ),
              if (_scope == PolicyScope.category) ...[
                const SizedBox(height: 12),
                StreamBuilder<List<Category>>(
                  stream: catalog.watchAllCategories(),
                  builder: (context, snap) => DropdownButtonFormField<int>(
                    isExpanded: true,
                    initialValue: _categoryId,
                    decoration: const InputDecoration(labelText: 'التصنيف'),
                    items: [
                      for (final c in snap.data ?? const <Category>[]) DropdownMenuItem(value: c.id, child: Text(c.nameAr)),
                    ],
                    onChanged: (v) => setState(() => _categoryId = v),
                  ),
                ),
              ],
              if (_scope == PolicyScope.product) ...[
                const SizedBox(height: 12),
                if (_product != null) Text('الصنف: ${_product!.product.code} — ${_product!.product.nameAr}'),
                ProductSearchField(autofocus: false, onSelected: (r) => setState(() => _product = r)),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _a,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: widget.buying ? 'الخصم الأساسي %' : 'خصم السياسة %'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _b,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: widget.buying ? 'خصم شراء إضافي % (إن وجد)' : 'أقصى خصم بدون موافقة % (اختياري)'),
              ),
              if (!widget.buying) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _c,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'أدنى هامش بدون موافقة % (اختياري)'),
                ),
              ],
              const SizedBox(height: 12),
              TextField(controller: _note, decoration: const InputDecoration(labelText: 'ملاحظة')),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(onPressed: _save, child: const Text('حفظ')),
      ],
    );
  }
}

class _CompletePolicyDialog extends ConsumerStatefulWidget {
  const _CompletePolicyDialog({required this.policy});

  final BuyingPolicy policy;

  @override
  ConsumerState<_CompletePolicyDialog> createState() => _CompletePolicyDialogState();
}

class _CompletePolicyDialogState extends ConsumerState<_CompletePolicyDialog> {
  late int? _brandId = widget.policy.brandId;
  int? _listId;

  Future<void> _save() async {
    if (_brandId == null || _listId == null) {
      await showMessage(context, 'اختر الماركة والقائمة');
      return;
    }
    final ok = await runGuarded(context, () async {
      await ref
          .read(buyingPolicyServiceProvider)
          .complete(widget.policy.id, brandId: _brandId!, priceListId: _listId!, user: ref.read(currentUserProvider)!);
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final brands = ref.watch(_brandsProvider).valueOrNull ?? const <Brand>[];
    final lists = (ref.watch(_summariesProvider).valueOrNull ?? const <PriceListSummary>[])
        .where((s) => s.list.brandId == _brandId)
        .toList();
    return AlertDialog(
      title: const Text('إكمال سياسة مرحّلة'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<int>(
              isExpanded: true,
              key: ValueKey(brands.length),
              initialValue: _brandId,
              decoration: const InputDecoration(labelText: 'الماركة'),
              items: [for (final b in brands) DropdownMenuItem(value: b.id, child: Text(b.name))],
              onChanged: (v) => setState(() {
                _brandId = v;
                _listId = null;
              }),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              isExpanded: true,
              key: ValueKey('list-$_brandId-${lists.length}'),
              initialValue: _listId,
              decoration: const InputDecoration(labelText: 'قائمة الأسعار'),
              items: [
                for (final s in lists)
                  DropdownMenuItem(value: s.list.id, child: Text('PL-${s.list.id} ${s.list.listType} V${s.list.versionNo}')),
              ],
              onChanged: (v) => setState(() => _listId = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(onPressed: _save, child: const Text('حفظ')),
      ],
    );
  }
}
