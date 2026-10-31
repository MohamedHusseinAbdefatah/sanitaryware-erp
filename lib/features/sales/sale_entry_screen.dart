import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/search_text.dart';
import '../../core/services/product_service.dart';
import '../../core/services/sales_service.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/number_fields.dart';
import '../parties/party_form_dialog.dart';
import '../parties/parties_screen.dart';

/// One editable line. Text fields are parsed on every change; an invalid
/// field shows its error and blocks saving.
class _Line {
  _Line(this.row, int price)
      : qty = TextEditingController(text: '1'),
        price = TextEditingController(text: _plain(price)),
        discount = TextEditingController();

  final ProductRow row;
  final TextEditingController qty;
  final TextEditingController price;
  final TextEditingController discount;
  final qtyFocus = FocusNode();

  /// Once the person types a price, a customer change no longer reprices it.
  bool priceEdited = false;

  Product get product => row.product;
  int? get qtyValue => parseQty(qty.text, allowDecimal: row.unitAllowsDecimal);
  int? get priceValue => parseMoney(price.text);
  int get discountValue => discount.text.trim().isEmpty ? 0 : (parseMoney(discount.text) ?? 0);

  /// Null while any field is invalid.
  int? get total {
    final q = qtyValue, p = priceValue;
    if (q == null || p == null) return null;
    return lineAmount(q, p) - discountValue;
  }

  void dispose() {
    qty.dispose();
    price.dispose();
    discount.dispose();
    qtyFocus.dispose();
  }
}

String _plain(int piastres) => formatMoney(piastres).replaceAll(',', '');

class SaleEntryScreen extends ConsumerStatefulWidget {
  const SaleEntryScreen({super.key});

  @override
  ConsumerState<SaleEntryScreen> createState() => _SaleEntryScreenState();
}

class _SaleEntryScreenState extends ConsumerState<SaleEntryScreen> {
  final _form = GlobalKey<FormState>();
  final _lines = <_Line>[];
  final _invoiceDiscount = TextEditingController();
  final _paid = TextEditingController();
  final _notes = TextEditingController();
  final _productSearchFocus = FocusNode();
  Customer? _customer;
  String _method = PaymentMethod.cash;
  bool _paidEdited = false;
  bool _saving = false;
  int _searchKey = 0; // bumped to clear the product search field

  String get _priceLevel => _customer?.priceLevel ?? PriceLevel.retail;

