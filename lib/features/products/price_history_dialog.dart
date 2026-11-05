import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/pricing_math.dart';
import '../../core/providers.dart';
import '../../core/services/price_list_service.dart';
import '../../core/services/product_service.dart';

Future<void> showPriceHistory(BuildContext context, ProductRow row) =>
    showDialog<void>(context: context, builder: (_) => _PriceHistoryDialog(row: row));

String _date(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Every price the product has had, version by version. Nothing here is ever
/// overwritten.
class _PriceHistoryDialog extends ConsumerWidget {
  const _PriceHistoryDialog({required this.row});

  final ProductRow row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AlertDialog(
      title: Text('سجل الأسعار: ${row.product.code} — ${row.product.nameAr}'),
      content: SizedBox(
        width: 620,
        height: 380,
        child: FutureBuilder<List<PriceHistoryRow>>(
          future: ref.read(priceListServiceProvider).history(row.product.id),
          builder: (context, snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final rows = snap.data!;
            if (rows.isEmpty) return const Center(child: Text('لا يوجد سعر معتمد لهذا الصنف'));
            return ListView(
              children: [
                for (final r in rows)
                  ListTile(
                    dense: true,
                    title: Text('${r.item.price == null ? '—' : formatMoney(r.item.price!)} — '
                        '${r.brandName ?? ''} ${r.list.listType} V${r.list.versionNo} (PL-${r.list.id})'),
                    subtitle: Text('من ${_date(r.list.effectiveFrom)}'
                        '${r.list.effectiveTo == null ? ' (مفتوحة)' : ' إلى ${_date(r.list.effectiveTo!)}'} · '
                        '${VatStatus.label(r.list.vatStatus)}'
                        '${r.item.status == PriceRowStatus.ok ? '' : ' · غير معتمد'}'),
                  ),
              ],
            );
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.close))],
    );
  }
}
