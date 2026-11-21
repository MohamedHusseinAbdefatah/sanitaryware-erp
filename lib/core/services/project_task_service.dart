import 'package:drift/drift.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import '../pricing_math.dart';
import 'audit_service.dart';
import 'errors.dart';

abstract final class TaskKind {
  static const task = 'task';
  static const milestone = 'milestone';
  static const delivery = 'delivery';
  static const all = [task, milestone, delivery];

  static String label(String k) => switch (k) {
        milestone => 'مرحلة رئيسية',
        delivery => 'تسليم / توريد',
        _ => 'مهمة',
      };
}

/// Stored states. "Late" is not stored: it is worked out from the dates.
abstract final class TaskStatus {
  static const notStarted = 'not_started';
  static const inProgress = 'in_progress';
  static const done = 'done';
  static const all = [notStarted, inProgress, done];

  static String label(String s) => switch (s) {
        inProgress => 'جاري التنفيذ',
        done => 'مكتمل',
        _ => 'لم يبدأ',
      };
}

/// What a task looks like today.
enum TaskState { notStarted, inProgress, done, late }

extension TaskStateLabel on TaskState {
  String get label => switch (this) {
        TaskState.notStarted => 'لم يبدأ',
        TaskState.inProgress => 'جاري التنفيذ',
        TaskState.done => 'مكتمل',
        TaskState.late => 'متأخر',
      };
}

class TaskInput {
  const TaskInput({
    required this.projectId,
    required this.title,
    required this.dueDate,
    this.kind = TaskKind.task,
    this.startDate,
    this.assigneeUserId,
    this.assigneeName,
    this.status = TaskStatus.notStarted,
    this.progress = 0,
    this.remindDaysBefore = 2,
    this.notes,
  });

  final int projectId;
  final String title;
  final DateTime dueDate;
  final String kind;
  final DateTime? startDate;
  final int? assigneeUserId;
  final String? assigneeName;
  final String status;
  final int progress;
  final int remindDaysBefore;
  final String? notes;
}

/// A task with its project and who is responsible, and where it stands.
class TaskRow {
  const TaskRow(this.task, this.projectName, this.projectCode, this.assignee);

  final ProjectTask task;
  final String projectName;
  final String projectCode;

  /// The user's name, or the name typed in.
  final String? assignee;

  TaskState stateOn(DateTime today) {
    if (task.status == TaskStatus.done) return TaskState.done;
    if (dayOf(task.dueDate).isBefore(dayOf(today))) return TaskState.late;
    return task.status == TaskStatus.inProgress ? TaskState.inProgress : TaskState.notStarted;
  }

  /// Days from the planned day to the day it was done (or to today, if still
  /// open and past it). Positive = late, negative = early.
  int delayDays(DateTime today) {
    final end = task.completedAt ?? (task.status == TaskStatus.done ? task.dueDate : today);
    final d = dayOf(end).difference(dayOf(task.plannedDate)).inDays;
    return task.status == TaskStatus.done || d > 0 ? d : 0;
  }

  /// Open, and due within its reminder days (or already late).
  bool needsAttention(DateTime today) {
    if (task.status == TaskStatus.done) return false;
    final due = dayOf(task.dueDate);
    return !due.isAfter(dayOf(today).add(Duration(days: task.remindDaysBefore)));
  }

  /// Moved from the day first planned.
  bool get moved => dayOf(task.dueDate) != dayOf(task.plannedDate);
}

/// A project's plan in figures.
class PlanSummary {
  const PlanSummary({
    required this.total,
    required this.done,
    required this.late,
    required this.percent,
    required this.lateMilestones,
    required this.averageDelayDays,
  });

  final int total;
  final int done;
  final int late;

  /// Completion, 0 to 100: the average progress of the tasks.
  final int percent;
  final int lateMilestones;

  /// Over the tasks done: days from the planned day to the real one.
  final double averageDelayDays;

  int get pending => total - done;
}

/// Projects' tasks, milestones and deliveries: the weekly and monthly
/// plan, what is late, and reminders before a due day.
class ProjectTaskService {
  ProjectTaskService(this.db);

  final AppDatabase db;

  void _check(User user) {
    if (!user.can(Perm.projects)) throw ValidationException('خطة المشروعات لصلاحية المشروعات');
    if (user.readOnly) throw ValidationException('هذا المستخدم للاطلاع فقط');
  }

