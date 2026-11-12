import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/db/database.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/services/doc_types.dart';
import '../../core/services/project_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/charts.dart';
import '../../core/widgets/data_list.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/list_kit.dart';
import '../../core/widgets/number_fields.dart';
import '../../core/widgets/pickers.dart';
import '../../core/widgets/record_page.dart';
import '../accounting/accounting_kit.dart' show percentBp;
import '../purchases/purchase_orders_dialog.dart';
import '../sales/orders_screens.dart';
import '../sales/sales_orders_dialog.dart';

final projectsProvider = FutureProvider.autoDispose<List<ProjectRow>>((ref) => ref.watch(projectServiceProvider).list());

Widget projectPill(String s) => switch (s) {
      ProjectStatus.active => StatusPill.good(ProjectStatus.label(s)),
      ProjectStatus.lead => StatusPill(ProjectStatus.label(s)),
      ProjectStatus.onHold => StatusPill.warn(ProjectStatus.label(s)),
      ProjectStatus.done => StatusPill(ProjectStatus.label(s), color: AppColors.muted, background: AppColors.canvas),
      _ => StatusPill.bad(ProjectStatus.label(s)),
    };

/// Every project with what it earned and how far its bill of quantities got.
class ProjectsScreen extends ConsumerStatefulWidget {
  const ProjectsScreen({super.key});

  @override
  ConsumerState<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends ConsumerState<ProjectsScreen> {
  String _query = '';
  String? _status;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(projectsProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeader(title: 'المشروعات', actions: [
        SearchBox(onChanged: (v) => setState(() => _query = v), hint: 'بحث بالاسم أو العميل أو الموقع'),
        FilledButton.icon(
          onPressed: () async {
            final id = await showProjectForm(context);
            if (id != null && context.mounted) context.go('/projects/$id');
          },
          icon: const Icon(Icons.add),
          label: const Text('مشروع جديد'),
        ),
      ]),
      Expanded(
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
          data: (all) {
            final q = _query.trim();
            final rows = all.where((r) {
              if (_status != null && r.project.status != _status) return false;
              if (q.isEmpty) return true;
              return r.project.name.contains(q) ||
                  (r.customerName ?? '').contains(q) ||
                  (r.project.location ?? '').contains(q) ||
                  r.project.code.contains(q);
            }).toList();
            final live = all.where((r) => r.project.status == ProjectStatus.active);
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SummaryStrip(items: [
                SummaryItem('مشروعات جارية', '${live.length}', icon: Icons.construction),
                SummaryItem('قيمة التعاقدات الجارية', formatMoney(live.fold(0, (s, r) => s + r.project.contractValue)), icon: Icons.handshake_outlined),
                SummaryItem('مفوتر', formatMoney(all.fold(0, (s, r) => s + r.money.invoiced)), icon: Icons.receipt_long_outlined),
                SummaryItem('مستحق التحصيل', formatMoney(all.fold(0, (s, r) => s + r.money.open)), icon: Icons.call_received, tone: AppColors.warn),
                SummaryItem('صافي الربح', formatMoney(all.fold(0, (s, r) => s + r.money.netProfit)), icon: Icons.trending_up, tone: AppColors.good),
              ]),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                child: Wrap(spacing: 8, children: [
                  ChoiceChip(label: Text('الكل (${all.length})'), selected: _status == null, onSelected: (_) => setState(() => _status = null)),
                  for (final s in ProjectStatus.all)
                    ChoiceChip(
                      label: Text('${ProjectStatus.label(s)} (${all.where((r) => r.project.status == s).length})'),
                      selected: _status == s,
                      onSelected: (_) => setState(() => _status = s),
                    ),
                ]),
              ),
              Expanded(
                child: DataList<ProjectRow>(
                  rows: rows,
                  emptyText: 'لا توجد مشروعات بعد. أضف مشروعاً لتتابع كمياته وتوريداته وربحيته.',
                  onTap: (r) => context.go('/projects/${r.project.id}'),
                  columns: [
                    DataListColumn('الكود', width: 100, (r) => Text(r.project.code, style: const TextStyle(color: AppColors.muted))),
                    DataListColumn('المشروع', flex: 3, (r) => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(r.project.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                            if (r.project.location != null)
                              Text(r.project.location!, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                          ],
                        )),
                    DataListColumn('العميل', flex: 2, (r) => Text(r.customerName ?? '—')),
                    DataListColumn('التعاقد', numeric: true, (r) => Text(r.project.contractValue == 0 ? '—' : formatMoney(r.project.contractValue))),
                    DataListColumn('مفوتر', numeric: true, (r) => Text(formatMoney(r.money.invoiced))),
                    DataListColumn('محصّل', numeric: true, (r) => Text(formatMoney(r.money.collected))),
                    DataListColumn('الربح', numeric: true, (r) => Text(
                          '${formatMoney(r.money.netProfit)}\n${percentBp(r.money.marginBp)}',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontWeight: FontWeight.w700, color: r.money.netProfit < 0 ? AppColors.bad : AppColors.good),
                        )),
                    DataListColumn('التوريد', flex: 2, (r) => r.boqDoneBp == null
                        ? const Text('—', style: TextStyle(color: AppColors.muted))
                        : _Progress(r.boqDoneBp!)),
                    DataListColumn('الحالة', numeric: true, (r) => projectPill(r.project.status)),
                  ],
                ),
              ),
            ]);
          },
        ),
      ),
    ]);
  }
}

