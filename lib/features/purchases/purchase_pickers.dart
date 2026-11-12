import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/dates.dart';
import '../../core/db/database.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/search_text.dart';
import '../../core/services/price_list_service.dart';
import '../../core/services/purchase_order_service.dart';

/// Picks an approved purchase order still waiting for goods, for
/// [supplierId] when one is chosen.
Future<PoDetail?> pickPurchaseOrder(BuildContext context, {int? supplierId}) =>
    showDialog<PoDetail>(context: context, builder: (_) => _OrderPicker(supplierId: supplierId));

class _OrderPicker extends ConsumerWidget {
  const _OrderPicker({this.supplierId});

  final int? supplierId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AlertDialog(
      title: const Text('استلام من أمر شراء'),
      content: SizedBox(
        width: 620,
        height: 420,
        child: FutureBuilder<List<PoDetail>>(
          future: PurchaseOrderService(ref.read(databaseProvider)).openOrders(supplierId: supplierId),
          builder: (context, snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final orders = snap.data!;
            if (orders.isEmpty) {
              return Center(
                child: Text(supplierId == null
                    ? 'لا توجد أوامر شراء معتمدة تنتظر الاستلام.'
                    : 'لا توجد أوامر شراء معتمدة لهذا المورد تنتظر الاستلام.'),
              );
            }
            return ListView.separated(
              itemCount: orders.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final o = orders[i];
                final open = o.lines.where((l) => l.remaining > 0).toList();
                return ListTile(
                  leading: const Icon(Icons.assignment_outlined),
                  title: Text('${o.order.number} · ${o.supplierName}'),
                  subtitle: Text(
                    '${formatDate(o.order.orderDate)} · ${open.length} صنف متبقي · '
                    'المتبقي ${formatMoney(o.remainingValue)}',
                  ),
                  trailing: const Icon(Icons.chevron_left),
                  onTap: () => Navigator.pop(context, o),
                );
              },
            );
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء'))],
    );
  }
}

/// One product picked from a price list, with its quantity.
class PickedItem {
  const PickedItem(this.productId, this.qty);

  final int productId;
  final int qty;
}

/// Picks several products from one price list at once: choose the list,
/// search, tick, set quantities, add.
Future<List<PickedItem>?> pickFromPriceList(BuildContext context) =>
    showDialog<List<PickedItem>>(context: context, builder: (_) => const _ListPicker());

class _ListPicker extends ConsumerStatefulWidget {
  const _ListPicker();

  @override
  ConsumerState<_ListPicker> createState() => _ListPickerState();
}

class _ListPickerState extends ConsumerState<_ListPicker> {
  int? _listId;
  List<PriceListItem> _items = const [];
  String _search = '';
  final _picked = <int, TextEditingController>{}; // product id -> qty

  @override
  void dispose() {
    for (final c in _picked.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load(int listId) async {
    final items = await ref.read(priceListServiceProvider).items(listId);
    if (!mounted) return;
    setState(() {
      _listId = listId;
      _items = items.where((i) => i.productId != null && i.status == PriceRowStatus.ok).toList();
    });
  }

  void _toggle(int productId, bool on) {
    setState(() {
      if (on) {
        _picked[productId] = TextEditingController(text: '1');
      } else {
        _picked.remove(productId)?.dispose();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final lists = (ref.watch(_liveListsProvider).valueOrNull ?? const <PriceListSummary>[])
        .where((s) => s.list.status == PriceListStatus.active)
        .toList();
    final q = foldForSearch(_search);
    final shown = _items
        .where((i) => q.isEmpty || foldForSearch('${i.manufacturerCode} ${i.name} ${i.variant ?? ''}').contains(q))
        .take(300)
        .toList();
    final ready = _picked.entries.every((e) => (parseQty(e.value.text) ?? 0) > 0);
    return AlertDialog(
      title: const Text('إضافة أصناف من قائمة أسعار'),
      content: SizedBox(
        width: 760,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<int>(
              isExpanded: true,
              initialValue: _listId,
              decoration: const InputDecoration(labelText: 'قائمة الأسعار'),
              items: [
                for (final s in lists)
                  DropdownMenuItem(
                    value: s.list.id,
                    child: Text('PL-${s.list.id} · ${s.brandName ?? ''} · ${s.list.listType} V${s.list.versionNo} — ${s.list.name}',
                        overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) {
                if (v != null) _load(v);
              },
            ),
            const SizedBox(height: 8),
            TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'ابحث بالكود أو الاسم أو اللون',
                isDense: true,
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
            const SizedBox(height: 4),
            Text('${_items.length} صنف في القائمة · المحدد ${_picked.length}'),
            const SizedBox(height: 4),
            Expanded(
              child: _listId == null
                  ? const Center(child: Text('اختر قائمة الأسعار'))
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (context, i) {
                        final item = shown[i];
                        final id = item.productId!;
                        final qty = _picked[id];
                        return Row(
                          children: [
                            Checkbox(value: qty != null, onChanged: (v) => _toggle(id, v ?? false)),
                            Expanded(
                              flex: 2,
                              child: Text(item.manufacturerCode, textDirection: TextDirection.ltr),
                            ),
                            Expanded(
                              flex: 5,
                              child: Text('${item.name}${item.variant == null ? '' : ' · ${item.variant}'}',
                                  overflow: TextOverflow.ellipsis),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(item.price == null ? '' : formatMoney(item.price!), textAlign: TextAlign.end),
                            ),
                            const SizedBox(width: 12),
                            SizedBox(
                              width: 80,
                              child: qty == null
                                  ? const SizedBox()
                                  : TextField(
                                      controller: qty,
                                      textAlign: TextAlign.center,
                                      decoration: const InputDecoration(isDense: true, hintText: 'الكمية'),
                                      onChanged: (_) => setState(() {}),
                                    ),
                            ),
                          ],
                        );
                      },
                    ),
            ),
            if (shown.length == 300) const Text('يظهر أول 300 صنف؛ اكتب في البحث للوصول للباقي.'),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(
          onPressed: _picked.isEmpty || !ready
              ? null
              : () => Navigator.pop(context, [
                    for (final e in _picked.entries) PickedItem(e.key, parseQty(e.value.text)!),
                  ]),
          child: Text('إضافة (${_picked.length})'),
        ),
      ],
    );
  }
}

final _liveListsProvider = StreamProvider.autoDispose<List<PriceListSummary>>(
  (ref) => ref.watch(priceListServiceProvider).watchSummaries(),
);