  void _validate(TaskInput i) {
    if (i.title.trim().isEmpty) throw ValidationException('اكتب اسم المهمة');
    if (!TaskKind.all.contains(i.kind)) throw ArgumentError.value(i.kind, 'kind');
    if (!TaskStatus.all.contains(i.status)) throw ArgumentError.value(i.status, 'status');
    if (i.progress < 0 || i.progress > 100) throw ValidationException('نسبة الإنجاز بين 0 و 100');
    if (i.remindDaysBefore < 0 || i.remindDaysBefore > 60) throw ValidationException('التذكير من 0 إلى 60 يوماً قبل الموعد');
    if (i.startDate != null && dayOf(i.dueDate).isBefore(dayOf(i.startDate!))) {
      throw ValidationException('موعد التسليم قبل البداية');
    }
  }

  /// Adds a task, or changes one when [id] is given. Its first due day is
  /// kept as the planned day; later changes move only the due day.
  Future<int> save(TaskInput input, {int? id, required User user}) {
    return db.transaction(() async {
      _check(user);
      _validate(input);
      final done = input.status == TaskStatus.done;
      final assigneeName = (input.assigneeName ?? '').trim().isEmpty ? null : input.assigneeName!.trim();
      final notes = (input.notes ?? '').trim().isEmpty ? null : input.notes!.trim();
      if (id == null) {
        final newId = await db.into(db.projectTasks).insert(ProjectTasksCompanion.insert(
              projectId: input.projectId,
              title: input.title.trim(),
              kind: Value(input.kind),
              assigneeUserId: Value(input.assigneeUserId),
              assigneeName: Value(assigneeName),
              startDate: Value(input.startDate == null ? null : dayOf(input.startDate!)),
              plannedDate: dayOf(input.dueDate),
              dueDate: dayOf(input.dueDate),
              status: Value(input.status),
              progress: Value(done ? 100 : input.progress),
              completedAt: Value(done ? DateTime.now() : null),
              remindDaysBefore: Value(input.remindDaysBefore),
              notes: Value(notes),
            ));
        await AuditService(db).log(
            action: AuditAction.create, entity: 'project_task', entityId: newId, userId: user.id, details: input.title.trim());
        return newId;
      }
      final before = await _get(id);
      await (db.update(db.projectTasks)..where((t) => t.id.equals(id))).write(ProjectTasksCompanion(
            title: Value(input.title.trim()),
            kind: Value(input.kind),
            assigneeUserId: Value(input.assigneeUserId),
            assigneeName: Value(assigneeName),
            startDate: Value(input.startDate == null ? null : dayOf(input.startDate!)),
            dueDate: Value(dayOf(input.dueDate)),
            status: Value(input.status),
            progress: Value(done ? 100 : input.progress),
            completedAt: Value(done ? (before.completedAt ?? DateTime.now()) : null),
            remindDaysBefore: Value(input.remindDaysBefore),
            notes: Value(notes),
            updatedAt: Value(DateTime.now()),
          ));
      await AuditService(db).log(
        action: AuditAction.update,
        entity: 'project_task',
        entityId: id,
        userId: user.id,
        details: input.title.trim(),
        oldValue: '${_d(before.dueDate)} · ${TaskStatus.label(before.status)} ${before.progress}%',
        newValue: '${_d(input.dueDate)} · ${TaskStatus.label(input.status)} ${done ? 100 : input.progress}%',
      );
      return id;
    });
  }

  static String _d(DateTime d) => '${d.year}/${d.month}/${d.day}';

  /// Moves a task to another day (the planned day stays for comparison).
  Future<void> move(int id, DateTime day, {required User user}) {
    return db.transaction(() async {
      _check(user);
      final t = await _get(id);
      if (t.startDate != null && dayOf(day).isBefore(t.startDate!)) {
        throw ValidationException('الموعد الجديد قبل بداية المهمة (${_d(t.startDate!)})');
      }
      if (dayOf(day) == dayOf(t.dueDate)) return;
      await (db.update(db.projectTasks)..where((x) => x.id.equals(id)))
          .write(ProjectTasksCompanion(dueDate: Value(dayOf(day)), updatedAt: Value(DateTime.now())));
      await AuditService(db).log(
        action: AuditAction.update,
        entity: 'project_task',
        entityId: id,
        userId: user.id,
        details: 'نقل موعد: ${t.title}',
        oldValue: _d(t.dueDate),
        newValue: _d(day),
      );
    });
  }