class _Progress extends StatelessWidget {
  const _Progress(this.bp);

  final int bp;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: bp / 10000,
            minHeight: 8,
            backgroundColor: AppColors.canvas,
            color: bp >= 10000 ? AppColors.good : AppColors.brand,
          ),
        ),
      ),
      const SizedBox(width: 8),
      Text('${bp ~/ 100}%', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
    ]);
  }
}

// --------------------------------------------------------------- the form

Future<int?> showProjectForm(BuildContext context, {Project? project}) =>
    showDialog<int>(context: context, builder: (_) => _ProjectForm(project: project));

class _ProjectForm extends ConsumerStatefulWidget {
  const _ProjectForm({this.project});

  final Project? project;

  @override
  ConsumerState<_ProjectForm> createState() => _ProjectFormState();
}

class _ProjectFormState extends ConsumerState<_ProjectForm> {
  late final _name = TextEditingController(text: widget.project?.name);
  late final _location = TextEditingController(text: widget.project?.location);
  late final _contact = TextEditingController(text: widget.project?.contactName);
  late final _phone = TextEditingController(text: widget.project?.contactPhone);
  late final _value = TextEditingController(
      text: (widget.project?.contractValue ?? 0) == 0 ? '' : formatMoney(widget.project!.contractValue).replaceAll(',', ''));
  late final _terms = TextEditingController(text: widget.project?.paymentTerms);
  late final _notes = TextEditingController(text: widget.project?.notes);
  late int? _customerId = widget.project?.customerId;
  late String _status = widget.project?.status ?? ProjectStatus.active;
  late DateTime? _start = widget.project?.startDate;
  late DateTime? _end = widget.project?.endDate;
  List<Customer>? _customers;

  @override
  void initState() {
    super.initState();
    final db = ref.read(databaseProvider);
    db.select(db.customers).get().then((c) {
      if (mounted) setState(() => _customers = c);
    });
  }

  Future<DateTime?> _pick(DateTime? initial) =>
      showDatePicker(context: context, firstDate: DateTime(2000), lastDate: DateTime(2100), initialDate: initial ?? DateTime.now());

