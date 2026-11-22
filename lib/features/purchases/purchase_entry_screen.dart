import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/pricing_math.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/services/buying_policy_service.dart';
import '../../core/services/doc_types.dart';
import '../../core/services/payment_service.dart';
import '../../core/services/product_service.dart';
import '../../core/services/purchase_order_service.dart';
import '../../core/services/purchase_service.dart';
import '../../core/services/stock_service.dart';
import '../../core/services/supplier_advance_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/amounts.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/number_fields.dart';
import '../../core/widgets/pickers.dart';
import '../parties/party_form_dialog.dart';
import '../sales/product_browser.dart';
import 'purchase_pickers.dart';

String _pct(int bp) => '${(bp / 100).toStringAsFixed(bp % 100 == 0 ? 0 : 1)}%';

/// Percent text -> basis points; empty is 0, null when not 0 to 100.
int? _bpOf(String text) {
  final t = text.trim().replaceAll(',', '.').replaceAll('%', '');
  if (t.isEmpty) return 0;
  final v = double.tryParse(t);
  if (v == null || v < 0 || v > 100) return null;
  return (v * 100).round();
}

class _Line {
  _Line(this.row, {this.poLine})
    : qty = TextEditingController(text: '1'),
      cost = TextEditingController(),
      extra = TextEditingController();

  final ProductRow row;
  final TextEditingController qty;

  /// The final cost of one unit, as on the supplier's invoice.
  final TextEditingController cost;

  /// An extra discount % on this line only, on top of the agreed one.
  final TextEditingController extra;
  final qtyFocus = FocusNode();

  /// From an approved purchase order: its cost is locked.
  final PoLineRow? poLine;

  /// The list price and this supplier's recorded discount, when known.
  BuyQuote? quote;

  /// Why there is no quote to start from, shown under the product.
  String? note;

  /// From the invoice being corrected: the list and discounts it was bought
  /// under, kept unless the person changes the cost.
  int? presetListId;
  int? presetListPrice;
  int? presetPolicyId;
  int presetBaseBp = 0;
  int presetExtraBp = 0;
  int? presetCategoryId;
  String? presetCategoryName;

  /// Where this line is received; null takes the invoice's place.
  int? locationId;

  int? get qtyValue => parseQty(qty.text, allowDecimal: row.unitAllowsDecimal);
  int? get costValue => parseMoney(cost.text);
  int? get total {
    final q = qtyValue, c = costValue;
    return q == null || c == null ? null : lineAmount(q, c);
  }

  int? get listPrice => poLine?.line.listPrice ?? quote?.listPrice ?? presetListPrice;

  /// The discount agreed with the supplier (base + extra of the policy).
  int? get agreedBp {
    if (poLine != null) {
      return poLine!.line.listPrice == null ? null : poLine!.line.discountBp + poLine!.line.extraDiscountBp;
    }
    final q = quote;
    if (q == null && presetListPrice != null) return presetBaseBp + presetExtraBp;
    return q == null || q.missingPolicy ? null : q.baseBp + q.extraBp;
  }

  /// The discount this invoice gives against the list price.
  int? get actualBp {
    final list = listPrice, c = costValue;
    if (list == null || list == 0 || c == null) return null;
    return ((list - c) * 10000 / list).round();
  }

  /// The agreed cost before any extra discount on this line.
  int? get expectedCost {
    final list = listPrice, bp = agreedBp;
    return list == null || bp == null ? null : applyDiscount(list, bp > 10000 ? 10000 : bp);
  }

  /// The supplier charged more than agreed.
  bool get overAgreed {
    final e = expectedCost, c = costValue;
    return e != null && c != null && c > e;
  }

  void dispose() {
    qty.dispose();
    cost.dispose();
    extra.dispose();
    qtyFocus.dispose();
  }
}

/// New purchase invoice (admin). With a supplier chosen, a line starts at the
/// list price less that supplier's recorded discount, shown step by step. A
/// cost above what was agreed is marked. Lines can come from an approved
/// purchase order or be ticked from a price list.
class PurchaseEntryScreen extends ConsumerStatefulWidget {
  const PurchaseEntryScreen({super.key, this.supplierId, this.correctInvoiceId});

  /// Starts the invoice for this supplier (from the supplier's page).
  final int? supplierId;

  /// Owner: corrects this saved invoice. The form opens with its lines; on
  /// saving, the corrected invoice replaces it (the old one stays on record,
  /// cancelled) and its payments move over.
  final int? correctInvoiceId;

  @override
  ConsumerState<PurchaseEntryScreen> createState() => _PurchaseEntryScreenState();
}

