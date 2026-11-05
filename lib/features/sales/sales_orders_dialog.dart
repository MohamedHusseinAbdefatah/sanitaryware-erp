import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/services/approval_service.dart';
import '../../core/services/doc_types.dart';
import '../../core/services/product_service.dart';
import '../../core/services/sales_order_service.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/pickers.dart';

String soStatusLabel(String s) => switch (s) {
      SoStatus.quotation => 'عرض سعر',
      SoStatus.draft => 'مسودة',
      SoStatus.confirmed => 'مؤكد',
      SoStatus.partlyDelivered => 'تسليم جزئي',
      SoStatus.delivered => 'تم التسليم',
      SoStatus.cancelled => 'ملغي',
      _ => s,
    };

/// Percent text -> basis points; null if not a number from 0 to 100.
int? _bp(String text) {
  final t = text.trim().replaceAll(',', '.');
  if (t.isEmpty) return 0;
  final v = double.tryParse(t);
  if (v == null || v < 0 || v > 100) return null;
  return (v * 100).round();
}

final _soListProvider = StreamProvider.autoDispose<List<SoDetail>>(
    (ref) => ref.watch(salesOrderServiceProvider).watchAll());

/// All sales orders, with ordered / delivered / remaining at a glance.
class SalesOrdersDialog extends ConsumerWidget {
  const SalesOrdersDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = ref.watch(_soListProvider).valueOrNull ?? const <SoDetail>[];
    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('أوامر البيع')),
          TextButton.icon(
            onPressed: () => showDialog<void>(context: context, builder: (_) => const _ApprovalsDialog()),
            icon: const Icon(Icons.verified_outlined),
            label: const Text('سجل الموافقات'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: () => showDialog<void>(context: context, builder: (_) => const _NewSoDialog()),
            icon: const Icon(Icons.add),
            label: const Text('أمر جديد'),
          ),
        ],
      ),
      content: SizedBox(
        width: 820,
        height: 460,
        child: orders.isEmpty
            ? const Center(child: Text('لا توجد أوامر بيع'))
            : ListView(
                children: [
                  for (final d in orders)
                    ListTile(
                      dense: true,
                      title: Text('${d.order.number} — ${d.customerName} (${SaleChannel.label(d.order.channel)})'),
                      subtitle: Text(
                          'المطلوب ${formatMoney(d.orderedValue)}  •  المسلَّم ${formatMoney(d.deliveredValue)}  •  المتبقي ${formatMoney(d.remainingValue)}'),
                      trailing: Text(soStatusLabel(d.order.status)),
                      onTap: () => showDialog<void>(
                          context: context, builder: (_) => _SoDetailDialog(orderId: d.order.id)),
                    ),
                ],
              ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.close))],
    );
  }
}

class _NewLine {
  _NewLine(this.row)
      : qty = TextEditingController(text: '1'),
        extra = TextEditingController();
  final ProductRow row;
  final TextEditingController qty;
  final TextEditingController extra;
}

class _NewSoDialog extends ConsumerStatefulWidget {
  const _NewSoDialog();

  @override
  ConsumerState<_NewSoDialog> createState() => _NewSoDialogState();
}

class _NewSoDialogState extends ConsumerState<_NewSoDialog> {
  int? _customerId;
  String _channel = SaleChannel.showroom;
  final _lines = <_NewLine>[];
  final _notes = TextEditingController();
  final _external = TextEditingController();
  final _reason = TextEditingController();
  bool _quotation = false;