  int get _subtotal => _lines.fold(0, (s, l) => s + (l.total ?? 0));
  int get _discount => moneyOrZero(_invoiceDiscount);
  int get _total => _subtotal - _discount;
  int get _paidValue => moneyOrZero(_paid);

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    _invoiceDiscount.dispose();
    _paid.dispose();
    _notes.dispose();
    _productSearchFocus.dispose();
    super.dispose();
  }

  /// Recomputes after any edit. A cash sale is paid in full by default.
  void _changed() {
    if (_customer == null && !_paidEdited) _paid.text = _plain(_total);
    setState(() {});
  }

  void _addProduct(ProductRow row) {
    final line = _Line(row, row.product.priceFor(_priceLevel));
    setState(() {
      _lines.add(line);
      _searchKey++;
    });
    _changed();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      line.qtyFocus.requestFocus();
      line.qty.selection = TextSelection(baseOffset: 0, extentOffset: line.qty.text.length);
    });
  }

  void _removeLine(_Line line) {
    setState(() => _lines.remove(line));
    line.dispose();
    _changed();
  }

  void _setCustomer(Customer? c) {
    _customer = c;
    for (final l in _lines.where((l) => !l.priceEdited)) {
      l.price.text = _plain(l.product.priceFor(_priceLevel));
    }
    if (c != null && !_paidEdited) _paid.text = '';
    _changed();
  }

  Future<void> _newCustomer() async {
    final id = await showCustomerForm(context);
    if (id == null || !mounted) return;
    _setCustomer(await ref.read(partyServiceProvider).customer(id));
  }

  /// Total quantity of [product] across all lines (it may be on several).
  int _qtyOnInvoice(int productId) => _lines
      .where((l) => l.product.id == productId)
      .fold(0, (s, l) => s + (l.qtyValue ?? 0));

  Future<void> _save() async {
    if (_saving) return;
    if (_lines.isEmpty) {
      await showMessage(context, Strings.addAtLeastOneItem);
      return;
    }
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final input = SaleInput(
      customerId: _customer?.id,
      lines: [
        for (final l in _lines)
          SaleLineInput(
            productId: l.product.id,
            qty: l.qtyValue!,
            unitPrice: l.priceValue!,
            discount: l.discountValue,
          ),
      ],
      discount: _discount,
      paidAmount: _paidValue,
      paymentMethod: _method,
      notes: _notes.text,
    );
    final invoice = await runGuarded(
      context,
      () => ref.read(salesServiceProvider).post(input, userId: ref.read(currentUserProvider)?.id),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (invoice != null) {
      showToast(context, '${Strings.invoiceSaved} ${invoice.number}');
      context.go('/sales/${invoice.id}');
    }
  }

  Future<void> _discard() async {
    if (_lines.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          content: const Text(Strings.discardInvoice),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text(Strings.no)),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text(Strings.yes)),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    context.go('/sales');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAdmin = ref.watch(currentUserProvider)?.isAdmin ?? false;
    final customers = ref.watch(_activeCustomersProvider).valueOrNull ?? const <Customer>[];

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.f2): () => _productSearchFocus.requestFocus(),
      },
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Top: number, date, customer.
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
              child: Row(
                children: [
                  Text(Strings.newInvoice, style: theme.textTheme.headlineSmall),
                  const SizedBox(width: 24),
                  Text('${Strings.invoiceNo}: ${Strings.automatic}'),
                  const SizedBox(width: 24),
                  Text('${Strings.date}: ${formatDateTime(DateTime.now())}'),
                  const Spacer(),
                  SizedBox(
                    width: 320,
                    child: _CustomerPicker(
                      key: ValueKey(_customer?.id),
                      customers: customers,
                      selected: _customer,
                      onSelected: _setCustomer,
                    ),
                  ),
                  IconButton(
                    tooltip: Strings.newCustomer,
                    onPressed: _newCustomer,
                    icon: const Icon(Icons.person_add_alt),
                  ),
                  if (_customer != null)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(start: 8),
                      child: Chip(label: Text(priceLevelLabel(_customer!.priceLevel))),
                    ),
                ],
              ),
            ),
            // Product search.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: _ProductSearch(
                key: ValueKey(_searchKey),
                focusNode: _productSearchFocus,
                priceLevel: _priceLevel,
                onSelected: _addProduct,
              ),
            ),
            const SizedBox(height: 8),
            // Lines.
            Expanded(
              child: _lines.isEmpty
                  ? const Center(child: Text(Strings.searchToAddHint))
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      itemCount: _lines.length + 1,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) => i == 0
                          ? const _LineHeader()
                          : _LineRow(
                              index: i,
                              line: _lines[i - 1],
                              showCost: isAdmin,
                              qtyOnInvoice: _qtyOnInvoice(_lines[i - 1].product.id),
                              onChanged: _changed,
                              onPriceEdited: () => _lines[i - 1].priceEdited = true,
                              onRemove: () => _removeLine(_lines[i - 1]),
                              onSubmitted: () => _productSearchFocus.requestFocus(),
                            ),
                    ),
            ),
            // Bottom: totals and payment.
            Container(
              color: theme.colorScheme.surfaceContainerHigh,
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  SizedBox(
                    width: 280,
                    child: TextField(
                      controller: _notes,
                      decoration: const InputDecoration(labelText: Strings.notes, isDense: true),
                    ),
                  ),
                  const Spacer(),
                  _Amount(Strings.subtotal, _subtotal),
                  const SizedBox(width: 16),
                  SizedBox(
                    width: 110,
                    child: MoneyField(
                      controller: _invoiceDiscount,
                      label: Strings.invoiceDiscount,
                      onChanged: (_) => _changed(),
                    ),
                  ),
                  const SizedBox(width: 16),
                  _Amount(Strings.total, _total, big: true),
                  const SizedBox(width: 24),
                  SizedBox(
                    width: 120,
                    child: MoneyField(
                      controller: _paid,
                      label: Strings.paidNow,
                      onChanged: (_) {
                        _paidEdited = true;
                        _changed();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  DropdownButton<String>(
                    value: _method,
                    items: const [
                      DropdownMenuItem(value: PaymentMethod.cash, child: Text(Strings.methodCash)),
                      DropdownMenuItem(value: PaymentMethod.bank, child: Text(Strings.methodBank)),
                    ],
                    onChanged: (v) => setState(() => _method = v!),
                  ),
                  const SizedBox(width: 16),
                  _Amount(Strings.remaining, _total - _paidValue),
                  const SizedBox(width: 24),
                  OutlinedButton(onPressed: _discard, child: const Text(Strings.cancel)),
                  const SizedBox(width: 8),
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

class _Amount extends StatelessWidget {
  const _Amount(this.label, this.value, {this.big = false});

  final String label;
  final int value;
  final bool big;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        Text(
          formatMoney(value),
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: big ? 22 : 16),
        ),
      ],
    );
  }
}

