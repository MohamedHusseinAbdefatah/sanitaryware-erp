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
import '../../core/pricing_math.dart';
import '../../core/printing/print_actions.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/services/errors.dart';
import '../../core/services/fifo_service.dart';
import '../../core/services/product_service.dart';
import '../../core/services/sales_service.dart';
import '../../core/services/selling_policy_service.dart';
import '../../core/services/stock_price_service.dart';
import '../../core/services/stock_service.dart';
import '../../core/widgets/amounts.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/number_fields.dart';
import '../../core/widgets/pickers.dart';
import '../parties/party_form_dialog.dart';
import '../parties/parties_screen.dart';
import 'sale_preview_dialog.dart';

/// One editable line. Text fields are parsed on every change; an invalid
/// field shows its error and blocks saving.
class _Line {
  _Line(this.row, this.quote, this.costHint, this.priceSplit)
      : qty = TextEditingController(text: '1'),
        price = TextEditingController(text: quote == null ? '' : _plain(quote.listPrice)),
        discount = TextEditingController();

  final ProductRow row;

  /// The approved price this line starts from. Null = none exists, so the
  /// person types a price, which needs a manager.
  SellQuote? quote;

  /// The next FIFO cost per unit, for the admin's warning. Null = none on record.
  final int? costHint;

  /// How much of it is at the old and the new price.
  final StockPriceSummary priceSplit;

  /// The place chosen on this line. Null = the sellable places in order.
  int? locationId;
  final TextEditingController qty;
  final TextEditingController price;
  final TextEditingController discount;
  final qtyFocus = FocusNode();

  /// Once the person types a price, a customer change no longer reprices it.
  bool priceEdited = false;

  /// Once the person types a discount, the policy and customer ones stop filling it.
  bool discountEdited = false;

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
  const SaleEntryScreen({super.key, this.customerId, this.projectId});

  /// Starts the invoice for this project (from the project page).
  final int? projectId;

  /// Starts the invoice for this customer (from the customer's page).
  final int? customerId;

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
  int? _customerBalance;
  String _method = PaymentMethod.cash;
  bool _paidEdited = false;
  bool _saving = false;
  int _searchKey = 0; // bumped to clear the product search field
  int? _projectId;
  List<Project> _projects = const [];

  Future<void> _loadProjects() async {
    final list = await ref.read(projectServiceProvider).open(customerId: _customer?.id);
    if (!mounted) return;
    setState(() {
      _projects = list;
      if (!list.any((p) => p.id == _projectId)) _projectId = null;
    });
  }

  int get _subtotal => _lines.fold(0, (s, l) => s + (l.total ?? 0));
  bool _discountPercent = false;
  int get _discount =>
      discountAmount(_invoiceDiscount.text, percent: _discountPercent, subtotal: _subtotal) ?? 0;
  int get _total => _subtotal - _discount;
  int get _paidValue => moneyOrZero(_paid);