  @override
  void dispose() {
    for (final l in _lines) {
      l.qty.dispose();
      l.extra.dispose();
    }
    _notes.dispose();
    _external.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final user = ref.read(currentUserProvider);
    if (user == null) return;
    if (_customerId == null) {
      await showMessage(context, 'اختر العميل');
      return;
    }
    final inputs = <SoLineInput>[];
    for (final l in _lines) {
      final q = parseQty(l.qty.text, allowDecimal: l.row.unitAllowsDecimal);
      final bp = _bp(l.extra.text);
      if (q == null || q <= 0 || bp == null) {
        await showMessage(context, 'بيانات غير صحيحة: ${l.row.product.nameAr}');
        return;
      }
      inputs.add(SoLineInput(productId: l.row.product.id, qty: q, extraDiscountBp: bp));
    }
    final id = await runGuarded(
        context,
        () => ref.read(salesOrderServiceProvider).createDraft(
              customerId: _customerId!,
              lines: inputs,
              channel: _channel,
              notes: _notes.text,
              externalId: _external.text,
              asQuotation: _quotation,
              approvalReason: _reason.text,
              user: user,
            ));
    if (id != null && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('أمر بيع جديد'),
      content: SizedBox(
        width: 680,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: StreamBuilder<List<Customer>>(
                      stream: ref.watch(partyServiceProvider).watchCustomers(activeOnly: true),
                      builder: (context, snap) => DropdownButtonFormField<int>(
                        initialValue: _customerId,
                        decoration: const InputDecoration(labelText: 'العميل'),
                        items: [
                          for (final c in snap.data ?? const <Customer>[])
                            DropdownMenuItem(value: c.id, child: Text(c.name)),
                        ],
                        onChanged: (v) => setState(() => _customerId = v),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 160,
                    child: DropdownButtonFormField<String>(
                      initialValue: _channel,
                      decoration: const InputDecoration(labelText: 'القناة'),
                      items: [
                        for (final c in SaleChannel.all)
                          DropdownMenuItem(value: c, child: Text(SaleChannel.label(c))),
                      ],
                      onChanged: (v) => setState(() => _channel = v!),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ProductSearchField(
                autofocus: false,
                onSelected: (r) => setState(() => _lines.add(_NewLine(r))),
                trailing: (r) => formatMoney(r.product.priceRetail),
              ),
              for (final l in _lines)
                Row(
                  children: [
                    Expanded(child: Text(l.row.product.nameAr)),
                    SizedBox(
                      width: 90,
                      child: TextField(
                        controller: l.qty,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'الكمية'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: l.extra,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'خصم إضافي %'),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() {
                        _lines.remove(l);
                        l.qty.dispose();
                        l.extra.dispose();
                      }),
                    ),
                  ],
                ),
              TextField(
                controller: _external,
                decoration: const InputDecoration(labelText: 'رقم الطلب الخارجي (اختياري)'),
              ),
              TextField(controller: _notes, decoration: const InputDecoration(labelText: Strings.notes)),
              TextField(
                controller: _reason,
                decoration: const InputDecoration(
                    labelText: 'سبب الخصم الإضافي (عند تجاوز حد الكاشير — للمدير)'),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('عرض سعر (لم يُؤكَّد بعد)'),
                value: _quotation,
                onChanged: (v) => setState(() => _quotation = v ?? false),
              ),
              const Text('السعر وخصم العميل يُثبَّتان عند التأكيد.', style: TextStyle(fontSize: 12)),
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

class _SoDetailDialog extends ConsumerStatefulWidget {
  const _SoDetailDialog({required this.orderId});

  final int orderId;

  @override
  ConsumerState<_SoDetailDialog> createState() => _SoDetailDialogState();
}

class _SoDetailDialogState extends ConsumerState<_SoDetailDialog> {
  SoDetail? _detail;
  final _deliver = <int, TextEditingController>{};
  final _paid = TextEditingController();
  final _belowCost = TextEditingController();
  final _adv = TextEditingController();
  int _advance = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _deliver.values) {
      c.dispose();
    }
    _paid.dispose();
    _belowCost.dispose();
    _adv.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final d = await ref.read(salesOrderServiceProvider).detail(widget.orderId);
    final adv = await ref.read(paymentServiceProvider).advancesOn(RefType.salesOrder, widget.orderId);
    if (!mounted) return;
    setState(() {
      _detail = d;
      _advance = adv;
      for (final l in d.lines) {
        _deliver.putIfAbsent(l.line.id, () => TextEditingController());
        _deliver[l.line.id]!.clear();
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
    await _act((user) => ref
        .read(paymentServiceProvider)
        .receiveAdvance(widget.orderId, amount: amount, userId: user.id));
    _adv.clear();
  }

  Future<void> _doDeliver() async {
    final d = _detail!;
    final qtys = <int, int>{};
    for (final l in d.lines) {
      final text = _deliver[l.line.id]!.text.trim();
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
    await _act((user) => ref.read(salesOrderServiceProvider).deliver(
          widget.orderId,
          qtyByLine: qtys,
          paidAmount: paid,
          belowCostReason: _belowCost.text,
          user: user,
        ));
    _paid.clear();
    _belowCost.clear();
  }

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    if (d == null) {
      return const AlertDialog(content: SizedBox(height: 80, child: Center(child: CircularProgressIndicator())));
    }
    final status = d.order.status;
    final canDeliver = status == SoStatus.confirmed || status == SoStatus.partlyDelivered;
    final svc = ref.read(salesOrderServiceProvider);
    const head = TextStyle(fontWeight: FontWeight.bold);
    return AlertDialog(
      title: Text('${d.order.number} — ${d.customerName}  (${soStatusLabel(status)})'),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('تاريخ الأمر: ${formatDateTime(d.order.orderDate)}  •  ${SaleChannel.label(d.order.channel)}'),
              if (d.order.notes != null) Text(d.order.notes!),
              const SizedBox(height: 8),
              Table(
                columnWidths: const {0: FlexColumnWidth(3)},
                children: [
                  const TableRow(children: [
                    Text('الصنف', style: head),
                    Text('المطلوب', style: head),
                    Text('المسلَّم', style: head),
                    Text('المتبقي', style: head),
                    Text('سعر القائمة', style: head),
                    Text('خصم العميل %', style: head),
                    Text('إضافي %', style: head),
                    Text('السعر', style: head),
                  ]),
                  for (final l in d.lines)
                    TableRow(children: [
                      Text(l.productName),
                      Text(formatQty(l.line.qty)),
                      Text(formatQty(l.line.qtyDelivered)),
                      Text(formatQty(l.remaining)),
                      Text(status == SoStatus.draft || status == SoStatus.quotation ? '—' : formatMoney(l.line.listPrice)),
                      Text(status == SoStatus.draft || status == SoStatus.quotation ? '—' : (l.line.baseDiscountBp / 100).toString()),
                      Text((l.line.extraDiscountBp / 100).toString()),
                      Text(status == SoStatus.draft || status == SoStatus.quotation ? 'عند التأكيد' : formatMoney(l.line.unitPrice)),
                    ]),
                ],
              ),
              const SizedBox(height: 8),
              Text('المطلوب ${formatMoney(d.orderedValue)}  •  المسلَّم ${formatMoney(d.deliveredValue)}  •  المتبقي ${formatMoney(d.remainingValue)}'),
              const SizedBox(height: 4),
              Text('المدفوع مقدماً: ${formatMoney(_advance)}'),
              if (status != SoStatus.cancelled && status != SoStatus.delivered)
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
              if (canDeliver) ...[
                const Divider(height: 24),
                Text('تسليم بضاعة', style: Theme.of(context).textTheme.titleSmall),
                for (final l in d.lines.where((l) => l.remaining > 0))
                  Row(
                    children: [
                      Expanded(child: Text('${l.productName} (المتبقي ${formatQty(l.remaining)})')),
                      SizedBox(
                        width: 110,
                        child: TextField(
                          controller: _deliver[l.line.id],
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(labelText: 'الكمية المسلَّمة'),
                        ),
                      ),
                    ],
                  ),
                Row(
                  children: [
                    SizedBox(
                      width: 170,
                      child: TextField(
                        controller: _paid,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'المدفوع الآن'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _belowCost,
                        decoration: const InputDecoration(labelText: 'سبب البيع بأقل من التكلفة (للمدير)'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: _doDeliver,
                      icon: const Icon(Icons.local_shipping_outlined),
                      label: const Text('تسليم وإصدار فاتورة'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (status == SoStatus.draft || status == SoStatus.quotation)
          FilledButton(
            onPressed: () => _act((u) => svc.confirm(widget.orderId, user: u)),
            child: const Text('تأكيد وتثبيت السعر'),
          ),
        if (status == SoStatus.draft || status == SoStatus.quotation || status == SoStatus.confirmed)
          TextButton(
            onPressed: () => _act((u) => svc.cancel(widget.orderId, user: u)),
            child: const Text('إلغاء الأمر'),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.close)),
      ],
    );
  }
}

String _approvalKindLabel(String k) => switch (k) {
      ApprovalKind.extraDiscount => 'خصم إضافي',
      ApprovalKind.belowCost => 'بيع بأقل من التكلفة',
      ApprovalKind.priceOverride => 'تعديل سعر',
      _ => k,
    };

final _approvalsProvider =
    StreamProvider.autoDispose<List<Approval>>((ref) => ref.watch(approvalServiceProvider).watchAll());

/// Every exception a manager allowed, newest first.
class _ApprovalsDialog extends ConsumerWidget {
  const _ApprovalsDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(_approvalsProvider).valueOrNull ?? const <Approval>[];
    return AlertDialog(
      title: const Text('سجل الموافقات'),
      content: SizedBox(
        width: 640,
        height: 420,
        child: rows.isEmpty
            ? const Center(child: Text('لا توجد موافقات مسجلة'))
            : ListView(
                children: [
                  for (final a in rows)
                    ListTile(
                      dense: true,
                      title: Text('${_approvalKindLabel(a.kind)} — ${a.reason}'),
                      subtitle: Text(
                          '${a.docType == 'sales_order' ? 'أمر بيع' : 'فاتورة بيع'} #${a.docId}  •  ${formatDateTime(a.createdAt)}'),
                    ),
                ],
              ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.close))],
    );
  }
}
