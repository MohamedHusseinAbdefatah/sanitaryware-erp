import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets/feedback.dart';

final _allCategoriesProvider = StreamProvider.autoDispose<List<Category>>(
  (ref) => ref.watch(catalogServiceProvider).watchAllCategories(),
);

/// Gives the [productIds] one category and, optionally, a subcategory under
/// it; a new category or subcategory can be made on the spot. Returns how
/// many products changed, or null when cancelled.
Future<int?> showBulkCategory(BuildContext context, List<int> productIds) =>
    showDialog<int>(context: context, builder: (_) => _BulkCategoryDialog(productIds));

class _BulkCategoryDialog extends ConsumerStatefulWidget {
  const _BulkCategoryDialog(this.productIds);

  final List<int> productIds;

  @override
  ConsumerState<_BulkCategoryDialog> createState() => _BulkCategoryDialogState();
}

class _BulkCategoryDialogState extends ConsumerState<_BulkCategoryDialog> {
  int? _categoryId;
  int? _subcategoryId;

  Future<String?> _askName(String title) async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(labelText: Strings.name),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text(Strings.save)),
        ],
      ),
    );
    c.dispose();
    return name == null || name.trim().isEmpty ? null : name;
  }

  Future<void> _newCategory({required bool sub}) async {
    if (sub && _categoryId == null) {
      await showMessage(context, 'اختر التصنيف الرئيسي أولاً');
      return;
    }
    final name = await _askName(sub ? 'تصنيف فرعي جديد' : 'تصنيف جديد');
    if (name == null || !mounted) return;
    final id = await runGuarded(
      context,
      () => ref.read(catalogServiceProvider).saveCategory(name: name, parentId: sub ? _categoryId : null),
    );
    if (id == null || !mounted) return;
    setState(() {
      if (sub) {
        _subcategoryId = id;
      } else {
        _categoryId = id;
        _subcategoryId = null;
      }
    });
  }

  Future<void> _apply() async {
    if (_categoryId == null) {
      await showMessage(context, 'اختر التصنيف');
      return;
    }
    final changed = await runGuarded(
      context,
      () => ref.read(productServiceProvider).setCategory(
            widget.productIds,
            categoryId: _categoryId!,
            subcategoryId: _subcategoryId,
            userId: ref.read(currentUserProvider)?.id,
          ),
    );
    if (changed != null && mounted) Navigator.pop(context, changed);
  }

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(_allCategoriesProvider).valueOrNull ?? const <Category>[];
    final mains = all.where((c) => c.parentId == null).toList();
    final subs = all.where((c) => _categoryId != null && c.parentId == _categoryId).toList();
    return AlertDialog(
      title: Text('تعيين التصنيف لـ ${widget.productIds.length} صنف'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                key: ValueKey(('main', _categoryId, mains.length)),
                initialValue: mains.any((c) => c.id == _categoryId) ? _categoryId : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'التصنيف'),
                items: [for (final c in mains) DropdownMenuItem(value: c.id, child: Text(c.nameAr))],
                onChanged: (v) => setState(() {
                  _categoryId = v;
                  _subcategoryId = null;
                }),
              ),
            ),
            IconButton(
              tooltip: 'تصنيف جديد',
              icon: const Icon(Icons.add_circle_outline),
              onPressed: () => _newCategory(sub: false),
            ),
          ]),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<int?>(
                key: ValueKey(('sub', _categoryId, _subcategoryId, subs.length)),
                initialValue: subs.any((c) => c.id == _subcategoryId) ? _subcategoryId : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'التصنيف الفرعي (اختياري)'),
                items: [
                  const DropdownMenuItem<int?>(value: null, child: Text('بدون تصنيف فرعي')),
                  for (final c in subs) DropdownMenuItem<int?>(value: c.id, child: Text(c.nameAr)),
                ],
                onChanged: (v) => setState(() => _subcategoryId = v),
              ),
            ),
            IconButton(
              tooltip: 'تصنيف فرعي جديد',
              icon: const Icon(Icons.add_circle_outline),
              onPressed: () => _newCategory(sub: true),
            ),
          ]),
          const SizedBox(height: 10),
          const Text(
            'يُستبدل تصنيف كل الأصناف المحددة بهذا التصنيف، ويُسجل التغيير لكل صنف في سجل العمليات. '
            'خصومات الشراء والبيع على هذا التصنيف تنطبق عليها فوراً.',
            style: TextStyle(fontSize: 12, color: AppColors.muted),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.cancel)),
        FilledButton.icon(onPressed: _apply, icon: const Icon(Icons.check), label: const Text('تطبيق')),
      ],
    );
  }
}
