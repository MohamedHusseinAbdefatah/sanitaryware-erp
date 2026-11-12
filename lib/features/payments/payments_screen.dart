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

class _PaymentList extends ConsumerWidget {
  const _PaymentList({required this.direction});

  final String direction;

  Future<void> _cancel(BuildContext context, WidgetRef ref, PaymentRow row) async {
    final reason = await askReason(context, title: '${Strings.cancelPayment} ${row.payment.number}');
    if (reason == null || !context.mounted) return;
    await runGuarded(
      context,
      () =>
          ref.read(paymentServiceProvider).cancel(row.payment.id, reason: reason, user: ref.read(currentUserProvider)!),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAdmin = ref.watch(currentUserProvider)?.can(Perm.payOut) ?? false;
    final rows = ref.watch(_paymentsProvider(direction));
    return rows.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (list) {
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
            Expanded(child: _table(context, ref, list, isAdmin)),
          ],
        );
      },
    );
  }

  Widget _table(BuildContext context, WidgetRef ref, List<PaymentRow> list, bool isAdmin) {
    return DataList<PaymentRow>(
      rows: list,
      emptyText: Strings.noPayments,
      rowColor: (r) => r.payment.status == DocStatus.cancelled ? AppColors.canvas : null,
      trailing: (r) => PopupMenuButton<VoidCallback>(
        onSelected: (f) => f(),
        itemBuilder: (_) => [
          PopupMenuItem(value: () => printReceipt(context, ref, r), child: const Text(Strings.printReceipt)),
          if (isAdmin && r.payment.status == DocStatus.active)
            PopupMenuItem(value: () => _cancel(context, ref, r), child: const Text(Strings.cancelPayment)),
        ],
      ),
      columns: [
        DataListColumn(
          Strings.number,
          (r) => Text(r.payment.number, style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        DataListColumn(Strings.date, flex: 2, (r) => Text(formatDateTime(r.payment.date))),
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
              ? const StatusPill.bad(Strings.cancelled)
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
    RefType.supplierAdvance => 'دفعة مقدمة بسعر قائمة',
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
    final reason = await askReason(context, title: '${Strings.markBounced}: ${row.cheque.chequeNo}');
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
                        DataListColumn(Strings.dueDate, (r) => Text(formatDate(r.cheque.dueDate))),
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
