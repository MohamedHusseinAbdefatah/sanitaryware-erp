import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/db/database.dart';
import '../../core/pricing_math.dart';
import '../../core/providers.dart';
import '../../core/services/project_task_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/data_list.dart';
import '../../core/widgets/feedback.dart';

// ------------------------------------------------------------- look & feel

Color stateColor(TaskState s) => switch (s) {
      TaskState.done => AppColors.good,
      TaskState.late => AppColors.bad,
      TaskState.inProgress => AppColors.info,
      TaskState.notStarted => AppColors.muted,
    };

Color stateBg(TaskState s) => switch (s) {
      TaskState.done => AppColors.goodBg,
      TaskState.late => AppColors.badBg,
      TaskState.inProgress => AppColors.infoBg,
      TaskState.notStarted => AppColors.canvas,
    };

IconData kindIcon(String kind) => switch (kind) {
      TaskKind.milestone => Icons.flag_outlined,
      TaskKind.delivery => Icons.local_shipping_outlined,
      _ => Icons.task_alt,
    };

const _weekdaysShort = ['الاثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت', 'الأحد'];

/// The Saturday a week starts on (the usual week in Egypt).
DateTime weekStart(DateTime d) {
  final day = dayOf(d);
  final back = (day.weekday - DateTime.saturday) % 7;
  return day.subtract(Duration(days: back));
}

String _dm(DateTime d) => '${d.day}/${d.month}';

final _usersListProvider = FutureProvider.autoDispose<List<User>>((ref) async {
  final db = ref.watch(databaseProvider);
  return (db.select(db.users)..where((u) => u.isActive.equals(true))).get();
});

// ------------------------------------------------------------- task dialog

/// Adds or edits a task, milestone or delivery.
Future<void> showTaskDialog(BuildContext context, {required int projectId, ProjectTask? task, DateTime? day}) =>
    showDialog<void>(context: context, builder: (_) => _TaskDialog(projectId: projectId, task: task, day: day));

class _TaskDialog extends ConsumerStatefulWidget {
  const _TaskDialog({required this.projectId, this.task, this.day});

  final int projectId;
  final ProjectTask? task;
  final DateTime? day;

  @override
  ConsumerState<_TaskDialog> createState() => _TaskDialogState();
}

class _TaskDialogState extends ConsumerState<_TaskDialog> {
  late final ProjectTask? _t = widget.task;
  late final _title = TextEditingController(text: _t?.title ?? '');
  late final _assignee = TextEditingController(text: _t?.assigneeName ?? '');
  late final _notes = TextEditingController(text: _t?.notes ?? '');
  late String _kind = _t?.kind ?? TaskKind.task;
  late String _status = _t?.status ?? TaskStatus.notStarted;
  late double _progress = (_t?.progress ?? 0).toDouble();
  late int? _userId = _t?.assigneeUserId;
  late DateTime? _start = _t?.startDate;
  late DateTime _due = _t?.dueDate ?? widget.day ?? DateTime.now().add(const Duration(days: 7));
  late int _remind = _t?.remindDaysBefore ?? 2;

