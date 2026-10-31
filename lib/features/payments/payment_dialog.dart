import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/services/doc_types.dart';
import '../../core/services/payment_service.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/number_fields.dart';
import '../../core/widgets/pickers.dart';

/// Receive from a customer ([PartyType.customer]) or pay a supplier.
/// [partyId] and [invoiceId] prefill the dialog. Returns true if saved.
Future<bool> showPaymentDialog(
  BuildContext context, {
  required String partyType,
  int? partyId,
  int? invoiceId,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _PaymentDialog(partyType: partyType, partyId: partyId, invoiceId: invoiceId),
  );
  return saved ?? false;
}

typedef _OpenInvoice = (int id, String number, DateTime date, int remaining);

class _PaymentDialog extends ConsumerStatefulWidget {
  const _PaymentDialog({required this.partyType, this.partyId, this.invoiceId});

  final String partyType;
  final int? partyId;
  final int? invoiceId;

  @override
  ConsumerState<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends ConsumerState<_PaymentDialog> {
  final _form = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _chequeNo = TextEditingController();
  final _bank = TextEditingController();
  final _notes = TextEditingController();
  int? _partyId;
  String _partyName = '';
  int? _balance;
  List<_OpenInvoice> _open = const [];
  int? _invoiceId;
  String _method = PaymentMethod.cash;
  DateTime _dueDate = DateTime.now();
  bool _saving = false;

  bool get _isCustomer => widget.partyType == PartyType.customer;

  @override
  void initState() {
    super.initState();
    if (widget.partyId != null) _selectParty(widget.partyId!, preselectInvoice: widget.invoiceId);
  }

  @override
  void dispose() {
    for (final c in [_amount, _chequeNo, _bank, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _selectParty(int id, {int? preselectInvoice}) async {
    final db = ref.read(databaseProvider);
    final balances = ref.read(balanceServiceProvider);
    final name = _isCustomer
        ? (await (db.select(db.customers)..where((t) => t.id.equals(id))).getSingle()).name
        : (await (db.select(db.suppliers)..where((t) => t.id.equals(id))).getSingle()).name;
    final balance =
        _isCustomer ? await balances.customerBalance(id) : await balances.supplierBalance(id);
    final open = await ref.read(paymentServiceProvider).openInvoices(widget.partyType, id);
    if (!mounted) return;
    setState(() {
      _partyId = id;
      _partyName = name;
      _balance = balance;
      _open = open;
      _invoiceId = open.any((o) => o.$1 == preselectInvoice) ? preselectInvoice : null;
      final inv = open.where((o) => o.$1 == _invoiceId).firstOrNull;
      if (inv != null) _amount.text = formatMoney(inv.$4).replaceAll(',', '');
    });
  }

  Future<void> _pickDueDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _dueDate = picked);
  }

  Future<void> _save() async {
    if (_partyId == null) {
      await showMessage(context, _isCustomer ? Strings.chooseCustomer : Strings.chooseSupplier);
      return;
    }
    if (!_form.currentState!.validate() || _saving) return;
    setState(() => _saving = true);
    final input = PaymentInput(
      partyId: _partyId!,
      amount: moneyOrZero(_amount),
      method: _method,
      invoiceId: _invoiceId,
      notes: _notes.text,
      cheque: _method == PaymentMethod.cheque
          ? ChequeInput(number: _chequeNo.text, bank: _bank.text, dueDate: _dueDate)
          : null,
    );
    final user = ref.read(currentUserProvider)!;
    final service = ref.read(paymentServiceProvider);
    final payment = await runGuarded(
      context,
      () => _isCustomer ? service.receive(input, userId: user.id) : service.pay(input, user: user),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (payment != null) {
      showToast(context, '${Strings.paymentSaved} ${payment.number}');
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(_isCustomer ? Strings.receiveFromCustomer : Strings.payToSupplier),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.partyId == null)
                  _isCustomer
                      ? PartyPicker<Customer>(
                          items: ref.watch(activeCustomersProvider).valueOrNull ?? const [],
                          selected: null,
                          label: Strings.customer,
                          nameOf: (c) => c.name,
                          searchFields: (c) => [c.name, c.phone],
                          onSelected: (c) => c == null ? null : _selectParty(c.id),
                        )
                      : PartyPicker<Supplier>(
                          items: ref.watch(activeSuppliersProvider).valueOrNull ?? const [],
                          selected: null,
                          label: Strings.supplier,
                          nameOf: (s) => s.name,
                          searchFields: (s) => [s.name, s.phone],
                          onSelected: (s) => s == null ? null : _selectParty(s.id),
                        )
                else
                  Text(_partyName, style: theme.textTheme.titleMedium),
                if (_balance != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '${_isCustomer ? Strings.customerOwes : Strings.weOweSupplier}: ${formatMoney(_balance!)}',
                    ),
                  ),
                const SizedBox(height: 12),
                if (_partyId != null)
                  DropdownButtonFormField<int?>(
                    key: ValueKey('invoices-$_partyId-${_open.length}'),
                    isExpanded: true,
                    initialValue: _invoiceId,
                    decoration: const InputDecoration(labelText: Strings.linkToInvoice),
                    items: [
                      const DropdownMenuItem(value: null, child: Text(Strings.onAccount)),
                      for (final o in _open)
                        DropdownMenuItem(
                          value: o.$1,
                          child: Text(
                            '${o.$2} — ${formatDate(o.$3)} — ${Strings.remaining} ${formatMoney(o.$4)}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() {
                      _invoiceId = v;
                      final inv = _open.where((o) => o.$1 == v).firstOrNull;
                      if (inv != null) _amount.text = formatMoney(inv.$4).replaceAll(',', '');
                    }),
                  ),
                MoneyField(controller: _amount, label: Strings.amount, required: true),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: PaymentMethod.cash, label: Text(Strings.methodCash)),
                    ButtonSegment(value: PaymentMethod.bank, label: Text(Strings.methodBank)),
                    ButtonSegment(value: PaymentMethod.cheque, label: Text(Strings.methodCheque)),
                  ],
                  selected: {_method},
                  onSelectionChanged: (s) => setState(() => _method = s.single),
                ),
                if (_method == PaymentMethod.cheque) ...[
                  TextFormField(
                    controller: _chequeNo,
                    decoration: const InputDecoration(labelText: Strings.chequeNo),
                    validator: (v) => (v ?? '').trim().isEmpty ? Strings.required : null,
                  ),
                  TextFormField(
                    controller: _bank,
                    decoration: const InputDecoration(labelText: Strings.bank),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(Strings.dueDate),
                    subtitle: Text(formatDate(_dueDate)),
                    trailing: const Icon(Icons.calendar_month),
                    onTap: _pickDueDate,
                  ),
                ],
                TextFormField(
                  controller: _notes,
                  decoration: const InputDecoration(labelText: Strings.notes),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text(Strings.cancel)),
        FilledButton(onPressed: _saving ? null : _save, child: const Text(Strings.save)),
      ],
    );
  }
}
