import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/pricing_math.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/project_service.dart';
import 'package:sanitaryware_erp/core/services/project_task_service.dart';

import '../support/fixture.dart';

/// 2.4: a project's plan, week by week and month by month.
void main() {
  late Shop shop;
  late ProjectTaskService tasks;
  late int projectId;
  final today = dayOf(DateTime.now());

  setUp(() async {
    shop = await Shop.open();
    tasks = ProjectTaskService(shop.db);
    projectId = await ProjectService(shop.db).save(
      ProjectInput(name: 'برج النيل', startDate: today.subtract(const Duration(days: 30)), endDate: today.add(const Duration(days: 60))),
      user: shop.admin,
    );
  });
  tearDown(() => shop.close());

  Future<List<TaskRow>> plan() => tasks.watchProject(projectId).first;

  test('weekly milestones and monthly deliveries; moving keeps the planned day; done and late are told apart', () async {
    for (var w = 1; w <= 4; w++) {
      await tasks.save(
        TaskInput(projectId: projectId, title: 'مرحلة الأسبوع $w', kind: TaskKind.milestone, dueDate: today.add(Duration(days: 7 * w))),
        user: shop.admin,
      );
    }
    for (var m = 1; m <= 2; m++) {
      await tasks.save(
        TaskInput(projectId: projectId, title: 'توريد الشهر $m', kind: TaskKind.delivery, dueDate: today.add(Duration(days: 30 * m)), assigneeName: 'أحمد'),
        user: shop.admin,
      );
    }
    final late = await tasks.save(
      TaskInput(projectId: projectId, title: 'اعتماد العينات', dueDate: today.subtract(const Duration(days: 3))),
      user: shop.admin,
    );

    var rows = await plan();
    expect(rows, hasLength(7));
    expect(rows.first.task.title, 'اعتماد العينات', reason: 'by due day');
    expect(rows.first.stateOn(today), TaskState.late);
    expect(rows.where((r) => r.task.kind == TaskKind.delivery).first.assignee, 'أحمد');

    // Moved a week later: the planned day stays.
    final first = rows.firstWhere((r) => r.task.title == 'مرحلة الأسبوع 1');
    await tasks.move(first.task.id, today.add(const Duration(days: 14)), user: shop.admin);
    rows = await plan();
    final moved = rows.firstWhere((r) => r.task.id == first.task.id);
    expect(moved.moved, isTrue);
    expect(moved.task.plannedDate, today.add(const Duration(days: 7)));

    // Finished three days late.
    await tasks.setStatus(late, TaskStatus.done, user: shop.admin);
    rows = await plan();
    final doneRow = rows.firstWhere((r) => r.task.id == late);
    expect(doneRow.stateOn(today), TaskState.done);
    expect(doneRow.task.progress, 100);
    expect(doneRow.delayDays(today), 3);

    final s = ProjectTaskService.summarize(rows, today);
    expect((s.total, s.done, s.late, s.pending), (7, 1, 0, 6));
    expect(s.averageDelayDays, 3);
  });

  test('the dashboard shows what is late or due soon; the calendar finds a week', () async {
    await tasks.save(TaskInput(projectId: projectId, title: 'متأخرة', dueDate: today.subtract(const Duration(days: 1))), user: shop.admin);
    await tasks.save(TaskInput(projectId: projectId, title: 'قريبة', dueDate: today.add(const Duration(days: 2))), user: shop.admin);
    await tasks.save(TaskInput(projectId: projectId, title: 'بعيدة', dueDate: today.add(const Duration(days: 40))), user: shop.admin);
    final attention = await tasks.watchAttention(user: shop.admin).first;
    expect(attention.map((r) => r.task.title).toSet(), {'متأخرة', 'قريبة'});
    expect(attention.firstWhere((r) => r.task.title == 'قريبة').needsAttention(today), isTrue);

    final week = await tasks.watchBetween(today, today.add(const Duration(days: 6))).first;
    expect(week.map((r) => r.task.title), ['قريبة']);
  });

  test('a cashier cannot change the plan; a due day before the start is refused', () async {
    await expectLater(
      tasks.save(TaskInput(projectId: projectId, title: 'x', dueDate: today), user: shop.cashier),
      throwsA(isA<ValidationException>()),
    );
    await expectLater(
      tasks.save(
          TaskInput(projectId: projectId, title: 'x', startDate: today, dueDate: today.subtract(const Duration(days: 1))),
          user: shop.admin),
      throwsA(isA<ValidationException>()),
    );
  });
}
