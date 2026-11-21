import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/services/doc_types.dart';
import '../../core/services/payment_service.dart';
import '../../core/services/supplier_advance_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/number_fields.dart';

/// A supplier's advances: the balance, each advance with what was taken from
/// it and on which invoices, and a new one.
Future<void> showSupplierAdvances(BuildContext context, Supplier supplier) =>
    showDialog<void>(context: context, builder: (_) => _AdvancesDialog(supplier: supplier));

class _AdvancesDialog extends ConsumerStatefulWidget {
  const _AdvancesDialog({required this.supplier});

  final Supplier supplier;

  @override
  ConsumerState<_AdvancesDialog> createState() => _AdvancesDialogState();
}

class _AdvancesData {
  const _AdvancesData(this.balance, this.rows, this.allocations);

  final AdvanceBalance balance;
  final List<AdvanceRow> rows;
  final List<AllocationRow> allocations;
}

class _AdvancesDialogState extends ConsumerState<_AdvancesDialog> {
  late Future<_AdvancesData> _data = _load();

  Future<_AdvancesData> _load() async {
    final s = ref.read(supplierAdvanceServiceProvider);
    final id = widget.supplier.id;
    return _AdvancesData(await s.balance(id), await s.rows(supplierId: id), await s.allocations(supplierId: id));
  }

  void _reload() => setState(() => _data = _load());

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

  /// Owner: a wrong amount typed for the advance itself.
  Future<void> _correctAmount(AdvanceRow r) async {
    final amount = await askAmount(
      context,
      title: 'تصحيح مبلغ الدفعة ${r.advance.number}',
      hint: 'المسجل ${formatMoney(r.advance.amount)} · المخصوم منها ${formatMoney(r.used)}',
      initial: r.advance.amount,
    );
    if (amount == null || !mounted) return;
    final reason = await askReason(context, title: 'سبب التصحيح');
    if (reason == null || !mounted) return;
    final ok = await runGuarded(context, () async {
      await ref
          .read(paymentServiceProvider)
          .correct(r.advance.paymentId, amount: amount, reason: reason, user: ref.read(currentUserProvider)!);
      return true;
    });
    if (ok == true) _reload();
  }

  /// Owner: undoes one use of an advance on an invoice.
  Future<void> _cancelAllocation(AllocationRow a) async {
    final reason = await askReason(context,
        title: 'إلغاء خصم ${formatMoney(a.allocation.amount)} من ${a.advanceNumber} على ${a.invoiceNumber}');
    if (reason == null || !mounted) return;
    final ok = await runGuarded(context, () async {
      await ref
          .read(supplierAdvanceServiceProvider)
          .cancelAllocation(a.allocation.id, reason: reason, user: ref.read(currentUserProvider)!);
      return true;
    });
    if (ok == true) _reload();
  }