  @override
  void initState() {
    super.initState();
    _projectId = widget.projectId;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadProjects());
    final id = widget.customerId;
    if (id != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final c = await ref.read(partyServiceProvider).customer(id);
        if (mounted) await _setCustomer(c);
      });
    }
  }

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
    _fillCustomerDiscounts();
    if (_customer == null && !_paidEdited) _paid.text = _plain(_total);
    setState(() {});
  }

  /// Each line gets its policy and customer discount unless the person has
  /// typed one. 21% from the policy and 1% more is 22%.
  void _fillCustomerDiscounts() {
    for (final l in _lines.where((l) => !l.discountEdited)) {
      final q = l.qtyValue, p = l.priceValue;
      final bp = l.quote?.totalBp ?? 0;
      var text = '';
      if (bp > 0 && q != null && p != null) {
        final gross = lineAmount(q, p);
        final off = gross - applyDiscount(gross, bp);
        if (off > 0) text = _plain(off);
      }
      if (l.discount.text != text) l.discount.text = text;
    }
  }

  Future<void> _addProduct(ProductRow row) async {
    final quotes = await ref.read(sellingPolicyServiceProvider).quotes(row.product.id, customer: _customer);
    final stock = StockService(ref.read(databaseProvider));
    final cost = await FifoService(ref.read(databaseProvider))
        .peek(row.product.id, qtyScale, locationIds: await stock.sellableLocationIds());
    final split = await ref.read(stockPriceServiceProvider).summaryOf(row.product.id);
    if (!mounted) return;
    var quote = quotes.length == 1 ? quotes.single : null;
    if (quotes.length > 1) {
      quote = await pickSellQuote(context, quotes, row.product.nameAr);
      if (quote == null || !mounted) return;
    }
    final line = _Line(row, quote, cost?.averageUnitCost, split);
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

  Future<void> _setCustomer(Customer? c) async {
    _customer = c;
    _customerBalance = null;
    _loadProjects();
    // The pricing type and the customer's discount come with the customer.
    final policies = ref.read(sellingPolicyServiceProvider);
    for (final l in List.of(_lines)) {
      if (l.priceEdited) continue;
      final current = l.quote?.quote.priceListId;
      final fresh = await policies.quotes(l.product.id, customer: c);
      final same = fresh.where((q) => q.quote.priceListId == current).firstOrNull;
      l.quote = same ?? (fresh.length == 1 ? fresh.single : null);
      l.price.text = l.quote == null ? '' : _plain(l.quote!.listPrice);
    }
    if (!mounted) return;
    if (c != null && !_paidEdited) _paid.text = '';
    _changed();
    if (c != null) {
      ref.read(balanceServiceProvider).customerBalance(c.id).then((b) {
        if (mounted && _customer?.id == c.id) setState(() => _customerBalance = b);
      });
    }
  }

  /// The customer's balance after this invoice, once it is known.
  int? get _balanceAfter =>
      _customerBalance == null ? null : _customerBalance! + _total - _paidValue;

  bool get _overCreditLimit {
    final limit = _customer?.creditLimit ?? 0;
    final after = _balanceAfter;
    return limit > 0 && after != null && after > limit;
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

  /// Saves; with [andPrint] the print dialog opens before going to the
  /// saved invoice.
  Future<void> _save({bool andPrint = false}) async {
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
            priceListId: l.quote?.quote.priceListId,
            locationId: l.locationId,
          ),
      ],
      discount: _discount,
      paidAmount: _paidValue,
      paymentMethod: _method,
      notes: _notes.text,
      projectId: _projectId,
    );
    final user = ref.read(currentUserProvider);
    // Blueprint 3.4: everything is shown before approval.
    final preview = await runGuarded(context, () => ref.read(salePreviewServiceProvider).preview(input));
    final approvalReason = preview == null || !mounted
        ? null
        : await showSalePreview(context, preview, isAdmin: user?.isAdmin ?? false);
    if (!mounted) return;
    if (approvalReason == null) {
      setState(() => _saving = false);
      return;
    }
    Future<SalesInvoice> post({bool override = false, String? reason}) =>
        ref.read(salesServiceProvider).post(input,
            userId: user?.id,
            allowOverCreditLimit: override,
            belowCostReason: reason,
            approvalReason: approvalReason);
    SalesInvoice? invoice;
    try {
      invoice = await post();
    } on CreditLimitException catch (e) {
      // Only an admin may go over the limit, after confirming.
      if (mounted && (user?.isAdmin ?? false) && await _confirmOverLimit(e.message)) {
        if (mounted) invoice = await runGuarded(context, () => post(override: true));
      } else if (mounted) {
        await showMessage(context, e.message);
      }
    } on BelowCostException catch (e) {
      // A cashier is refused; an admin gives a reason, which is logged.
      final reason = (mounted && e.needsReason) ? await _askBelowCostReason(e.message) : null;
      if (mounted && reason != null) {
        invoice = await runGuarded(context, () => post(reason: reason));
      } else if (mounted && !e.needsReason) {
        await showMessage(context, e.message);
      }
    } on ValidationException catch (e) {
      if (mounted) await showMessage(context, e.message);
    } catch (e) {
      if (mounted) await showMessage(context, '${Strings.unexpectedError}\n$e');
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (invoice != null) {
      showToast(context, '${Strings.invoiceSaved} ${invoice.number}');
      if (andPrint) await printSalesInvoice(context, ref, invoice.id);
      if (mounted) context.go('/sales/${invoice.id}');
    }
  }

  Future<String?> _askBelowCostReason(String message) async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('بيع أقل من التكلفة'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'سبب البيع بأقل من التكلفة'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.cancel)),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) Navigator.pop(context, controller.text.trim());
            },
            child: const Text(Strings.saveAnyway),
          ),
        ],
      ),
    );
    controller.dispose();
    return reason;
  }

  Future<bool> _confirmOverLimit(String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(Strings.creditLimitExceeded),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text(Strings.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text(Strings.saveAnyway)),
        ],
      ),
    );
    return ok ?? false;
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
    final customers = ref.watch(activeCustomersProvider).valueOrNull ?? const <Customer>[];

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyP, control: true): () => _save(andPrint: true),
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
              // Wraps the customer picker onto a second line in a narrow window.
              child: Wrap(
                spacing: 24,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(Strings.newInvoice, style: theme.textTheme.headlineSmall),
                  Text('${Strings.invoiceNo}: ${Strings.automatic}'),
                  Text('${Strings.date}: ${formatDateTime(DateTime.now())}'),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 320,
                        child: PartyPicker<Customer>(
                          key: ValueKey(_customer?.id),
                          items: customers,
                          selected: _customer,
                          label: Strings.customer,
                          hint: Strings.cashCustomer,
                          clearTooltip: Strings.cashSale,
                          nameOf: (c) => c.name,
                          searchFields: (c) => [c.name, c.phone],
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
                          child: Chip(
                              label: Text(categoryNameOf(
                                  _customer!, ref.watch(customerCategoriesProvider).valueOrNull ?? const []))),
                        ),
                    ],
                  ),
                  if (_projects.isNotEmpty)
                    SizedBox(
                      width: 280,
                      child: DropdownButtonFormField<int?>(
                        key: ValueKey(('prj', _projectId, _projects.length)),
                        initialValue: _projectId,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'المشروع', isDense: true, prefixIcon: Icon(Icons.apartment_outlined)),
                        items: [
                          const DropdownMenuItem<int?>(value: null, child: Text('بدون مشروع')),
                          for (final p in _projects) DropdownMenuItem<int?>(value: p.id, child: Text(p.name, overflow: TextOverflow.ellipsis)),
                        ],
                        onChanged: (v) => setState(() => _projectId = v),
                      ),
                    ),
                ],
              ),
            ),
            // Product search.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: ProductSearchField(
                key: ValueKey(_searchKey),
                focusNode: _productSearchFocus,
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
              // Wraps onto two lines in a narrow window instead of overflowing.
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
                  AmountLabel(Strings.subtotal, _subtotal),
                  SizedBox(
                    width: 280,
                    child: DiscountField(
                      controller: _invoiceDiscount,
                      label: Strings.invoiceDiscount,
                      percent: _discountPercent,
                      subtotal: _subtotal,
                      onModeChanged: (v) {
                        setState(() => _discountPercent = v);
                        _changed();
                      },
                      onChanged: (_) => _changed(),
                    ),
                  ),
                  AmountLabel(Strings.total, _total, big: true),
                  SizedBox(
                    width: 130,
                    child: MoneyField(
                      controller: _paid,
                      label: Strings.paidNow,
                      onChanged: (_) {
                        _paidEdited = true;
                        _changed();
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
                  AmountLabel(Strings.remaining, _total - _paidValue),
                  if (_customerBalance != null) ...[
                    AmountLabel(Strings.previousBalance, _customerBalance!),
                    Tooltip(
                      message: _overCreditLimit
                          ? '${Strings.creditLimitExceeded} (${formatMoney(_customer!.creditLimit)})'
                          : '',
                      child: AmountLabel(
                        Strings.newBalance,
                        _balanceAfter!,
                        color: _overCreditLimit ? theme.colorScheme.error : null,
                      ),
                    ),
                  ],
                  OutlinedButton(onPressed: _discard, child: const Text(Strings.cancel)),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.save),
                    label: const Text('${Strings.save} (Ctrl+S)'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _saving ? null : () => _save(andPrint: true),
                    icon: const Icon(Icons.print_outlined),
                    label: const Text('${Strings.saveAndPrint} (Ctrl+P)'),
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
          const SizedBox(width: 96),
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
    final short = qtyOnInvoice > line.row.sellableStock;
    final price = line.priceValue;
    final belowCost = showCost && price != null && line.costHint != null && price < line.costHint!;
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
                Text(
                  line.quote == null
                      ? '${line.product.code} · لا يوجد سعر معتمد'
                      : '${line.product.code} · ${line.quote!.quote.label}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (line.priceSplit.old != 0 || line.priceSplit.unknown != 0)
                  Text(
                    [
                      if (line.priceSplit.current != 0) 'بالسعر الجديد ${formatQty(line.priceSplit.current)}',
                      if (line.priceSplit.old != 0) 'بالسعر القديم ${formatQty(line.priceSplit.old)}',
                      if (line.priceSplit.unknown != 0) 'غير محدد ${formatQty(line.priceSplit.unknown)}',
                    ].join(' · '),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.tertiary),
                  ),
              ],
            ),
          ),
          cell(
            2,
            Tooltip(
              message: short ? Strings.notEnoughStock : '',
              child: Text(
                formatQty(line.row.sellableStock),
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
              message: belowCost ? '${Strings.belowCost} (${formatMoney(line.costHint!)})' : '',
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
              onChanged: (_) {
                line.discountEdited = true;
                onChanged();
              },
            ),
          ),
          cell(
            7,
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (belowCost) Icon(Icons.warning_amber, size: 16, color: scheme.tertiary),
                // Shrinks instead of overflowing when the amount is long.
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      total == null ? '—' : formatMoney(total),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 48,
            child: _PlaceButton(line: line),
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

/// Which place a line is sold from. Display-only places are not offered.
class _PlaceButton extends ConsumerWidget {
  const _PlaceButton({required this.line});

  final _Line line;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<List<Location>>(
      future: ref.read(locationServiceProvider).all(activeOnly: true),
      builder: (context, snap) {
        final places = (snap.data ?? const <Location>[]).where((l) => l.isSellable).toList();
        if (places.length < 2) return const SizedBox.shrink();
        return PopupMenuButton<int>(
          tooltip: 'مكان البيع: ${line.locationId == null ? 'تلقائي' : places.where((p) => p.id == line.locationId).firstOrNull?.name ?? ''}',
          icon: Icon(line.locationId == null ? Icons.warehouse_outlined : Icons.warehouse),
          initialValue: line.locationId ?? 0,
          onSelected: (v) => line.locationId = v == 0 ? null : v,
          itemBuilder: (_) => [
            const PopupMenuItem(value: 0, child: Text('تلقائي: المخزن الرئيسي أولاً')),
            for (final p in places) PopupMenuItem(value: p.id, child: Text(p.name)),
          ],
        );
      },
    );
  }
}
