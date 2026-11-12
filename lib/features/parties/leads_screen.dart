import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/db/database.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/services/lead_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/data_list.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/list_kit.dart';
import '../../core/widgets/number_fields.dart';

final _leadsProvider = StreamProvider.autoDispose<List<Lead>>(
  (ref) => LeadService(ref.watch(databaseProvider)).watchAll(),
);

Widget leadPill(String s) => switch (s) {
      LeadStage.won => StatusPill.good(LeadStage.label(s)),
      LeadStage.lost => StatusPill.bad(LeadStage.label(s)),
      LeadStage.quoted => StatusPill.warn(LeadStage.label(s)),
      _ => StatusPill(LeadStage.label(s)),
    };

/// Possible customers before their first purchase (blueprint 6.1).
class LeadsScreen extends ConsumerStatefulWidget {
  const LeadsScreen({super.key});

  @override
  ConsumerState<LeadsScreen> createState() => _LeadsScreenState();
}

class _LeadsScreenState extends ConsumerState<LeadsScreen> {
  String? _stage = 'open';
  String _search = '';

  LeadService get _svc => LeadService(ref.read(databaseProvider));

  Future<void> _edit([Lead? lead]) => showDialog<void>(context: context, builder: (_) => _LeadDialog(lead: lead));

  Future<void> _stageOf(Lead l, String stage) async {
    String? reason;
    if (stage == LeadStage.lost) {
      reason = await askReason(context, title: 'سبب عدم الإتمام');
      if (reason == null) return;
    }
    if (!mounted) return;
    await runGuarded(context, () async {
      await _svc.setStage(l.id, stage, lostReason: reason, user: ref.read(currentUserProvider)!);
      return true;
    });
  }