  Widget _figure(String label, int amount, Color color) => Expanded(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(color: AppColors.muted)),
            const SizedBox(height: 4),
            Text(formatMoney(amount), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: color)),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final owner = ref.watch(currentUserProvider)?.isAdmin ?? false;
    return AlertDialog(
      title: Text('الدفعات المقدمة — ${widget.supplier.name}'),
      content: SizedBox(
        width: 820,
        height: 540,
        child: FutureBuilder<_AdvancesData>(
          future: _data,
          builder: (context, snap) {
            if (snap.hasError) return Center(child: Text('${snap.error}'));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final d = snap.data!;
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                _figure('إجمالي الدفعات المقدمة', d.balance.paid, AppColors.info),
                const SizedBox(width: 10),
                _figure('المخصوم على فواتير', d.balance.allocated, AppColors.warn),
                const SizedBox(width: 10),
                _figure('المتبقي للمورد عندنا', d.balance.remaining, AppColors.good),
              ]),
              const SizedBox(height: 10),
              const InfoNote(
                'الدفعة المقدمة رصيد للمورد، وليست مرتبطة بقائمة أسعار. عند تسجيل أي فاتورة شراء لهذا المورد '
                '(أي ماركة أو قائمة) يمكن خصم جزء منها، ويُحفظ كل خصم مرتبطاً بفاتورته.',
              ),
              const SizedBox(height: 10),
              Expanded(
                child: d.rows.isEmpty
                    ? const Center(child: Text('لا توجد دفعات مقدمة لهذا المورد', style: TextStyle(color: AppColors.muted)))
                    : ListView.separated(
                          itemCount: d.rows.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final r = d.rows[i];
                            final cancelled = r.advance.status == DocStatus.cancelled;
                            final uses = d.allocations.where((a) => a.allocation.advanceId == r.advance.id).toList();
                            return ExpansionTile(
                              leading: Icon(Icons.account_balance_wallet_outlined,
                                  color: cancelled ? AppColors.muted : AppColors.brand),
                              title: Text(
                                '${r.advance.number} · ${formatDate(r.advance.date)} · ${formatMoney(r.advance.amount)}'
                                '${cancelled ? ' (ملغاة)' : ''}',
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                              subtitle: Text(
                                'المخصوم ${formatMoney(r.used)} · المتبقي ${formatMoney(cancelled ? 0 : r.remaining)}'
                                '${r.advance.note == null ? '' : ' · ${r.advance.note}'}'
                                '${r.lists.isEmpty ? '' : '\nقبل 2.4 كانت مثبتة على: ${r.lists.map((l) => l.brandName).toSet().join('، ')}'}',
                              ),
                              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                                if (!cancelled && owner)
                                  IconButton(
                                    tooltip: 'تصحيح المبلغ',
                                    onPressed: () => _correctAmount(r),
                                    icon: const Icon(Icons.edit_outlined),
                                  ),
                                if (!cancelled && r.used == 0)
                                  TextButton(onPressed: () => _cancel(r), child: const Text('إلغاء')),
                                const Icon(Icons.expand_more),
                              ]),
                              children: [
                                if (uses.isEmpty)
                                  const ListTile(dense: true, title: Text('لم يُخصم منها شيء بعد')),
                                for (final a in uses)
                                  ListTile(
                                    dense: true,
                                    leading: Icon(a.active ? Icons.receipt_long_outlined : Icons.block,
                                        size: 18, color: a.active ? null : AppColors.muted),
                                    title: Text('${a.invoiceNumber} · ${formatDate(a.invoiceDate)} · ${formatMoney(a.allocation.amount)}'
                                        '${a.active ? '' : ' (ملغى)'}'),
                                    subtitle: a.allocation.note == null ? null : Text(a.allocation.note!),
                                    trailing: a.active && owner
                                        ? TextButton(onPressed: () => _cancelAllocation(a), child: const Text('تصحيح / إلغاء'))
                                        : null,
                                  ),
                              ],
                            );
                          },
                        ),
              ),
            ]);
          },
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
  String _method = PaymentMethod.cash;
  DateTime _date = DateTime.now();
  DateTime _chequeDue = DateTime.now();

  @override
  void dispose() {
    for (final c in [_amount, _note, _chequeNo, _bank]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final ok = await runGuarded(context, () async {
      await ref.read(supplierAdvanceServiceProvider).create(
            supplierId: widget.supplier.id,
            amount: parseMoney(_amount.text)!,
            method: _method,
            cheque: _method == PaymentMethod.cheque
                ? ChequeInput(number: _chequeNo.text, bank: _bank.text, dueDate: _chequeDue)
                : null,
            date: _date,
            note: _note.text,
            user: ref.read(currentUserProvider)!,
          );
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context, true);
  }

  Future<DateTime?> _pick(DateTime initial, {bool past = true}) => showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: DateTime(2000),
        lastDate: past ? DateTime.now() : DateTime.now().add(const Duration(days: 3650)),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('دفعة مقدمة جديدة — ${widget.supplier.name}'),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MoneyField(controller: _amount, label: 'المبلغ', required: true),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () async {
                    final d = await _pick(_date);
                    if (d != null) setState(() => _date = d);
                  },
                  icon: const Icon(Icons.event),
                  label: Text('تاريخ الدفع ${formatDate(_date)}'),
                ),
                const SizedBox(height: 12),
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
                      final d = await _pick(_chequeDue, past: false);
                      if (d != null) setState(() => _chequeDue = d);
                    },
                    icon: const Icon(Icons.event),
                    label: Text('استحقاق الشيك ${formatDate(_chequeDue)}'),
                  ),
                ],
                const SizedBox(height: 8),
                TextField(controller: _note, decoration: const InputDecoration(labelText: Strings.notes)),
                const SizedBox(height: 12),
                const InfoNote('لا يُطلب اختيار قائمة أسعار: الدفعة تُخصم لاحقاً من أي فاتورة شراء لهذا المورد.'),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.cancel)),
        FilledButton(onPressed: _save, child: const Text('حفظ الدفعة')),
      ],
    );
  }
}
