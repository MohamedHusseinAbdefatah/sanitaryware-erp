import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/strings.dart';
import '../../core/providers.dart';
import '../../core/services/errors.dart';
import '../../core/widgets/feedback.dart';

/// Categories, brands and units in three tabs, each a list with add and
/// rename. Nothing is deleted: products may still point at an entry.
class CatalogDialog extends ConsumerWidget {
  const CatalogDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(catalogServiceProvider);
    return DefaultTabController(
      length: 4,
      child: AlertDialog(
        title: const TabBar(tabs: [
          Tab(text: Strings.categories),
          Tab(text: 'تصنيفات فرعية'),
          Tab(text: Strings.brands),
          Tab(text: Strings.units),
        ]),
        content: SizedBox(
          width: 520,
          height: 420,
          child: TabBarView(children: [
            _NameList(
              stream: catalog.watchCategories().map((l) => [for (final c in l) (c.id, c.nameAr, false)]),
              onSave: (id, name, _) => catalog.saveCategory(id: id, name: name),
            ),
            // A subcategory is added from the product form, under its category.
            _NameList(
              stream: catalog.watchSubcategories().map((l) => [for (final c in l) (c.id, c.nameAr, false)]),
              onSave: (id, name, _) async {
                if (id == null) throw ValidationException('أضف التصنيف الفرعي من شاشة الصنف');
                final all = await catalog.watchAllCategories().first;
                return catalog.saveCategory(
                    id: id, name: name, parentId: all.firstWhere((c) => c.id == id).parentId);
              },
            ),
            _NameList(
              stream: catalog.watchBrands().map((l) => [for (final b in l) (b.id, b.name, false)]),
              onSave: (id, name, _) => catalog.saveBrand(id: id, name: name),
            ),
            _NameList(
              stream: catalog.watchUnits().map((l) => [for (final u in l) (u.id, u.nameAr, u.allowDecimal)]),
              onSave: (id, name, decimal) => catalog.saveUnit(id: id, name: name, allowDecimal: decimal),
              withDecimalFlag: true,
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.close)),
        ],
      ),
    );
  }
}

typedef _Entry = (int id, String name, bool allowDecimal);

class _NameList extends StatelessWidget {
  const _NameList({required this.stream, required this.onSave, this.withDecimalFlag = false});

  final Stream<List<_Entry>> stream;
  final Future<int> Function(int? id, String name, bool allowDecimal) onSave;
  final bool withDecimalFlag;

  Future<void> _edit(BuildContext context, [_Entry? entry]) async {
    final result = await showDialog<(String, bool)>(
      context: context,
      builder: (_) => _NameDialog(entry: entry, withDecimalFlag: withDecimalFlag),
    );
    if (result == null || !context.mounted) return;
    await runGuarded(context, () => onSave(entry?.$1, result.$1, result.$2));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: () => _edit(context),
            icon: const Icon(Icons.add),
            label: const Text(Strings.add),
          ),
        ),
        Expanded(
          child: StreamBuilder<List<_Entry>>(
            stream: stream,
            builder: (context, snap) => ListView(
              children: [
                for (final e in snap.data ?? const <_Entry>[])
                  ListTile(
                    dense: true,
                    title: Text(e.$2),
                    subtitle: withDecimalFlag && e.$3 ? const Text(Strings.allowsFractions) : null,
                    trailing: IconButton(
                      tooltip: Strings.edit,
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _edit(context, e),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({this.entry, required this.withDecimalFlag});

  final _Entry? entry;
  final bool withDecimalFlag;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _name = TextEditingController(text: widget.entry?.$2);
  late bool _decimal = widget.entry?.$3 ?? false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _ok() {
    if (_name.text.trim().isNotEmpty) Navigator.pop(context, (_name.text, _decimal));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: Strings.name),
              onSubmitted: (_) => _ok(),
            ),
            if (widget.withDecimalFlag)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(Strings.allowsFractions),
                subtitle: const Text(Strings.allowsFractionsHint),
                value: _decimal,
                onChanged: (v) => setState(() => _decimal = v ?? false),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.cancel)),
        FilledButton(onPressed: _ok, child: const Text(Strings.save)),
      ],
    );
  }
}