  /// Sets where a task stands. Done fills in the real day and 100%.
  Future<void> setStatus(int id, String status, {int? progress, required User user}) {
    return db.transaction(() async {
      _check(user);
      if (!TaskStatus.all.contains(status)) throw ArgumentError.value(status, 'status');
      final t = await _get(id);
      final done = status == TaskStatus.done;
      final p = done ? 100 : (progress ?? (status == TaskStatus.notStarted ? 0 : t.progress));
      if (p < 0 || p > 100) throw ValidationException('نسبة الإنجاز بين 0 و 100');
      await (db.update(db.projectTasks)..where((x) => x.id.equals(id))).write(ProjectTasksCompanion(
            status: Value(status),
            progress: Value(p),
            completedAt: Value(done ? (t.completedAt ?? DateTime.now()) : null),
            updatedAt: Value(DateTime.now()),
          ));
      await AuditService(db).log(
        action: AuditAction.update,
        entity: 'project_task',
        entityId: id,
        userId: user.id,
        details: t.title,
        oldValue: '${TaskStatus.label(t.status)} ${t.progress}%',
        newValue: '${TaskStatus.label(status)} $p%',
      );
    });
  }

  Future<void> delete(int id, {required User user}) {
    return db.transaction(() async {
      _check(user);
      final t = await _get(id);
      await (db.delete(db.projectTasks)..where((x) => x.id.equals(id))).go();
      await AuditService(db).log(
          action: AuditAction.cancel, entity: 'project_task', entityId: id, userId: user.id, details: t.title);
    });
  }

  Future<ProjectTask> _get(int id) async {
    final t = await (db.select(db.projectTasks)..where((x) => x.id.equals(id))).getSingleOrNull();
    if (t == null) throw ValidationException('المهمة غير موجودة');
    return t;
  }

  JoinedSelectStatement<HasResultSet, dynamic> _joined() => db.select(db.projectTasks).join([
        innerJoin(db.projects, db.projects.id.equalsExp(db.projectTasks.projectId)),
        leftOuterJoin(db.users, db.users.id.equalsExp(db.projectTasks.assigneeUserId)),
      ]);

  TaskRow _row(TypedResult r) {
    final t = r.readTable(db.projectTasks);
    final p = r.readTable(db.projects);
    return TaskRow(t, p.name, p.code, r.readTableOrNull(db.users)?.fullName ?? t.assigneeName);
  }

  /// One project's plan, by due day.
  Stream<List<TaskRow>> watchProject(int projectId) {
    final q = _joined()
      ..where(db.projectTasks.projectId.equals(projectId))
      ..orderBy([OrderingTerm.asc(db.projectTasks.dueDate), OrderingTerm.asc(db.projectTasks.id)]);
    return q.watch().map((rows) => rows.map(_row).toList());
  }

  /// Every project's tasks due between two days (inclusive), plus open late
  /// ones when [withLate]; cancelled and finished projects are left out.
  Stream<List<TaskRow>> watchBetween(DateTime from, DateTime to, {bool withLate = false}) {
    final start = dayOf(from), end = dayOf(to).add(const Duration(days: 1));
    final inRange = db.projectTasks.dueDate.isBiggerOrEqualValue(start) & db.projectTasks.dueDate.isSmallerThanValue(end);
    final late = db.projectTasks.dueDate.isSmallerThanValue(dayOf(DateTime.now())) &
        db.projectTasks.status.equals(TaskStatus.done).not();
    final q = _joined()
      ..where((withLate ? (inRange | late) : inRange) & db.projects.status.isIn(['active', 'on_hold', 'lead']))
      ..orderBy([OrderingTerm.asc(db.projectTasks.dueDate), OrderingTerm.asc(db.projectTasks.id)]);
    return q.watch().map((rows) => rows.map(_row).toList());
  }

  /// For the dashboard: open tasks that are late or due within [days], and
  /// those whose reminder time has come, for [user] (theirs and unassigned)
  /// or everyone for the owner.
  Stream<List<TaskRow>> watchAttention({required User user, int days = 7}) {
    final today = DateTime.now();
    return watchBetween(today, today.add(Duration(days: days)), withLate: true).map((rows) => rows
        .where((r) => r.task.status != TaskStatus.done)
        .where((r) => user.isAdmin || r.task.assigneeUserId == null || r.task.assigneeUserId == user.id)
        .toList());
  }

  static PlanSummary summarize(List<TaskRow> rows, DateTime today) {
    final done = rows.where((r) => r.task.status == TaskStatus.done).toList();
    final late = rows.where((r) => r.stateOn(today) == TaskState.late).toList();
    final percent = rows.isEmpty ? 0 : (rows.fold<int>(0, (s, r) => s + r.task.progress) / rows.length).round();
    final delays = done.map((r) => r.delayDays(today)).toList();
    return PlanSummary(
      total: rows.length,
      done: done.length,
      late: late.length,
      percent: percent,
      lateMilestones: late.where((r) => r.task.kind == TaskKind.milestone).length,
      averageDelayDays: delays.isEmpty ? 0 : delays.reduce((a, b) => a + b) / delays.length,
    );
  }
}
