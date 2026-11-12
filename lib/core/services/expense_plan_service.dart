import 'package:drift/drift.dart';
import 'package:excel/excel.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import '../excel_open.dart';
import '../money.dart';
import '../search_text.dart';
import 'audit_service.dart';
import 'doc_types.dart';
import 'errors.dart';
import 'expense_service.dart';

abstract final class PlanFrequency {
  static const monthly = 'monthly';
  static const quarterly = 'quarterly';
  static const yearly = 'yearly';
  static const all = [monthly, quarterly, yearly];

  static String label(String f) => switch (f) {
        quarterly => 'كل 3 شهور',
        yearly => 'سنوياً',
        _ => 'شهرياً',
      };

  static DateTime next(DateTime d, String f) => switch (f) {
        quarterly => DateTime(d.year, d.month + 3, d.day),
        yearly => DateTime(d.year + 1, d.month, d.day),
        _ => DateTime(d.year, d.month + 1, d.day),
      };
}

class PlanRow {
  const PlanRow(this.plan, this.categoryName);

  final ExpensePlan plan;
  final String categoryName;

  bool get isDue => plan.isActive && !plan.nextDue.isAfter(DateTime.now());
}

/// One row of an expenses file being imported.
class ExpenseImportRow {
  ExpenseImportRow(this.rowNo, this.date, this.category, this.amount, this.method, this.description);

  final int rowNo;
  final DateTime? date;
  final String category;
  final int? amount;
  final String method;
  final String? description;
  final problems = <String>[];
  bool duplicate = false;
  bool newCategory = false;

  bool get ok => problems.isEmpty && !duplicate;
}

/// Expected recurring expenses (blueprint 9.1) and the import of past
/// expenses from Excel. A plan never posts anything by itself: "record"
/// makes the real expense, once, on the day it is paid.
class ExpensePlanService {
  ExpensePlanService(this.db);

  final AppDatabase db;

  void _check(User user) {
    if (!user.can(Perm.expenses)) throw ValidationException('المصروفات لصلاحية المحاسبة');
  }

  Stream<List<PlanRow>> watchPlans() {
    final q = db.select(db.expensePlans).join([
      innerJoin(db.expenseCategories, db.expenseCategories.id.equalsExp(db.expensePlans.categoryId)),
    ])
      ..orderBy([OrderingTerm.asc(db.expensePlans.nextDue)]);
    return q.watch().map((rows) => [
          for (final r in rows) PlanRow(r.readTable(db.expensePlans), r.readTable(db.expenseCategories).nameAr),
        ]);
  }

  Future<int> savePlan({
    int? id,
    required int categoryId,
    required int amount,
    String method = PaymentMethod.cash,
    String? description,
    String frequency = PlanFrequency.monthly,
    required DateTime nextDue,
    DateTime? endDate,
    bool isActive = true,
    required User user,
  }) async {
    _check(user);
    if (amount <= 0) throw ValidationException('المبلغ يجب أن يكون أكبر من صفر');
    if (!PlanFrequency.all.contains(frequency)) throw ArgumentError.value(frequency, 'frequency');
    final c = ExpensePlansCompanion(
      categoryId: Value(categoryId),
      amount: Value(amount),
      method: Value(method),
      description: Value((description ?? '').trim().isEmpty ? null : description!.trim()),
      frequency: Value(frequency),
      nextDue: Value(DateTime(nextDue.year, nextDue.month, nextDue.day)),
      endDate: Value(endDate),
      isActive: Value(isActive),
      updatedAt: Value(DateTime.now()),
    );
    if (id == null) return db.into(db.expensePlans).insert(c);
    await (db.update(db.expensePlans)..where((p) => p.id.equals(id))).write(c);
    return id;
  }

  /// Records the real expense for the plan's due date (the amount may differ
  /// from the plan: a higher bill, say) and moves the plan to its next date.
  Future<Expense> record(int planId, {int? amount, DateTime? date, required User user}) {
    return db.transaction(() async {
      _check(user);
      final plan = await (db.select(db.expensePlans)..where((p) => p.id.equals(planId))).getSingle();
      if (!plan.isActive) throw ValidationException('الخطة موقوفة');
      final expense = await ExpenseService(db).add(
        ExpenseInput(
          categoryId: plan.categoryId,
          amount: amount ?? plan.amount,
          method: plan.method,
          date: date ?? DateTime.now(),
          description: plan.description,
        ),
        user: user,
      );
      final next = PlanFrequency.next(plan.nextDue, plan.frequency);
      final ended = plan.endDate != null && next.isAfter(plan.endDate!);
      await (db.update(db.expensePlans)..where((p) => p.id.equals(planId))).write(ExpensePlansCompanion(
            nextDue: Value(next),
            isActive: Value(!ended),
            updatedAt: Value(DateTime.now()),
          ));
      return expense;
    });
  }

  /// Moves the plan on without an expense (not paid this time).
  Future<void> skip(int planId, {required User user}) async {
    _check(user);
    final plan = await (db.select(db.expensePlans)..where((p) => p.id.equals(planId))).getSingle();
    await (db.update(db.expensePlans)..where((p) => p.id.equals(planId)))
        .write(ExpensePlansCompanion(nextDue: Value(PlanFrequency.next(plan.nextDue, plan.frequency))));
  }

  // ---------------------------------------------------------------- import

  static const headers = ['التاريخ', 'البند', 'المبلغ', 'الطريقة', 'البيان'];

