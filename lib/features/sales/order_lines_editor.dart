import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/quantity.dart';
import '../../core/services/product_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/pickers.dart';
import '../products/products_screen.dart';
import 'product_browser.dart';

/// One product line of a new sales order, quotation or purchase order.
class OrderLine {
  OrderLine(this.row, {this.priceListId})
      : qty = TextEditingController(text: '1'),
        extra = TextEditingController();

  final ProductRow row;

  /// The price list version chosen when several can price the product.
  final int? priceListId;
  final TextEditingController qty;
  final TextEditingController extra;

  int? get qtyValue => parseQty(qty.text, allowDecimal: row.unitAllowsDecimal);

  void dispose() {
    qty.dispose();
    extra.dispose();
  }
}

/// The product part of an order form, as on the invoice: a search that clears
/// after each pick, the product browser (F3), and a table of lines. Picking a
/// product already on the order adds one more of it.
class OrderLinesEditor extends ConsumerStatefulWidget {
  const OrderLinesEditor({
    super.key,
    required this.lines,
    required this.create,
    required this.onChanged,
    this.withDiscount = false,
    this.inStockOnly = true,
  });

  final List<OrderLine> lines;

  /// Makes the line for a picked product, or null when the person cancels
  /// (for example when asked which price list).
  final Future<OrderLine?> Function(ProductRow row) create;
  final VoidCallback onChanged;
  final bool withDiscount;

  /// Whether the browser starts on products in stock (sales) or on all
  /// products (purchases).
  final bool inStockOnly;

  @override
  ConsumerState<OrderLinesEditor> createState() => _OrderLinesEditorState();
}

class _OrderLinesEditorState extends ConsumerState<OrderLinesEditor> {
  int _searchKey = 0;
  final _searchFocus = FocusNode();

  @override
  void dispose() {
    _searchFocus.dispose();
    super.dispose();
  }

  OrderLine? _existing(int productId) =>
      widget.lines.where((l) => l.row.product.id == productId).firstOrNull;

  Future<void> _add(ProductRow row, {bool refocus = true}) async {
    final existing = _existing(row.product.id);
    if (existing != null) {
      existing.qty.text = formatQty((existing.qtyValue ?? 0) + qtyScale);
    } else {
      final line = await widget.create(row);
      if (line == null || !mounted) return;
      widget.lines.add(line);
    }
    setState(() => _searchKey++);
    widget.onChanged();
    if (refocus) WidgetsBinding.instance.addPostFrameCallback((_) => _searchFocus.requestFocus());
  }

  Future<void> _browse() => showProductBrowser(
        context,
        onPick: (r) => _add(r, refocus: false),
        countOf: (id) => (_existing(id)?.qtyValue ?? 0) ~/ qtyScale,
        inStockOnly: widget.inStockOnly,
      );

  void _remove(OrderLine l) {
    widget.lines.remove(l);
    l.dispose();
    setState(() {});
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final prices = ref.watch(listPricesProvider).valueOrNull ?? const <int, int>{};
    var total = 0;
    var priced = true;
    for (final l in widget.lines) {
      final price = prices[l.row.product.id];
      final q = l.qtyValue;
      if (price == null || q == null) {
        priced = false;
        continue;
      }
      total += lineAmount(q, price);
    }
    const head = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.muted);

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.f3): _browse},
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Expanded(
              child: ProductSearchField(
                key: ValueKey(_searchKey),
                focusNode: _searchFocus,
                autofocus: false,
                onSelected: _add,
              ),
            ),
            const SizedBox(width: 10),
            FilledButton.tonalIcon(
              onPressed: _browse,
              icon: const Icon(Icons.grid_view_rounded),
              label: const Text('تصفح الأصناف (F3)'),
            ),
          ]),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(6),
            ),
            child: widget.lines.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('ابحث عن صنف بالاسم أو الكود أو الباركود، أو افتح تصفح الأصناف. يمكن إضافة أي عدد من الأصناف.',
                        textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted)),
                  )
                : Column(children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                      child: Row(children: [
                        const SizedBox(width: 28, child: Text('#', style: head)),
                        const Expanded(flex: 5, child: Text('الصنف', style: head)),
                        const SizedBox(width: 80, child: Text('المتاح', style: head)),
                        const SizedBox(width: 100, child: Text('سعر القائمة', style: head)),
                        const SizedBox(width: 90, child: Text('الكمية', style: head)),
                        if (widget.withDiscount) const SizedBox(width: 100, child: Text('خصم إضافي %', style: head)),
                        const SizedBox(width: 110, child: Text('بسعر القائمة', style: head)),
                        const SizedBox(width: 40),
                      ]),
                    ),
                    const Divider(height: 1),
                    for (final (i, l) in widget.lines.indexed) _lineRow(i, l, prices[l.row.product.id]),
                  ]),
          ),
          if (widget.lines.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                Text('${widget.lines.length} صنف', style: const TextStyle(fontWeight: FontWeight.w700)),
                const Spacer(),
                Text(
                  'الإجمالي بسعر القائمة: ${formatMoney(total)}${priced ? '' : ' (بعض الأصناف بلا سعر ساري)'}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ]),
            ),
        ],
      ),
    );
  }

  Widget _lineRow(int i, OrderLine l, int? price) {
    final p = l.row.product;
    final q = l.qtyValue;
    return Container(
      color: i.isOdd ? Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: .35) : null,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(children: [
        SizedBox(width: 28, child: Text('${i + 1}')),
        Expanded(
          flex: 5,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${p.nameAr}${p.variant == null ? '' : ' (${p.variant})'}', overflow: TextOverflow.ellipsis),
            Text('${p.code}${p.manufacturerCode.isEmpty ? '' : ' · ${p.manufacturerCode}'}',
                style: const TextStyle(fontSize: 11, color: AppColors.muted)),
          ]),
        ),
        SizedBox(width: 80, child: Text('${formatQty(l.row.sellableStock)} ${l.row.unitName ?? ''}')),
        SizedBox(width: 100, child: Text(price == null ? 'بلا سعر' : formatMoney(price))),
        SizedBox(
          width: 90,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: TextField(
              controller: l.qty,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(isDense: true),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ),
        if (widget.withDiscount)
          SizedBox(
            width: 100,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: TextField(
                controller: l.extra,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(isDense: true, hintText: '0'),
              ),
            ),
          ),
        SizedBox(width: 110, child: Text(price == null || q == null ? '—' : formatMoney(lineAmount(q, price)))),
        SizedBox(
          width: 40,
          child: IconButton(
            tooltip: 'حذف السطر',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => _remove(l),
          ),
        ),
      ]),
    );
  }
}
