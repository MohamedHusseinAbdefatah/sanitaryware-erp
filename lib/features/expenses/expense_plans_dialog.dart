import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/db/database.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/services/doc_types.dart';
import '../../core/services/expense_plan_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/number_fields.dart';
import '../../core/widgets/report_view.dart';

final _plansProvider = StreamProvider.autoDispose<List<PlanRow>>(
  (ref) => ExpensePlanService(ref.watch(databaseProvider)).watchPlans(),
);

/// How many plans are due now (for a badge on the expenses page).
final duePlansProvider = Provider.autoDispose<int>(
  (ref) => (ref.watch(_plansProvider).valueOrNull ?? const <PlanRow>[]).where((p) => p.isDue).length,
);

Future<void> showExpensePlans(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _PlansDialog());

class _PlansDialog extends ConsumerWidget {
  const _PlansDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plans = ref.watch(_plansProvider).valueOrNull ?? const <PlanRow>[];
    final svc = ExpensePlanService(ref.read(databaseProvider));
    final user = ref.read(currentUserProvider)!;
    return AlertDialog(
      title: Row(children: [
        const Expanded(child: Text('المصروفات المتكررة (الخطة)')),
        FilledButton.icon(
          onPressed: () => showDialog<void>(context: context, builder: (_) => const _PlanForm()),
          icon: const Icon(Icons.add),
          label: const Text('خطة جديدة'),
        ),
      ]),
      content: SizedBox(
        width: 760,
        height: 440,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text(
            'الخطة تذكير فقط ولا تُسجل مصروفاً وحدها. عند الدفع الفعلي اضغط «تسجيل الآن» فيُسجل المصروف مرة واحدة وتنتقل الخطة لموعدها التالي.',
            style: TextStyle(color: AppColors.muted, fontSize: 12.5),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: plans.isEmpty
                ? const Center(child: Text('لا توجد خطط. أضف الإيجار والرواتب والاشتراكات.', style: TextStyle(color: AppColors.muted)))
                : ListView.separated(
                    itemCount: plans.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final p = plans[i];
                      return ListTile(
                        leading: Icon(Icons.event_repeat, color: p.isDue ? AppColors.bad : AppColors.muted),
                        title: Text('${p.categoryName}${p.plan.description == null ? '' : ' — ${p.plan.description}'}'),
                        subtitle: Text('${PlanFrequency.label(p.plan.frequency)} · ${formatMoney(p.plan.amount)} · '
                            'التالي ${formatDate(p.plan.nextDue)}${p.plan.isActive ? '' : ' · موقوفة'}'),
                        trailing: Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                          if (p.isDue) const StatusPill.bad('مستحق'),
                          if (p.plan.isActive)
                            FilledButton.tonal(
                              onPressed: () async {
                                final c = TextEditingController(text: formatMoney(p.plan.amount).replaceAll(',', ''));
                                final ok = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: Text('تسجيل ${p.categoryName}'),
                                    content: SizedBox(width: 320, child: MoneyField(controller: c, label: 'المبلغ المدفوع فعلاً')),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
                                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تسجيل')),
                                    ],
                                  ),
                                );
                                if (ok != true || !context.mounted) return;
                                final done = await runGuarded(
                                    context, () => svc.record(p.plan.id, amount: parseMoney(c.text), user: user));
                                if (done != null && context.mounted) showToast(context, 'تم تسجيل المصروف');
                              },
                              child: const Text('تسجيل الآن'),
                            ),
                          PopupMenuButton<String>(
                            onSelected: (v) async {
                              if (v == 'skip') {
                                await runGuarded(context, () async {
                                  await svc.skip(p.plan.id, user: user);
                                  return true;
                                });
                              } else if (v == 'edit') {
                                await showDialog<void>(context: context, builder: (_) => _PlanForm(plan: p.plan));
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'skip', child: Text('تخطي هذه المرة')),
                              PopupMenuItem(value: 'edit', child: Text('تعديل / إيقاف')),
                            ],
                          ),
                        ]),
                      );
                    },
                  ),
          ),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق'))],
    );
  }
}

class _PlanForm extends ConsumerStatefulWidget {
  const _PlanForm({this.plan});

  final ExpensePlan? plan;

  @override
  ConsumerState<_PlanForm> createState() => _PlanFormState();
}

class _PlanFormState extends ConsumerState<_PlanForm> {
  late int? _category = widget.plan?.categoryId;
  late final _amount = TextEditingController(text: widget.plan == null ? '' : formatMoney(widget.plan!.amount).replaceAll(',', ''));
  late final _desc = TextEditingController(text: widget.plan?.description);
  late String _frequency = widget.plan?.frequency ?? PlanFrequency.monthly;
  late String _method = widget.plan?.method ?? PaymentMethod.cash;
  late DateTime _next = widget.plan?.nextDue ?? DateTime(DateTime.now().year, DateTime.now().month + 1, 1);
  late bool _active = widget.plan?.isActive ?? true;