  @override
  void dispose() {
    for (final c in [_title, _assignee, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<DateTime?> _pick(DateTime initial) => showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: DateTime(2015),
        lastDate: DateTime.now().add(const Duration(days: 3650)),
      );

  Future<void> _save() async {
    final ok = await runGuarded(context, () async {
      await ref.read(projectTaskServiceProvider).save(
            TaskInput(
              projectId: widget.projectId,
              title: _title.text,
              dueDate: _due,
              kind: _kind,
              startDate: _start,
              assigneeUserId: _userId,
              assigneeName: _userId == null ? _assignee.text : null,
              status: _status,
              progress: _progress.round(),
              remindDaysBefore: _remind,
              notes: _notes.text,
            ),
            id: _t?.id,
            user: ref.read(currentUserProvider)!,
          );
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final users = ref.watch(_usersListProvider).valueOrNull ?? const <User>[];
    return AlertDialog(
      title: Text(_t == null ? 'مهمة / موعد جديد' : 'تعديل: ${_t.title}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SegmentedButton<String>(
              segments: [
                for (final k in TaskKind.all)
                  ButtonSegment(value: k, icon: Icon(kindIcon(k)), label: Text(TaskKind.label(k))),
              ],
              selected: {_kind},
              onSelectionChanged: (v) => setState(() => _kind = v.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _title,
              autofocus: _t == null,
              decoration: const InputDecoration(labelText: 'الوصف (مثال: توريد أطقم الدور الثالث)'),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 10, runSpacing: 8, children: [
              OutlinedButton.icon(
                onPressed: () async {
                  final d = await _pick(_start ?? _due);
                  if (d != null) setState(() => _start = d);
                },
                icon: const Icon(Icons.play_arrow_outlined),
                label: Text(_start == null ? 'البداية (اختياري)' : 'تبدأ ${formatDate(_start!)}'),
              ),
              FilledButton.tonalIcon(
                onPressed: () async {
                  final d = await _pick(_due);
                  if (d != null) setState(() => _due = d);
                },
                icon: const Icon(Icons.event_available),
                label: Text('موعد التسليم ${formatDate(_due)}'),
              ),
            ]),
            if (_t != null && dayOf(_t.plannedDate) != dayOf(_due))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('المقرر أصلاً ${formatDate(_t.plannedDate)}', style: const TextStyle(color: AppColors.warn)),
              ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: DropdownButtonFormField<int?>(
                  isExpanded: true,
                  initialValue: users.any((u) => u.id == _userId) ? _userId : null,
                  decoration: const InputDecoration(labelText: 'المسؤول (مستخدم)'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('— اكتب الاسم —')),
                    for (final u in users) DropdownMenuItem(value: u.id, child: Text(u.fullName)),
                  ],
                  onChanged: (v) => setState(() => _userId = v),
                ),
              ),
              if (_userId == null) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(controller: _assignee, decoration: const InputDecoration(labelText: 'اسم المسؤول')),
                ),
              ],
            ]),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _status,
              decoration: const InputDecoration(labelText: 'الحالة'),
              items: [for (final s in TaskStatus.all) DropdownMenuItem(value: s, child: Text(TaskStatus.label(s)))],
              onChanged: (v) => setState(() {
                _status = v!;
                if (_status == TaskStatus.done) _progress = 100;
                if (_status == TaskStatus.notStarted) _progress = 0;
              }),
            ),
            const SizedBox(height: 8),
            Row(children: [
              const Text('نسبة الإنجاز'),
              Expanded(
                child: Slider(
                  value: _progress,
                  max: 100,
                  divisions: 20,
                  label: '${_progress.round()}%',
                  onChanged: _status == TaskStatus.done ? null : (v) => setState(() => _progress = v),
                ),
              ),
              SizedBox(width: 44, child: Text('${_progress.round()}%')),
            ]),
            DropdownButtonFormField<int>(
              initialValue: _remind,
              decoration: const InputDecoration(labelText: 'التذكير قبل الموعد'),
              items: [
                for (final d in const [0, 1, 2, 3, 7, 14])
                  DropdownMenuItem(value: d, child: Text(d == 0 ? 'يوم الموعد' : 'قبل $d يوم')),
              ],
              onChanged: (v) => setState(() => _remind = v!),
            ),
            const SizedBox(height: 8),
            TextField(controller: _notes, decoration: const InputDecoration(labelText: 'ملاحظات'), maxLines: 2),
          ]),
        ),
      ),
      actions: [
        if (_t != null)
          TextButton.icon(
            onPressed: () async {
              final sure = await confirmAction(context,
                  title: 'حذف المهمة؟',
                  message: 'ستُحذف المهمة "${_t.title}" من خطة المشروع، ويُسجَّل ذلك في سجل التعديلات.',
                  confirmLabel: 'حذف',
                  destructive: true);
              if (!sure || !context.mounted) return;
              final ok = await runGuarded(context, () async {
                await ref.read(projectTaskServiceProvider).delete(_t.id, user: ref.read(currentUserProvider)!);
                return true;
              });
              if (ok == true && context.mounted) Navigator.pop(context);
            },
            icon: const Icon(Icons.delete_outline),
            label: const Text('حذف'),
            style: TextButton.styleFrom(foregroundColor: AppColors.bad),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(onPressed: _save, child: const Text('حفظ')),
      ],
    );
  }
}

// ------------------------------------------------------------- project tab

final _projectTasksProvider = StreamProvider.autoDispose.family<List<TaskRow>, int>(
    (ref, id) => ref.watch(projectTaskServiceProvider).watchProject(id));

