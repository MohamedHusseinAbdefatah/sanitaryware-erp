import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/services/doc_types.dart';
import '../../core/services/expense_service.dart';
import '../../core/widgets/data_list.dart';
import '../../core/widgets/date_range_bar.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/number_fields.dart';
import '../payments/payments_screen.dart';

/// Admin only (the section is).
class ExpensesScreen extends ConsumerStatefulWidget {
  const ExpensesScreen({super.key});

  @override
  ConsumerState<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends ConsumerState<ExpensesScreen> {
  DayRange _range = DayRange.thisMonth();

  @override
  void initState() {
    super.initState();
    // Databases set up before expenses existed get the starting list here.
    ref.read(expenseServiceProvider).seedDefaultCategories();
  }

  Future<void> _cancel(ExpenseRow row) async {
    final reason = await askReason(context, title: Strings.cancelExpense);
    if (reason == null || !mounted) return;
    await runGuarded(
      context,
      () => ref.read(expenseServiceProvider).cancel(row.expense.id, reason: reason, user: ref.read(currentUserProvider)!),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(_expensesProvider(_range));
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: Strings.expenses,
          actions: [
            OutlinedButton.icon(
              onPressed: () => showDialog<void>(context: context, builder: (_) => const _CategoriesDialog()),
              icon: const Icon(Icons.list_alt),
              label: const Text(Strings.expenseCategories),
            ),
            FilledButton.icon(
              onPressed: () => showDialog<void>(context: context, builder: (_) => const _ExpenseDialog()),
              icon: const Icon(Icons.add),
              label: const Text(Strings.newExpense),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: DateRangeBar(value: _range, onChanged: (r) => setState(() => _range = r)),
        ),
        Expanded(
          child: rows.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('$e')),
            data: (list) {
              final total = list
                  .where((r) => r.expense.status == DocStatus.active)
                  .fold(0, (s, r) => s + r.expense.amount);
              return Column(
                children: [
                  Expanded(
                    child: DataList<ExpenseRow>(
                      rows: list,
                      emptyText: Strings.noExpenses,
                      rowColor: (r) => r.expense.status == DocStatus.cancelled
                          ? scheme.errorContainer.withValues(alpha: 0.3)
                          : null,
                      trailing: (r) => r.expense.status == DocStatus.active
                          ? IconButton(
                              tooltip: Strings.cancelExpense,
                              icon: const Icon(Icons.block),
                              onPressed: () => _cancel(r),
                            )
                          : const SizedBox(),
                      columns: [
                        DataListColumn(Strings.date, (r) => Text(formatDate(r.expense.date))),
                        DataListColumn(Strings.expenseCategory, flex: 2, (r) => Text(r.categoryName)),
                        DataListColumn(Strings.amount, numeric: true, (r) => Text(formatMoney(r.expense.amount))),
                        DataListColumn(Strings.method, numeric: true, (r) => Text(paymentMethodLabel(r.expense.method))),
                        DataListColumn(Strings.description, flex: 3, (r) => Text(r.expense.description ?? '')),
                      ],
                    ),
                  ),
                  Container(
                    color: scheme.surfaceContainerHigh,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                    child: Row(
                      children: [
                        Text(_range.label),
                        const Spacer(),
                        Text(
                          '${Strings.totalExpenses}: ${formatMoney(total)}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ExpenseDialog extends ConsumerStatefulWidget {
  const _ExpenseDialog();

  @override
  ConsumerState<_ExpenseDialog> createState() => _ExpenseDialogState();
}

class _ExpenseDialogState extends ConsumerState<_ExpenseDialog> {
  final _form = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _description = TextEditingController();
  int? _categoryId;
  String _method = PaymentMethod.cash;
  DateTime _date = DateTime.now();

  @override
  void dispose() {
    _amount.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      final now = DateTime.now();
      setState(() => _date = DateTime(picked.year, picked.month, picked.day, now.hour, now.minute));
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final ok = await runGuarded(context, () async {
      await ref.read(expenseServiceProvider).add(
            ExpenseInput(
              categoryId: _categoryId ?? -1,
              amount: moneyOrZero(_amount),
              method: _method,
              date: _date,
              description: _description.text,
            ),
            user: ref.read(currentUserProvider)!,
          );
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(_categoriesProvider).valueOrNull ?? const <ExpenseCategory>[];
    return AlertDialog(
      title: const Text(Strings.newExpense),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<int>(
                key: ValueKey(categories.length),
                initialValue: _categoryId,
                decoration: const InputDecoration(labelText: Strings.expenseCategory),
                items: [for (final c in categories) DropdownMenuItem(value: c.id, child: Text(c.nameAr))],
                validator: (v) => v == null ? Strings.required : null,
                onChanged: (v) => setState(() => _categoryId = v),
              ),
              MoneyField(controller: _amount, label: Strings.amount, required: true),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: PaymentMethod.cash, label: Text(Strings.methodCash)),
                  ButtonSegment(value: PaymentMethod.bank, label: Text(Strings.methodBank)),
                ],
                selected: {_method},
                onSelectionChanged: (s) => setState(() => _method = s.single),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(Strings.date),
                subtitle: Text(formatDate(_date)),
                trailing: const Icon(Icons.calendar_month),
                onTap: _pickDate,
              ),
              TextFormField(
                controller: _description,
                decoration: const InputDecoration(labelText: Strings.description),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.cancel)),
        FilledButton(onPressed: _save, child: const Text(Strings.save)),
      ],
    );
  }
}

class _CategoriesDialog extends ConsumerWidget {
  const _CategoriesDialog();

  Future<void> _edit(BuildContext context, WidgetRef ref, [ExpenseCategory? c]) async {
    final controller = TextEditingController(text: c?.nameAr);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: Strings.name),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text(Strings.save)),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !context.mounted) return;
    await runGuarded(context, () => ref.read(expenseServiceProvider).saveCategory(id: c?.id, name: name));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(_categoriesProvider).valueOrNull ?? const <ExpenseCategory>[];
    return AlertDialog(
      title: const Text(Strings.expenseCategories),
      content: SizedBox(
        width: 400,
        height: 360,
        child: Column(
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () => _edit(context, ref),
                icon: const Icon(Icons.add),
                label: const Text(Strings.add),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final c in categories)
                    ListTile(
                      dense: true,
                      title: Text(c.nameAr),
                      trailing: IconButton(
                        tooltip: Strings.edit,
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _edit(context, ref, c),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.close))],
    );
  }
}

final _expensesProvider = StreamProvider.autoDispose.family<List<ExpenseRow>, DayRange>(
  (ref, range) => ref.watch(expenseServiceProvider).watchList(from: range.from, to: range.to),
);

final _categoriesProvider = StreamProvider.autoDispose<List<ExpenseCategory>>(
  (ref) => ref.watch(expenseServiceProvider).watchCategories(),
);
