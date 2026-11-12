import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/services/doc_types.dart';
import '../../core/services/return_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/data_list.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/list_kit.dart';

class ReturnsScreen extends ConsumerStatefulWidget {
  const ReturnsScreen({super.key});

  @override
  ConsumerState<ReturnsScreen> createState() => _ReturnsScreenState();
}

class _ReturnsScreenState extends ConsumerState<ReturnsScreen> {
  String? _kind;

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(currentUserProvider)?.can(Perm.purchase) ?? false;
    final rows = ref.watch(_returnsProvider(_kind));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: Strings.returns,
          actions: [
            SegmentedButton<String?>(
              segments: const [
                ButtonSegment(value: null, label: Text(Strings.all)),
                ButtonSegment(value: ReturnKind.sale, label: Text(Strings.saleReturns)),
                ButtonSegment(value: ReturnKind.purchase, label: Text(Strings.purchaseReturns)),
              ],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() => _kind = s.single),
            ),
            FilledButton.icon(
              onPressed: () => context.go('/returns/new?kind=${ReturnKind.sale}'),
              icon: const Icon(Icons.assignment_return_outlined),
              label: const Text(Strings.newSaleReturn),
            ),
            if (isAdmin)
              FilledButton.tonalIcon(
                onPressed: () => context.go('/returns/new?kind=${ReturnKind.purchase}'),
                icon: const Icon(Icons.assignment_return_outlined),
                label: const Text(Strings.newPurchaseReturn),
              ),
          ],
        ),
        Expanded(
          child: rows.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('$e')),
            data: (list) {
              final active = list.where((r) => r.doc.status == DocStatus.active);
              int sum(Iterable<ReturnRow> rs) => rs.fold(0, (s, r) => s + r.doc.total);
              final now = DateTime.now();
              final month = active.where((r) => r.doc.date.year == now.year && r.doc.date.month == now.month);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SummaryStrip(items: [
                    SummaryItem('مرتجعات البيع (الشهر)', formatMoney(sum(month.where((r) => r.doc.kind == ReturnKind.sale))),
                        icon: Icons.assignment_return_outlined, tone: AppColors.warn),
                    if (isAdmin)
                      SummaryItem('مرتجعات الشراء (الشهر)',
                          formatMoney(sum(month.where((r) => r.doc.kind == ReturnKind.purchase))),
                          icon: Icons.local_shipping_outlined),
                    SummaryItem('المردود نقداً (الشهر)', formatMoney(month.fold(0, (s, r) => s + r.doc.refundAmount)),
                        icon: Icons.payments_outlined),
                    SummaryItem('عدد المرتجعات', '${active.length}', icon: Icons.numbers),
                  ]),
                  Expanded(
                    child: DataList<ReturnRow>(
                      rows: list,
                      emptyText: Strings.noReturns,
                      onTap: (r) => showDialog<void>(context: context, builder: (_) => _ReturnDialog(row: r)),
                      rowColor: (r) => r.doc.status == DocStatus.cancelled ? AppColors.canvas : null,
                      columns: [
                        DataListColumn(Strings.number, (r) => Text(r.doc.number, style: const TextStyle(fontWeight: FontWeight.w700))),
                        DataListColumn(Strings.date, flex: 2, (r) => Text(formatDateTime(r.doc.date))),
                        DataListColumn(Strings.kind, numeric: true, (r) => r.doc.kind == ReturnKind.sale
                            ? const StatusPill.warn(Strings.saleReturn)
                            : const StatusPill(Strings.purchaseReturn)),
                        DataListColumn(Strings.party, flex: 3, (r) => Text(r.partyName ?? Strings.cashCustomer)),
                        DataListColumn(Strings.originalInvoice, (r) => r.doc.originalInvoiceId == null
                            ? const Text('—')
                            : InkWell(
                                onTap: () => context.go(
                                    '/${r.doc.kind == ReturnKind.sale ? 'sales' : 'purchases'}/${r.doc.originalInvoiceId}'),
                                child: Text(r.invoiceNumber ?? '',
                                    style: const TextStyle(color: AppColors.brand, fontWeight: FontWeight.w600)),
                              )),
                        DataListColumn(Strings.total, numeric: true,
                            (r) => Text(formatMoney(r.doc.total), style: const TextStyle(fontWeight: FontWeight.w700))),
                        DataListColumn(Strings.refunded, numeric: true, (r) => Text(formatMoney(r.doc.refundAmount))),
                        DataListColumn(Strings.status, numeric: true, (r) => r.doc.status == DocStatus.cancelled
                            ? const StatusPill.bad(Strings.cancelled)
                            : const StatusPill.good('ساري')),
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

/// A return's lines, with cancel for the admin.
class _ReturnDialog extends ConsumerWidget {
  const _ReturnDialog({required this.row});

  final ReturnRow row;

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final reason = await askReason(context, title: '${Strings.cancelReturn} ${row.doc.number}');
    if (reason == null || !context.mounted) return;
    final ok = await runGuarded(context, () async {
      await ref.read(returnServiceProvider).cancel(row.doc.id, reason: reason, user: ref.read(currentUserProvider)!);
      return true;
    });
    if (ok == true && context.mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAdmin = ref.watch(currentUserProvider)?.can(Perm.cancel) ?? false;
    final doc = row.doc;
    return AlertDialog(
      title: Text('${doc.kind == ReturnKind.sale ? Strings.saleReturn : Strings.purchaseReturn} ${doc.number}'),
      content: SizedBox(
        width: 600,
        child: FutureBuilder<List<ReturnDetailLine>>(
          future: ref.read(returnServiceProvider).lines(doc.id),
          builder: (context, snap) {
            final lines = snap.data;
            if (lines == null) return const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()));
            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${Strings.party}: ${row.partyName ?? Strings.cashCustomer}'
                      '${row.invoiceNumber == null ? '' : ' — ${Strings.originalInvoice}: ${row.invoiceNumber}'}'),
                  const SizedBox(height: 8),
                  DataTable(
                    columns: const [
                      DataColumn(label: Text(Strings.code)),
                      DataColumn(label: Text(Strings.productName)),
                      DataColumn(label: Text(Strings.qty), numeric: true),
                      DataColumn(label: Text(Strings.price), numeric: true),
                      DataColumn(label: Text(Strings.lineTotal), numeric: true),
                    ],
                    rows: [
                      for (final l in lines)
                        DataRow(cells: [
                          DataCell(Text(l.productCode)),
                          DataCell(Text(l.productName)),
                          DataCell(Text(formatQty(l.item.qty))),
                          DataCell(Text(formatMoney(l.item.unitPrice))),
                          DataCell(Text(formatMoney(l.item.lineTotal))),
                        ]),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text('${Strings.total}: ${formatMoney(doc.total)} — ${Strings.refunded}: ${formatMoney(doc.refundAmount)}'),
                  if (doc.notes != null) Text('${Strings.notes}: ${doc.notes}'),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        if (isAdmin && doc.status == DocStatus.active)
          TextButton(
            onPressed: () => _cancel(context, ref),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            child: const Text(Strings.cancelReturn),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.close)),
      ],
    );
  }
}

final _returnsProvider = StreamProvider.autoDispose.family<List<ReturnRow>, String?>(
  (ref, kind) => ref.watch(returnServiceProvider).watchList(kind: kind),
);