class _PurchaseEntryScreenState extends ConsumerState<PurchaseEntryScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.correctInvoiceId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadForCorrection(widget.correctInvoiceId!));
    }
    final id = widget.supplierId;
    if (id != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final db = ref.read(databaseProvider);
        final s = await (db.select(db.suppliers)..where((t) => t.id.equals(id))).getSingleOrNull();
        if (mounted && s != null) _setSupplier(s);
      });
    }
  }

  final _form = GlobalKey<FormState>();
  final _lines = <_Line>[];
  final _supplierInvoiceNo = TextEditingController();
  final _discount = TextEditingController();
  final _extraCosts = TextEditingController();
  final _vat = TextEditingController();
  final _extraCostsNote = TextEditingController();
  final _paid = TextEditingController();
  final _notes = TextEditingController();
  final _chequeNo = TextEditingController();
  final _chequeBank = TextEditingController();
  final _searchFocus = FocusNode();
  Supplier? _supplier;
  PoDetail? _order;

  /// What is left of the supplier's advances, and how much of it this
  /// invoice takes.
  AdvanceBalance? _advanceBalance;
  final _fromAdvance = TextEditingController();

  /// The invoice being corrected, when correcting.
  PurchaseInvoice? _correcting;
  String _method = PaymentMethod.cash;
  int _locationId = mainLocationId;
  bool _saving = false;
  int _searchKey = 0;
  bool _discountPercent = false;
  bool _extraOnSupplier = true;
  DateTime? _dueDate;
  DateTime _chequeDue = DateTime.now();

  int get _subtotal => _lines.fold(0, (s, l) => s + (l.total ?? 0));
  int get _discountValue => discountAmount(_discount.text, percent: _discountPercent, subtotal: _subtotal) ?? 0;
  int get _extraValue => moneyOrZero(_extraCosts);
  int get _vatValue => moneyOrZero(_vat);
  int get _total => _subtotal - _discountValue + (_extraOnSupplier ? _extraValue : 0) + _vatValue;
  int get _advanceValue => moneyOrZero(_fromAdvance);

  /// What the advances can give: what is left of them, plus (when
  /// correcting) what the old invoice took, which comes back on saving.
  int get _advanceAvailable => (_advanceBalance?.remaining ?? 0) + (_correcting?.advanceUsed ?? 0);
  int get _paidValue => _correcting != null ? _correctingPaid : moneyOrZero(_paid);
  int _correctingPaid = 0;
  int get _remaining => _total - _paidValue - _advanceValue;

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    for (final c in [
      _supplierInvoiceNo,
      _discount,
      _extraCosts,
      _vat,
      _extraCostsNote,
      _paid,
      _notes,
      _chequeNo,
      _chequeBank,
      _fromAdvance,
    ]) {
      c.dispose();
    }
    _searchFocus.dispose();
    super.dispose();
  }

  void _add(ProductRow row, {int? qty}) {
    final line = _Line(row);
    if (qty != null) line.qty.text = formatQty(qty);
    setState(() {
      _lines.add(line);
      _searchKey++;
    });
    _applyListCost(line);
    if (qty == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        line.qtyFocus.requestFocus();
        line.qty.selection = TextSelection(baseOffset: 0, extentOffset: line.qty.text.length);
      });
    }
  }

  /// From the product browser: one more of a product already on the invoice
  /// (outside a purchase order's lines), or a new line for it.
  Future<void> _pickFromBrowser(ProductRow row) async {
    final existing = _lines.where((l) => l.poLine == null && l.row.product.id == row.product.id).firstOrNull;
    if (existing != null) {
      existing.qty.text = formatQty((existing.qtyValue ?? 0) + qtyScale);
      setState(() {});
      return;
    }
    _add(row, qty: qtyScale);
  }

  Future<void> _browse() => showProductBrowser(
        context,
        onPick: _pickFromBrowser,
        countOf: (id) =>
            _lines.where((l) => l.row.product.id == id).fold(0, (s, l) => s + (l.qtyValue ?? 0)) ~/ qtyScale,
        inStockOnly: false,
      );

  /// With a supplier chosen, a line starts at the cost its recorded policy
  /// gives, when exactly one version has one. With a list price but no
  /// policy, the list price shows and the cost is typed: no discount is assumed.
  Future<void> _applyListCost(_Line line) async {
    final supplier = _supplier;
    if (supplier == null || line.poLine != null || line.presetListPrice != null) return;
    final quotes = await ref.read(buyingPolicyServiceProvider).quotes(line.row.product.id, supplierId: supplier.id);
    final backed = quotes.where((q) => !q.missingPolicy).toList();
    if (!mounted || supplier.id != _supplier?.id) return;
    setState(() {
      line.extra.clear();
      if (backed.length == 1) {
        line.quote = backed.single;
        line.note = backed.single.fromCategory
            ? '${backed.single.discountSource} ${_pct(backed.single.baseBp)} (لا يوجد خصم خاص بهذا المورد)'
            : null;
        line.cost.text = _plain(backed.single.netCost!);
      } else if (backed.isEmpty && quotes.length == 1) {
        line.quote = quotes.single;
        line.note = 'لا يوجد خصم مسجل لهذا المورد على ${quotes.single.quote.label}؛ اكتب التكلفة';
        line.cost.clear();
      } else {
        line.quote = null;
        line.note = quotes.isEmpty ? 'لا يوجد سعر قائمة ساري لهذا الصنف' : 'للصنف أكثر من قائمة سارية؛ اكتب التكلفة';
        line.cost.clear();
      }
    });
  }

  String _plain(int money) => formatMoney(money).replaceAll(',', '');

  /// An extra % on the line: the cost becomes list less agreed + extra.
  void _extraChanged(_Line l) {
    final list = l.listPrice, agreed = l.agreedBp ?? 0, bp = _bpOf(l.extra.text);
    if (list == null || bp == null) return setState(() {});
    final total = agreed + bp;
    setState(() => l.cost.text = _plain(applyDiscount(list, total > 10000 ? 10000 : total)));
  }

  void _refreshListCosts() {
    for (final l in List.of(_lines)) {
      _applyListCost(l);
    }
  }

  void _setSupplier(Supplier? s) {
    if (_order != null && s?.id != _order!.order.supplierId) {
      // Lines from another supplier's order cannot stay.
      _clearOrder();
    }
    setState(() {
      _supplier = s;
      _advanceBalance = null;
      _fromAdvance.clear();
    });
    _loadAdvances();
    _refreshListCosts();
  }

  Future<void> _loadAdvances() async {
    final s = _supplier;
    if (s == null) return;
    final b = await ref.read(supplierAdvanceServiceProvider).balance(s.id);
    if (!mounted || s.id != _supplier?.id) return;
    setState(() => _advanceBalance = b);
  }

  /// Takes as much of the advances as the invoice still needs.
  void _useAdvance() {
    final need = _total - _paidValue;
    final take = need < _advanceAvailable ? need : _advanceAvailable;
    setState(() => _fromAdvance.text = take <= 0 ? '' : _plain(take));
  }

  /// Opens the saved invoice in the form, with its lines and their lists.
  Future<void> _loadForCorrection(int id) async {
    final service = ref.read(purchaseServiceProvider);
    final d = await service.detail(id);
    final products = ref.read(productServiceProvider);
    final lines = <_Line>[];
    for (final l in d.lines) {
      final line = _Line(await products.row(l.item.productId));
      line.qty.text = formatQty(l.item.qty);
      line.cost.text = _plain(l.item.unitCost);
      line.presetListId = l.item.priceListId;
      line.presetListPrice = l.item.listPrice;
      line.presetPolicyId = l.item.buyingPolicyId;
      line.presetBaseBp = l.item.baseDiscountBp;
      line.presetExtraBp = l.item.extraDiscountBp;
      line.presetCategoryId = l.item.listCategoryId;
      line.presetCategoryName = l.item.listCategoryName;
      line.note = 'من الفاتورة الأصلية ${d.invoice.number}';
      lines.add(line);
    }
    final paid = await ref.read(paymentServiceProvider).onInvoice(RefType.purchaseInvoice, id);
    if (!mounted) return;
    final inv = d.invoice;
    setState(() {
      _correcting = inv;
      _correctingPaid = paid.where((p) => p.status == DocStatus.active).fold(0, (s, p) => s + p.amount);
      _supplier = d.supplier;
      _lines.addAll(lines);
      _supplierInvoiceNo.text = inv.supplierInvoiceNo ?? '';
      _discountPercent = inv.discountBp != null;
      _discount.text = inv.discountBp != null
          ? (inv.discountBp! / 100).toString()
          : (inv.discount == 0 ? '' : _plain(inv.discount));
      _extraCosts.text = inv.extraCosts == 0 ? '' : _plain(inv.extraCosts);
      _extraOnSupplier = inv.extraCostsOnSupplier;
      _vat.text = inv.vatAmount == 0 ? '' : _plain(inv.vatAmount);
      _notes.text = inv.notes ?? '';
      _dueDate = inv.dueDate;
      _fromAdvance.text = inv.advanceUsed == 0 ? '' : _plain(inv.advanceUsed);
    });
    _loadAdvances();
  }

  void _clearOrder() {
    setState(() {
      for (final l in _lines.where((l) => l.poLine != null).toList()) {
        _lines.remove(l);
        l.dispose();
      }
      _order = null;
    });
  }

  Future<void> _newSupplier() async {
    final id = await showSupplierForm(context);
    if (id == null || !mounted) return;
    final db = ref.read(databaseProvider);
    final s = await (db.select(db.suppliers)..where((t) => t.id.equals(id))).getSingle();
    _setSupplier(s);
  }

  Future<void> _fromOrder() async {
    final picked = await pickPurchaseOrder(context, supplierId: _supplier?.id);
    if (picked == null || !mounted) return;
    final db = ref.read(databaseProvider);
    final products = ref.read(productServiceProvider);
    final supplier = await (db.select(db.suppliers)..where((t) => t.id.equals(picked.order.supplierId))).getSingle();
    final lines = <_Line>[];
    for (final l in picked.lines.where((l) => l.remaining > 0)) {
      final line = _Line(await products.row(l.line.productId), poLine: l);
      line.qty.text = formatQty(l.remaining);
      line.cost.text = _plain(l.line.unitCost);
      lines.add(line);
    }
    if (!mounted) return;
    _clearOrder();
    setState(() {
      _supplier = supplier;
      _order = picked;
      _lines.insertAll(0, lines);
    });
    _loadAdvances();
    _refreshListCosts();
  }

  Future<void> _fromList() async {
    final picked = await pickFromPriceList(context);
    if (picked == null || !mounted) return;
    final products = ref.read(productServiceProvider);
    for (final p in picked) {
      _add(await products.row(p.productId), qty: p.qty);
    }
  }

  Future<void> _pickDate(bool cheque) async {
    final d = await showDatePicker(
      context: context,
      initialDate: (cheque ? _chequeDue : _dueDate) ?? DateTime.now().add(const Duration(days: 30)),
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
    );
    if (d != null) setState(() => cheque ? _chequeDue = d : _dueDate = d);
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
    if (_advanceValue > _advanceAvailable) {
      await showMessage(context, 'رصيد الدفعات المقدمة لهذا المورد ${formatMoney(_advanceAvailable)} فقط');
      return;
    }
    if (_remaining < 0) {
      await showMessage(context, 'المدفوع والمخصوم من الدفعة المقدمة أكبر من إجمالي الفاتورة');
      return;
    }
    final over = _lines.where((l) => l.overAgreed).toList();
    if (over.isNotEmpty) {
      final go = await _confirm(
        'تكلفة أعلى من المتفق',
        'هذه الأصناف تكلفتها أعلى من سعر القائمة ناقص خصم المورد المسجل:\n'
            '${over.map((l) => '• ${l.row.product.nameAr}: المتفق ${formatMoney(l.expectedCost!)} والفاتورة ${formatMoney(l.costValue!)}').join('\n')}\n\n'
            'راجع فاتورة المورد. هل تحفظ بهذه الأسعار؟',
      );
      if (go != true || !mounted) return;
    }
    if (_correcting != null) {
      await _saveCorrection();
      return;
    }
    var allowDuplicate = false;
    final no = _supplierInvoiceNo.text.trim();
    if (no.isNotEmpty) {
      final same = await ref.read(purchaseServiceProvider).findBySupplierNo(_supplier!.id, no);
      if (same != null && mounted) {
        final go = await _confirm(
          'رقم فاتورة المورد مكرر',
          'رقم فاتورة المورد "$no" مسجل من قبل في الفاتورة ${same.number} بتاريخ ${formatDate(same.date)} '
              'بإجمالي ${formatMoney(same.total)}.\n\nهل هذه فاتورة مختلفة فعلاً؟',
        );
        if (go != true || !mounted) return;
        allowDuplicate = true;
      }
    }
    if (!mounted) return;
    setState(() => _saving = true);
    final user = ref.read(currentUserProvider)!;
    final cheque = _method == PaymentMethod.cheque
        ? ChequeInput(number: _chequeNo.text, bank: _chequeBank.text, dueDate: _chequeDue)
        : null;
    final free = [for (final l in _lines.where((l) => l.poLine == null)) _lineInput(l)];
    final invoice = await runGuarded(context, () async {
      if (_order != null) {
        final received = await PurchaseOrderService(ref.read(databaseProvider)).receive(
          _order!.order.id,
          qtyByLine: {for (final l in _lines.where((l) => l.poLine != null)) l.poLine!.line.id: l.qtyValue!},
          supplierInvoiceNo: _supplierInvoiceNo.text,
          paidAmount: moneyOrZero(_paid),
          paymentMethod: _method,
          cheque: cheque,
          locationId: _locationId,
          discount: _discountValue,
          extraCosts: _extraValue,
          extraCostsOnSupplier: _extraOnSupplier,
          extraCostsNote: _extraCostsNote.text,
          dueDate: _dueDate,
          notes: _notes.text,
          vatAmount: _vatValue,
          allowDuplicateSupplierNo: allowDuplicate,
          extraLines: free,
          user: user,
        );
        if (_advanceValue > 0) {
          await ref
              .read(supplierAdvanceServiceProvider)
              .allocate(invoiceId: received.id, amount: _advanceValue, user: user);
        }
        return received;
      }
      return ref
          .read(purchaseServiceProvider)
          .post(
            PurchaseInput(
              supplierId: _supplier!.id,
              supplierInvoiceNo: _supplierInvoiceNo.text,
              lines: free,
              discount: _discountValue,
              extraCosts: _extraValue,
              extraCostsOnSupplier: _extraOnSupplier,
              extraCostsNote: _extraCostsNote.text,
              dueDate: _dueDate,
              vatAmount: _vatValue,
              paidAmount: moneyOrZero(_paid),
              paymentMethod: _method,
              cheque: cheque,
              notes: _notes.text,
              locationId: _locationId,
              allowDuplicateSupplierNo: allowDuplicate,
              advanceAmount: _advanceValue,
              discountBp: _discountBp,
            ),
            user: user,
          );
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (invoice != null) {
      showToast(context, '${Strings.invoiceSaved} ${invoice.number}');
      context.go('/purchases/${invoice.id}');
    }
  }

  /// The invoice discount as a percent, when it was typed as one.
  int? get _discountBp => _discountPercent && _discount.text.trim().isNotEmpty ? _bpOf(_discount.text) : null;

  /// Owner: the corrected invoice replaces the saved one, after a reason.
  Future<void> _saveCorrection() async {
    final old = _correcting!;
    final reason = await askReason(context, title: 'سبب تصحيح الفاتورة ${old.number}');
    if (reason == null || !mounted) return;
    setState(() => _saving = true);
    final fixed = await runGuarded(
      context,
      () => ref.read(purchaseServiceProvider).correct(
            old.id,
            PurchaseInput(
              supplierId: old.supplierId,
              supplierInvoiceNo: _supplierInvoiceNo.text,
              lines: [for (final l in _lines) _lineInput(l)],
              date: old.date,
              discount: _discountValue,
              discountBp: _discountBp,
              extraCosts: _extraValue,
              extraCostsOnSupplier: _extraOnSupplier,
              extraCostsNote: _extraCostsNote.text,
              dueDate: _dueDate,
              vatAmount: _vatValue,
              notes: _notes.text,
              locationId: _locationId,
              advanceAmount: _advanceValue,
            ),
            reason: reason,
            user: ref.read(currentUserProvider)!,
          ),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (fixed != null) {
      showToast(context, 'تم التصحيح: ${old.number} ← ${fixed.number}');
      context.go('/purchases/${fixed.id}');
    }
  }

  /// Splits a line so part of it goes to another place: a copy with the same
  /// cost and discounts, an empty quantity, and the next place.
  Future<void> _split(_Line l) async {
    final places = (await ref.read(locationServiceProvider).watchAll().first).where((p) => p.isActive).toList();
    final here = l.locationId ?? _locationId;
    final other = places.where((p) => p.id != here).firstOrNull;
    final c = _Line(l.row)
      ..quote = l.quote
      ..note = l.note
      ..presetListId = l.presetListId
      ..presetListPrice = l.presetListPrice
      ..presetPolicyId = l.presetPolicyId
      ..presetBaseBp = l.presetBaseBp
      ..presetExtraBp = l.presetExtraBp
      ..presetCategoryId = l.presetCategoryId
      ..presetCategoryName = l.presetCategoryName
      ..locationId = other?.id ?? here;
    c.cost.text = l.cost.text;
    c.extra.text = l.extra.text;
    c.qty.text = '';
    if (!mounted) return;
    setState(() => _lines.insert(_lines.indexOf(l) + 1, c));
    WidgetsBinding.instance.addPostFrameCallback((_) => c.qtyFocus.requestFocus());
  }

  /// The line as saved: the list price and version are kept whenever they are
  /// known, so the stock knows its list; the discount is what this invoice gave.
  PurchaseLineInput _lineInput(_Line l) {
    if (l.quote == null && l.presetListPrice != null) {
      final list = l.presetListPrice!, c = l.costValue!;
      final actual = list == 0 ? 0 : ((list - c) * 10000 / list).round();
      final base = actual < l.presetBaseBp ? (actual < 0 ? 0 : actual) : l.presetBaseBp;
      return PurchaseLineInput(
        productId: l.row.product.id,
        qty: l.qtyValue!,
        unitCost: c,
        priceListId: l.presetListId,
        listPrice: list,
        buyingPolicyId: l.presetPolicyId,
        baseDiscountBp: base,
        extraDiscountBp: actual > base ? actual - base : 0,
        listCategoryId: l.presetCategoryId,
        listCategoryName: l.presetCategoryName,
        locationId: l.locationId,
      );
    }
    final q = l.quote;
    final actual = l.actualBp;
    final base = q == null || q.missingPolicy ? 0 : q.baseBp;
    return PurchaseLineInput(
      productId: l.row.product.id,
      qty: l.qtyValue!,
      unitCost: l.costValue!,
      priceListId: q?.quote.priceListId,
      listPrice: q?.listPrice,
      buyingPolicyId: q?.policy?.id,
      listCategoryId: q != null && q.fromCategory ? q.category!.id : null,
      listCategoryName: q != null && q.fromCategory ? q.category!.name : null,
      baseDiscountBp: q == null ? 0 : (actual == null ? base : (actual < base ? (actual < 0 ? 0 : actual) : base)),
      extraDiscountBp: q == null || actual == null || actual <= base ? 0 : actual - base,
      locationId: l.poLine == null ? l.locationId : null,
    );
  }

  Future<bool?> _confirm(String title, String text) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(width: 480, child: SingleChildScrollView(child: Text(text))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('رجوع')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('حفظ')),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const warn = AppColors.warn;
    final suppliers = ref.watch(activeSuppliersProvider).valueOrNull ?? const <Supplier>[];
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.f2): () => _searchFocus.requestFocus(),
        const SingleActivator(LogicalKeyboardKey.f3): _browse,
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
                  if (_correcting != null)
                    IconButton.outlined(
                      tooltip: 'رجوع للفاتورة',
                      onPressed: () => context.go('/purchases/${_correcting!.id}'),
                      icon: const Icon(Icons.arrow_forward),
                    ),
                  Text(_correcting == null ? Strings.newPurchase : 'تصحيح الفاتورة ${_correcting!.number}',
                      style: theme.textTheme.headlineSmall),
                  Text('${Strings.date}: ${formatDateTime(_correcting?.date ?? DateTime.now())}'),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 300,
                        child: PartyPicker<Supplier>(
                          key: ValueKey(_supplier?.id),
                          items: suppliers,
                          selected: _supplier,
                          label: Strings.supplier,
                          nameOf: (s) => s.name,
                          searchFields: (s) => [s.name, s.phone],
                          onSelected: _setSupplier,
                        ),
                      ),
                      IconButton(
                        tooltip: Strings.newSupplier,
                        onPressed: _newSupplier,
                        icon: const Icon(Icons.add_business_outlined),
                      ),
                    ],
                  ),
                  LocationDropdown(
                    label: 'مكان الاستلام',
                    value: _locationId,
                    onChanged: (v) => setState(() => _locationId = v),
                  ),
                  SizedBox(
                    width: 190,
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
              child: Row(
                children: [
                  Expanded(
                    child: ProductSearchField(key: ValueKey(_searchKey), focusNode: _searchFocus, onSelected: _add),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: _browse,
                    icon: const Icon(Icons.grid_view_rounded),
                    label: const Text('تصفح الأصناف (F3)'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _fromOrder,
                    icon: const Icon(Icons.assignment_outlined),
                    label: const Text('من أمر شراء'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _fromList,
                    icon: const Icon(Icons.playlist_add_check),
                    label: const Text('من قائمة أسعار'),
                  ),
                ],
              ),
            ),
            if (_correcting != null)
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 8, 24, 0),
                child: InfoNote(
                  'تصحيح فاتورة محفوظة: عند الحفظ تُسجل الفاتورة المصححة برقم جديد، وتنتقل إليها المدفوعات '
                  'والمخصوم من الدفعات المقدمة، وتُلغى الفاتورة الأصلية وتبقى في السجل. المخزون والتكلفة '
                  'ورصيد المورد والقيود تتعدل تلقائياً، ويُسجل التصحيح في سجل العمليات.',
                  warning: true,
                ),
              ),
            if (_order != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                child: Row(
                  children: [
                    Icon(Icons.assignment_turned_in_outlined, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'استلام من أمر الشراء ${_order!.order.number}: الأسعار مثبتة من الأمر، '
                        'والكمية لا تزيد عن المتبقي. يمكن إضافة أصناف أخرى على نفس الفاتورة.',
                      ),
                    ),
                    TextButton(onPressed: _clearOrder, child: const Text('إلغاء الربط بالأمر')),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            if (_lines.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: DefaultTextStyle.merge(
                  style: theme.textTheme.labelMedium!.copyWith(fontWeight: FontWeight.bold),
                  child: const Row(
                    children: [
                      SizedBox(width: 32),
                      Expanded(flex: 5, child: Text('الصنف')),
                      Expanded(flex: 2, child: Text(Strings.qty, textAlign: TextAlign.center)),
                      Expanded(flex: 2, child: Text('سعر القائمة', textAlign: TextAlign.center)),
                      Expanded(flex: 2, child: Text('خصم المورد', textAlign: TextAlign.center)),
                      Expanded(flex: 2, child: Text('خصم إضافي %', textAlign: TextAlign.center)),
                      Expanded(flex: 2, child: Text('التكلفة', textAlign: TextAlign.center)),
                      Expanded(flex: 2, child: Text('الإجمالي', textAlign: TextAlign.center)),
                      SizedBox(width: 48),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: _lines.isEmpty
                  ? const Center(
                      child: Text(
                        'ابحث عن صنف، أو اختر «من أمر شراء» أو «من قائمة أسعار» لإضافة أصناف كثيرة مرة واحدة',
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      itemCount: _lines.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) => _lineRow(i, theme, warn),
                    ),
            ),
            _bottom(theme),
          ],
        ),
      ),
    );
  }

  Widget _lineRow(int i, ThemeData theme, Color warn) {
    final l = _lines[i];
    final list = l.listPrice;
    final agreed = l.agreedBp;
    final actual = l.actualBp;
    final po = l.poLine;
    String? message;
    Color? color;
    if (l.overAgreed) {
      message =
          'أعلى من المتفق: خصم المورد ${_pct(agreed!)} والفاتورة '
          '${actual == null
              ? '—'
              : actual < 0
              ? 'أعلى من سعر القائمة'
              : _pct(actual)} '
          '(المتفق ${formatMoney(l.expectedCost!)})';
      color = warn;
    } else if (po != null) {
      message = 'من أمر الشراء · المتبقي ${formatQty(po.remaining)}';
      color = theme.colorScheme.primary;
    } else if (l.note != null) {
      message = l.note;
      color = theme.colorScheme.outline;
    }
    return Container(
      color: l.overAgreed ? AppColors.warnBg : null,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 32, child: Text('${i + 1}', textAlign: TextAlign.center)),
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(l.row.product.nameAr),
                  ModelTag(l.row.product.modelNo),
                ]),
                Text(
                  '${l.row.product.code} · ${l.row.product.manufacturerCode} · ${Strings.stock}: ${formatQty(l.row.stock)} ${l.row.unitName ?? ''}',
                  style: theme.textTheme.bodySmall,
                ),
                if (message != null) Text(message, style: theme.textTheme.bodySmall!.copyWith(color: color)),
                // Where it is received: part can go to the showroom and part to
                // the warehouse (split the line).
                if (po == null)
                  _LinePlace(
                    value: l.locationId ?? _locationId,
                    onChanged: (v) => setState(() => l.locationId = v),
                    onSplit: () => _split(l),
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
          Expanded(flex: 2, child: Text(list == null ? '—' : formatMoney(list), textAlign: TextAlign.center)),
          Expanded(flex: 2, child: Text(agreed == null ? '—' : _pct(agreed), textAlign: TextAlign.center)),
          Expanded(
            flex: 2,
            child: po != null || list == null
                ? const SizedBox()
                : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: TextFormField(
                      controller: l.extra,
                      textAlign: TextAlign.center,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: '%',
                        contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 9),
                      ),
                      validator: (v) => _bpOf(v ?? '') == null ? '0 - 100' : null,
                      onChanged: (_) => _extraChanged(l),
                    ),
                  ),
          ),
          Expanded(
            flex: 2,
            child: po != null
                ? Text(formatMoney(l.costValue ?? 0), textAlign: TextAlign.center)
                : MoneyField(
                    controller: l.cost,
                    label: Strings.unitCost,
                    required: true,
                    dense: true,
                    onChanged: (_) => setState(() => l.extra.clear()),
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
  }

  Widget _bottom(ThemeData theme) {
    final hasRemaining = _remaining > 0;
    return Container(
      color: theme.colorScheme.surfaceContainerHigh,
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: 16,
            runSpacing: 10,
            children: [
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _notes,
                  decoration: const InputDecoration(labelText: Strings.notes, isDense: true),
                ),
              ),
              AmountLabel(Strings.subtotal, _subtotal),
              SizedBox(
                width: 280,
                child: DiscountField(
                  controller: _discount,
                  label: Strings.invoiceDiscount,
                  percent: _discountPercent,
                  subtotal: _subtotal,
                  onModeChanged: (v) => setState(() => _discountPercent = v),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              SizedBox(
                width: 150,
                child: MoneyField(controller: _extraCosts, label: 'نقل وتحميل', onChanged: (_) => setState(() {})),
              ),
              if (_extraValue > 0) ...[
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  segments: const [
                    ButtonSegment(value: true, label: Text('على فاتورة المورد')),
                    ButtonSegment(value: false, label: Text('دُفعت لجهة أخرى')),
                  ],
                  selected: {_extraOnSupplier},
                  onSelectionChanged: (s) => setState(() => _extraOnSupplier = s.first),
                ),
                if (!_extraOnSupplier)
                  SizedBox(
                    width: 170,
                    child: TextField(
                      controller: _extraCostsNote,
                      decoration: const InputDecoration(labelText: 'لمن؟ (اختياري)', isDense: true),
                    ),
                  ),
              ],
              SizedBox(
                width: 170,
                child: Tooltip(
                  message: 'ضريبة القيمة المضافة على فاتورة المورد الضريبية، القابلة للخصم. لا تدخل في تكلفة الأصناف.',
                  child: MoneyField(controller: _vat, label: 'ضريبة مدخلات (إن وُجدت)', onChanged: (_) => setState(() {})),
                ),
              ),
              AmountLabel(Strings.total, _total, big: true),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: 16,
            runSpacing: 10,
            children: [
              if (_extraValue > 0)
                Text(
                  _extraOnSupplier
                      ? 'النقل يُضاف لتكلفة الأصناف ولحساب المورد'
                      : 'النقل يُضاف لتكلفة الأصناف ويُسجل مصروف شراء نقدي (لا يُخصم مرتين من صافي الربح)',
                  style: theme.textTheme.bodySmall,
                ),
              if (_advanceAvailable > 0 || _advanceValue > 0)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(
                    width: 170,
                    child: MoneyField(
                      controller: _fromAdvance,
                      label: 'من الدفعات المقدمة',
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Tooltip(
                    message: 'رصيد الدفعات المقدمة لهذا المورد (لأي ماركة أو قائمة)',
                    child: TextButton.icon(
                      onPressed: _useAdvance,
                      icon: const Icon(Icons.account_balance_wallet_outlined, size: 18),
                      label: Text('المتاح ${formatMoney(_advanceAvailable)}'),
                    ),
                  ),
                ]),
              if (_correcting != null) ...[
                AmountLabel('مدفوع من قبل (ينتقل للفاتورة المصححة)', _correctingPaid),
                AmountLabel(Strings.remaining, _remaining, color: _remaining > 0 ? AppColors.warn : AppColors.good),
              ],
              if (_correcting == null) ...[
                SizedBox(
                  width: 130,
                  child: MoneyField(controller: _paid, label: Strings.paidNow, onChanged: (_) => setState(() {})),
                ),
                DropdownButton<String>(
                  value: _method,
                  items: const [
                    DropdownMenuItem(value: PaymentMethod.cash, child: Text(Strings.methodCash)),
                    DropdownMenuItem(value: PaymentMethod.bank, child: Text(Strings.methodBank)),
                    DropdownMenuItem(value: PaymentMethod.cheque, child: Text('شيك')),
                  ],
                  onChanged: (v) => setState(() => _method = v!),
                ),
                if (_method == PaymentMethod.cheque && moneyOrZero(_paid) > 0) ...[
                  SizedBox(
                    width: 130,
                    child: TextFormField(
                      controller: _chequeNo,
                      decoration: const InputDecoration(labelText: 'رقم الشيك', isDense: true),
                      validator: (v) => (v ?? '').trim().isEmpty ? Strings.required : null,
                    ),
                  ),
                  SizedBox(
                    width: 130,
                    child: TextField(
                      controller: _chequeBank,
                      decoration: const InputDecoration(labelText: 'البنك', isDense: true),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _pickDate(true),
                    icon: const Icon(Icons.event),
                    label: Text('استحقاق الشيك ${formatDate(_chequeDue)}'),
                  ),
                ],
                AmountLabel(Strings.remaining, _remaining, color: _remaining > 0 ? AppColors.warn : AppColors.good),
                if (hasRemaining)
                  OutlinedButton.icon(
                    onPressed: () => _pickDate(false),
                    icon: const Icon(Icons.event_note),
                    label: Text(_dueDate == null ? 'تاريخ استحقاق الباقي' : 'يستحق ${formatDate(_dueDate!)}'),
                  ),
              ],
              OutlinedButton(onPressed: () => context.go('/purchases'), child: const Text(Strings.cancel)),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: Icon(_correcting == null ? Icons.save : Icons.published_with_changes),
                label: Text(_correcting == null ? '${Strings.save} (Ctrl+S)' : 'حفظ التصحيح (Ctrl+S)'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A purchase line's receiving place as a small menu, with a button to split
/// the line onto another place.
class _LinePlace extends ConsumerWidget {
  const _LinePlace({required this.value, required this.onChanged, required this.onSplit});

  final int value;
  final ValueChanged<int> onChanged;
  final VoidCallback onSplit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder<List<Location>>(
      stream: ref.watch(locationServiceProvider).watchAll(),
      builder: (context, snap) {
        final places = (snap.data ?? const <Location>[]).where((p) => p.isActive || p.id == value).toList();
        final name = places.where((p) => p.id == value).firstOrNull?.name ?? '';
        return Wrap(spacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          PopupMenuButton<int>(
            tooltip: 'مكان استلام هذا الصنف',
            onSelected: onChanged,
            itemBuilder: (_) => [for (final p in places) PopupMenuItem(value: p.id, child: Text(p.name))],
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.place_outlined, size: 14, color: AppColors.brand),
                const SizedBox(width: 2),
                Flexible(
                  child: Text('يُستلم في: $name',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: AppColors.brand, fontWeight: FontWeight.w700)),
                ),
                const Icon(Icons.arrow_drop_down, size: 16, color: AppColors.brand),
              ]),
            ),
          ),
          if (places.length > 1)
            TextButton.icon(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
              onPressed: onSplit,
              icon: const Icon(Icons.call_split, size: 14),
              label: const Text('تقسيم على مكان آخر', style: TextStyle(fontSize: 12)),
            ),
        ]);
      },
    );
  }
}