/// A project's plan: how far it got, what is late, and its tasks week by
/// week, each with quick buttons to start, finish or move it.
class ProjectPlanTab extends ConsumerWidget {
  const ProjectPlanTab({super.key, required this.project});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(_projectTasksProvider(project.id)).valueOrNull;
    if (rows == null) return const Center(child: CircularProgressIndicator());
    final today = DateTime.now();
    final s = ProjectTaskService.summarize(rows, today);
    final weeks = <DateTime, List<TaskRow>>{};
    for (final r in rows) {
      (weeks[weekStart(r.task.dueDate)] ??= []).add(r);
    }
    return ListView(padding: const EdgeInsets.all(20), children: [
      Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
        _Ring(percent: s.percent),
        _Fact('مكتمل', '${s.done}', AppColors.good),
        _Fact('متبقي', '${s.pending}', AppColors.info),
        _Fact('متأخر', '${s.late}', s.late > 0 ? AppColors.bad : AppColors.muted),
        _Fact('مراحل متأخرة', '${s.lateMilestones}', s.lateMilestones > 0 ? AppColors.bad : AppColors.muted),
        _Fact('متوسط التأخير', '${s.averageDelayDays.toStringAsFixed(1)} يوم', AppColors.warn),
        FilledButton.icon(
          onPressed: () => showTaskDialog(context, projectId: project.id),
          icon: const Icon(Icons.add_task),
          label: const Text('مهمة / موعد'),
        ),
        OutlinedButton.icon(
          onPressed: () => context.go('/projects/calendar?project=${project.id}'),
          icon: const Icon(Icons.calendar_month_outlined),
          label: const Text('عرض في التقويم'),
        ),
      ]),
      const SizedBox(height: 16),
      _Timeline(project: project, rows: rows),
      const SizedBox(height: 16),
      if (rows.isEmpty)
        const Padding(
          padding: EdgeInsets.all(32),
          child: Center(
            child: Text('لا توجد مهام بعد. أضف مراحل المشروع ومواعيد التوريد والتسليم لتظهر هنا وفي التقويم.',
                style: TextStyle(color: AppColors.muted)),
          ),
        ),
      for (final e in weeks.entries) ...[
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 6),
          child: Row(children: [
            Icon(Icons.date_range, size: 18,
                color: weekStart(today) == e.key ? AppColors.brand : AppColors.muted),
            const SizedBox(width: 6),
            Text(
              'أسبوع ${_dm(e.key)} – ${_dm(e.key.add(const Duration(days: 6)))}'
              '${weekStart(today) == e.key ? '  (هذا الأسبوع)' : ''}',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: weekStart(today) == e.key ? AppColors.brand : AppColors.ink,
              ),
            ),
          ]),
        ),
        for (final r in e.value) TaskCard(row: r),
      ],
    ]);
  }
}

