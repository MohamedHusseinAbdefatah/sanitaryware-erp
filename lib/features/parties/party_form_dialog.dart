import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/services/party_service.dart';
import '../../core/services/product_service.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/number_fields.dart';
import 'parties_screen.dart';

/// Returns the saved customer's id, or null if cancelled.
Future<int?> showCustomerForm(BuildContext context, {Customer? existing}) =>
    showDialog<int>(context: context, builder: (_) => _PartyFormDialog(customer: existing, isCustomer: true));

Future<int?> showSupplierForm(BuildContext context, {Supplier? existing}) =>
    showDialog<int>(context: context, builder: (_) => _PartyFormDialog(supplier: existing, isCustomer: false));

/// Add or edit a customer or supplier. Money fields (opening balance, credit
/// limit) are for the admin only; a cashier can still add a customer at the
/// counter.
class _PartyFormDialog extends ConsumerStatefulWidget {
  const _PartyFormDialog({this.customer, this.supplier, required this.isCustomer});

  final Customer? customer;
  final Supplier? supplier;
  final bool isCustomer;

  @override
  ConsumerState<_PartyFormDialog> createState() => _PartyFormDialogState();
}

class _PartyFormDialogState extends ConsumerState<_PartyFormDialog> {
  final _form = GlobalKey<FormState>();
  late final _c = widget.customer;
  late final _s = widget.supplier;
  late final _name = TextEditingController(text: _c?.name ?? _s?.name);
  late final _phone = TextEditingController(text: _c?.phone ?? _s?.phone);
  late final _address = TextEditingController(text: _c?.address ?? _s?.address);
  late final _opening = TextEditingController(text: _money(_c?.openingBalance ?? _s?.openingBalance));
  late final _creditLimit = TextEditingController(text: _money(_c?.creditLimit));
  late final _notes = TextEditingController(text: _c?.notes ?? _s?.notes);
  late String _priceLevel = _c?.priceLevel ?? PriceLevel.retail;
  late bool _active = _c?.isActive ?? _s?.isActive ?? true;

  static String _money(int? v) => v == null || v == 0 ? '' : formatMoney(v).replaceAll(',', '');

  bool get _isNew => _c == null && _s == null;

  @override
  void dispose() {
    for (final c in [_name, _phone, _address, _opening, _creditLimit, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final user = ref.read(currentUserProvider);
    final service = ref.read(partyServiceProvider);
    final id = await runGuarded(context, () {
      if (widget.isCustomer) {
        return service.saveCustomer(
          CustomerInput(
            name: _name.text,
            phone: _phone.text,
            address: _address.text,
            openingBalance: moneyOrZero(_opening),
            creditLimit: moneyOrZero(_creditLimit),
            priceLevel: _priceLevel,
            notes: _notes.text,
            isActive: _active,
          ),
          id: _c?.id,
          userId: user?.id,
        );
      }
      return service.saveSupplier(
        SupplierInput(
          name: _name.text,
          phone: _phone.text,
          address: _address.text,
          openingBalance: moneyOrZero(_opening),
          notes: _notes.text,
          isActive: _active,
        ),
        id: _s?.id,
        userId: user?.id,
      );
    });
    if (id != null && mounted) Navigator.pop(context, id);
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(currentUserProvider)?.isAdmin ?? false;
    final title = widget.isCustomer
        ? (_isNew ? Strings.newCustomer : Strings.editCustomer)
        : (_isNew ? Strings.newSupplier : Strings.editSupplier);
    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _name,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: Strings.name),
                  validator: (v) => (v ?? '').trim().isEmpty ? Strings.required : null,
                ),
                TextFormField(
                  controller: _phone,
                  decoration: const InputDecoration(labelText: Strings.phone),
                ),
                TextFormField(
                  controller: _address,
                  decoration: const InputDecoration(labelText: Strings.address),
                ),
                if (widget.isCustomer)
                  DropdownButtonFormField<String>(
                    initialValue: _priceLevel,
                    decoration: const InputDecoration(labelText: Strings.priceLevel),
                    items: [
                      for (final l in PriceLevel.all)
                        DropdownMenuItem(value: l, child: Text(priceLevelLabel(l))),
                    ],
                    onChanged: (v) => setState(() => _priceLevel = v!),
                  ),
                if (isAdmin) ...[
                  MoneyField(
                    controller: _opening,
                    label: widget.isCustomer ? Strings.openingBalanceCustomer : Strings.openingBalanceSupplier,
                    allowNegative: true,
                  ),
                  if (widget.isCustomer)
                    MoneyField(controller: _creditLimit, label: Strings.creditLimitHint),
                ],
                TextFormField(
                  controller: _notes,
                  decoration: const InputDecoration(labelText: Strings.notes),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(Strings.active),
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.cancel)),
        FilledButton(onPressed: _save, child: const Text(Strings.save)),
      ],
    );
  }
}