  Future<void> _save() async {
    final id = await runGuarded(context, () => ref.read(projectServiceProvider).save(
          ProjectInput(
            name: _name.text,
            customerId: _customerId,
            location: _location.text,
            contactName: _contact.text,
            contactPhone: _phone.text,
            startDate: _start,
            endDate: _end,
            status: _status,
            contractValue: parseMoney(_value.text) ?? 0,
            paymentTerms: _terms.text,
            notes: _notes.text,
          ),
          id: widget.project?.id,
          user: ref.read(currentUserProvider)!,
        ));
    if (id != null && mounted) {
      ref.invalidate(projectsProvider);
      Navigator.pop(context, id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final customers = _customers;
    Widget two(Widget a, Widget b) => Row(children: [Expanded(child: a), const SizedBox(width: 12), Expanded(child: b)]);
    return AlertDialog(
      title: Text(widget.project == null ? 'مشروع جديد' : 'تعديل ${widget.project!.code}'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: _name, autofocus: true, decoration: const InputDecoration(labelText: 'اسم المشروع *')),
            const SizedBox(height: 12),
            if (customers == null)
              const LinearProgressIndicator()
            else
              PartyPicker<Customer>(
                items: customers,
                selected: customers.where((c) => c.id == _customerId).firstOrNull,
                label: 'العميل (المقاول / المالك / المهندس)',
                nameOf: (c) => c.name,
                searchFields: (c) => [c.name, c.phone],
                onSelected: (c) => setState(() => _customerId = c?.id),
              ),
            const SizedBox(height: 12),
            two(
              TextField(controller: _location, decoration: const InputDecoration(labelText: 'الموقع')),
              DropdownButtonFormField<String>(
                initialValue: _status,
                decoration: const InputDecoration(labelText: 'الحالة'),
                items: [for (final s in ProjectStatus.all) DropdownMenuItem(value: s, child: Text(ProjectStatus.label(s)))],
                onChanged: (v) => setState(() => _status = v ?? _status),
              ),
            ),
            const SizedBox(height: 12),
            two(
              TextField(controller: _contact, decoration: const InputDecoration(labelText: 'مسؤول الموقع')),
              TextField(controller: _phone, decoration: const InputDecoration(labelText: 'تليفونه')),
            ),
            const SizedBox(height: 12),
            two(
              OutlinedButton.icon(
                onPressed: () async {
                  final d = await _pick(_start);
                  if (d != null) setState(() => _start = d);
                },
                icon: const Icon(Icons.event),
                label: Text(_start == null ? 'تاريخ البدء' : 'البدء: ${formatDate(_start!)}'),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  final d = await _pick(_end);
                  if (d != null) setState(() => _end = d);
                },
                icon: const Icon(Icons.event_available),
                label: Text(_end == null ? 'التسليم المتوقع' : 'التسليم: ${formatDate(_end!)}'),
              ),
            ),
            const SizedBox(height: 12),
            two(
              MoneyField(controller: _value, label: 'قيمة التعاقد (اختياري)'),
              TextField(controller: _terms, decoration: const InputDecoration(labelText: 'شروط الدفع (مثال: 30% مقدم)')),
            ),
            const SizedBox(height: 12),
            TextField(controller: _notes, maxLines: 2, decoration: const InputDecoration(labelText: 'ملاحظات')),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(onPressed: _save, child: const Text('حفظ')),
      ],
    );
  }
}

// ----------------------------------------------------------- project page

class _ProjectData {
  const _ProjectData(this.project, this.customerName, this.money, this.boq, this.docs);

  final Project project;
  final String? customerName;
  final ProjectMoney money;
  final List<BoqProgress> boq;
  final List<ProjectDoc> docs;
}

final _projectProvider = FutureProvider.autoDispose.family<_ProjectData, int>((ref, id) async {
  final s = ref.watch(projectServiceProvider);
  final db = ref.watch(databaseProvider);
  final p = await s.get(id);
  final c = p.customerId == null ? null : await (db.select(db.customers)..where((t) => t.id.equals(p.customerId!))).getSingleOrNull();
  return _ProjectData(p, c?.name, await s.money(id), await s.boqProgress(id), await s.documents(id));
});

String docLabel(String refType) => switch (refType) {
      RefType.salesOrder => 'أمر بيع / عرض سعر',
      RefType.salesInvoice => 'فاتورة بيع',
      RefType.purchaseOrder => 'أمر شراء',
      RefType.purchaseInvoice => 'فاتورة شراء',
      _ => 'مصروف',
    };

class ProjectPage extends ConsumerWidget {
  const ProjectPage({super.key, required this.projectId});