/// The project's dates on one line: start, today, the due days, the end.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.project, required this.rows});

  final Project project;
  final List<TaskRow> rows;

  @override
  Widget build(BuildContext context) {
    final dates = [
      if (project.startDate != null) project.startDate!,
      if (project.endDate != null) project.endDate!,
      for (final r in rows) r.task.dueDate,
      DateTime.now(),
    ];
    if (dates.length < 2) return const SizedBox.shrink();
    final first = dates.reduce((a, b) => a.isBefore(b) ? a : b);
    final last = dates.reduce((a, b) => a.isAfter(b) ? a : b);
    final days = dayOf(last).difference(dayOf(first)).inDays;
    final span = days < 1 ? 1 : days;
    double at(DateTime d) => dayOf(d).difference(dayOf(first)).inDays / span;
    final today = DateTime.now();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Text('الجدول الزمني', style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            Text(
              '${project.startDate == null ? '' : 'البدء ${formatDate(project.startDate!)}'}'
              '${project.endDate == null ? '' : '   ·   التسليم المتوقع ${formatDate(project.endDate!)}'}',
              style: const TextStyle(color: AppColors.muted, fontSize: 12),
            ),
          ]),
          const SizedBox(height: 12),
          SizedBox(
            height: 46,
            child: LayoutBuilder(builder: (context, c) {
              final w = c.maxWidth;
              return Stack(clipBehavior: Clip.none, children: [
                Positioned(
                  top: 18,
                  left: 0,
                  right: 0,
                  child: Container(height: 8, decoration: BoxDecoration(color: AppColors.canvas, borderRadius: BorderRadius.circular(4))),
                ),
                if (project.startDate != null && project.endDate != null)
                  PositionedDirectional(
                    top: 18,
                    start: w * at(project.startDate!),
                    width: (w * (at(project.endDate!) - at(project.startDate!))).clamp(2, w).toDouble(),
                    child: Container(
                      height: 8,
                      decoration: BoxDecoration(color: AppColors.brand.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(4)),
                    ),
                  ),
                for (final r in rows)
                  PositionedDirectional(
                    top: 12,
                    start: (w * at(r.task.dueDate) - 10).clamp(0, w - 20).toDouble(),
                    child: Tooltip(
                      message: '${r.task.title} — ${formatDate(r.task.dueDate)} — ${r.stateOn(today).label}',
                      child: Icon(kindIcon(r.task.kind), size: 20, color: stateColor(r.stateOn(today))),
                    ),
                  ),
                PositionedDirectional(
                  top: 0,
                  start: (w * at(today) - 1).clamp(0, w - 2).toDouble(),
                  child: Column(children: [
                    Container(width: 2, height: 40, color: AppColors.bad),
                  ]),
                ),
              ]);
            }),
          ),
          const Row(children: [
            Icon(Icons.circle, size: 10, color: AppColors.bad),
            SizedBox(width: 4),
            Text('اليوم', style: TextStyle(fontSize: 12)),
            SizedBox(width: 16),
            Icon(Icons.flag_outlined, size: 14, color: AppColors.muted),
            SizedBox(width: 4),
            Text('مرحلة', style: TextStyle(fontSize: 12)),
            SizedBox(width: 16),
            Icon(Icons.local_shipping_outlined, size: 14, color: AppColors.muted),
            SizedBox(width: 4),
            Text('تسليم', style: TextStyle(fontSize: 12)),
          ]),
        ]),
      ),
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring({required this.percent});

  final int percent;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 86,
      height: 86,
      child: Stack(alignment: Alignment.center, children: [
        SizedBox.expand(
          child: CircularProgressIndicator(
            value: percent / 100,
            strokeWidth: 9,
            backgroundColor: AppColors.canvas,
            color: percent >= 100 ? AppColors.good : AppColors.brand,
          ),
        ),
        Column(mainAxisSize: MainAxisSize.min, children: [
          Text('$percent%', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const Text('إنجاز', style: TextStyle(fontSize: 11, color: AppColors.muted)),
        ]),
      ]),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value, this.color);

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 120,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
        Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color)),
      ]),
    );
  }
}

/// One task with its state, dates, who is responsible and quick actions.
class TaskCard extends ConsumerWidget {
  const TaskCard({super.key, required this.row, this.showProject = false});

  final TaskRow row;
  final bool showProject;

