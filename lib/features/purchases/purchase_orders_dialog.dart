import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/services/doc_types.dart';
import '../../core/services/product_service.dart';
import '../../core/services/purchase_order_service.dart';
import '../../core/services/stock_service.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/pickers.dart';

String poStatusLabel(String s) => switch (s) {
      PoStatus.draft => 'مسودة',
      PoStatus.approved => 'معتمد',
      PoStatus.partlyReceived => 'استلام جزئي',
      PoStatus.received => 'تم الاستلام',
      PoStatus.cancelled => 'ملغي',
      _ => s,
    };

final _poListProvider = StreamProvider.autoDispose<List<PoDetail>>(
    (ref) => ref.watch(purchaseOrderServiceProvider).watchAll());

/// All purchase orders, with ordered / received / remaining at a glance.
class PurchaseOrdersDialog extends ConsumerWidget {
  const PurchaseOrdersDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = ref.watch(_poListProvider).valueOrNull ?? const <PoDetail>[];
    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('أوامر الشراء')),
          FilledButton.icon(
            onPressed: () => showDialog<void>(context: context, builder: (_) => const _NewOrderDialog()),
            icon: const Icon(Icons.add),
            label: const Text('أمر جديد'),
          ),
        ],
      ),
      content: SizedBox(
        width: 820,
        height: 460,
        child: orders.isEmpty
            ? const Center(child: Text('لا توجد أوامر شراء'))
            : ListView(
                children: [
                  for (final d in orders)
                    ListTile(
                      dense: true,
                      title: Text('${d.order.number} — ${d.supplierName}'),
                      subtitle: Text(
                          'المطلوب ${formatMoney(d.orderedValue)}  •  المستلم ${formatMoney(d.receivedValue)}  •  المتبقي ${formatMoney(d.remainingValue)}'),
                      trailing: Text(poStatusLabel(d.order.status)),
                      onTap: () => showDialog<void>(
                          context: context, builder: (_) => _OrderDetailDialog(orderId: d.order.id)),
                    ),
                ],
              ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.close))],
    );
  }
}

class _NewLine {
  _NewLine(this.row) : qty = TextEditingController(text: '1');
  final ProductRow row;
  final TextEditingController qty;
}

class _NewOrderDialog extends ConsumerStatefulWidget {
  const _NewOrderDialog();

  @override
  ConsumerState<_NewOrderDialog> createState() => _NewOrderDialogState();
}

class _NewOrderDialogState extends ConsumerState<_NewOrderDialog> {
  int? _supplierId;
  final _lines = <_NewLine>[];
  final _notes = TextEditingController();

  @override
  void dispose() {
    for (final l in _lines) {
      l.qty.dispose();
    }
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final user = ref.read(currentUserProvider);
    if (user == null) return;
    final inputs = <PoLineInput>[];
    for (final l in _lines) {
      final q = parseQty(l.qty.text, allowDecimal: l.row.unitAllowsDecimal);
      if (q == null || q <= 0) {
        await showMessage(context, 'كمية غير صحيحة: ${l.row.product.nameAr}');
        return;
      }
      inputs.add(PoLineInput(productId: l.row.product.id, qty: q));
    }
    if (_supplierId == null) {
      await showMessage(context, Strings.chooseSupplier);
      return;
    }
    final id = await runGuarded(
        context,
        () => ref.read(purchaseOrderServiceProvider).createDraft(
              supplierId: _supplierId!,
              lines: inputs,
              notes: _notes.text,
              user: user,
            ));
    if (id != null && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('أمر شراء جديد'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              StreamBuilder<List<Supplier>>(
                stream: ref.watch(partyServiceProvider).watchSuppliers(),
                builder: (context, snap) => DropdownButtonFormField<int>(
                  initialValue: _supplierId,
                  decoration: const InputDecoration(labelText: Strings.supplier),
                  items: [
                    for (final s in (snap.data ?? const <Supplier>[]).where((s) => s.isActive))
                      DropdownMenuItem(value: s.id, child: Text(s.name)),
                  ],
                  onChanged: (v) => setState(() => _supplierId = v),
                ),
              ),
              const SizedBox(height: 12),
              ProductSearchField(
                autofocus: false,
                onSelected: (r) => setState(() => _lines.add(_NewLine(r))),
              ),
              for (final l in _lines)
                Row(
                  children: [
                    Expanded(child: Text(l.row.product.nameAr)),
                    SizedBox(
                      width: 100,
                      child: TextField(
                        controller: l.qty,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'الكمية'),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() {
                        _lines.remove(l);
                        l.qty.dispose();
                      }),
                    ),
                  ],
                ),
              TextField(controller: _notes, decoration: const InputDecoration(labelText: Strings.notes)),
              const SizedBox(height: 8),
              const Text('التكلفة تُثبَّت عند الاعتماد من القائمة السارية وسياسة الشراء المسجلة لهذا المورد؛ بدون سياسة لا يُفترض خصم وتُدخل التكلفة يدوياً.',
                  style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.cancel)),
        FilledButton(onPressed: _save, child: const Text('حفظ كمسودة')),
      ],
    );
  }
}