  final int projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_projectProvider(projectId));
    void refresh() {
      ref.invalidate(_projectProvider(projectId));
      ref.invalidate(projectsProvider);
    }

    Future<void> act(Future<Object?> Function() f, String done) async {
      final ok = await runGuarded(context, () async {
        await f();
        return true;
      });
      if (ok == true && context.mounted) {
        refresh();
        showToast(context, done);
      }
    }

    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (d) {
        final p = d.project;
        final m = d.money;
        final user = ref.read(currentUserProvider)!;
        final svc = ref.read(projectServiceProvider);
        final contractPct = p.contractValue == 0 ? null : (m.invoiced * 10000 ~/ p.contractValue);
        return RecordPage(
          backLabel: 'المشروعات',
          backPath: '/projects',
          title: p.name,
          subtitle: [p.code, if (d.customerName != null) d.customerName!, if (p.location != null) p.location!].join('  ·  '),
          leading: InitialsAvatar(p.name),
          onRefresh: refresh,
          pills: [
            projectPill(p.status),
            if (p.endDate != null)
              p.endDate!.isBefore(DateTime.now()) && p.status == ProjectStatus.active
                  ? StatusPill.bad('تأخر عن التسليم ${formatDate(p.endDate!)}')
                  : StatusPill('التسليم ${formatDate(p.endDate!)}'),
          ],
          actions: [
            FilledButton.icon(
              onPressed: () async {
                final id = await act(() => svc.quoteRemaining(p.id, user: user), 'تم إنشاء عرض سعر للمتبقي');
                return id;
              },
              icon: const Icon(Icons.request_quote_outlined),
              label: const Text('عرض سعر للمتبقي'),
            ),
            OutlinedButton.icon(
              onPressed: () => act(() => svc.orderShortages(p.id, user: user), 'تم إنشاء أوامر الشراء للنواقص'),
              icon: const Icon(Icons.shopping_cart_checkout),
              label: const Text('أوامر شراء للنواقص'),
            ),
            if (p.customerId != null)
              OutlinedButton.icon(
                onPressed: () => context.go('/sales/new?customer=${p.customerId}&project=${p.id}'),
                icon: const Icon(Icons.point_of_sale),
                label: const Text('فاتورة للمشروع'),
              ),
            OutlinedButton.icon(
              onPressed: () async {
                if (await showProjectForm(context, project: p) != null) refresh();
              },
              icon: const Icon(Icons.edit_outlined),
              label: const Text('تعديل'),
            ),
          ],
          stats: [
            StatTile('قيمة التعاقد', p.contractValue == 0 ? '—' : formatMoney(p.contractValue),
                hint: contractPct == null ? null : 'مفوتر ${contractPct ~/ 100}%', icon: Icons.handshake_outlined),
            StatTile('مفوتر', formatMoney(m.invoiced), hint: m.returned == 0 ? null : 'مرتجع ${formatMoney(m.returned)}', icon: Icons.receipt_long_outlined),
            StatTile('محصّل', formatMoney(m.collected), icon: Icons.payments_outlined, tone: AppColors.good),
            StatTile('مستحق التحصيل', formatMoney(m.open), icon: Icons.call_received, tone: m.open > 0 ? AppColors.warn : null),
            StatTile('أوامر لم تُفوتر', formatMoney(m.ordered), icon: Icons.pending_actions_outlined),
            StatTile('صافي الربح', formatMoney(m.netProfit),
                hint: 'هامش ${percentBp(m.marginBp)}', icon: Icons.trending_up, tone: m.netProfit < 0 ? AppColors.bad : AppColors.good),
          ],
          tabs: [
            RecordTab('بنود الكميات', _BoqTab(data: d, onChanged: refresh), count: d.boq.length, icon: Icons.checklist),
            RecordTab('الربحية', _ProfitTab(data: d), icon: Icons.insights_outlined),
            RecordTab('المستندات', _DocsTab(data: d, onChanged: refresh), count: d.docs.length, icon: Icons.folder_open),
            RecordTab('البيانات', RecordDetails(rows: [
              ('الكود', p.code),
              ('العميل', d.customerName ?? ''),
              ('الموقع', p.location ?? ''),
              ('مسؤول الموقع', [p.contactName, p.contactPhone].whereType<String>().join(' — ')),
              ('تاريخ البدء', p.startDate == null ? '' : formatDate(p.startDate!)),
              ('التسليم المتوقع', p.endDate == null ? '' : formatDate(p.endDate!)),
              ('شروط الدفع', p.paymentTerms ?? ''),
              ('ملاحظات', p.notes ?? ''),
            ]), icon: Icons.info_outline),
          ],
        );
      },
    );
  }
}

class _BoqTab extends ConsumerWidget {
  const _BoqTab({required this.data, required this.onChanged});

