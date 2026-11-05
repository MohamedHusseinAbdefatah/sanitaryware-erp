import 'package:flutter/material.dart';

import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/pricing_math.dart';
import '../../core/quantity.dart';
import '../../core/services/sale_preview_service.dart';
import '../../core/services/selling_policy_service.dart';

String _percent(int? bp) => bp == null ? '—' : '${(bp / 100).toStringAsFixed(2)}%';

/// Blueprint 3.4: before approval, shows the list price, each discount and its
/// source, the final price, VAT, the FIFO cost, gross profit, margin and any
/// limit or approval needed. Cost and profit are shown to the admin only.
///
/// Returns the approval reason (possibly empty) to go ahead, or null to go back.
Future<String?> showSalePreview(
  BuildContext context,
  SalePreview preview, {
  required bool isAdmin,
  String confirmLabel = 'اعتماد وحفظ',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _SalePreviewDialog(preview: preview, isAdmin: isAdmin, confirmLabel: confirmLabel),
  );
}

class _SalePreviewDialog extends StatefulWidget {
  const _SalePreviewDialog({required this.preview, required this.isAdmin, required this.confirmLabel});

  final SalePreview preview;
  final bool isAdmin;
  final String confirmLabel;

  @override
  State<_SalePreviewDialog> createState() => _SalePreviewDialogState();
}

class _SalePreviewDialogState extends State<_SalePreviewDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Widget _kv(String k, String v, {Color? color, bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          children: [
            Expanded(child: Text(k)),
            Flexible(
              child: Text(v,
                  textAlign: TextAlign.end,
                  style: TextStyle(color: color, fontWeight: bold ? FontWeight.bold : null)),
            ),
          ],
        ),
      );

  String _vatText(SaleLinePreview l) => l.vatAmount == null
      ? '${VatStatus.label(l.vatStatus)} — لا يُحسب رقم'
      : '${formatMoney(l.vatAmount!)} (${VatStatus.label(l.vatStatus)} ${_percent(l.vatRateBp)})';

  @override
  Widget build(BuildContext context) {
    final p = widget.preview;
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('مراجعة قبل الاعتماد'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final l in p.lines)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('${l.product.code} — ${l.product.nameAr} × ${formatQty(l.qty)}',
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        _kv('سعر القائمة',
                            l.listPrice == null ? 'لا يوجد سعر معتمد' : '${formatMoney(l.listPrice!)}  (${l.listLabel ?? 'مثبت عند الاعتماد'})'),
                        for (final d in l.discounts)
                          _kv('${d.label} [${d.source}]',
                              d.bp != null ? _percent(d.bp) : formatMoney(d.amount ?? 0)),
                        _kv('السعر النهائي للوحدة', formatMoney(l.finalUnitPrice), bold: true),
                        _kv('صافي السطر', formatMoney(l.netTotal), bold: true),
                        _kv('الضريبة', _vatText(l)),
                        if (widget.isAdmin) ...[
                          _kv('تكلفة FIFO المتوقعة', l.expectedCost == null ? 'لا توجد تكلفة مسجلة' : formatMoney(l.expectedCost!)),
                          _kv('مجمل الربح', l.grossProfit == null ? '—' : formatMoney(l.grossProfit!)),
                          _kv('الهامش (من البيع)', _percent(l.margin)),
                          _kv('Markup (من التكلفة)', _percent(l.markup)),
                        ],
                        if (l.maxDiscountBp != null) _kv('أقصى خصم بدون موافقة', _percent(l.maxDiscountBp)),
                        if (l.minMarginBp != null && widget.isAdmin) _kv('أدنى هامش بدون موافقة', _percent(l.minMarginBp)),
                        for (final a in l.approvals)
                          Text('يلزم موافقة: $a', style: TextStyle(color: scheme.error, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              _kv('إجمالي الفاتورة', formatMoney(p.total), bold: true),
              if (p.invoiceDiscount > 0) _kv('منها خصم الفاتورة (موزع على السطور)', formatMoney(p.invoiceDiscount)),
              _kv('إجمالي الضريبة', p.totalVat == null ? 'غير متحقق منها في سطر أو أكثر' : formatMoney(p.totalVat!)),
              if (widget.isAdmin) ...[
                _kv('إجمالي مجمل الربح', p.grossProfit == null ? '—' : formatMoney(p.grossProfit!), bold: true),
                _kv('الهامش', _percent(p.margin)),
                _kv('Markup', _percent(p.markup)),
              ],
              if (p.needsApproval && widget.isAdmin) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _reason,
                  decoration: const InputDecoration(labelText: 'سبب الموافقة (يُسجَّل)'),
                ),
              ],
              if (p.needsApproval && !widget.isAdmin) ...[
                const SizedBox(height: 12),
                Text('لا يمكن الحفظ بدون موافقة المدير.', style: TextStyle(color: scheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.cancel)),
        FilledButton(
          autofocus: true,
          onPressed: p.needsApproval && !widget.isAdmin ? null : () => Navigator.pop(context, _reason.text.trim()),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// More than one version can price a product (Duravit Ceramic and Bathtubs, a
/// premium and an economic list): the person chooses, nothing is assumed.
Future<SellQuote?> pickSellQuote(BuildContext context, List<SellQuote> quotes, String productName) {
  return showDialog<SellQuote>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text('اختر قائمة الأسعار: $productName'),
      children: [
        for (final q in quotes)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, q),
            child: Text('${q.quote.label} — ${formatMoney(q.listPrice)}'),
          ),
      ],
    ),
  );
}
