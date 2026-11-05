import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/services/buying_policy_service.dart';
import '../../core/services/doc_types.dart';
import '../../core/services/product_service.dart';
import '../../core/services/purchase_service.dart';
import '../../core/widgets/amounts.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/number_fields.dart';
import '../../core/widgets/pickers.dart';
import '../parties/party_form_dialog.dart';

class _Line {
  _Line(this.row)
      : qty = TextEditingController(text: '1'),
        cost = TextEditingController();

  final ProductRow row;
  final TextEditingController qty;
  final TextEditingController cost;
  final qtyFocus = FocusNode();

  /// The cost as first shown; if it still matches, the person has not typed over it.
  String initialCost = '';

  /// Where the shown cost came from; dropped once the person types over it.
  BuyQuote? quote;

  int? get qtyValue => parseQty(qty.text, allowDecimal: row.unitAllowsDecimal);
  int? get costValue => parseMoney(cost.text);
  int? get total {
    final q = qtyValue, c = costValue;
    return q == null || c == null ? null : lineAmount(q, c);
  }

  void dispose() {
    qty.dispose();
    cost.dispose();
    qtyFocus.dispose();
  }
}

/// New purchase invoice (admin). With a supplier chosen, a line starts at the
/// list price less that supplier's recorded buying policy. With no policy the
/// cost stays empty: no discount is assumed, and the person types the cost.
class PurchaseEntryScreen extends ConsumerStatefulWidget {
  const PurchaseEntryScreen({super.key});

  @override
  ConsumerState<PurchaseEntryScreen> createState() => _PurchaseEntryScreenState();
}

class _PurchaseEntryScreenState extends ConsumerState<PurchaseEntryScreen> {
  final _form = GlobalKey<FormState>();
  final _lines = <_Line>[];
  final _supplierInvoiceNo = TextEditingController();
  final _discount = TextEditingController();
  final _paid = TextEditingController();
  final _notes = TextEditingController();
  final _searchFocus = FocusNode();
  Supplier? _supplier;
  String _method = PaymentMethod.cash;
  bool _saving = false;
  int _searchKey = 0;