  final _ProjectData data;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = data.docs.where((x) => x.refType == RefType.salesOrder).toList();
    Text q(int v, {Color? color, bool bold = false}) => Text(v == 0 ? '—' : formatQty(v),
        style: TextStyle(color: color, fontWeight: bold ? FontWeight.w800 : null));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            onPressed: () async {
              if (await showDialog<bool>(context: context, builder: (_) => _BoqLineDialog(projectId: data.project.id)) == true) {
                onChanged();
              }
            },
            icon: const Icon(Icons.add),
            label: const Text('بند'),
          ),
          if (orders.isNotEmpty)
            PopupMenuButton<int>(
              tooltip: 'من أمر بيع أو عرض سعر',
              onSelected: (id) async {
                final n = await runGuarded(context,
                    () => ref.read(projectServiceProvider).boqFromOrder(data.project.id, id, user: ref.read(currentUserProvider)!));
                if (n != null && context.mounted) {
                  onChanged();
                  showToast(context, 'تمت إضافة/تحديث $n بند');
                }
              },
              itemBuilder: (_) => [for (final o in orders) PopupMenuItem(value: o.id, child: Text('${o.number}  ${formatDate(o.date)}'))],
              child: const Chip(avatar: Icon(Icons.download, size: 16), label: Text('تعبئة من أمر بيع / عرض سعر')),
            ),
          const Text('  المسلَّم = المفوتر للمشروع ناقص المرتجع. "للشراء" = المتبقي بعد المخزون وأوامر الشراء.',
              style: TextStyle(color: AppColors.muted, fontSize: 12)),
        ]),
      ),
      Expanded(
        child: DataList<BoqProgress>(
          rows: data.boq,
          emptyText: 'لا توجد بنود. أضف بنود المقايسة (الأصناف والكميات المطلوبة للموقع).',
          onTap: (b) async {
            if (await showDialog<bool>(context: context, builder: (_) => _BoqLineDialog(projectId: data.project.id, line: b.line)) == true) {
              onChanged();
            }
          },
          trailing: (b) => IconButton(
            tooltip: 'حذف البند',
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: () async {
              final ok = await runGuarded(context, () async {
                await ref.read(projectServiceProvider).deleteBoqLine(b.line.id, user: ref.read(currentUserProvider)!);
                return true;
              });
              if (ok == true) onChanged();
            },
          ),
          columns: [
            DataListColumn('البند', flex: 3, (b) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(b.productName ?? b.line.description, style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text([if (b.productCode != null) b.productCode!, if (b.supplierName != null) 'المورد: ${b.supplierName}',
                        if (b.line.neededBy != null) 'مطلوب ${formatDate(b.line.neededBy!)}'].join('  ·  '),
                      style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                ])),
            DataListColumn('المطلوب', numeric: true, (b) => q(b.line.qtyRequired, bold: true)),
            DataListColumn('في عروض', numeric: true, (b) => q(b.quoted)),
            DataListColumn('في أوامر بيع', numeric: true, (b) => q(b.ordered)),
            DataListColumn('أوامر شراء', numeric: true, (b) => q(b.purchased)),
            DataListColumn('المسلَّم', numeric: true, (b) => q(b.delivered, color: AppColors.good, bold: true)),
            DataListColumn('المتبقي', numeric: true, (b) => q(b.remaining > 0 ? b.remaining : 0)),
            DataListColumn('بالمخزن', numeric: true, (b) => q(b.inStock)),
            DataListColumn('للشراء', numeric: true, (b) => q(b.toBuy, color: b.toBuy > 0 ? AppColors.bad : null, bold: true)),
            DataListColumn('التقدم', flex: 2, (b) => _Progress(b.doneBp)),
          ],
        ),
      ),
    ]);
  }
}

class _BoqLineDialog extends ConsumerStatefulWidget {
  const _BoqLineDialog({required this.projectId, this.line});

  final int projectId;
  final ProjectBoqLine? line;

  @override
  ConsumerState<_BoqLineDialog> createState() => _BoqLineDialogState();
}

class _BoqLineDialogState extends ConsumerState<_BoqLineDialog> {
  late int? _productId = widget.line?.productId;
  String? _productName;
  bool _decimal = true;
  late final _desc = TextEditingController(text: widget.line?.description);
  late final _qty = TextEditingController(text: widget.line == null ? '' : formatQty(widget.line!.qtyRequired));
  late final _notes = TextEditingController(text: widget.line?.notes);
  late int? _supplierId = widget.line?.preferredSupplierId;
  late DateTime? _needed = widget.line?.neededBy;
  List<Supplier>? _suppliers;

  @override
  void initState() {
    super.initState();
    final db = ref.read(databaseProvider);
    db.select(db.suppliers).get().then((s) {
      if (mounted) setState(() => _suppliers = s);
    });
  }

