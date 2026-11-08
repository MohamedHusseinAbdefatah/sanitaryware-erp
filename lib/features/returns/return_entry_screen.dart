import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/session.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/services/doc_types.dart';
import '../../core/services/fifo_service.dart';
import '../../core/services/product_service.dart';
import '../../core/services/stock_service.dart';
import '../../core/services/return_service.dart';
import '../../core/widgets/amounts.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/number_fields.dart';
import '../../core/widgets/pickers.dart';

/// One line of the return. With an original invoice, [maxQty] is what can
/// still go back; without one, there is no limit here (the service checks).
class _Line {
  _Line({
    required this.productId,
    required this.code,
    required this.name,
    required this.unitName,
    required this.allowDecimal,
    required int price,
    this.maxQty,
    String qty = '',
  })  : qty = TextEditingController(text: qty),
        price = TextEditingController(text: formatMoney(price).replaceAll(',', ''));

  final int productId;
  final String code;
  final String name;
  final String? unitName;
  final bool allowDecimal;
  final int? maxQty;
  final TextEditingController qty;
  final TextEditingController price;

  int get qtyValue => qty.text.trim().isEmpty ? 0 : (parseQty(qty.text, allowDecimal: allowDecimal) ?? 0);
  int get priceValue => parseMoney(price.text) ?? 0;
  int get total => lineAmount(qtyValue, priceValue);

  void dispose() {
    qty.dispose();
    price.dispose();
  }
}

/// New sale return ([ReturnKind.sale]) or purchase return. Opened from an
/// invoice (its lines are listed with what can still go back) or empty, in
/// which case an invoice number can be typed or products added freely.
class ReturnEntryScreen extends ConsumerStatefulWidget {
  const ReturnEntryScreen({super.key, required this.kind, this.invoiceId});

  final String kind;
  final int? invoiceId;

  @override
  ConsumerState<ReturnEntryScreen> createState() => _ReturnEntryScreenState();
}

class _ReturnEntryScreenState extends ConsumerState<ReturnEntryScreen> {
  final _form = GlobalKey<FormState>();
  final _invoiceNo = TextEditingController();
  final _refund = TextEditingController();
  final _notes = TextEditingController();
  final _lines = <_Line>[];
  ReturnSource? _source;
  Customer? _customer;
  Supplier? _supplier;
  String _method = PaymentMethod.cash;
  int _locationId = mainLocationId;
  bool _refundEdited = false;
  bool _saving = false;
  int _searchKey = 0;

  bool get _isSale => widget.kind == ReturnKind.sale;
  int get _total => _lines.fold(0, (s, l) => s + l.total);

  /// A walk-in sale return (no customer) must be refunded in full.
  bool get _mustRefundAll => _isSale && _source?.partyId == null && _customer == null;