  int get _subtotal => _lines.fold(0, (s, l) => s + (l.total ?? 0));
  int get _total => _subtotal - moneyOrZero(_discount);

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    for (final c in [_supplierInvoiceNo, _discount, _paid, _notes]) {
      c.dispose();
    }
    _searchFocus.dispose();
    super.dispose();
  }

  void _add(ProductRow row) {
    final line = _Line(row);
    setState(() {
      _lines.add(line);
      _searchKey++;
    });
    _applyListCost(line);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      line.qtyFocus.requestFocus();
      line.qty.selection = TextSelection(baseOffset: 0, extentOffset: line.qty.text.length);
    });
  }

  /// With a supplier chosen, a line starts at the cost its recorded policy
  /// gives, when exactly one version has one and the person has not typed over.
  Future<void> _applyListCost(_Line line) async {
    final supplier = _supplier;
    if (supplier == null) return;
    final quotes = await ref
        .read(buyingPolicyServiceProvider)
        .quotes(line.row.product.id, supplierId: supplier.id);
    final backed = quotes.where((q) => !q.missingPolicy).toList();
    if (!mounted || supplier.id != _supplier?.id) return;
    if (line.cost.text != line.initialCost) return;
    setState(() {
      line.quote = backed.length == 1 ? backed.single : null;
      line.cost.text = line.quote == null ? '' : formatMoney(line.quote!.netCost!).replaceAll(',', '');
      line.initialCost = line.cost.text;
    });
  }

  void _refreshListCosts() {
    for (final l in List.of(_lines)) {
      _applyListCost(l);
    }
  }

  Future<void> _newSupplier() async {
    final id = await showSupplierForm(context);
    if (id == null || !mounted) return;
    final db = ref.read(databaseProvider);
    final s = await (db.select(db.suppliers)..where((t) => t.id.equals(id))).getSingle();
    setState(() => _supplier = s);
    _refreshListCosts();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_supplier == null) {
      await showMessage(context, Strings.chooseSupplier);
      return;
    }
    if (_lines.isEmpty) {
      await showMessage(context, Strings.addAtLeastOneItem);
      return;
    }
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final input = PurchaseInput(
      supplierId: _supplier!.id,
      supplierInvoiceNo: _supplierInvoiceNo.text,
      lines: [
        for (final l in _lines)
          PurchaseLineInput(
            productId: l.row.product.id,
            qty: l.qtyValue!,
            unitCost: l.costValue!,
            // Typed over: the cost no longer comes from the policy.
            priceListId: l.cost.text == l.initialCost ? l.quote?.quote.priceListId : null,
            listPrice: l.cost.text == l.initialCost ? l.quote?.listPrice : null,
            buyingPolicyId: l.cost.text == l.initialCost ? l.quote?.policy?.id : null,
            baseDiscountBp: l.cost.text == l.initialCost ? (l.quote?.baseBp ?? 0) : 0,
            extraDiscountBp: l.cost.text == l.initialCost ? (l.quote?.extraBp ?? 0) : 0,
          ),
      ],
      discount: moneyOrZero(_discount),
      paidAmount: moneyOrZero(_paid),
      paymentMethod: _method,
      notes: _notes.text,
    );
    final invoice = await runGuarded(
      context,
      () => ref.read(purchaseServiceProvider).post(input, user: ref.read(currentUserProvider)!),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (invoice != null) {
      showToast(context, '${Strings.invoiceSaved} ${invoice.number}');
      context.go('/purchases/${invoice.id}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final suppliers = ref.watch(activeSuppliersProvider).valueOrNull ?? const <Supplier>[];
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.f2): () => _searchFocus.requestFocus(),
      },
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
              child: Wrap(
                spacing: 24,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(Strings.newPurchase, style: theme.textTheme.headlineSmall),
                  Text('${Strings.date}: ${formatDateTime(DateTime.now())}'),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 320,
                        child: PartyPicker<Supplier>(
                          key: ValueKey(_supplier?.id),
                          items: suppliers,
                          selected: _supplier,
                          label: Strings.supplier,
                          nameOf: (s) => s.name,
                          searchFields: (s) => [s.name, s.phone],
                          onSelected: (s) {
                            setState(() => _supplier = s);
                            _refreshListCosts();
                          },
                        ),
                      ),
                      IconButton(
                        tooltip: Strings.newSupplier,
                        onPressed: _newSupplier,
                        icon: const Icon(Icons.add_business_outlined),
                      ),
                    ],
                  ),
                  SizedBox(
                    width: 200,
                    child: TextField(
                      controller: _supplierInvoiceNo,
                      decoration: const InputDecoration(
                        labelText: Strings.supplierInvoiceNo,
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: ProductSearchField(
                key: ValueKey(_searchKey),
                focusNode: _searchFocus,
                onSelected: _add,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _lines.isEmpty
                  ? const Center(child: Text(Strings.searchToAddHint))
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
                              SizedBox(width: 32, child: Text('${i + 1}', textAlign: TextAlign.center)),
                              Expanded(
                                flex: 5,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(l.row.product.nameAr),
                                    Text(
                                      '${l.row.product.code} · ${Strings.stock}: ${formatQty(l.row.stock)}',
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                flex: 2,
                                child: QtyField(
                                  controller: l.qty,
                                  focusNode: l.qtyFocus,
                                  label: Strings.qty,
                                  allowDecimal: l.row.unitAllowsDecimal,
                                  required: true,
                                  dense: true,
                                  onChanged: (_) => setState(() {}),
                                  onSubmitted: (_) => _searchFocus.requestFocus(),
                                ),
                              ),
                              Expanded(child: Text(l.row.unitName ?? '', textAlign: TextAlign.center)),
                              Expanded(
                                flex: 2,
                                child: MoneyField(
                                  controller: l.cost,
                                  label: Strings.unitCost,
                                  required: true,
                                  dense: true,
                                  onChanged: (_) => setState(() {}),
                                ),
                              ),
                              Expanded(
                                flex: 2,
                                child: Text(
                                  l.total == null ? '—' : formatMoney(l.total!),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontWeight: FontWeight.bold),
                                ),
                              ),
                              IconButton(
                                tooltip: Strings.removeLine,
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => setState(() => _lines.removeAt(i).dispose()),
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
                  AmountLabel(Strings.subtotal, _subtotal),
                  SizedBox(
                    width: 110,
                    child: MoneyField(
                      controller: _discount,
                      label: Strings.invoiceDiscount,
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  AmountLabel(Strings.total, _total, big: true),
                  SizedBox(
                    width: 120,
                    child: MoneyField(
                      controller: _paid,
                      label: Strings.paidNow,
                      onChanged: (_) => setState(() {}),
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
                  AmountLabel(Strings.remaining, _total - moneyOrZero(_paid)),
                  OutlinedButton(onPressed: () => context.go('/purchases'), child: const Text(Strings.cancel)),
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