  Future<void> _act(BuildContext context, WidgetRef ref, Future<void> Function(ProjectTaskService s, User u) f) =>
      runGuarded(context, () => f(ref.read(projectTaskServiceProvider), ref.read(currentUserProvider)!));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = row.task;
    final state = row.stateOn(DateTime.now());
    final color = stateColor(state);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: color.withValues(alpha: 0.45)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => showTaskDialog(context, projectId: t.projectId, task: t),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: stateBg(state),
              child: Icon(kindIcon(t.kind), color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(t.title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                  StatusPill(state.label, color: color, background: stateBg(state)),
                  if (showProject) StatusPill(row.projectName),
                ]),
                const SizedBox(height: 4),
                Text(
                  [
                    '${TaskKind.label(t.kind)} · الموعد ${formatDate(t.dueDate)}',
                    if (row.moved) 'كان مقرراً ${formatDate(t.plannedDate)}',
                    if (t.completedAt != null) 'تم ${formatDate(t.completedAt!)}',
                    if (row.assignee != null) 'المسؤول: ${row.assignee}',
                  ].join('  ·  '),
                  style: const TextStyle(fontSize: 12.5, color: AppColors.muted),
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: t.progress / 100,
                    minHeight: 6,
                    backgroundColor: AppColors.canvas,
                    color: color,
                  ),
                ),
              ]),
            ),
            const SizedBox(width: 8),
            if (t.status == TaskStatus.notStarted)
              IconButton(
                tooltip: 'بدء التنفيذ',
                icon: const Icon(Icons.play_circle_outline),
                onPressed: () => _act(context, ref, (s, u) => s.setStatus(t.id, TaskStatus.inProgress, progress: 10, user: u)),
              ),
            if (t.status != TaskStatus.done)
              IconButton(
                tooltip: 'تم',
                icon: const Icon(Icons.check_circle_outline, color: AppColors.good),
                onPressed: () => _act(context, ref, (s, u) => s.setStatus(t.id, TaskStatus.done, user: u)),
              ),
            PopupMenuButton<int>(
              tooltip: 'نقل الموعد',
              icon: const Icon(Icons.update),
              onSelected: (days) async {
                if (days == 0) {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: t.dueDate,
                    firstDate: DateTime(2015),
                    lastDate: DateTime.now().add(const Duration(days: 3650)),
                  );
                  if (d != null && context.mounted) await _act(context, ref, (s, u) => s.move(t.id, d, user: u));
                } else {
                  await _act(context, ref, (s, u) => s.move(t.id, t.dueDate.add(Duration(days: days)), user: u));
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 1, child: Text('تأجيل يوم')),
                PopupMenuItem(value: 7, child: Text('تأجيل أسبوع')),
                PopupMenuItem(value: -1, child: Text('تقديم يوم')),
                PopupMenuItem(value: 0, child: Text('اختيار يوم...')),
              ],
            ),
          ]),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- calendar

final _projectsLiteProvider = FutureProvider.autoDispose<List<Project>>((ref) async {
  final db = ref.watch(databaseProvider);
  return (db.select(db.projects)..where((p) => p.status.isIn(['active', 'on_hold', 'lead']))).get();
});

typedef _Range = ({DateTime from, DateTime to});

final _rangeTasksProvider = StreamProvider.autoDispose.family<List<TaskRow>, _Range>(
    (ref, r) => ref.watch(projectTaskServiceProvider).watchBetween(r.from, r.to));

/// Every project's deadlines by week or month. A task can be dragged to
/// another day; a click opens it.
class ProjectCalendarScreen extends ConsumerStatefulWidget {
  const ProjectCalendarScreen({super.key, this.projectId});

  final int? projectId;

  @override
  ConsumerState<ProjectCalendarScreen> createState() => _ProjectCalendarScreenState();
}

class _ProjectCalendarScreenState extends ConsumerState<ProjectCalendarScreen> {
  bool _month = false;
  DateTime _anchor = dayOf(DateTime.now());
  late int? _project = widget.projectId;

  _Range get _range {
    if (!_month) {
      final s = weekStart(_anchor);
      return (from: s, to: s.add(const Duration(days: 6)));
    }
    final first = DateTime(_anchor.year, _anchor.month, 1);
    final s = weekStart(first);
    final last = DateTime(_anchor.year, _anchor.month + 1, 0);
    final e = weekStart(last).add(const Duration(days: 6));
    return (from: s, to: e);
  }

  void _shift(int dir) => setState(() {
        _anchor = _month
            ? DateTime(_anchor.year, _anchor.month + dir, 1)
            : _anchor.add(Duration(days: 7 * dir));
      });

  Future<void> _move(TaskRow r, DateTime day) async {
    await runGuarded(context, () => ref.read(projectTaskServiceProvider).move(r.task.id, day, user: ref.read(currentUserProvider)!));
  }

