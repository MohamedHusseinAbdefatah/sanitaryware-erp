import 'package:drift/drift.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import '../money.dart';
import '../search_text.dart';
import 'audit_service.dart';
import 'doc_types.dart';
import 'errors.dart';
import 'query_helpers.dart';

class ExpenseInput {
  const ExpenseInput({
    required this.categoryId,
    required this.amount,
    this.method = PaymentMethod.cash,
    this.date,
    this.description,
    this.projectId,
  });

  final int categoryId;
  final int amount;
  final String method;
  final DateTime? date;
  final String? description;

  /// Spent for this project, if any.
  final int? projectId;
}

class ExpenseRow {
  const ExpenseRow(this.expense, this.categoryName);
  final Expense expense;
  final String categoryName;
}

/// Shop expenses: rent, transport, salaries, electricity... Admin only.
class ExpenseService {
  ExpenseService(this.db);

  final AppDatabase db;

  Stream<List<ExpenseCategory>> watchCategories() => (db.select(db.expenseCategories)
        ..orderBy([(t) => OrderingTerm(expression: t.nameAr)]))
      .watch();

  /// The plan's starting list; only added when there are none yet.
  Future<void> seedDefaultCategories() async {
    if ((await db.select(db.expenseCategories).get()).isNotEmpty) return;
    for (final name in ['إيجار', 'نقل ومشال', 'مرتبات', 'كهرباء ومياه', 'نثريات']) {
      await db.into(db.expenseCategories).insert(ExpenseCategoriesCompanion.insert(nameAr: name));
    }
  }

  Future<int> saveCategory({int? id, required String name}) async {
    final n = name.trim();
    if (n.isEmpty) throw ValidationException('الاسم مطلوب');
    final others = (await db.select(db.expenseCategories).get()).where((c) => c.id != id);
    if (others.any((c) => foldForSearch(c.nameAr) == foldForSearch(n))) {
      throw ValidationException('البند "$n" موجود من قبل');
    }
    if (id == null) {
      return db.into(db.expenseCategories).insert(ExpenseCategoriesCompanion.insert(nameAr: n));
    }
    await (db.update(db.expenseCategories)..where((t) => t.id.equals(id))).write(
      ExpenseCategoriesCompanion(nameAr: Value(n), updatedAt: Value(DateTime.now())),
    );
    return id;
  }

  Future<Expense> add(ExpenseInput input, {required User user}) {
    return db.transaction(() async {
      if (!user.isAdmin) throw ValidationException('المصروفات للمدير فقط');
      if (input.amount <= 0) throw ValidationException('المبلغ يجب أن يكون أكبر من صفر');
      if (input.method != PaymentMethod.cash && input.method != PaymentMethod.bank) {
        throw ArgumentError.value(input.method, 'method');
      }
      final category = await (db.select(db.expenseCategories)..where((t) => t.id.equals(input.categoryId)))
          .getSingleOrNull();
      if (category == null) throw ValidationException('اختر بند المصروف');
      final id = await db.into(db.expenses).insert(ExpensesCompanion.insert(
            date: input.date ?? DateTime.now(),
            categoryId: input.categoryId,
            amount: input.amount,
            method: Value(input.method),
            description: Value((input.description ?? '').trim().isEmpty ? null : input.description!.trim()),
            createdBy: Value(user.id),
            projectId: Value(input.projectId),
          ));
      await AuditService(db).log(
        action: AuditAction.create,
        entity: 'expense',
        entityId: id,
        userId: user.id,
        details: '${category.nameAr} ${formatMoney(input.amount)}',
      );
      return (db.select(db.expenses)..where((t) => t.id.equals(id))).getSingle();
    });
  }

  /// Admin only; the expense stays on record as cancelled.
  Future<void> cancel(int expenseId, {required String reason, required User user}) {
    return db.transaction(() async {
      if (!user.isAdmin) throw ValidationException('إلغاء المصروفات للمدير فقط');
      if (reason.trim().isEmpty) throw ValidationException('سبب الإلغاء مطلوب');
      final e = await (db.select(db.expenses)..where((t) => t.id.equals(expenseId))).getSingle();
      if (e.status == DocStatus.cancelled) throw ValidationException('المصروف ملغى من قبل');
      if (e.purchaseInvoiceId != null) {
        throw ValidationException('هذا المصروف من فاتورة شراء وهو جزء من تكلفة البضاعة؛ يُلغى بإلغاء الفاتورة');
      }
      final note = 'سبب الإلغاء: ${reason.trim()}';
      await (db.update(db.expenses)..where((t) => t.id.equals(expenseId))).write(ExpensesCompanion(
            status: const Value(DocStatus.cancelled),
            description: Value(e.description == null ? note : '${e.description}\n$note'),
            updatedAt: Value(DateTime.now()),
          ));
      await AuditService(db).log(
        action: AuditAction.cancel,
        entity: 'expense',
        entityId: expenseId,
        userId: user.id,
        details: reason.trim(),
      );
    });
  }

  /// Newest first, optionally one category, between two days (inclusive).
  Stream<List<ExpenseRow>> watchList({DateTime? from, DateTime? to, int? categoryId}) {
    return db.customSelect(
      '''
      SELECT e.*, c.name_ar AS category_name
      FROM expenses e JOIN expense_categories c ON c.id = e.category_id
      WHERE (? IS NULL OR e.date >= ?) AND (? IS NULL OR e.date < ?)
        AND (? IS NULL OR e.category_id = ?)
      ORDER BY e.date DESC, e.id DESC
      ''',
      variables: [
        ...dateRangeVariables(from, to),
        Variable<int>(categoryId),
        Variable<int>(categoryId),
      ],
      readsFrom: {db.expenses, db.expenseCategories},
    ).watch().map((rows) => [
          for (final r in rows) ExpenseRow(db.expenses.map(r.data), r.read<String>('category_name')),
        ]);
  }
}