  List<int> template() {
    final excel = Excel.createExcel();
    const name = 'المصروفات';
    excel.rename(excel.getDefaultSheet()!, name);
    final sheet = excel[name];
    sheet.isRTL = true;
    sheet.appendRow([for (final h in headers) TextCellValue(h)]);
    sheet.appendRow([
      TextCellValue('2026/01/31'),
      TextCellValue('إيجار'),
      IntCellValue(15000),
      TextCellValue('نقدي'),
      TextCellValue('إيجار يناير'),
    ]);
    return excel.encode()!;
  }

  static DateTime? _date(CellValue? v) {
    switch (v) {
      case DateCellValue d:
        return DateTime(d.year, d.month, d.day);
      case DateTimeCellValue d:
        return DateTime(d.year, d.month, d.day);
      case null:
        return null;
      default:
        final t = v.toString().trim().replaceAll('-', '/').replaceAll('.', '/');
        final p = t.split(' ').first.split('/').map(int.tryParse).toList();
        if (p.length != 3 || p.any((x) => x == null)) return null;
        // 2026/01/31 or 31/01/2026
        final (y, m, d) = p[0]! > 31 ? (p[0]!, p[1]!, p[2]!) : (p[2]!, p[1]!, p[0]!);
        if (m < 1 || m > 12 || d < 1 || d > 31) return null;
        final date = DateTime(y, m, d);
        return date.month == m ? date : null; // 31/02 is not a day
    }
  }

  static String _text(CellValue? v) => switch (v) {
        null => '',
        TextCellValue t => t.value.text ?? '',
        DoubleCellValue d => d.value.toString(),
        IntCellValue i => '${i.value}',
        _ => v.toString(),
      }
          .trim();

  /// Reads the file and checks every row: date, category, amount, method,
  /// and whether the same expense is already recorded. Nothing is saved.
  Future<List<ExpenseImportRow>> preview(List<int> bytes) async {
    final Excel excel;
    try {
      excel = openExcel(bytes);
    } on Object {
      throw ValidationException('الملف ليس ملف Excel صالحاً (xlsx)');
    }
    final sheet = excel.tables.values.where((t) => t.maxRows > 0).firstOrNull;
    if (sheet == null) return const [];
    final rows = sheet.rows;
    final head = rows.indexWhere((r) => r.any((c) => _text(c?.value).isNotEmpty));
    if (head < 0) return const [];
    final col = <String, int>{};
    for (var i = 0; i < rows[head].length; i++) {
      final h = foldForSearch(_text(rows[head][i]?.value));
      for (final name in headers) {
        if (foldForSearch(name) == h) col[name] = i;
      }
    }
    final missing = ['التاريخ', 'البند', 'المبلغ'].where((h) => !col.containsKey(h)).toList();
    if (missing.isNotEmpty) throw ValidationException('أعمدة ناقصة في الملف: ${missing.join('، ')}');
    final categories = {for (final c in await db.select(db.expenseCategories).get()) foldForSearch(c.nameAr): c.id};
    final existing = <String>{
      for (final e in await (db.select(db.expenses)..where((e) => e.status.equals(DocStatus.active))).get())
        '${e.date.year}-${e.date.month}-${e.date.day}|${e.categoryId}|${e.amount}',
    };
    final seen = <String>{};
    final out = <ExpenseImportRow>[];
    for (var r = head + 1; r < rows.length; r++) {
      final cells = rows[r];
      CellValue? at(String h) => col[h] == null || col[h]! >= cells.length ? null : cells[col[h]!]?.value;
      if (headers.every((h) => _text(at(h)).isEmpty)) continue;
      final methodText = _text(at('الطريقة'));
      final row = ExpenseImportRow(
        r + 1,
        _date(at('التاريخ')),
        _text(at('البند')),
        parseMoney(_text(at('المبلغ'))),
        methodText.contains('بنك') || methodText.contains('تحويل') ? PaymentMethod.bank : PaymentMethod.cash,
        _text(at('البيان')).isEmpty ? null : _text(at('البيان')),
      );
      if (row.date == null) row.problems.add('التاريخ غير مفهوم');
      if (row.date != null && row.date!.isAfter(DateTime.now())) row.problems.add('تاريخ في المستقبل');
      if (row.category.isEmpty) row.problems.add('البند فارغ');
      if (row.amount == null || row.amount! <= 0) row.problems.add('المبلغ غير صحيح');
      final catId = categories[foldForSearch(row.category)];
      row.newCategory = catId == null && row.category.isNotEmpty;
      if (row.problems.isEmpty) {
        final key = '${row.date!.year}-${row.date!.month}-${row.date!.day}|${catId ?? row.category}|${row.amount}';
        if ((catId != null && existing.contains(key)) || !seen.add(key)) row.duplicate = true;
      }
      out.add(row);
    }
    return out;
  }

  /// Records the rows that passed, with their original dates; new
  /// categories are added. All or nothing. Returns how many were recorded.
  Future<int> import(List<ExpenseImportRow> rows, {required User user}) {
    return db.transaction(() async {
      _check(user);
      final expenses = ExpenseService(db);
      var n = 0;
      for (final r in rows.where((r) => r.ok)) {
        final cats = {for (final c in await db.select(db.expenseCategories).get()) foldForSearch(c.nameAr): c.id};
        final catId = cats[foldForSearch(r.category)] ?? await expenses.saveCategory(name: r.category);
        await expenses.add(
          ExpenseInput(
            categoryId: catId,
            amount: r.amount!,
            method: r.method,
            date: DateTime(r.date!.year, r.date!.month, r.date!.day, 12),
            description: r.description ?? 'مستورد من Excel',
          ),
          user: user,
        );
        n++;
      }
      await AuditService(db).log(
          action: AuditAction.create, entity: 'expense', entityId: 0, userId: user.id, details: 'استيراد $n مصروف من Excel');
      return n;
    });
  }
}
