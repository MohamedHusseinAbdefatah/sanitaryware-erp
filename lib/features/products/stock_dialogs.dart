import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/services/product_service.dart';
import '../../core/services/stock_service.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/number_fields.dart';

Future<void> showStockAdjust(BuildContext context, ProductRow row) =>
    showDialog<void>(context: context, builder: (_) => _StockAdjustDialog(row: row));

Future<void> showStockCard(BuildContext context, ProductRow row) =>
    showDialog<void>(context: context, builder: (_) => _StockCardDialog(row: row));

String movementTypeLabel(String type) => switch (type) {
      StockMovementType.opening => Strings.mvOpening,
      StockMovementType.purchase => Strings.mvPurchase,
      StockMovementType.sale => Strings.mvSale,
      StockMovementType.saleCancel => Strings.mvSaleCancel,
      StockMovementType.saleReturn => Strings.mvSaleReturn,
      StockMovementType.purchaseReturn => Strings.mvPurchaseReturn,
      StockMovementType.adjustment => Strings.mvAdjustment,
      _ => type,
    };

class _StockAdjustDialog extends ConsumerStatefulWidget {
  const _StockAdjustDialog({required this.row});

  final ProductRow row;

  @override
  ConsumerState<_StockAdjustDialog> createState() => _StockAdjustDialogState();
}

class _StockAdjustDialogState extends ConsumerState<_StockAdjustDialog> {
  final _form = GlobalKey<FormState>();
  final _qty = TextEditingController();
  final _reason = TextEditingController();
  bool _increase = false;

  @override
  void dispose() {
    _qty.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final qty = qtyOrZero(_qty);
    final ok = await runGuarded(context, () async {
      await ref.read(stockServiceProvider).adjust(
            productId: widget.row.product.id,
            delta: _increase ? qty : -qty,
            reason: _reason.text,
            userId: ref.read(currentUserProvider)?.id,
          );
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.row;
    return AlertDialog(
      title: Text('${Strings.stockAdjust}: ${r.product.nameAr}'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('${Strings.currentStock}: ${formatQty(r.stock)} ${r.unitName ?? ''}'),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text(Strings.decrease), icon: Icon(Icons.remove)),
                  ButtonSegment(value: true, label: Text(Strings.increase), icon: Icon(Icons.add)),
                ],
                selected: {_increase},
                onSelectionChanged: (s) => setState(() => _increase = s.single),
              ),
              QtyField(
                controller: _qty,
                label: Strings.qty,
                allowDecimal: r.unitAllowsDecimal,
                required: true,
              ),
              TextFormField(
                controller: _reason,
                decoration: const InputDecoration(labelText: Strings.reasonHint),
                validator: (v) => (v ?? '').trim().isEmpty ? Strings.required : null,
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

/// Every movement of one product, newest first, with the running balance.
class _StockCardDialog extends ConsumerWidget {
  const _StockCardDialog({required this.row});

  final ProductRow row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AlertDialog(
      title: Text('${Strings.stockCard}: ${row.product.code} — ${row.product.nameAr}'),
      content: SizedBox(
        width: 720,
        height: 480,
        child: StreamBuilder<List<StockMovement>>(
          stream: ref.watch(stockServiceProvider).watchMovements(row.product.id),
          builder: (context, snap) {
            final list = snap.data;
            if (list == null) return const Center(child: CircularProgressIndicator());
            if (list.isEmpty) return const Center(child: Text(Strings.noMovements));
            // Running balance after each movement, computed oldest first.
            final balances = <int>[];
            var running = 0;
            for (final m in list.reversed) {
              running += m.qty;
              balances.add(running);
            }
            final after = balances.reversed.toList();
            return SingleChildScrollView(
              child: DataTable(
                columnSpacing: 16,
                columns: const [
                  DataColumn(label: Text(Strings.date)),
                  DataColumn(label: Text(Strings.movementType)),
                  DataColumn(label: Text(Strings.qty), numeric: true),
                  DataColumn(label: Text(Strings.balanceAfter), numeric: true),
                  DataColumn(label: Text(Strings.notes)),
                ],
                rows: [
                  for (var i = 0; i < list.length; i++)
                    DataRow(cells: [
                      DataCell(Text(formatDateTime(list[i].date))),
                      DataCell(Text(movementTypeLabel(list[i].type))),
                      DataCell(Text(
                        list[i].qty > 0 ? '+${formatQty(list[i].qty)}' : formatQty(list[i].qty),
                        textDirection: TextDirection.ltr,
                      )),
                      DataCell(Text(formatQty(after[i]))),
                      DataCell(Text(list[i].note ?? '')),
                    ]),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.close)),
      ],
    );
  }
}
