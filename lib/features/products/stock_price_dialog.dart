import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/services/price_list_service.dart';
import '../../core/services/product_service.dart';
import '../../core/services/stock_price_service.dart';
import '../../core/widgets/feedback.dart';

Future<void> showStockByPrice(BuildContext context, ProductRow row) =>
    showDialog<void>(context: context, builder: (_) => _StockByPriceDialog(row: row));

/// How much of a product is at the old price and at the new price, and where.
class _StockByPriceDialog extends ConsumerStatefulWidget {
  const _StockByPriceDialog({required this.row});

  final ProductRow row;

  @override
  ConsumerState<_StockByPriceDialog> createState() => _StockByPriceDialogState();
}

class _StockByPriceDialogState extends ConsumerState<_StockByPriceDialog> {
  late Future<List<StockPriceLine>> _lines = _load();

  Future<List<StockPriceLine>> _load() => ref.read(stockPriceServiceProvider).breakdown(widget.row.product.id);

  Future<void> _assign() async {
    final history = await ref.read(priceListServiceProvider).history(widget.row.product.id);
    final usable = history.where((h) => h.item.status == PriceRowStatus.ok && h.item.price != null).toList();
    if (!mounted) return;
    if (usable.isEmpty) {
      await showMessage(context, 'هذا الصنف غير موجود في أي قائمة أسعار');
      return;
    }
    final chosen = await showDialog<PriceHistoryRow>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('القائمة التي دخل بها هذا المخزون'),
        children: [
          for (final h in usable)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, h),
              child: Text('${h.list.listType} V${h.list.versionNo} (PL-${h.list.id}) — ${formatMoney(h.item.price!)}'),
            ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    final ok = await runGuarded(context, () async {
      await ref
          .read(stockPriceServiceProvider)
          .assignUnknown(widget.row.product.id, chosen.list.id, user: ref.read(currentUserProvider)!);
      return true;
    });
    if (ok == true && mounted) setState(() => _lines = _load());
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.row.product;
    final isAdmin = ref.watch(currentUserProvider)?.seesCost ?? false;
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text('المخزون حسب السعر: ${p.code} — ${p.nameAr}'),
      content: SizedBox(
        width: 760,
        height: 380,
        child: FutureBuilder<List<StockPriceLine>>(
          future: _lines,
          builder: (context, snap) {
            final lines = snap.data;
            if (lines == null) return const Center(child: CircularProgressIndicator());
            if (lines.isEmpty) return const Center(child: Text('لا يوجد مخزون من هذا الصنف'));
            return SingleChildScrollView(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columnSpacing: 18,
                  columns: [
                    const DataColumn(label: Text('الحالة')),
                    const DataColumn(label: Text('الكمية'), numeric: true),
                    const DataColumn(label: Text('سعر القائمة'), numeric: true),
                    const DataColumn(label: Text('السعر الحالي'), numeric: true),
                    const DataColumn(label: Text('القائمة')),
                    const DataColumn(label: Text('المكان')),
                    if (isAdmin) const DataColumn(label: Text('التكلفة الفعلية'), numeric: true),
                  ],
                  rows: [
                    for (final l in lines)
                      DataRow(cells: [
                        DataCell(Text(
                          l.kind.label,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: l.kind == StockPriceKind.current ? scheme.primary : (l.kind == StockPriceKind.old ? scheme.error : null),
                          ),
                        )),
                        DataCell(Text(formatQty(l.qty))),
                        DataCell(Text(l.listPrice == null ? '—' : formatMoney(l.listPrice!))),
                        DataCell(Text(l.currentPrice == null ? '—' : formatMoney(l.currentPrice!))),
                        DataCell(Text(l.versionLabel ?? '—')),
                        DataCell(Text(l.places.entries.map((e) => '${e.key}: ${formatQty(e.value)}').join('، '))),
                        if (isAdmin) DataCell(Text(formatMoney(l.value))),
                      ]),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      actions: [
        if (isAdmin)
          FutureBuilder<List<StockPriceLine>>(
            future: _lines,
            builder: (context, snap) => (snap.data ?? const []).any((l) => l.kind == StockPriceKind.unknown)
                ? TextButton(onPressed: _assign, child: const Text('تحديد قائمة المخزون غير المحدد'))
                : const SizedBox.shrink(),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.close)),
      ],
    );
  }
}
