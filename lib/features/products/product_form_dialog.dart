import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/pricing_math.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/services/product_service.dart';
import '../../core/services/stock_service.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/number_fields.dart';
import 'product_image.dart';

Future<void> showProductForm(BuildContext context, {ProductRow? existing}) {
  return showDialog<void>(
    context: context,
    builder: (_) => ProductFormDialog(existing: existing),
  );
}

/// Add or edit a product's master data (admin). No price or cost is kept here:
/// prices are in price list versions, cost in FIFO layers. Opening stock is
/// asked only when adding, with its location and actual cost.
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
  late final _manufacturer = TextEditingController(text: _p?.manufacturerCode);
  late final _description = TextEditingController(text: _p?.description);
  late final _series = TextEditingController(text: _p?.series);
  late final _dimensions = TextEditingController(text: _p?.dimensions);
  late final _variant = TextEditingController(text: _p?.variant);
  late final _finish = TextEditingController(text: _p?.finish);
  late final _barcode = TextEditingController(text: _p?.barcode);
  late final _specs = TextEditingController(text: _p?.technicalSpecs);
  late final _vatRate =
      TextEditingController(text: _p?.vatRateBp == null ? '' : (_p!.vatRateBp! / 100).toString());
  late final _openingCost = TextEditingController();
  late final _minStock = TextEditingController(text: _p == null ? '' : formatQty(_p.minStock));
  late final _opening = TextEditingController();
  late final _notes = TextEditingController(text: _p?.notes);
  late int? _categoryId = _p?.categoryId;
  late int? _subcategoryId = _p?.subcategoryId;
  late String? _vatBasis = _p?.vatBasis;
  int _locationId = mainLocationId;
  List<Location> _locations = const [];
  List<Category> _subcategories = const [];
  late int? _brandId = _p?.brandId;
  late int? _unitId = _p?.unitId;
  late bool _active = _p?.isActive ?? true;
  List<Category> _categories = const [];
  List<Brand> _brands = const [];
  List<Unit> _units = const [];

  @override
  void initState() {
    super.initState();
    final catalog = ref.read(catalogServiceProvider);
    Future.wait([
      catalog.watchCategories().first,
      catalog.watchBrands().first,
      catalog.watchUnits().first,
      catalog.watchSubcategories().first,
      ref.read(databaseProvider).select(ref.read(databaseProvider).locations).get(),
    ]).then((lists) {
      if (!mounted) return;
      setState(() {
        _categories = lists[0] as List<Category>;
        _brands = lists[1] as List<Brand>;
        _units = lists[2] as List<Unit>;
        _subcategories = lists[3] as List<Category>;
        _locations = lists[4] as List<Location>;
        // New products default to the first unit (piece).
        if (_p == null && _unitId == null && _units.isNotEmpty) _unitId = _units.first.id;
      });
    });
  }

  @override
  void dispose() {
    for (final c in [
      _code, _name, _manufacturer, _description, _series, _dimensions, _variant, _finish, _barcode, _specs,
      _vatRate, _openingCost, _minStock, _opening, _notes,
    ]) {
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
      manufacturerCode: _manufacturer.text,
      description: _description.text,
      categoryId: _categoryId,
      subcategoryId: _subcategoryId,
      brandId: _brandId,
      series: _series.text,
      dimensions: _dimensions.text,
      variant: _variant.text,
      finish: _finish.text,
      unitId: _unitId,
      barcode: _barcode.text,
      technicalSpecs: _specs.text,
      vatBasis: _vatBasis,
      vatRateBp: _vatRate.text.trim().isEmpty
          ? null
          : ((double.tryParse(_vatRate.text.trim().replaceAll(',', '.')) ?? -1) * 100).round(),
      minStock: qtyOrZero(_minStock),
      isActive: _active,
      notes: _notes.text,
    );
    final userId = ref.read(currentUserProvider)?.id;
    final service = ref.read(productServiceProvider);
    final ok = await runGuarded(context, () async {
      if (_p == null) {
        await service.create(
          input,
          openingQty: qtyOrZero(_opening),
          openingCost: _openingCost.text.trim().isEmpty ? null : parseMoney(_openingCost.text),
          locationId: _locationId,
          userId: userId,
        );
      } else {
        await service.update(_p.id, input, userId: userId);
      }
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context);
  }

  Future<void> _addSubcategory() async {
    final parent = _categoryId;
    if (parent == null) {
      await showMessage(context, 'اختر التصنيف أولاً');
      return;
    }
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تصنيف فرعي جديد'),
        content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(labelText: 'الاسم')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text(Strings.save)),
        ],
      ),
    );
    c.dispose();
    if (name == null || !mounted) return;
    final catalog = ref.read(catalogServiceProvider);
    final id = await runGuarded(context, () => catalog.saveCategory(name: name, parentId: parent));
    if (id == null) return;
    final subs = await catalog.watchSubcategories().first;
    if (mounted) {
      setState(() {
        _subcategories = subs;
        _subcategoryId = id;
      });
    }
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
      isExpanded: true,
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
        width: 760,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _p == null
                      ? Row(children: [
                          Icon(Icons.image_outlined, color: Theme.of(context).colorScheme.outline),
                          const SizedBox(width: 8),
                          const Text('الصورة تُضاف بعد حفظ الصنف: افتحه مرة أخرى للتعديل.'),
                        ])
                      : Align(alignment: AlignmentDirectional.centerStart, child: ProductImageBox(productId: _p.id)),
                ),
                _row([
                  TextFormField(
                    controller: _code,
                    autofocus: _p == null,
                    readOnly: _p != null,
                    decoration: InputDecoration(
                      labelText: 'رقم الصنف (Product ID)',
                      helperText: _p == null ? 'يترك فارغاً ليُعطى تلقائياً. لا يتغير بعد الحفظ.' : 'ثابت ولا يتغير',
                    ),
                  ),
                  TextFormField(
                    controller: _manufacturer,
                    decoration: const InputDecoration(
                      labelText: 'كود الشركة (Manufacturer Code)',
                      helperText: 'يُحفظ كنص كما هو: الأصفار والحروف والشرطات',
                    ),
                  ),
                ]),
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: Strings.productName),
                  validator: (v) => (v ?? '').trim().isEmpty ? Strings.required : null,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _description,
                  decoration: const InputDecoration(labelText: 'الوصف'),
                ),
                const SizedBox(height: 8),
                _row([
                  _dropdown(Strings.brand, _brandId, _brands, (b) => b.id, (b) => b.name,
                      (v) => setState(() => _brandId = v)),
                  _dropdown(Strings.category, _categoryId, _categories, (c) => c.id, (c) => c.nameAr,
                      (v) => setState(() {
                            _categoryId = v;
                            _subcategoryId = null;
                          })),
                  Row(
                    children: [
                      Expanded(
                        child: _dropdown('التصنيف الفرعي', _subcategoryId,
                            _subcategories.where((c) => c.parentId == _categoryId).toList(), (c) => c.id,
                            (c) => c.nameAr, (v) => setState(() => _subcategoryId = v)),
                      ),
                      IconButton(
                        tooltip: 'تصنيف فرعي جديد',
                        onPressed: _addSubcategory,
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                ]),
                _row([
                  TextFormField(controller: _series, decoration: const InputDecoration(labelText: 'السلسلة (Series)')),
                  TextFormField(controller: _variant, decoration: const InputDecoration(labelText: 'اللون / Variant')),
                  TextFormField(controller: _finish, decoration: const InputDecoration(labelText: 'التشطيب (Finish)')),
                ]),
                _row([
                  TextFormField(controller: _dimensions, decoration: const InputDecoration(labelText: 'المقاسات')),
                  _dropdown(Strings.unit, _unitId, _units, (u) => u.id, (u) => u.nameAr,
                      (v) => setState(() => _unitId = v)),
                  QtyField(controller: _minStock, label: Strings.minStock, allowDecimal: _unitAllowsDecimal),
                ]),
                _row([
                  TextFormField(controller: _barcode, decoration: const InputDecoration(labelText: 'الباركود')),
                  TextFormField(controller: _specs, decoration: const InputDecoration(labelText: 'المواصفات الفنية')),
                ]),
                _row([
                  DropdownButtonFormField<String?>(
                    isExpanded: true,
                    initialValue: _vatBasis,
                    decoration: const InputDecoration(labelText: 'أساس الضريبة (بعد التحقق)'),
                    items: const [
                      DropdownMenuItem(value: null, child: Text('غير متحقق منه')),
                      DropdownMenuItem(value: VatStatus.inclusive, child: Text('شامل الضريبة')),
                      DropdownMenuItem(value: VatStatus.exclusive, child: Text('غير شامل الضريبة')),
                    ],
                    onChanged: (v) => setState(() => _vatBasis = v),
                  ),
                  TextFormField(
                    controller: _vatRate,
                    decoration: const InputDecoration(labelText: 'نسبة الضريبة % (بعد التحقق)'),
                  ),
                ]),
                if (_p == null)
                  _row([
                    QtyField(controller: _opening, label: Strings.openingStock, allowDecimal: _unitAllowsDecimal),
                    MoneyField(controller: _openingCost, label: 'التكلفة الفعلية للوحدة'),
                    DropdownButtonFormField<int>(
                      isExpanded: true,
                      key: ValueKey('location-${_locations.length}'),
                      initialValue: _locationId,
                      decoration: const InputDecoration(labelText: 'المكان'),
                      items: [
                        if (_locations.isEmpty) const DropdownMenuItem(value: mainLocationId, child: Text('المخزن الرئيسي')),
                        for (final l in _locations) DropdownMenuItem(value: l.id, child: Text(l.name)),
                      ],
                      onChanged: (v) => setState(() => _locationId = v ?? mainLocationId),
                    ),
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
