import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/services/doc_types.dart';
import '../../core/services/payment_service.dart';
import '../../core/services/supplier_advance_service.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/number_fields.dart';

/// A supplier's advances locked to price lists, and a new one.
Future<void> showSupplierAdvances(BuildContext context, Supplier supplier) =>
    showDialog<void>(context: context, builder: (_) => _AdvancesDialog(supplier: supplier));

class _AdvancesDialog extends ConsumerStatefulWidget {
  const _AdvancesDialog({required this.supplier});

  final Supplier supplier;

  @override
  ConsumerState<_AdvancesDialog> createState() => _AdvancesDialogState();
}

class _AdvancesDialogState extends ConsumerState<_AdvancesDialog> {
  late Future<List<AdvanceRow>> _rows = _load();

  Future<List<AdvanceRow>> _load() => ref.read(supplierAdvanceServiceProvider).rows(supplierId: widget.supplier.id);

  void _reload() => setState(() => _rows = _load());

  Future<void> _new() async {
    final saved = await showDialog<bool>(context: context, builder: (_) => _NewAdvanceDialog(supplier: widget.supplier));
    if (saved == true) _reload();
  }

  Future<void> _cancel(AdvanceRow r) async {
    final reason = await askReason(context, title: 'إلغاء الدفعة ${r.advance.number}');
    if (reason == null || !mounted) return;
    final ok = await runGuarded(context, () async {
      await ref.read(supplierAdvanceServiceProvider).cancel(r.advance.id, reason: reason, user: ref.read(currentUserProvider)!);
      return true;
    });
    if (ok == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('دفعات مقدمة بسعر قائمة — ${widget.supplier.name}'),
      content: SizedBox(
        width: 720,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              color: theme.colorScheme.surfaceContainerHighest,
              child: const Text(
                'مبلغ يُدفع للمورد مقدماً ويُثبت على قوائم أسعار الماركات المختارة السارية يوم الدفع، وعلى خصم المورد '
                'في ذلك اليوم. تُسحب البضاعة لاحقاً من فاتورة شراء باختيار الدفعة، بالأسعار المثبتة حتى لو صدرت قوائم أغلى.',
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: FutureBuilder<List<AdvanceRow>>(
                future: _rows,
                builder: (context, snap) {
                  if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                  final rows = snap.data!;
                  if (rows.isEmpty) return const Center(child: Text('لا توجد دفعات مقدمة لهذا المورد'));
                  return ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final r = rows[i];
                      final cancelled = r.advance.status == DocStatus.cancelled;
                      return ListTile(
                        leading: Icon(Icons.lock_clock_outlined,
                            color: cancelled ? theme.disabledColor : theme.colorScheme.primary),
                        title: Text('${r.advance.number} · ${formatDate(r.advance.date)} · ${formatMoney(r.advance.amount)}'
                            '${cancelled ? ' (ملغاة)' : ''}'),
                        subtitle: Text(
                          'مثبتة على: ${r.lists.map((l) => '${l.brandName} PL-${l.list.id} ${l.list.listType} V${l.list.versionNo}').join('، ')}\n'
                          'المسحوب ${formatMoney(r.used)} · المتبقي ${formatMoney(r.remaining)}',
                        ),
                        isThreeLine: true,
                        trailing: cancelled || r.used > 0
                            ? null
                            : TextButton(onPressed: () => _cancel(r), child: const Text('إلغاء')),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton.icon(onPressed: _new, icon: const Icon(Icons.add), label: const Text('دفعة مقدمة جديدة')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.close)),
      ],
    );
  }
}

class _NewAdvanceDialog extends ConsumerStatefulWidget {
  const _NewAdvanceDialog({required this.supplier});

  final Supplier supplier;

  @override
  ConsumerState<_NewAdvanceDialog> createState() => _NewAdvanceDialogState();
}

class _NewAdvanceDialogState extends ConsumerState<_NewAdvanceDialog> {
  final _form = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _note = TextEditingController();
  final _chequeNo = TextEditingController();
  final _bank = TextEditingController();
  final _brands = <int>{};
  String _method = PaymentMethod.cash;
  DateTime _chequeDue = DateTime.now();
  late final Future<List<(Brand, List<PriceList>)>> _options = _loadBrands();

  Future<List<(Brand, List<PriceList>)>> _loadBrands() async {
    final db = ref.read(databaseProvider);
    final svc = ref.read(supplierAdvanceServiceProvider);
    final brands = await (db.select(db.brands)..orderBy([(b) => OrderingTerm.asc(b.name)])).get();
    return [for (final b in brands) (b, await svc.listsInForce(b.id, DateTime.now()))];
  }

  @override
  void dispose() {
    for (final c in [_amount, _note, _chequeNo, _bank]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_brands.isEmpty) {
      await showMessage(context, 'اختر الماركات التي تثبت الدفعة على قوائمها');
      return;
    }
    final ok = await runGuarded(context, () async {
      await ref.read(supplierAdvanceServiceProvider).create(
            supplierId: widget.supplier.id,
            amount: parseMoney(_amount.text)!,
            brandIds: _brands.toList(),
            method: _method,
            cheque: _method == PaymentMethod.cheque
                ? ChequeInput(number: _chequeNo.text, bank: _bank.text, dueDate: _chequeDue)
                : null,
            note: _note.text,
            user: ref.read(currentUserProvider)!,
          );
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('دفعة مقدمة بسعر قائمة — ${widget.supplier.name}'),
      content: SizedBox(
        width: 560,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MoneyField(controller: _amount, label: 'المبلغ', required: true),
                const SizedBox(height: 12),
                const Text('الماركات (تُثبت قوائمها السارية اليوم):', style: TextStyle(fontWeight: FontWeight.bold)),
                FutureBuilder<List<(Brand, List<PriceList>)>>(
                  future: _options,
                  builder: (context, snap) {
                    if (!snap.hasData) return const LinearProgressIndicator();
                    return Column(
                      children: [
                        for (final (b, lists) in snap.data!)
                          CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            value: _brands.contains(b.id),
                            onChanged: lists.isEmpty
                                ? null
                                : (v) => setState(() => v == true ? _brands.add(b.id) : _brands.remove(b.id)),
                            title: Text(b.name),
                            subtitle: Text(lists.isEmpty
                                ? 'لا توجد قائمة سارية اليوم'
                                : lists.map((l) => 'PL-${l.id} ${l.listType} V${l.versionNo} — ${l.name}').join('، ')),
                          ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _method,
                  decoration: const InputDecoration(labelText: 'طريقة الدفع'),
                  items: const [
                    DropdownMenuItem(value: PaymentMethod.cash, child: Text(Strings.methodCash)),
                    DropdownMenuItem(value: PaymentMethod.bank, child: Text(Strings.methodBank)),
                    DropdownMenuItem(value: PaymentMethod.cheque, child: Text('شيك')),
                  ],
                  onChanged: (v) => setState(() => _method = v!),
                ),
                if (_method == PaymentMethod.cheque) ...[
                  TextFormField(
                    controller: _chequeNo,
                    decoration: const InputDecoration(labelText: 'رقم الشيك'),
                    validator: (v) => (v ?? '').trim().isEmpty ? Strings.required : null,
                  ),
                  TextField(controller: _bank, decoration: const InputDecoration(labelText: 'البنك')),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: _chequeDue,
                        firstDate: DateTime.now().subtract(const Duration(days: 365)),
                        lastDate: DateTime.now().add(const Duration(days: 3650)),
                      );
                      if (d != null) setState(() => _chequeDue = d);
                    },
                    icon: const Icon(Icons.event),
                    label: Text('استحقاق الشيك ${formatDate(_chequeDue)}'),
                  ),
                ],
                TextField(controller: _note, decoration: const InputDecoration(labelText: Strings.notes)),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.cancel)),
        FilledButton(onPressed: _save, child: const Text('دفع وتثبيت السعر')),
      ],
    );
  }
}