class _OrderDetailDialog extends ConsumerStatefulWidget {
  const _OrderDetailDialog({required this.orderId});

  final int orderId;

  @override
  ConsumerState<_OrderDetailDialog> createState() => _OrderDetailDialogState();
}

class _OrderDetailDialogState extends ConsumerState<_OrderDetailDialog> {
  PoDetail? _detail;
  final _receive = <int, TextEditingController>{};
  final _invoiceNo = TextEditingController();
  int _locationId = mainLocationId;
  final _paid = TextEditingController();
  final _adv = TextEditingController();
  int _advance = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _receive.values) {
      c.dispose();
    }
    _invoiceNo.dispose();
    _paid.dispose();
    _adv.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final d = await ref.read(purchaseOrderServiceProvider).detail(widget.orderId);
    final adv = await ref.read(paymentServiceProvider).advancesOn(RefType.purchaseOrder, widget.orderId);
    if (!mounted) return;
    setState(() {
      _detail = d;
      _advance = adv;
      for (final l in d.lines) {
        _receive.putIfAbsent(l.line.id, () => TextEditingController());
        _receive[l.line.id]!.clear();
      }
    });
  }

  Future<void> _act(Future<Object?> Function(User user) action) async {
    final user = ref.read(currentUserProvider);
    if (user == null) return;
    final ok = await runGuarded(context, () async {
      await action(user);
      return true;
    });
    if (ok == true && mounted) await _load();
  }

  Future<void> _doAdvance() async {
    final amount = parseMoney(_adv.text);
    if (amount == null || amount <= 0) {
      await showMessage(context, 'أدخل مبلغاً صحيحاً');
      return;
    }
    await _act((user) =>
        ref.read(paymentServiceProvider).payAdvance(widget.orderId, amount: amount, user: user));
    _adv.clear();
  }

  Future<void> _doReceive() async {
    final d = _detail!;
    final qtys = <int, int>{};
    for (final l in d.lines) {
      final text = _receive[l.line.id]!.text.trim();
      if (text.isEmpty) continue;
      final q = parseQty(text);
      if (q == null || q < 0) {
        await showMessage(context, 'كمية غير صحيحة: ${l.productName}');
        return;
      }
      if (q > 0) qtys[l.line.id] = q;
    }
    final paid = _paid.text.trim().isEmpty ? 0 : parseMoney(_paid.text);
    if (paid == null) {
      await showMessage(context, 'المبلغ المدفوع غير صحيح');
      return;
    }
    await _act((user) => ref.read(purchaseOrderServiceProvider).receive(
          widget.orderId,
          qtyByLine: qtys,
          supplierInvoiceNo: _invoiceNo.text,
          locationId: _locationId,
          paidAmount: paid,
          user: user,
        ));
    _invoiceNo.clear();
    _paid.clear();
  }

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    if (d == null) {
      return const AlertDialog(content: SizedBox(height: 80, child: Center(child: CircularProgressIndicator())));
    }
    final status = d.order.status;
    final canReceive = status == PoStatus.approved || status == PoStatus.partlyReceived;
    final svc = ref.read(purchaseOrderServiceProvider);
    return AlertDialog(
      title: Text('${d.order.number} — ${d.supplierName}  (${poStatusLabel(status)})'),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('تاريخ الأمر: ${formatDateTime(d.order.orderDate)}'),
              if (d.order.notes != null) Text(d.order.notes!),
              const SizedBox(height: 8),
              Table(
                columnWidths: const {0: FlexColumnWidth(3)},
                children: [
                  const TableRow(children: [
                    Text('الصنف', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text('المطلوب', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text('المستلم', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text('المتبقي', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text('سعر القائمة', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text('الخصم %', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text('التكلفة', style: TextStyle(fontWeight: FontWeight.bold)),
                  ]),
                  for (final l in d.lines)
                    TableRow(children: [
                      Text(l.productName),
                      Text(formatQty(l.line.qty)),
                      Text(formatQty(l.line.qtyReceived)),
                      Text(formatQty(l.remaining)),
                      Text(l.line.listPrice == null ? '—' : formatMoney(l.line.listPrice!)),
                      Text(status == PoStatus.draft ? '—' : ((l.line.discountBp + l.line.extraDiscountBp) / 100).toString()),
                      Text(status == PoStatus.draft ? 'عند الاعتماد' : formatMoney(l.line.unitCost)),
                    ]),
                ],
              ),
              const SizedBox(height: 8),
              Text('المطلوب ${formatMoney(d.orderedValue)}  •  المستلم ${formatMoney(d.receivedValue)}  •  المتبقي ${formatMoney(d.remainingValue)}'),
              const SizedBox(height: 4),
              Text('المدفوع مقدماً للمورد: ${formatMoney(_advance)}'),
              if (status != PoStatus.cancelled && status != PoStatus.received)
                Row(
                  children: [
                    SizedBox(
                      width: 170,
                      child: TextField(
                        controller: _adv,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'دفعة مقدمة'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(onPressed: _doAdvance, child: const Text('تسجيل الدفعة')),
                  ],
                ),
              if (canReceive) ...[
                const Divider(height: 24),
                Text('استلام بضاعة', style: Theme.of(context).textTheme.titleSmall),
                for (final l in d.lines.where((l) => l.remaining > 0))
                  Row(
                    children: [
                      Expanded(child: Text('${l.productName} (المتبقي ${formatQty(l.remaining)})')),
                      SizedBox(
                        width: 110,
                        child: TextField(
                          controller: _receive[l.line.id],
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(labelText: 'الكمية المستلمة'),
                        ),
                      ),
                    ],
                  ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _invoiceNo,
                        decoration: const InputDecoration(labelText: Strings.supplierInvoiceNo),
                      ),
                    ),
                    const SizedBox(width: 12),
                    LocationDropdown(
                      label: 'مكان الاستلام',
                      value: _locationId,
                      onChanged: (v) => setState(() => _locationId = v),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 150,
                      child: TextField(
                        controller: _paid,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'المدفوع الآن'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilledButton.icon(
                    onPressed: _doReceive,
                    icon: const Icon(Icons.inventory_2_outlined),
                    label: const Text('استلام'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (status == PoStatus.draft)
          FilledButton(
            onPressed: () async {
              // A line with no recorded policy needs its cost typed; none is assumed.
              final d = await svc.detail(widget.orderId);
              final buying = ref.read(buyingPolicyServiceProvider);
              final missing = <PoLineRow>[];
              for (final l in d.lines) {
                final quotes = await buying.quotes(l.line.productId, supplierId: d.order.supplierId);
                if (quotes.where((q) => !q.missingPolicy).length != 1) missing.add(l);
              }
              if (!context.mounted) return;
              var manual = const <int, int>{};
              if (missing.isNotEmpty) {
                final typed = await showDialog<Map<int, int>>(
                    context: context, builder: (_) => _ManualCostsDialog(lines: missing));
                if (typed == null) return;
                manual = typed;
              }
              await _act((u) => svc.approve(widget.orderId, manualCosts: manual, user: u));
            },
            child: const Text('اعتماد وتثبيت السعر'),
          ),
        if (status == PoStatus.draft || status == PoStatus.approved)
          TextButton(
            onPressed: () => _act((u) => svc.cancel(widget.orderId, user: u)),
            child: const Text('إلغاء الأمر'),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.close)),
      ],
    );
  }
}

/// The cost of lines with no recorded buying policy, typed from the supplier's
/// own offer.
class _ManualCostsDialog extends StatefulWidget {
  const _ManualCostsDialog({required this.lines});

  final List<PoLineRow> lines;

  @override
  State<_ManualCostsDialog> createState() => _ManualCostsDialogState();
}

class _ManualCostsDialogState extends State<_ManualCostsDialog> {
  late final _fields = {for (final l in widget.lines) l.line.id: TextEditingController()};

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final result = <int, int>{};
    for (final e in _fields.entries) {
      final v = parseMoney(e.value.text);
      if (v == null) return;
      result[e.key] = v;
    }
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('تكلفة أصناف بلا سياسة شراء مسجلة'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final l in widget.lines)
                TextField(
                  controller: _fields[l.line.id],
                  decoration: InputDecoration(labelText: '${l.productCode} — ${l.productName}'),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.cancel)),
        FilledButton(onPressed: _save, child: const Text('اعتماد')),
      ],
    );
  }
}