const _lineFlex = [1, 6, 2, 2, 2, 2, 2, 2];

class _LineHeader extends StatelessWidget {
  const _LineHeader();

  @override
  Widget build(BuildContext context) {
    const titles = [
      '#',
      Strings.productName,
      Strings.available,
      Strings.qty,
      Strings.unit,
      Strings.price,
      Strings.discount,
      Strings.lineTotal,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          for (var i = 0; i < titles.length; i++)
            Expanded(
              flex: _lineFlex[i],
              child: Text(
                titles[i],
                textAlign: i == 1 ? TextAlign.start : TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({
    required this.index,
    required this.line,
    required this.showCost,
    required this.qtyOnInvoice,
    required this.onChanged,
    required this.onPriceEdited,
    required this.onRemove,
    required this.onSubmitted,
  });

  final int index;
  final _Line line;
  final bool showCost;
  final int qtyOnInvoice;
  final VoidCallback onChanged;
  final VoidCallback onPriceEdited;
  final VoidCallback onRemove;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final short = qtyOnInvoice > line.row.stock;
    final price = line.priceValue;
    final belowCost = showCost && price != null && price < line.product.costPrice;
    final total = line.total;

    Widget cell(int i, Widget child) => Expanded(
          flex: _lineFlex[i],
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: child),
        );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          cell(0, Text('$index', textAlign: TextAlign.center)),
          cell(
            1,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(line.product.nameAr),
                Text(line.product.code, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          cell(
            2,
            Tooltip(
              message: short ? Strings.notEnoughStock : '',
              child: Text(
                formatQty(line.row.stock),
                textAlign: TextAlign.center,
                style: short ? TextStyle(color: scheme.error, fontWeight: FontWeight.bold) : null,
              ),
            ),
          ),
          cell(
            3,
            QtyField(
              controller: line.qty,
              focusNode: line.qtyFocus,
              label: Strings.qty,
              allowDecimal: line.row.unitAllowsDecimal,
              required: true,
              dense: true,
              onChanged: (_) => onChanged(),
              onSubmitted: (_) => onSubmitted(),
            ),
          ),
          cell(4, Text(line.row.unitName ?? '', textAlign: TextAlign.center)),
          cell(
            5,
            Tooltip(
              message: belowCost ? '${Strings.belowCost} (${formatMoney(line.product.costPrice)})' : '',
              child: MoneyField(
                controller: line.price,
                label: Strings.price,
                required: true,
                dense: true,
                onChanged: (_) {
                  onPriceEdited();
                  onChanged();
                },
              ),
            ),
          ),
          cell(
            6,
            MoneyField(
              controller: line.discount,
              label: Strings.discount,
              dense: true,
              onChanged: (_) => onChanged(),
            ),
          ),
          cell(
            7,
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (belowCost) Icon(Icons.warning_amber, size: 16, color: scheme.tertiary),
                Text(
                  total == null ? '—' : formatMoney(total),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 48,
            child: IconButton(
              tooltip: Strings.removeLine,
              icon: const Icon(Icons.delete_outline),
              onPressed: onRemove,
            ),
          ),
        ],
      ),
    );
  }
}

/// Type a code or name; Enter adds the highlighted product.
class _ProductSearch extends ConsumerStatefulWidget {
  const _ProductSearch({
    super.key,
    required this.focusNode,
    required this.priceLevel,
    required this.onSelected,
  });

  final FocusNode focusNode;
  final String priceLevel;
  final ValueChanged<ProductRow> onSelected;

  @override
  ConsumerState<_ProductSearch> createState() => _ProductSearchState();
}

class _ProductSearchState extends ConsumerState<_ProductSearch> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final priceLevel = widget.priceLevel;
    return RawAutocomplete<ProductRow>(
      focusNode: widget.focusNode,
      textEditingController: _controller,
      displayStringForOption: (r) => r.product.nameAr,
      optionsBuilder: (value) async {
        if (value.text.trim().isEmpty) return const [];
        return ref.read(productServiceProvider).search(value.text);
      },
      onSelected: widget.onSelected,
      fieldViewBuilder: (context, textController, focus, onSubmit) => TextField(
        controller: textController,
        focusNode: focus,
        autofocus: true,
        onSubmitted: (_) => onSubmit(),
        decoration: const InputDecoration(
          prefixIcon: Icon(Icons.qr_code_scanner),
          hintText: Strings.productSearchHint,
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      optionsViewBuilder: (context, onPick, options) => Align(
        alignment: AlignmentDirectional.topStart,
        child: Material(
          elevation: 6,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360, maxWidth: 720),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                for (final (i, r) in options.indexed)
                  Builder(builder: (context) {
                    final highlighted = AutocompleteHighlightedOption.of(context) == i;
                    return ListTile(
                      dense: true,
                      selected: highlighted,
                      selectedTileColor: Theme.of(context).colorScheme.secondaryContainer,
                      title: Text('${r.product.code} — ${r.product.nameAr}'),
                      subtitle: Text('${Strings.available}: ${formatQty(r.stock)} ${r.unitName ?? ''}'),
                      trailing: Text(formatMoney(r.product.priceFor(priceLevel))),
                      onTap: () => onPick(r),
                    );
                  }),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Pick a customer by name or phone; empty means a cash sale.
class _CustomerPicker extends StatelessWidget {
  const _CustomerPicker({
    super.key,
    required this.customers,
    required this.selected,
    required this.onSelected,
  });

  final List<Customer> customers;
  final Customer? selected;
  final ValueChanged<Customer?> onSelected;

  @override
  Widget build(BuildContext context) {
    return Autocomplete<Customer>(
      initialValue: TextEditingValue(text: selected?.name ?? ''),
      displayStringForOption: (c) => c.name,
      optionsBuilder: (value) => customers
          .where((c) => matchesSearch(value.text, [c.name, c.phone]))
          .take(20),
      onSelected: onSelected,
      fieldViewBuilder: (context, controller, focus, onSubmit) => TextField(
        controller: controller,
        focusNode: focus,
        onSubmitted: (_) => onSubmit(),
        decoration: InputDecoration(
          labelText: Strings.customer,
          hintText: Strings.cashCustomer,
          isDense: true,
          border: const OutlineInputBorder(),
          suffixIcon: selected == null
              ? null
              : IconButton(
                  tooltip: Strings.cashSale,
                  icon: const Icon(Icons.clear),
                  onPressed: () => onSelected(null),
                ),
        ),
      ),
    );
  }
}

final _activeCustomersProvider = StreamProvider.autoDispose<List<Customer>>(
  (ref) => ref.watch(partyServiceProvider).watchCustomers(activeOnly: true),
);