  @override
  Widget build(BuildContext context) {
    final range = _range;
    final all = ref.watch(_rangeTasksProvider(range)).valueOrNull ?? const <TaskRow>[];
    final rows = _project == null ? all : all.where((r) => r.task.projectId == _project).toList();
    final projects = ref.watch(_projectsLiteProvider).valueOrNull ?? const <Project>[];
    final today = DateTime.now();
    final title = _month
        ? '${monthName(_anchor.month)} ${_anchor.year}'
        : 'أسبوع ${_dm(range.from)} – ${_dm(range.to)} ${range.to.year}';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeader(title: 'خطة المشروعات', icon: Icons.calendar_view_week_outlined, subtitle: 'مهام كل المشروعات على أسبوع أو شهر؛ اسحب المهمة لتغيير موعدها', actions: [
        IconButton.outlined(
          tooltip: 'رجوع للمشروعات',
          onPressed: () => context.go('/projects'),
          icon: const Icon(Icons.arrow_forward),
        ),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, icon: Icon(Icons.view_week_outlined), label: Text('أسبوعي')),
            ButtonSegment(value: true, icon: Icon(Icons.calendar_month_outlined), label: Text('شهري')),
          ],
          selected: {_month},
          onSelectionChanged: (v) => setState(() => _month = v.first),
        ),
        SizedBox(
          width: 220,
          child: DropdownButtonFormField<int?>(
            isExpanded: true,
            initialValue: projects.any((p) => p.id == _project) ? _project : null,
            decoration: const InputDecoration(labelText: 'المشروع', isDense: true),
            items: [
              const DropdownMenuItem(value: null, child: Text('كل المشروعات')),
              for (final p in projects) DropdownMenuItem(value: p.id, child: Text(p.name, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => _project = v),
          ),
        ),
      ]),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(children: [
          IconButton(tooltip: 'السابق', onPressed: () => _shift(-1), icon: const Icon(Icons.chevron_right)),
          TextButton(onPressed: () => setState(() => _anchor = dayOf(DateTime.now())), child: const Text('اليوم')),
          IconButton(tooltip: 'التالي', onPressed: () => _shift(1), icon: const Icon(Icons.chevron_left)),
          const SizedBox(width: 8),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const Spacer(),
          for (final s in TaskState.values) ...[
            Icon(Icons.circle, size: 10, color: stateColor(s)),
            const SizedBox(width: 4),
            Text(s.label, style: const TextStyle(fontSize: 12)),
            const SizedBox(width: 12),
          ],
          Text('اسحب المهمة إلى يوم آخر لنقلها', style: const TextStyle(fontSize: 12, color: AppColors.muted)),
        ]),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: _month ? _monthGrid(range, rows, today) : _weekColumns(range, rows, today),
        ),
      ),
    ]);
  }

  List<TaskRow> _on(List<TaskRow> rows, DateTime day) =>
      rows.where((r) => dayOf(r.task.dueDate) == dayOf(day)).toList();

  Widget _dayTarget(DateTime day, Widget child, {required bool highlight}) {
    return DragTarget<TaskRow>(
      onWillAcceptWithDetails: (d) => dayOf(d.data.task.dueDate) != dayOf(day),
      onAcceptWithDetails: (d) => _move(d.data, day),
      builder: (context, candidate, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: candidate.isNotEmpty ? AppColors.infoBg : (highlight ? AppColors.goodBg.withValues(alpha: 0.5) : AppColors.surface),
          border: Border.all(color: candidate.isNotEmpty ? AppColors.info : AppColors.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: child,
      ),
    );
  }

  Widget _chip(TaskRow r, DateTime today, {bool compact = false}) {
    final s = r.stateOn(today);
    final chip = Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsetsDirectional.only(end: 6, top: 4, bottom: 4),
      decoration: BoxDecoration(
        color: stateBg(s),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: stateColor(s).withValues(alpha: 0.5)),
      ),
      child: Row(children: [
        Container(width: 3, height: 28, color: stateColor(s)),
        const SizedBox(width: 5),
        Icon(kindIcon(r.task.kind), size: 14, color: stateColor(s)),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            compact ? r.task.title : '${r.task.title}\n${r.projectName}${r.assignee == null ? '' : ' · ${r.assignee}'}',
            maxLines: compact ? 1 : 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ]),
    );
    return Draggable<TaskRow>(
      data: r,
      feedback: Material(elevation: 6, borderRadius: BorderRadius.circular(6), child: SizedBox(width: 180, child: chip)),
      childWhenDragging: Opacity(opacity: 0.35, child: chip),
      child: InkWell(onTap: () => showTaskDialog(context, projectId: r.task.projectId, task: r.task), child: chip),
    );
  }

  Widget _weekColumns(_Range range, List<TaskRow> rows, DateTime today) {
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < 7; i++)
        Builder(builder: (context) {
          final day = range.from.add(Duration(days: i));
          final isToday = dayOf(day) == dayOf(today);
          final tasks = _on(rows, day);
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: _dayTarget(
                day,
                highlight: isToday,
                Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: isToday ? AppColors.brand : AppColors.canvas,
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                    ),
                    child: Column(children: [
                      Text(_weekdaysShort[day.weekday - 1],
                          style: TextStyle(fontWeight: FontWeight.w700, color: isToday ? Colors.white : AppColors.ink)),
                      Text(_dm(day), style: TextStyle(fontSize: 12, color: isToday ? Colors.white : AppColors.muted)),
                    ]),
                  ),
                  Expanded(
                    child: ListView(padding: const EdgeInsets.all(6), children: [
                      for (final r in tasks) _chip(r, today),
                      if (_project != null)
                        IconButton(
                          tooltip: 'إضافة في هذا اليوم',
                          onPressed: () => showTaskDialog(context, projectId: _project!, day: day),
                          icon: const Icon(Icons.add, size: 18, color: AppColors.muted),
                        ),
                    ]),
                  ),
                ]),
              ),
            ),
          );
        }),
    ]);
  }

  Widget _monthGrid(_Range range, List<TaskRow> rows, DateTime today) {
    final days = range.to.difference(range.from).inDays + 1;
    final weeks = (days / 7).ceil();
    return Column(children: [
      Row(children: [
        for (var i = 0; i < 7; i++)
          Expanded(
            child: Center(
              child: Text(_weekdaysShort[range.from.add(Duration(days: i)).weekday - 1],
                  style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.muted)),
            ),
          ),
      ]),
      const SizedBox(height: 4),
      Expanded(
        child: Column(children: [
          for (var w = 0; w < weeks; w++)
            Expanded(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (var i = 0; i < 7; i++)
                  Builder(builder: (context) {
                    final day = range.from.add(Duration(days: w * 7 + i));
                    final inMonth = day.month == _anchor.month;
                    final isToday = dayOf(day) == dayOf(today);
                    final tasks = _on(rows, day);
                    return Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: _dayTarget(
                          day,
                          highlight: isToday,
                          Padding(
                            padding: const EdgeInsets.all(4),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                              Text(
                                '${day.day}',
                                style: TextStyle(
                                  fontWeight: isToday ? FontWeight.w900 : FontWeight.w600,
                                  color: isToday ? AppColors.brand : (inMonth ? AppColors.ink : AppColors.border),
                                ),
                              ),
                              Expanded(
                                child: ListView(children: [
                                  for (final r in tasks.take(4)) _chip(r, today, compact: true),
                                  if (tasks.length > 4)
                                    Text('+${tasks.length - 4} أخرى', style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                                ]),
                              ),
                            ]),
                          ),
                        ),
                      ),
                    );
                  }),
              ]),
            ),
        ]),
      ),
    ]);
  }
}