  Future<void> _save() async {
    final qty = parseQty(_qty.text, allowDecimal: _decimal);
    if (qty == null) {
      await showMessage(context, 'اكتب الكمية المطلوبة');
      return;
    }
    final ok = await runGuarded(context, () async {
      await ref.read(projectServiceProvider).saveBoqLine(
            id: widget.line?.id,
            projectId: widget.projectId,
            productId: _productId,
            description: _desc.text,
            qtyRequired: qty,
            preferredSupplierId: _supplierId,
            neededBy: _needed,
            notes: _notes.text,
            user: ref.read(currentUserProvider)!,
          );
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final suppliers = _suppliers;
    return AlertDialog(
      title: Text(widget.line == null ? 'بند جديد' : 'تعديل البند'),
      content: SizedBox(
        width: 560,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_productId != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.inventory_2_outlined),
              title: Text(_productName ?? widget.line?.description ?? 'صنف'),
              trailing: TextButton(onPressed: () => setState(() => _productId = null), child: const Text('تغيير')),
            )
          else
            ProductSearchField(
              autofocus: true,
              onSelected: (r) => setState(() {
                _productId = r.product.id;
                _productName = r.product.nameAr;
                _decimal = r.unitAllowsDecimal;
                if (_desc.text.isEmpty) _desc.text = r.product.nameAr;
              }),
            ),
          const SizedBox(height: 12),
          TextField(controller: _desc, decoration: const InputDecoration(labelText: 'الوصف (لبند بلا صنف في النظام)')),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: QtyField(controller: _qty, label: 'الكمية المطلوبة', allowDecimal: _decimal, required: true)),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  final d = await showDatePicker(
                      context: context, firstDate: DateTime(2000), lastDate: DateTime(2100), initialDate: _needed ?? DateTime.now());
                  if (d != null) setState(() => _needed = d);
                },
                icon: const Icon(Icons.event),
                label: Text(_needed == null ? 'مطلوب بتاريخ' : formatDate(_needed!)),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          if (suppliers == null)
            const LinearProgressIndicator()
          else
            PartyPicker<Supplier>(
              items: suppliers,
              selected: suppliers.where((s) => s.id == _supplierId).firstOrNull,
              label: 'المورد المفضل (لأوامر الشراء)',
              nameOf: (s) => s.name,
              searchFields: (s) => [s.name, s.phone],
              onSelected: (s) => setState(() => _supplierId = s?.id),
            ),
          const SizedBox(height: 12),
          TextField(controller: _notes, decoration: const InputDecoration(labelText: 'ملاحظات (اللون، المقاس...)')),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(onPressed: _save, child: const Text('حفظ')),
      ],
    );
  }
}

class _ProfitTab extends StatelessWidget {
  const _ProfitTab({required this.data});

  final _ProjectData data;

  @override
  Widget build(BuildContext context) {
    final m = data.money;
    Widget line(String label, int v, {bool strong = false, Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Expanded(child: Text(label, style: TextStyle(fontWeight: strong ? FontWeight.w900 : null))),
            Text(formatMoney(v), style: TextStyle(fontWeight: strong ? FontWeight.w900 : FontWeight.w600, color: color ?? (v < 0 ? AppColors.bad : null))),
          ]),
        );
    return ListView(padding: const EdgeInsets.fromLTRB(24, 0, 24, 24), children: [
      LayoutBuilder(builder: (context, box) {
        final pl = PanelCard(
          title: 'ربحية المشروع',
          child: Column(children: [
            line('المبيعات (بدون الضريبة، بعد المرتجع)', m.revenue, strong: true),
            line('تكلفة البضاعة المسلّمة (الفعلية)', -m.goodsCost),
            const Divider(),
            line('مجمل الربح', m.grossProfit, strong: true),
            line('مصروفات المشروع (نقل، تركيب، عمولات...)', -m.expenses),
            const Divider(),
            line('صافي ربح المشروع', m.netProfit, strong: true, color: m.netProfit < 0 ? AppColors.bad : AppColors.good),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: [
                const Expanded(child: Text('الهامش الصافي')),
                Text(percentBp(m.marginBp), style: const TextStyle(fontWeight: FontWeight.w800)),
              ]),
            ),
          ]),
        );
        final cash = PanelCard(
          title: 'التحصيل',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SplitBar(parts: [
              ('محصّل', m.collected, AppColors.good),
              ('مستحق', m.open > 0 ? m.open : 0, AppColors.warn),
              ('مرتجع', m.returned, AppColors.bad),
            ]),
            const SizedBox(height: 16),
            line('إجمالي الفواتير (شامل الضريبة)', m.invoiced),
            line('أوامر بيع لم تُفوتر بعد', m.ordered),
            line('مشتريات مسجلة على المشروع', m.purchases),
            const Text('المشتريات تدخل المخزون أولاً، وتُحسب تكلفتها على المشروع عند تسليمها بفاتورة.',
                style: TextStyle(color: AppColors.muted, fontSize: 12)),
          ]),
        );
        if (box.maxWidth < 900) return Column(children: [pl, const SizedBox(height: 16), cash]);
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: pl),
          const SizedBox(width: 16),
          Expanded(child: cash),
        ]);
      }),
    ]);
  }
}

