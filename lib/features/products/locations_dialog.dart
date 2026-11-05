import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/services/location_service.dart';
import '../../core/services/product_service.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/pickers.dart';

/// Admin tool: the places stock is kept in, and moving stock between them.
class LocationsDialog extends ConsumerStatefulWidget {
  const LocationsDialog({super.key});

  @override
  ConsumerState<LocationsDialog> createState() => _LocationsDialogState();
}

class _LocationsDialogState extends ConsumerState<LocationsDialog> {
  ProductRow? _product;
  Map<int, int> _stock = {};
  int? _from;
  int? _to;
  final _qty = TextEditingController();

  @override
  void dispose() {
    _qty.dispose();
    super.dispose();
  }

  Future<void> _pick(ProductRow row) async {
    final stock = await ref.read(locationServiceProvider).stockByLocation(row.product.id);
    if (!mounted) return;
    setState(() {
      _product = row;
      _stock = stock;
    });
  }

  Future<void> _transfer() async {
    final product = _product;
    final qty = parseQty(_qty.text, allowDecimal: product?.unitAllowsDecimal ?? false);
    if (product == null || _from == null || _to == null || qty == null || qty <= 0) {
      await showMessage(context, 'اختر الصنف والمكانين وأدخل كمية صحيحة');
      return;
    }
    final user = ref.read(currentUserProvider);
    final ok = await runGuarded(context, () async {
      await ref.read(locationServiceProvider).transfer(
            productId: product.product.id,
            qty: qty,
            fromLocationId: _from!,
            toLocationId: _to!,
            userId: user?.id,
          );
      return true;
    });
    if (ok == true && mounted) {
      _qty.clear();
      await _pick(product);
    }
  }

  Future<void> _edit(Location? existing) async {
    await showDialog<void>(context: context, builder: (_) => _LocationForm(existing: existing));
    if (_product != null && mounted) await _pick(_product!);
  }

  @override
  Widget build(BuildContext context) {
    final places = ref.watch(_locationsProvider).valueOrNull ?? const <Location>[];
    final active = places.where((l) => l.isActive).toList();
    String nameOf(int id) => places.where((l) => l.id == id).map((l) => l.name).firstOrNull ?? '';
    return AlertDialog(
      title: const Text('الأماكن والتحويل بينها'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final l in places)
                ListTile(
                  dense: true,
                  title: Text(l.name),
                  subtitle: Text([
                    LocationKind.label(l.kind),
                    if (!l.isSellable) 'غير متاح للبيع',
                    if (!l.isActive) 'موقوف',
                  ].join(' • ')),
                  trailing: IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => _edit(l),
                  ),
                ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () => _edit(null),
                  icon: const Icon(Icons.add),
                  label: const Text('مكان جديد'),
                ),
              ),
              const Divider(height: 28),
              Text('تحويل مخزون', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              ProductSearchField(
                autofocus: false,
                onSelected: _pick,
                trailing: (r) => formatQty(r.stock),
              ),
              if (_product != null) ...[
                const SizedBox(height: 8),
                Text(_product!.product.nameAr, style: const TextStyle(fontWeight: FontWeight.bold)),
                if (_stock.isEmpty)
                  const Text('لا يوجد رصيد لهذا الصنف')
                else
                  for (final e in _stock.entries) Text('${nameOf(e.key)}: ${formatQty(e.value)}'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _from,
                        decoration: const InputDecoration(labelText: 'من'),
                        items: [for (final l in active) DropdownMenuItem(value: l.id, child: Text(l.name))],
                        onChanged: (v) => setState(() => _from = v),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _to,
                        decoration: const InputDecoration(labelText: 'إلى'),
                        items: [for (final l in active) DropdownMenuItem(value: l.id, child: Text(l.name))],
                        onChanged: (v) => setState(() => _to = v),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: _qty,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'الكمية'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilledButton.icon(
                    onPressed: _transfer,
                    icon: const Icon(Icons.swap_horiz),
                    label: const Text('تحويل'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.close)),
      ],
    );
  }
}

final _locationsProvider =
    StreamProvider.autoDispose<List<Location>>((ref) => ref.watch(locationServiceProvider).watchAll());

class _LocationForm extends ConsumerStatefulWidget {
  const _LocationForm({this.existing});

  final Location? existing;

  @override
  ConsumerState<_LocationForm> createState() => _LocationFormState();
}

class _LocationFormState extends ConsumerState<_LocationForm> {
  late final _name = TextEditingController(text: widget.existing?.name);
  late String _kind = widget.existing?.kind ?? LocationKind.warehouse;
  late bool _sellable = widget.existing?.isSellable ?? true;
  late bool _active = widget.existing?.isActive ?? true;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final user = ref.read(currentUserProvider);
    final service = ref.read(locationServiceProvider);
    final e = widget.existing;
    final ok = await runGuarded(context, () async {
      if (e == null) {
        await service.create(name: _name.text, kind: _kind, isSellable: _sellable, userId: user?.id);
      } else {
        await service.update(e.id,
            name: _name.text, kind: _kind, isSellable: _sellable, isActive: _active, userId: user?.id);
      }
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'مكان جديد' : 'تعديل المكان'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: Strings.name),
            ),
            DropdownButtonFormField<String>(
              initialValue: _kind,
              decoration: const InputDecoration(labelText: 'النوع'),
              items: [for (final k in LocationKind.all) DropdownMenuItem(value: k, child: Text(LocationKind.label(k)))],
              onChanged: (v) => setState(() => _kind = v!),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('متاح للبيع'),
              value: _sellable,
              onChanged: (v) => setState(() => _sellable = v),
            ),
            if (widget.existing != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(Strings.active),
                value: _active,
                onChanged: (v) => setState(() => _active = v),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.cancel)),
        FilledButton(onPressed: _save, child: const Text(Strings.save)),
      ],
    );
  }
}
