import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/services/product_service.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/number_fields.dart';

Future<void> showProductForm(BuildContext context, {ProductRow? existing}) {
  return showDialog<void>(
    context: context,
    builder: (_) => ProductFormDialog(existing: existing),
  );
}

/// Add or edit a product (admin). Opening stock is only asked when adding;
/// after that stock changes through documents or an adjustment.
class ProductFormDialog extends ConsumerStatefulWidget {
  const ProductFormDialog({super.key, this.existing});

  final ProductRow? existing;

  @override
  ConsumerState<ProductFormDialog> createState() => _ProductFormDialogState();
}

class _ProductFormDialogState extends ConsumerState<ProductFormDialog> {
  final _form = GlobalKey<FormState>();
  late final Product? _p = widget.existing?.product;
  late final _code = TextEditingController(text: _p?.code);
  late final _name = TextEditingController(text: _p?.nameAr);
  late final _cost = TextEditingController(text: _money(_p?.costPrice));
  late final _retail = TextEditingController(text: _money(_p?.priceRetail));
  late final _wholesale = TextEditingController(text: _money(_p?.priceWholesale));
  late final _contractor = TextEditingController(text: _money(_p?.priceContractor));
  late final _minStock = TextEditingController(text: _p == null ? '' : formatQty(_p.minStock));
  late final _opening = TextEditingController();
  late final _notes = TextEditingController(text: _p?.notes);
  late int? _categoryId = _p?.categoryId;
  late int? _brandId = _p?.brandId;
  late int? _unitId = _p?.unitId;
  late bool _active = _p?.isActive ?? true;
  List<Category> _categories = const [];
  List<Brand> _brands = const [];
  List<Unit> _units = const [];

  static String _money(int? v) => v == null ? '' : formatMoney(v).replaceAll(',', '');

  @override
  void initState() {
    super.initState();
    final catalog = ref.read(catalogServiceProvider);
    Future.wait([
      catalog.watchCategories().first,
      catalog.watchBrands().first,
      catalog.watchUnits().first,
    ]).then((lists) {
      if (!mounted) return;
      setState(() {
        _categories = lists[0] as List<Category>;
        _brands = lists[1] as List<Brand>;
        _units = lists[2] as List<Unit>;
        // New products default to the first unit (piece).
        if (_p == null && _unitId == null && _units.isNotEmpty) _unitId = _units.first.id;
      });
    });
  }

  @override
  void dispose() {
    for (final c in [_code, _name, _cost, _retail, _wholesale, _contractor, _minStock, _opening, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _unitAllowsDecimal =>
      _units.where((u) => u.id == _unitId).firstOrNull?.allowDecimal ?? false;

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final input = ProductInput(
      code: _code.text,
      nameAr: _name.text,
      categoryId: _categoryId,
      brandId: _brandId,
      unitId: _unitId,
      costPrice: moneyOrZero(_cost),
      priceRetail: moneyOrZero(_retail),
      priceWholesale: moneyOrZero(_wholesale),
      priceContractor: moneyOrZero(_contractor),
      minStock: qtyOrZero(_minStock),
      isActive: _active,
      notes: _notes.text,
    );
    final userId = ref.read(currentUserProvider)?.id;
    final service = ref.read(productServiceProvider);
    final ok = await runGuarded(context, () async {
      if (_p == null) {
        await service.create(input, openingQty: qtyOrZero(_opening), userId: userId);
      } else {
        await service.update(_p.id, input, userId: userId);
      }
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context);
  }

  Widget _row(List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(width: 12),
              Expanded(child: children[i]),
            ],
          ],
        ),
      );

  DropdownButtonFormField<int?> _dropdown<T>(
    String label,
    int? value,
    List<T> items,
    int Function(T) id,
    String Function(T) name,
    ValueChanged<int?> onChanged,
  ) {
    return DropdownButtonFormField<int?>(
      // Rebuilt once the lists have loaded, so the starting value shows.
      key: ValueKey('$label-${items.length}'),
      initialValue: items.any((i) => id(i) == value) ? value : null,
      decoration: InputDecoration(labelText: label),
      items: [
        const DropdownMenuItem(value: null, child: Text('—')),
        for (final i in items) DropdownMenuItem(value: id(i), child: Text(name(i))),
      ],
      onChanged: onChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_p == null ? Strings.newProduct : Strings.editProduct),
      content: SizedBox(
        width: 640,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _row([
                  TextFormField(
                    controller: _code,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: Strings.code),
                    validator: (v) => (v ?? '').trim().isEmpty ? Strings.required : null,
                  ),
                  TextFormField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: Strings.productName),
                    validator: (v) => (v ?? '').trim().isEmpty ? Strings.required : null,
                  ),
                ]),
                _row([
                  _dropdown(Strings.category, _categoryId, _categories, (c) => c.id, (c) => c.nameAr,
                      (v) => setState(() => _categoryId = v)),
                  _dropdown(Strings.brand, _brandId, _brands, (b) => b.id, (b) => b.name,
                      (v) => setState(() => _brandId = v)),
                  _dropdown(Strings.unit, _unitId, _units, (u) => u.id, (u) => u.nameAr,
                      (v) => setState(() => _unitId = v)),
                ]),
                _row([
                  MoneyField(controller: _retail, label: Strings.priceRetail),
                  MoneyField(controller: _wholesale, label: Strings.priceWholesale),
                  MoneyField(controller: _contractor, label: Strings.priceContractor),
                ]),
                _row([
                  MoneyField(controller: _cost, label: Strings.costPrice),
                  QtyField(controller: _minStock, label: Strings.minStock, allowDecimal: _unitAllowsDecimal),
                  if (_p == null)
                    QtyField(controller: _opening, label: Strings.openingStock, allowDecimal: _unitAllowsDecimal)
                  else
                    const SizedBox(),
                ]),
                TextFormField(
                  controller: _notes,
                  decoration: const InputDecoration(labelText: Strings.notes),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(Strings.active),
                  subtitle: const Text(Strings.inactiveHint),
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