// ------------------------------------------------------------- dashboard

final _attentionProvider = StreamProvider.autoDispose<List<TaskRow>>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) return Stream.value(const []);
  return ref.watch(projectTaskServiceProvider).watchAttention(user: user);
});

/// On the dashboard: late project tasks and those due within a week, with
/// a reminder mark when their reminder time has come.
class ProjectDeadlinesCard extends ConsumerWidget {
  const ProjectDeadlinesCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(_attentionProvider).valueOrNull ?? const <TaskRow>[];
    if (rows.isEmpty) return const SizedBox.shrink();
    final today = DateTime.now();
    final late = rows.where((r) => r.stateOn(today) == TaskState.late).length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.event_note_outlined, color: AppColors.brand),
            const SizedBox(width: 8),
            Text('مواعيد المشروعات', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(width: 8),
            if (late > 0) StatusPill.bad('متأخر $late'),
            const Spacer(),
            TextButton(onPressed: () => context.go('/projects/calendar'), child: const Text('التقويم')),
          ]),
          const SizedBox(height: 6),
          for (final r in rows.take(8))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(kindIcon(r.task.kind), color: stateColor(r.stateOn(today))),
              title: Text('${r.task.title} — ${r.projectName}', overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${formatDate(r.task.dueDate)}'
                '${r.assignee == null ? '' : ' · ${r.assignee}'}'
                '${r.needsAttention(today) && r.stateOn(today) != TaskState.late ? ' · 🔔 تذكير' : ''}',
              ),
              trailing: StatusPill(r.stateOn(today).label,
                  color: stateColor(r.stateOn(today)), background: stateBg(r.stateOn(today))),
              onTap: () => context.go('/projects/${r.task.projectId}'),
            ),
        ]),
      ),
    );
  }
}
