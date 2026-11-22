import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/printing/print_actions.dart';
import '../../core/providers.dart';
import '../../core/services/doc_types.dart';
import '../../core/services/payment_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/data_list.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/list_kit.dart';
import '../../core/widgets/number_fields.dart';
import 'payment_dialog.dart';

String paymentMethodLabel(String method) => switch (method) {
  PaymentMethod.bank => Strings.methodBank,
  PaymentMethod.cheque => Strings.methodCheque,
  _ => Strings.methodCash,
};

String chequeStatusLabel(String status) => switch (status) {
  ChequeStatus.pending => Strings.chequePending,
  ChequeStatus.cleared => Strings.chequeCleared,
  ChequeStatus.bounced => Strings.chequeBounced,
  ChequeStatus.cancelled => Strings.cancelled,
  _ => status,
};

Widget chequePill(String status) => switch (status) {
  ChequeStatus.cleared => StatusPill.good(chequeStatusLabel(status)),
  ChequeStatus.bounced || ChequeStatus.cancelled => StatusPill.bad(chequeStatusLabel(status)),
  _ => StatusPill.warn(chequeStatusLabel(status)),
};

/// Received, paid (admin) and the cheque register in three tabs.
class PaymentsScreen extends ConsumerWidget {
  const PaymentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAdmin = ref.watch(currentUserProvider)?.can(Perm.payOut) ?? false;
    return DefaultTabController(
      length: isAdmin ? 3 : 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: Strings.payments,
            icon: Icons.payments_outlined,
            subtitle: 'المقبوضات والمدفوعات والشيكات',
            actions: [
              FilledButton.icon(
                onPressed: () => showPaymentDialog(context, partyType: PartyType.customer),
                icon: const Icon(Icons.call_received),
                label: const Text(Strings.receiveFromCustomer),
              ),
              if (isAdmin)
                FilledButton.tonalIcon(
                  onPressed: () => showPaymentDialog(context, partyType: PartyType.supplier),
                  icon: const Icon(Icons.call_made),
                  label: const Text(Strings.payToSupplier),
                ),
            ],
          ),
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              const Tab(text: Strings.received),
              if (isAdmin) const Tab(text: Strings.paidOut),
              const Tab(text: Strings.cheques),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                const _PaymentList(direction: PaymentDirection.inbound),
                if (isAdmin) const _PaymentList(direction: PaymentDirection.outbound),
                const _ChequeList(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Deletes a payment entered by mistake (a supplier advance with its
/// advance). Balances, the invoice and the books follow. Returns true when
/// done.
Future<bool> deletePayment(BuildContext context, WidgetRef ref, Payment p) async {
  final reason = await askReason(context, title: 'حذف الدفعة ${p.number} (${formatMoney(p.amount)})');
  if (reason == null || !context.mounted) return false;
  final ok = await runGuarded(context, () async {
    await ref.read(paymentServiceProvider).remove(p.id, reason: reason, user: ref.read(currentUserProvider)!);
    return true;
  });
  if (ok == true && context.mounted) showToast(context, 'حُذفت الدفعة ${p.number}، وتعدل الرصيد تلقائياً');
  return ok == true;
}

/// Print, correct and delete for one payment, wherever payments are listed
/// (the payments screen, a supplier's or customer's page).
class PaymentActions extends ConsumerWidget {
  const PaymentActions({super.key, required this.payment, required this.partyName, this.cheque, this.onChanged});

  final Payment payment;
  final String partyName;
  final Cheque? cheque;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final canDelete = user?.can(Perm.payOut) ?? false;
    final owner = user?.isAdmin ?? false;
    final row = PaymentRow(payment, partyName, cheque);
    final active = payment.status == DocStatus.active;
    return PopupMenuButton<VoidCallback>(
      tooltip: 'إجراءات',
      onSelected: (f) => f(),
      itemBuilder: (_) => [
        PopupMenuItem(value: () => printReceipt(context, ref, row), child: const Text(Strings.printReceipt)),
        if (owner && active)
          PopupMenuItem(
            value: () async {
              await showDialog<void>(context: context, builder: (_) => CorrectPaymentDialog(row: row));
              onChanged?.call();
            },
            child: const ListTile(dense: true, leading: Icon(Icons.edit_outlined), title: Text('تعديل الدفعة')),
          ),
        if (canDelete && active)
          PopupMenuItem(
            value: () async {
              if (await deletePayment(context, ref, payment)) onChanged?.call();
            },
            child: const ListTile(
              dense: true,
              leading: Icon(Icons.delete_outline, color: AppColors.bad),
              title: Text('حذف الدفعة', style: TextStyle(color: AppColors.bad)),
            ),
          ),
      ],
    );
  }
}

class _PaymentList extends ConsumerStatefulWidget {
  const _PaymentList({required this.direction});

  final String direction;

  @override
  ConsumerState<_PaymentList> createState() => _PaymentListState();
}

class _PaymentListState extends ConsumerState<_PaymentList> {
  /// Deleted (cancelled) payments are out of the list unless asked for.
  bool _showDeleted = false;

  String get direction => widget.direction;

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(currentUserProvider)?.can(Perm.payOut) ?? false;
    final owner = ref.watch(currentUserProvider)?.isAdmin ?? false;
    final rows = ref.watch(_paymentsProvider(direction));
    return rows.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (all) {
        final deleted = all.where((r) => r.payment.status != DocStatus.active).length;
        final list = _showDeleted ? all : all.where((r) => r.payment.status == DocStatus.active).toList();
        final active = list.where((r) => r.payment.status == DocStatus.active).toList();
        final now = DateTime.now();
        int sum(Iterable<PaymentRow> rs) => rs.fold(0, (s, r) => s + r.payment.amount);
        final today = active.where(
          (r) => r.payment.date.year == now.year && r.payment.date.month == now.month && r.payment.date.day == now.day,
        );
        final month = active.where((r) => r.payment.date.year == now.year && r.payment.date.month == now.month);
        int byMethod(String m) => sum(month.where((r) => r.payment.method == m));
        final inbound = direction == PaymentDirection.inbound;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            SummaryStrip(
              items: [
                SummaryItem(
                  'اليوم',
                  formatMoney(sum(today)),
                  icon: Icons.today_outlined,
                  tone: inbound ? AppColors.good : AppColors.warn,
                ),
                SummaryItem('هذا الشهر', formatMoney(sum(month)), icon: Icons.calendar_month_outlined),
                SummaryItem('نقدي (الشهر)', formatMoney(byMethod(PaymentMethod.cash)), icon: Icons.payments_outlined),
                SummaryItem(
                  'تحويل (الشهر)',
                  formatMoney(byMethod(PaymentMethod.bank)),
                  icon: Icons.account_balance_outlined,
                ),
                SummaryItem('شيكات (الشهر)', formatMoney(byMethod(PaymentMethod.cheque)), icon: Icons.receipt_outlined),
              ],
            ),
            if (deleted > 0)
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(24, 6, 24, 0),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilterChip(
                    label: Text('عرض المحذوفة ($deleted)'),
                    selected: _showDeleted,
                    onSelected: (v) => setState(() => _showDeleted = v),
                  ),
                ),
              ),
            Expanded(child: _table(context, ref, list, isAdmin, owner)),
          ],
        );
      },
    );
  }

  Widget _table(BuildContext context, WidgetRef ref, List<PaymentRow> list, bool isAdmin, bool owner) {
    return DataList<PaymentRow>(
      rows: list,
      emptyText: Strings.noPayments,
      rowColor: (r) => r.payment.status == DocStatus.cancelled ? AppColors.canvas : null,
      trailing: (r) => PaymentActions(payment: r.payment, partyName: r.partyName, cheque: r.cheque),
      columns: [
        DataListColumn(
          Strings.number,
          (r) => Text(r.payment.number, style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        DataListColumn(Strings.date, sortValue: (r) => r.payment.date, flex: 2, (r) => Text(formatDateTime(r.payment.date))),
        DataListColumn(
          Strings.party,
          flex: 3,
          (r) => r.payment.partyId <= 0
              ? Text(r.partyName)
              : InkWell(
                  onTap: () => context.go(
                    '/${r.payment.partyType == PartyType.customer ? 'customers' : 'suppliers'}/${r.payment.partyId}',
                  ),
                  child: Text(
                    r.partyName,
                    style: const TextStyle(color: AppColors.brand, fontWeight: FontWeight.w600),
                  ),
                ),
        ),
        DataListColumn(
          Strings.amount,
          sortValue: (r) => r.payment.amount,
          numeric: true,
          (r) => Text(formatMoney(r.payment.amount), style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        DataListColumn(
          Strings.method,
          numeric: true,
          (r) => Text(
            r.cheque == null ? paymentMethodLabel(r.payment.method) : '${Strings.methodCheque} ${r.cheque!.chequeNo}',
          ),
        ),
        DataListColumn(Strings.forWhat, flex: 2, (r) => Text(_refLabel(r.payment))),
        DataListColumn(
          Strings.status,
          numeric: true,
          (r) => r.payment.status == DocStatus.cancelled
              ? const StatusPill.bad('محذوفة')
              : r.cheque == null
              ? const StatusPill.good('سارية')
              : chequePill(r.cheque!.status),
        ),
      ],
    );
  }

  static String _refLabel(Payment payment) => switch (payment.invoiceRefType) {
    RefType.salesInvoice => Strings.salesInvoice,
    RefType.purchaseInvoice => Strings.purchaseInvoice,
    RefType.returnDoc => Strings.returnRefund,
    RefType.supplierAdvance => 'دفعة مقدمة لمورد',
    RefType.purchaseOrder => 'دفعة مقدمة على أمر شراء',
    RefType.salesOrder => 'دفعة مقدمة على أمر بيع',
    _ => Strings.onAccount,
  };
}

class _ChequeList extends ConsumerStatefulWidget {
  const _ChequeList();

  @override
  ConsumerState<_ChequeList> createState() => _ChequeListState();
}

class _ChequeListState extends ConsumerState<_ChequeList> {
  bool _pendingOnly = true;

  Future<void> _clear(ChequeRow row) => runGuarded(
    context,
    () => ref.read(paymentServiceProvider).clearCheque(row.cheque.id, user: ref.read(currentUserProvider)!),
  );

  Future<void> _bounce(ChequeRow row) async {
    final reason = await askReason(context, title: '${Strings.markBounced}: ${row.cheque.chequeNo}', required: true);
    if (reason == null || !mounted) return;
    await runGuarded(
      context,
      () => ref
          .read(paymentServiceProvider)
          .bounceCheque(row.cheque.id, reason: reason, user: ref.read(currentUserProvider)!),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(currentUserProvider)?.can(Perm.payOut) ?? false;
    final rows = ref.watch(_chequesProvider(_pendingOnly));
    final scheme = Theme.of(context).colorScheme;
    final today = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilterChip(
              label: const Text(Strings.pendingOnly),
              selected: _pendingOnly,
              onSelected: (v) => setState(() => _pendingOnly = v),
            ),
          ),
        ),
        Expanded(
          child: rows.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('$e')),
            data: (list) {
              final pending = list.where((r) => r.cheque.status == ChequeStatus.pending).toList();
              final endOfToday = DateTime(today.year, today.month, today.day, 23, 59);
              final week = endOfToday.add(const Duration(days: 7));
              int sum(Iterable<ChequeRow> rs) => rs.fold(0, (s, r) => s + r.payment.amount);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SummaryStrip(
                    items: [
                      SummaryItem(
                        'شيكات مستلمة تحت التحصيل',
                        formatMoney(sum(pending.where((r) => r.isReceived))),
                        icon: Icons.call_received,
                        tone: AppColors.good,
                      ),
                      if (isAdmin)
                        SummaryItem(
                          'شيكات صادرة لم تُصرف',
                          formatMoney(sum(pending.where((r) => !r.isReceived))),
                          icon: Icons.call_made,
                          tone: AppColors.warn,
                        ),
                      SummaryItem(
                        'مستحقة حتى اليوم',
                        '${pending.where((r) => !r.cheque.dueDate.isAfter(endOfToday)).length}',
                        icon: Icons.alarm_outlined,
                        tone: AppColors.bad,
                      ),
                      SummaryItem(
                        'تستحق خلال أسبوع',
                        '${pending.where((r) => r.cheque.dueDate.isAfter(endOfToday) && !r.cheque.dueDate.isAfter(week)).length}',
                        icon: Icons.event_outlined,
                      ),
                    ],
                  ),
                  Expanded(
                    child: DataList<ChequeRow>(
                      rows: list,
                      emptyText: Strings.noCheques,
                      // Pending cheques that are due (or overdue) stand out.
                      rowColor: (r) => r.cheque.status == ChequeStatus.pending && !r.cheque.dueDate.isAfter(endOfToday)
                          ? scheme.tertiaryContainer.withValues(alpha: 0.5)
                          : null,
                      trailing: isAdmin
                          ? (r) => r.cheque.status == ChequeStatus.pending
                                ? PopupMenuButton<void Function()>(
                                    onSelected: (f) => f(),
                                    itemBuilder: (_) => [
                                      PopupMenuItem(value: () => _clear(r), child: const Text(Strings.markCleared)),
                                      PopupMenuItem(value: () => _bounce(r), child: const Text(Strings.markBounced)),
                                    ],
                                  )
                                : const SizedBox()
                          : null,
                      columns: [
                        DataListColumn(Strings.dueDate, sortValue: (r) => r.cheque.dueDate, (r) => Text(formatDate(r.cheque.dueDate))),
                        DataListColumn(Strings.chequeNo, (r) => Text(r.cheque.chequeNo)),
                        DataListColumn(Strings.bank, (r) => Text(r.cheque.bank ?? '')),
                        DataListColumn(Strings.party, flex: 2, (r) => Text(r.partyName)),
                        DataListColumn(
                          Strings.direction,
                          numeric: true,
                          (r) => Text(r.isReceived ? Strings.chequeIn : Strings.chequeOut),
                        ),
                        DataListColumn(
                          Strings.amount,
                          numeric: true,
                          (r) =>
                              Text(formatMoney(r.payment.amount), style: const TextStyle(fontWeight: FontWeight.w700)),
                        ),
                        DataListColumn(Strings.status, numeric: true, (r) => chequePill(r.cheque.status)),
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

final _paymentsProvider = StreamProvider.autoDispose.family<List<PaymentRow>, String>(
  (ref, direction) => ref.watch(paymentServiceProvider).watchPayments(direction: direction),
);

final _chequesProvider = StreamProvider.autoDispose.family<List<ChequeRow>, bool>(
  (ref, pendingOnly) =>
      ref.watch(paymentServiceProvider).watchCheques(status: pendingOnly ? ChequeStatus.pending : null),
);

/// Owner: corrects a saved payment. The number stays; balances, the invoice
/// it pays and the books follow. The change and its reason are logged.
class CorrectPaymentDialog extends ConsumerStatefulWidget {
  const CorrectPaymentDialog({super.key, required this.row});

  final PaymentRow row;

  @override
  ConsumerState<CorrectPaymentDialog> createState() => _CorrectPaymentDialogState();
}

class _CorrectPaymentDialogState extends ConsumerState<CorrectPaymentDialog> {
  late final Payment _p = widget.row.payment;
  late final _amount = TextEditingController(text: formatMoney(_p.amount).replaceAll(',', ''));
  late final _notes = TextEditingController(text: _p.notes ?? '');
  final _reason = TextEditingController();
  final _form = GlobalKey<FormState>();
  late DateTime _date = _p.date;
  late int _partyId = _p.partyId;
  late String _method = _p.method;

  @override
  void dispose() {
    for (final c in [_amount, _notes, _reason]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final ok = await runGuarded(context, () async {
      await ref.read(paymentServiceProvider).correct(
            _p.id,
            amount: parseMoney(_amount.text),
            date: _date,
            partyId: _partyId,
            method: _method,
            notes: _notes.text,
            reason: _reason.text,
            user: ref.read(currentUserProvider)!,
          );
      return true;
    });
    if (ok == true && mounted) {
      showToast(context, 'تم تعديل الدفعة ${_p.number}');
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final newAmount = parseMoney(_amount.text);
    return AlertDialog(
      title: Text('تعديل الدفعة ${_p.number} — ${widget.row.partyName}'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _form,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('المسجل: ${formatMoney(_p.amount)} بتاريخ ${formatDate(_p.date)}',
                style: const TextStyle(color: AppColors.muted)),
            const SizedBox(height: 12),
            MoneyField(controller: _amount, label: 'المبلغ الصحيح', required: true, onChanged: (_) => setState(() {})),
            if (newAmount != null && newAmount != _p.amount)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'الفرق ${formatMoney(newAmount - _p.amount)}: يتعدل رصيد '
                  '${_p.partyType == PartyType.supplier ? 'المورد' : 'العميل'} والفاتورة المرتبطة والقيود تلقائياً',
                  style: const TextStyle(color: AppColors.info),
                ),
              ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                final d = await showDatePicker(
                  context: context,
                  initialDate: _date,
                  firstDate: DateTime(2000),
                  lastDate: DateTime.now().add(const Duration(days: 365)),
                );
                if (d != null) setState(() => _date = DateTime(d.year, d.month, d.day, _date.hour, _date.minute));
              },
              icon: const Icon(Icons.event),
              label: Text('التاريخ ${formatDate(_date)}'),
            ),
            const SizedBox(height: 12),
            TextField(controller: _notes, decoration: const InputDecoration(labelText: Strings.notes)),
            const SizedBox(height: 12),
            _PartyPicker(
              supplier: _p.partyType == PartyType.supplier,
              value: _partyId,
              onChanged: (v) => setState(() => _partyId = v),
            ),
            if (_partyId != _p.partyId && _p.invoiceRefId != null && _p.invoiceRefType != RefType.supplierAdvance)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('بنقلها لطرف آخر تُفك من الفاتورة أو الأمر المرتبط وتصبح تحت حساب الطرف الجديد',
                    style: TextStyle(color: AppColors.warn, fontSize: 12)),
              ),
            if (_p.method != PaymentMethod.cheque) ...[
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: PaymentMethod.cash, label: Text(Strings.methodCash)),
                  ButtonSegment(value: PaymentMethod.bank, label: Text(Strings.methodBank)),
                ],
                selected: {_method},
                onSelectionChanged: (s) => setState(() => _method = s.single),
              ),
            ],
            const SizedBox(height: 12),
            TextFormField(
              controller: _reason,
              decoration: const InputDecoration(labelText: 'سبب التعديل (اختياري، يُحفظ في سجل العمليات)'),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.cancel)),
        FilledButton.icon(onPressed: _save, icon: const Icon(Icons.save), label: const Text('حفظ التعديل')),
      ],
    );
  }
}

/// The supplier or customer a corrected payment belongs to.
class _PartyPicker extends ConsumerWidget {
  const _PartyPicker({required this.supplier, required this.value, required this.onChanged});

  final bool supplier;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parties = ref.watch(partyServiceProvider);
    return StreamBuilder<List<(int, String)>>(
      stream: supplier
          ? parties.watchSuppliers().map((l) => [for (final s in l) (s.id, s.name)])
          : parties.watchCustomers().map((l) => [for (final c in l) (c.id, c.name)]),
      builder: (context, snap) {
        final items = snap.data ?? const <(int, String)>[];
        return DropdownButtonFormField<int>(
          key: ValueKey(('party', items.length)),
          initialValue: items.any((e) => e.$1 == value) ? value : null,
          isExpanded: true,
          decoration: InputDecoration(labelText: supplier ? 'المورد' : 'العميل'),
          items: [for (final (id, name) in items) DropdownMenuItem(value: id, child: Text(name))],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        );
      },
    );
  }
}
