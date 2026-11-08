import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/database.dart';
import '../l10n/strings.dart';
import '../providers.dart';
import '../quantity.dart';
import '../search_text.dart';
import '../services/product_service.dart';

/// Type a code or name; Enter adds the highlighted product. [trailing] is
/// the price shown next to each option (sale price, cost, ...).
class ProductSearchField extends ConsumerStatefulWidget {
  const ProductSearchField({
    super.key,
    required this.onSelected,
    this.trailing,
    this.focusNode,
    this.autofocus = true,
  });

  final ValueChanged<ProductRow> onSelected;
  final String Function(ProductRow row)? trailing;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  ConsumerState<ProductSearchField> createState() => _ProductSearchFieldState();
}

class _ProductSearchFieldState extends ConsumerState<ProductSearchField> {
  final _controller = TextEditingController();
  FocusNode? _ownFocus;

  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  @override
  void dispose() {
    _controller.dispose();
    _ownFocus?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<ProductRow>(
      focusNode: _focus,
      textEditingController: _controller,
      displayStringForOption: (r) => r.product.nameAr,
      optionsBuilder: (value) async {
        if (value.text.trim().isEmpty) return const [];
        return ref.read(productServiceProvider).search(value.text);
      },
      onSelected: widget.onSelected,
      fieldViewBuilder: (context, textController, focus, onSubmit) => TextField(
        controller: textController,
        focusNode: focus,
        autofocus: widget.autofocus,
        onSubmitted: (_) => onSubmit(),
        decoration: const InputDecoration(
          prefixIcon: Icon(Icons.qr_code_scanner),
          hintText: Strings.productSearchHint,
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      optionsViewBuilder: (context, onPick, options) => Align(
        alignment: AlignmentDirectional.topStart,
        child: Material(
          elevation: 6,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360, maxWidth: 720),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                for (final (i, r) in options.indexed)
                  Builder(builder: (context) {
                    final highlighted = AutocompleteHighlightedOption.of(context) == i;
                    return ListTile(
                      dense: true,
                      selected: highlighted,
                      selectedTileColor: Theme.of(context).colorScheme.secondaryContainer,
                      title: Text('${r.product.code} — ${r.product.nameAr}'
                          '${r.product.variant == null ? '' : ' (${r.product.variant})'}'),
                      subtitle: Text('${r.product.manufacturerCode.isEmpty ? '' : '${r.product.manufacturerCode} · '}'
                          '${Strings.available}: ${formatQty(r.sellableStock)} ${r.unitName ?? ''}'
                          '${r.stock == r.sellableStock ? '' : ' (الإجمالي ${formatQty(r.stock)})'}'),
                      trailing: widget.trailing == null ? null : Text(widget.trailing!(r)),
                      onTap: () => onPick(r),
                    );
                  }),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Pick a place. [sellableOnly] leaves out display-only places.
class LocationDropdown extends ConsumerWidget {
  const LocationDropdown({
    super.key,
    required this.value,
    required this.onChanged,
    this.label = 'المكان',
    this.width = 200,
  });

  final int value;
  final ValueChanged<int> onChanged;
  final String label;
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      width: width,
      child: StreamBuilder<List<Location>>(
        stream: ref.watch(locationServiceProvider).watchAll(),
        builder: (context, snap) {
          final places = (snap.data ?? const <Location>[]).where((l) => l.isActive || l.id == value).toList();
          return DropdownButtonFormField<int>(
            key: ValueKey('$label-$value-${places.length}'),
            isExpanded: true,
            isDense: true,
            initialValue: places.any((l) => l.id == value) ? value : null,
            decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
            items: [for (final l in places) DropdownMenuItem(value: l.id, child: Text(l.name))],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          );
        },
      ),
    );
  }
}

/// Pick a customer or supplier by name or phone. Give it a key that changes
/// with [selected] so the text follows a selection made elsewhere.
class PartyPicker<T extends Object> extends StatelessWidget {
  const PartyPicker({
    super.key,
    required this.items,
    required this.selected,
    required this.label,
    required this.nameOf,
    required this.searchFields,
    required this.onSelected,
    this.hint,
    this.clearTooltip,
  });

  final List<T> items;
  final T? selected;
  final String label;
  final String Function(T) nameOf;
  final List<String?> Function(T) searchFields;
  final ValueChanged<T?> onSelected;
  final String? hint;
  final String? clearTooltip;

  @override
  Widget build(BuildContext context) {
    return Autocomplete<T>(
      initialValue: TextEditingValue(text: selected == null ? '' : nameOf(selected as T)),
      displayStringForOption: nameOf,
      optionsBuilder: (value) =>
          items.where((p) => matchesSearch(value.text, searchFields(p))).take(20),
      onSelected: onSelected,
      fieldViewBuilder: (context, controller, focus, onSubmit) => TextField(
        controller: controller,
        focusNode: focus,
        onSubmitted: (_) => onSubmit(),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
          suffixIcon: selected == null
              ? null
              : IconButton(
                  tooltip: clearTooltip ?? Strings.clear,
                  icon: const Icon(Icons.clear),
                  onPressed: () => onSelected(null),
                ),
        ),
      ),
    );
  }
}

final activeCustomersProvider = StreamProvider.autoDispose<List<Customer>>(
  (ref) => ref.watch(partyServiceProvider).watchCustomers(activeOnly: true),
);

final activeSuppliersProvider = StreamProvider.autoDispose<List<Supplier>>(
  (ref) => ref
      .watch(partyServiceProvider)
      .watchSuppliers()
      .map((all) => all.where((s) => s.isActive).toList()),
);