  @override
  void initState() {
    super.initState();
    if (widget.invoiceId != null) _loadInvoice(id: widget.invoiceId);
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    for (final c in [_invoiceNo, _refund, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  void _changed() {
    if (_mustRefundAll || !_refundEdited) {
      _refund.text = _mustRefundAll ? formatMoney(_total).replaceAll(',', '') : '';
    }
    setState(() {});
  }

  Future<void> _loadInvoice({int? id, String? number}) async {
    final service = ref.read(returnServiceProvider);
    final source = await service.findInvoice(widget.kind, id: id, number: number);
    if (!mounted) return;
    if (source == null) {
      await showMessage(context, Strings.invoiceNotFound);
      return;
    }
    final returnable = _isSale
        ? await service.returnableForSale(source.id)
        : await service.returnableForPurchase(source.id);
    if (!mounted) return;
    for (final l in _lines) {
      l.dispose();
    }
    setState(() {
      _source = source;
      _invoiceNo.text = source.number;
      _lines
        ..clear()
        ..addAll([
          for (final r in returnable.where((r) => r.returnable > 0))
            _Line(
              productId: r.productId,
              code: r.code,
              name: r.name,
              unitName: r.unitName,
              allowDecimal: r.allowDecimal,
              price: r.unitPrice,
              maxQty: r.returnable,
            ),
        ]);
    });
    _changed();
  }

  void _clearInvoice() {
    for (final l in _lines) {
      l.dispose();
    }
    setState(() {
      _source = null;
      _invoiceNo.clear();
      _lines.clear();
    });
    _changed();
  }

  Future<void> _addProduct(ProductRow row) async {
    // With no original invoice the price starts at the approved list price or
    // the last known cost, if there is one; otherwise the person types it.
    var price = 0;
    if (_isSale) {
      final quotes = await ref.read(sellingPolicyServiceProvider).quotes(row.product.id, customer: _customer);
      if (quotes.length == 1) price = quotes.single.unitPrice;
    } else {
      price = await FifoService(ref.read(databaseProvider)).lastKnownCost(row.product.id) ?? 0;
    }
    if (!mounted) return;
    setState(() {
      _lines.add(_Line(
        productId: row.product.id,
        code: row.product.code,
        name: row.product.nameAr,
        unitName: row.unitName,
        allowDecimal: row.unitAllowsDecimal,
        price: price,
        qty: '1',
      ));
      _searchKey++;
    });
    _changed();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    final lines = [
      for (final l in _lines.where((l) => l.qtyValue > 0))
        ReturnLineInput(productId: l.productId, qty: l.qtyValue, unitPrice: l.priceValue),
    ];
    if (lines.isEmpty) {
      await showMessage(context, Strings.enterReturnQty);
      return;
    }
    setState(() => _saving = true);
    final input = ReturnInput(
      lines: lines,
      originalInvoiceId: _source?.id,
      partyId: _source?.partyId ?? (_isSale ? _customer?.id : _supplier?.id),
      refundAmount: moneyOrZero(_refund),
      refundMethod: _method,
      notes: _notes.text,
      locationId: _locationId,
    );
    final user = ref.read(currentUserProvider)!;
    final service = ref.read(returnServiceProvider);
    final doc = await runGuarded(
      context,
      () => _isSale ? service.postSaleReturn(input, user: user) : service.postPurchaseReturn(input, user: user),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (doc != null) {
      showToast(context, '${Strings.returnSaved} ${doc.number}');
      context.go('/returns');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save},
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
              child: Wrap(
                spacing: 16,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(_isSale ? Strings.newSaleReturn : Strings.newPurchaseReturn,
                      style: theme.textTheme.headlineSmall),
                  SizedBox(
                    width: 220,
                    child: TextField(
                      controller: _invoiceNo,
                      readOnly: _source != null,
                      decoration: InputDecoration(
                        labelText: Strings.originalInvoice,
                        hintText: _isSale ? 'S-000012' : 'P-000012',
                        isDense: true,
                        border: const OutlineInputBorder(),
                        suffixIcon: _source == null
                            ? IconButton(
                                tooltip: Strings.load,
                                icon: const Icon(Icons.search),
                                onPressed: () => _loadInvoice(number: _invoiceNo.text),
                              )
                            : IconButton(
                                tooltip: Strings.withoutInvoice,
                                icon: const Icon(Icons.clear),
                                onPressed: _clearInvoice,
                              ),
                      ),
                      onSubmitted: (v) => _loadInvoice(number: v),
                    ),
                  ),
                  if (_source != null)
                    Text('${_isSale ? Strings.customer : Strings.supplier}: '
                        '${_source!.partyName ?? Strings.cashCustomer}')
                  else
                    SizedBox(
                      width: 300,
                      child: _isSale
                          ? PartyPicker<Customer>(
                              key: ValueKey('c${_customer?.id}'),
                              items: ref.watch(activeCustomersProvider).valueOrNull ?? const [],
                              selected: _customer,
                              label: Strings.customer,
                              hint: Strings.cashCustomer,
                              nameOf: (c) => c.name,
                              searchFields: (c) => [c.name, c.phone],
                              onSelected: (c) {
                                _customer = c;
                                _changed();
                              },
                            )
                          : PartyPicker<Supplier>(
                              key: ValueKey('s${_supplier?.id}'),
                              items: ref.watch(activeSuppliersProvider).valueOrNull ?? const [],
                              selected: _supplier,
                              label: Strings.supplier,
                              nameOf: (s) => s.name,
                              searchFields: (s) => [s.name, s.phone],
                              onSelected: (s) => setState(() => _supplier = s),
                            ),
                    ),
                ],
              ),
            ),
            if (_source == null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: ProductSearchField(
                  key: ValueKey(_searchKey),
                  autofocus: false,
                  onSelected: _addProduct,
                ),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: _lines.isEmpty
                  ? Center(child: Text(_source == null ? Strings.returnHint : Strings.nothingLeftToReturn))
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      itemCount: _lines.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final l = _lines[i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Expanded(
                                flex: 5,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(l.name),
                                    Text(
                                      l.maxQty == null
                                          ? l.code
                                          : '${l.code} · ${Strings.canReturn}: ${formatQty(l.maxQty!)} ${l.unitName ?? ''}',
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                flex: 2,
                                child: QtyField(
                                  controller: l.qty,
                                  label: Strings.returnQty,
                                  allowDecimal: l.allowDecimal,
                                  dense: true,
                                  onChanged: (_) => _changed(),
                                ),
                              ),
                              Expanded(child: Text(l.unitName ?? '', textAlign: TextAlign.center)),
                              Expanded(
                                flex: 2,
                                child: MoneyField(
                                  controller: l.price,
                                  label: _isSale ? Strings.price : Strings.unitCost,
                                  required: true,
                                  dense: true,
                                  onChanged: (_) => _changed(),
                                ),
                              ),
                              Expanded(
                                flex: 2,
                                child: Text(
                                  formatMoney(l.total),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontWeight: FontWeight.bold),
                                ),
                              ),
                              if (_source == null)
                                IconButton(
                                  tooltip: Strings.removeLine,
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () {
                                    setState(() => _lines.removeAt(i).dispose());
                                    _changed();
                                  },
                                ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            Container(
              color: theme.colorScheme.surfaceContainerHigh,
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
              child: Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.end,
                spacing: 16,
                runSpacing: 12,
                children: [
                  SizedBox(
                    width: 260,
                    child: TextField(
                      controller: _notes,
                      decoration: const InputDecoration(labelText: Strings.notes, isDense: true),
                    ),
                  ),
                  if (_isSale)
                    LocationDropdown(
                      label: 'مكان عودة البضاعة',
                      value: _locationId,
                      onChanged: (v) => setState(() => _locationId = v),
                    ),
                  AmountLabel(Strings.returnTotal, _total, big: true),
                  SizedBox(
                    width: 140,
                    child: MoneyField(
                      controller: _refund,
                      label: _isSale ? Strings.refundToCustomer : Strings.refundFromSupplier,
                      onChanged: (_) {
                        _refundEdited = true;
                        setState(() {});
                      },
                    ),
                  ),
                  DropdownButton<String>(
                    value: _method,
                    items: const [
                      DropdownMenuItem(value: PaymentMethod.cash, child: Text(Strings.methodCash)),
                      DropdownMenuItem(value: PaymentMethod.bank, child: Text(Strings.methodBank)),
                    ],
                    onChanged: (v) => setState(() => _method = v!),
                  ),
                  AmountLabel(Strings.toBalance, _total - moneyOrZero(_refund)),
                  OutlinedButton(onPressed: () => context.go('/returns'), child: const Text(Strings.cancel)),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.save),
                    label: const Text('${Strings.save} (Ctrl+S)'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
