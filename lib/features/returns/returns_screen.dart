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
import '../../core/widgets/data_list.dart';
import '../../core/widgets/feedback.dart';

class ReturnsScreen extends ConsumerStatefulWidget {
  const ReturnsScreen({super.key});

  @override
  ConsumerState<ReturnsScreen> createState() => _ReturnsScreenState();
}

class _ReturnsScreenState extends ConsumerState<ReturnsScreen> {
  String? _kind;

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(currentUserProvider)?.isAdmin ?? false;
    final rows = ref.watch(_returnsProvider(_kind));
    final scheme = Theme.of(context).colorScheme;
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
            data: (list) => DataList<ReturnRow>(
              rows: list,
              emptyText: Strings.noReturns,
              onTap: (r) => showDialog<void>(context: context, builder: (_) => _ReturnDialog(row: r)),
              rowColor: (r) => r.doc.status == DocStatus.cancelled
                  ? scheme.errorContainer.withValues(alpha: 0.3)
                  : null,
              columns: [
                DataListColumn(Strings.number, (r) => Text(r.doc.number)),
                DataListColumn(Strings.date, flex: 2, (r) => Text(formatDateTime(r.doc.date))),
                DataListColumn(Strings.kind, numeric: true,
                    (r) => Text(r.doc.kind == ReturnKind.sale ? Strings.saleReturn : Strings.purchaseReturn)),
                DataListColumn(Strings.party, flex: 3, (r) => Text(r.partyName ?? Strings.cashCustomer)),
                DataListColumn(Strings.originalInvoice, (r) => Text(r.invoiceNumber ?? '—')),
                DataListColumn(Strings.total, numeric: true, (r) => Text(formatMoney(r.doc.total))),
                DataListColumn(Strings.refunded, numeric: true, (r) => Text(formatMoney(r.doc.refundAmount))),
                DataListColumn(Strings.status, numeric: true, (r) => Text(
                      r.doc.status == DocStatus.cancelled ? Strings.cancelled : '',
                      style: TextStyle(color: scheme.error),
                    )),
              ],
            ),
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
    final isAdmin = ref.watch(currentUserProvider)?.isAdmin ?? false;
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