class _DocsTab extends ConsumerWidget {
  const _DocsTab({required this.data, required this.onChanged});

  final _ProjectData data;
  final VoidCallback onChanged;

  void _open(BuildContext context, ProjectDoc d) {
    switch (d.refType) {
      case RefType.salesInvoice:
        context.go('/sales/${d.id}');
      case RefType.purchaseInvoice:
        context.go('/purchases/${d.id}');
      case RefType.salesOrder:
        showSalesOrder(context, d.id);
      case RefType.purchaseOrder:
        showPurchaseOrder(context, d.id);
      default:
        context.go('/expenses');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final customerId = data.project.customerId;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (customerId != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              onPressed: () async {
                final list = await ref.read(projectServiceProvider).unlinked(customerId);
                if (!context.mounted) return;
                final picked = await showDialog<ProjectDoc>(
                  context: context,
                  builder: (ctx) => SimpleDialog(
                    title: const Text('ربط مستند من مستندات العميل'),
                    children: [
                      if (list.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('لا توجد مستندات غير مربوطة')),
                      for (final d in list)
                        SimpleDialogOption(
                          onPressed: () => Navigator.pop(ctx, d),
                          child: Text('${docLabel(d.refType)} ${d.number} — ${formatDate(d.date)}'
                              '${d.amount == 0 ? '' : ' — ${formatMoney(d.amount)}'}'),
                        ),
                    ],
                  ),
                );
                if (picked == null || !context.mounted) return;
                final ok = await runGuarded(context, () async {
                  await ref.read(projectServiceProvider)
                      .assign(picked.refType, picked.id, data.project.id, user: ref.read(currentUserProvider)!);
                  return true;
                });
                if (ok == true) onChanged();
              },
              icon: const Icon(Icons.link),
              label: const Text('ربط مستند سابق للعميل'),
            ),
          ),
        ),
      Expanded(
        child: DataList<ProjectDoc>(
          rows: data.docs,
          emptyText: 'لا توجد مستندات مربوطة بالمشروع',
          rowColor: (d) => d.status == DocStatus.cancelled ? AppColors.canvas : null,
          onTap: (d) => _open(context, d),
          trailing: (d) => IconButton(
            tooltip: 'فك الربط بالمشروع',
            icon: const Icon(Icons.link_off, size: 18),
            onPressed: () async {
              final ok = await runGuarded(context, () async {
                await ref.read(projectServiceProvider).assign(d.refType, d.id, null, user: ref.read(currentUserProvider)!);
                return true;
              });
              if (ok == true) onChanged();
            },
          ),
          columns: [
            DataListColumn('التاريخ', (d) => Text(formatDate(d.date))),
            DataListColumn('النوع', flex: 2, (d) => Text(docLabel(d.refType))),
            DataListColumn('الرقم', (d) => Text(d.number, style: const TextStyle(fontWeight: FontWeight.w700))),
            DataListColumn('الطرف / البيان', flex: 3, (d) => Text(d.party ?? '')),
            DataListColumn('المبلغ', numeric: true, (d) => Text(formatMoney(d.amount))),
            DataListColumn('الحالة', numeric: true, (d) => switch (d.refType) {
                  RefType.salesOrder => soPill(d.status),
                  RefType.purchaseOrder => poPill(d.status),
                  _ => d.status == DocStatus.cancelled ? StatusPill.bad('ملغى') : StatusPill.good('ساري'),
                }),
          ],
        ),
      ),
    ]);
  }
}