  @override
  Widget build(BuildContext context) {
    final db = ref.read(databaseProvider);
    return AlertDialog(
      title: Text(widget.plan == null ? 'خطة مصروف متكرر' : 'تعديل الخطة'),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          FutureBuilder<List<ExpenseCategory>>(
            future: db.select(db.expenseCategories).get(),
            builder: (context, snap) => DropdownButtonFormField<int>(
              key: ValueKey(snap.data?.length),
              initialValue: _category,
              decoration: const InputDecoration(labelText: 'البند'),
              items: [for (final c in snap.data ?? const <ExpenseCategory>[]) DropdownMenuItem(value: c.id, child: Text(c.nameAr))],
              onChanged: (v) => setState(() => _category = v),
            ),
          ),
          const SizedBox(height: 8),
          MoneyField(controller: _amount, label: 'المبلغ المتوقع', required: true),
          const SizedBox(height: 8),
          TextField(controller: _desc, decoration: const InputDecoration(labelText: 'البيان (مثال: إيجار المعرض)')),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _frequency,
            decoration: const InputDecoration(labelText: 'التكرار'),
            items: [for (final f in PlanFrequency.all) DropdownMenuItem(value: f, child: Text(PlanFrequency.label(f)))],
            onChanged: (v) => setState(() => _frequency = v ?? _frequency),
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: PaymentMethod.cash, label: Text('نقدي')),
              ButtonSegment(value: PaymentMethod.bank, label: Text('بنك')),
            ],
            selected: {_method},
            onSelectionChanged: (s) => setState(() => _method = s.first),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () async {
              final d = await showDatePicker(context: context, firstDate: DateTime(2000), lastDate: DateTime(2100), initialDate: _next);
              if (d != null) setState(() => _next = d);
            },
            icon: const Icon(Icons.event),
            label: Text('الموعد القادم ${formatDate(_next)}'),
          ),
          if (widget.plan != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _active,
              onChanged: (v) => setState(() => _active = v),
              title: const Text('الخطة نشطة'),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(
          onPressed: () async {
            if (_category == null) {
              await showMessage(context, 'اختر البند');
              return;
            }
            final ok = await runGuarded(context, () async {
              await ExpensePlanService(db).savePlan(
                id: widget.plan?.id,
                categoryId: _category!,
                amount: parseMoney(_amount.text) ?? 0,
                method: _method,
                description: _desc.text,
                frequency: _frequency,
                nextDue: _next,
                isActive: _active,
                user: ref.read(currentUserProvider)!,
              );
              return true;
            });
            if (ok == true && context.mounted) Navigator.pop(context);
          },
          child: const Text('حفظ'),
        ),
      ],
    );
  }
}

/// Imports past expenses from Excel: a preview of every row first.
Future<void> showExpenseImport(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _ImportDialog());

class _ImportDialog extends ConsumerStatefulWidget {
  const _ImportDialog();

  @override
  ConsumerState<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends ConsumerState<_ImportDialog> {
  List<ExpenseImportRow>? _rows;

  ExpensePlanService get _svc => ExpensePlanService(ref.read(databaseProvider));

  Future<void> _pick() async {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['xlsx']);
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;
    final rows = await runGuarded(context, () async => _svc.preview(await File(path).readAsBytes()));
    if (rows != null && mounted) setState(() => _rows = rows);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final ok = rows?.where((r) => r.ok).length ?? 0;
    return AlertDialog(
      title: const Text('استيراد مصروفات سابقة من Excel'),
      content: SizedBox(
        width: 760,
        height: 460,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text(
            'الأعمدة: التاريخ، البند، المبلغ، الطريقة (نقدي/بنك)، البيان. يُحتفظ بتاريخ كل مصروف الأصلي، '
            'والمكرر (نفس اليوم والبند والمبلغ) لا يُسجل مرتين.',
            style: TextStyle(color: AppColors.muted, fontSize: 12.5),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 10, children: [
            OutlinedButton.icon(
              onPressed: () => saveExcelFile(context, _svc.template(), 'نموذج المصروفات'),
              icon: const Icon(Icons.download_outlined),
              label: const Text('تحميل النموذج'),
            ),
            FilledButton.icon(onPressed: _pick, icon: const Icon(Icons.upload_file), label: const Text('اختيار الملف')),
            if (rows != null) ...[
              StatusPill.good('صالح $ok'),
              StatusPill.warn('مكرر ${rows.where((r) => r.duplicate).length}'),
              StatusPill.bad('أخطاء ${rows.where((r) => r.problems.isNotEmpty).length}'),
            ],
          ]),
          const SizedBox(height: 10),
          Expanded(
            child: rows == null
                ? const Center(child: Text('اختر الملف لعرض المعاينة', style: TextStyle(color: AppColors.muted)))
                : ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final r = rows[i];
                      return ListTile(
                        dense: true,
                        leading: Text('${r.rowNo}'),
                        title: Text('${r.date == null ? '؟' : formatDate(r.date!)} — ${r.category} — '
                            '${r.amount == null ? '؟' : formatMoney(r.amount!)}'),
                        subtitle: Text([
                          ...r.problems,
                          if (r.duplicate) 'مسجل من قبل — لن يُكرر',
                          if (r.newCategory) 'بند جديد سيُضاف',
                          if (r.description != null) r.description!,
                        ].join(' · ')),
                        trailing: r.ok ? const Icon(Icons.check_circle, color: AppColors.good) : const Icon(Icons.block, color: AppColors.bad),
                      );
                    },
                  ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق')),
        FilledButton(
          onPressed: ok == 0
              ? null
              : () async {
                  final n = await runGuarded(context, () => _svc.import(rows!, user: ref.read(currentUserProvider)!));
                  if (n != null && context.mounted) {
                    Navigator.pop(context);
                    showToast(context, 'تم استيراد $n مصروف');
                  }
                },
          child: Text('استيراد $ok صف'),
        ),
      ],
    );
  }
}