  Future<void> _convert(Lead l) async {
    final id = await runGuarded(context, () => _svc.convert(l.id, user: ref.read(currentUserProvider)!));
    if (id != null && mounted) {
      showToast(context, 'أصبح ${l.name} عميلاً');
      context.go('/customers/$id');
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_leadsProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 24, 0),
        child: Row(children: [
          TextButton.icon(
            onPressed: () => context.go('/customers'),
            icon: const Icon(Icons.arrow_forward, size: 18),
            label: const Text('العملاء'),
          ),
        ]),
      ),
      PageHeader(title: 'العملاء المحتملون (الفرص)', actions: [
        SearchBox(hint: 'بحث بالاسم أو التليفون', onChanged: (v) => setState(() => _search = v)),
        FilledButton.icon(onPressed: () => _edit(), icon: const Icon(Icons.add), label: const Text('فرصة جديدة')),
      ]),
      Expanded(
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
          data: (all) {
            final q = _search.trim();
            bool pass(Lead l, String? s) => s == null || (s == 'open' ? LeadStage.open.contains(l.stage) : l.stage == s);
            final base = all.where((l) => q.isEmpty || l.name.contains(q) || (l.phone ?? '').contains(q));
            final rows = base.where((l) => pass(l, _stage)).toList();
            final open = all.where((l) => LeadStage.open.contains(l.stage));
            final today = DateTime.now();
            final due = open.where((l) => l.nextFollowUp != null && !l.nextFollowUp!.isAfter(today)).length;
            final closed = all.where((l) => l.stage == LeadStage.won || l.stage == LeadStage.lost);
            final won = all.where((l) => l.stage == LeadStage.won).length;
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SummaryStrip(items: [
                SummaryItem('فرص مفتوحة', '${open.length}', icon: Icons.person_search_outlined),
                SummaryItem('القيمة المتوقعة', formatMoney(open.fold(0, (s, l) => s + l.expectedValue)), icon: Icons.trending_up),
                SummaryItem('متابعات مستحقة', '$due', icon: Icons.alarm, tone: due > 0 ? AppColors.warn : null),
                SummaryItem('نسبة النجاح', closed.isEmpty ? '—' : '${(won * 100 / closed.length).round()}%',
                    icon: Icons.emoji_events_outlined, tone: AppColors.good),
              ]),
              CountChips<String?>(
                options: [
                  ('open', 'مفتوحة', base.where((l) => pass(l, 'open')).length),
                  for (final s in LeadStage.all) (s, LeadStage.label(s), base.where((l) => pass(l, s)).length),
                  (null, 'الكل', base.length),
                ],
                selected: _stage,
                onSelected: (v) => setState(() => _stage = v),
              ),
              Expanded(
                child: DataList<Lead>(
                  rows: rows,
                  emptyText: 'لا توجد فرص هنا. سجّل كل زائر أو استفسار واتساب كفرصة لتتابعه.',
                  onTap: _edit,
                  trailing: (l) => PopupMenuButton<String>(
                    tooltip: 'إجراءات',
                    onSelected: (v) => v == 'convert' ? _convert(l) : _stageOf(l, v),
                    itemBuilder: (_) => [
                      if (l.customerId == null) const PopupMenuItem(value: 'convert', child: Text('تحويل لعميل')),
                      for (final s in LeadStage.all)
                        if (s != l.stage && s != LeadStage.won) PopupMenuItem(value: s, child: Text('المرحلة: ${LeadStage.label(s)}')),
                    ],
                  ),
                  columns: [
                    DataListColumn('الاسم', flex: 3, (l) => TitleCell(l.name, subtitle: l.phone, leading: NameAvatar(l.name))),
                    DataListColumn('المصدر', flex: 2, (l) => Text(LeadSource.label(l.source))),
                    DataListColumn('الاهتمام', flex: 3, (l) => Text(l.interest ?? '', overflow: TextOverflow.ellipsis)),
                    DataListColumn('القيمة المتوقعة', numeric: true, flex: 2, (l) => Text(l.expectedValue == 0 ? '—' : formatMoney(l.expectedValue))),
                    DataListColumn('المتابعة القادمة', numeric: true, flex: 2, (l) {
                      final d = l.nextFollowUp;
                      if (d == null) return const Text('—');
                      final late = LeadStage.open.contains(l.stage) && !d.isAfter(today);
                      return Text(formatDate(d), style: TextStyle(color: late ? AppColors.bad : null, fontWeight: late ? FontWeight.w800 : null));
                    }),
                    DataListColumn('المرحلة', numeric: true, (l) => leadPill(l.stage)),
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

class _LeadDialog extends ConsumerStatefulWidget {
  const _LeadDialog({this.lead});

  final Lead? lead;

  @override
  ConsumerState<_LeadDialog> createState() => _LeadDialogState();
}

class _LeadDialogState extends ConsumerState<_LeadDialog> {
  late final _name = TextEditingController(text: widget.lead?.name);
  late final _phone = TextEditingController(text: widget.lead?.phone);
  late final _interest = TextEditingController(text: widget.lead?.interest);
  late final _notes = TextEditingController(text: widget.lead?.notes);
  late final _value = TextEditingController(
      text: (widget.lead?.expectedValue ?? 0) == 0 ? '' : formatMoney(widget.lead!.expectedValue).replaceAll(',', ''));
  late String _source = widget.lead?.source ?? 'showroom';
  late DateTime? _next = widget.lead?.nextFollowUp ?? DateTime.now().add(const Duration(days: 2));

  Future<void> _save() async {
    final ok = await runGuarded(context, () async {
      await LeadService(ref.read(databaseProvider)).save(
        LeadInput(
          name: _name.text,
          phone: _phone.text,
          source: _source,
          interest: _interest.text,
          expectedValue: parseMoney(_value.text) ?? 0,
          nextFollowUp: _next,
          notes: _notes.text,
        ),
        id: widget.lead?.id,
        user: ref.read(currentUserProvider)!,
      );
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.lead == null ? 'فرصة جديدة' : widget.lead!.name),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(child: TextField(controller: _name, autofocus: true, decoration: const InputDecoration(labelText: 'الاسم *'))),
              const SizedBox(width: 12),
              Expanded(child: TextField(controller: _phone, decoration: const InputDecoration(labelText: 'التليفون'))),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _source,
                  decoration: const InputDecoration(labelText: 'المصدر'),
                  items: [for (final s in LeadSource.all) DropdownMenuItem(value: s, child: Text(LeadSource.label(s)))],
                  onChanged: (v) => setState(() => _source = v ?? _source),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: MoneyField(controller: _value, label: 'القيمة المتوقعة')),
            ]),
            const SizedBox(height: 12),
            TextField(controller: _interest, decoration: const InputDecoration(labelText: 'مهتم بـ (حمام كامل، خلاطات، مشروع...)')),
            const SizedBox(height: 12),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: () async {
                  final d = await showDatePicker(
                      context: context, firstDate: DateTime(2000), lastDate: DateTime(2100), initialDate: _next ?? DateTime.now());
                  if (d != null) setState(() => _next = d);
                },
                icon: const Icon(Icons.alarm),
                label: Text(_next == null ? 'موعد المتابعة' : 'المتابعة القادمة: ${formatDate(_next!)}'),
              ),
            ),
            const SizedBox(height: 12),
            TextField(controller: _notes, maxLines: 3, decoration: const InputDecoration(labelText: 'ملاحظات المتابعة')),
            if (widget.lead?.lostReason != null)
              Padding(padding: const EdgeInsets.only(top: 8), child: Text('سبب عدم الإتمام: ${widget.lead!.lostReason}')),
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
