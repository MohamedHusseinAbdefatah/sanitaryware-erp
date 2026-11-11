import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/providers.dart';

final _liveListsProvider = FutureProvider.autoDispose.family<List<PriceList>, int>(
  (ref, brandId) => ref.watch(priceListServiceProvider).liveListsOf(brandId),
);

/// The list type of an import. The same type as a list the brand already has
/// makes a new version of it (the old one stops, the supplier discounts move
/// over); a new type makes a separate list that runs beside the old one.
class ListTypeField extends ConsumerWidget {
  const ListTypeField({super.key, required this.brandId, required this.controller, required this.onChanged, this.label});

  final int? brandId;
  final TextEditingController controller;
  final VoidCallback onChanged;
  final String? label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final lists = brandId == null
        ? const <PriceList>[]
        : ref.watch(_liveListsProvider(brandId!)).valueOrNull ?? const <PriceList>[];
    final typed = controller.text.trim();
    final same = lists.where((l) => l.listType == typed).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: controller,
          decoration: InputDecoration(labelText: label ?? 'نوع القائمة (مثال: سيراميك، بانيوهات، Premium)'),
          onChanged: (_) => onChanged(),
        ),
        if (lists.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text('تحديث قائمة موجودة؟ اختر نوعها:'),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final l in lists)
                ChoiceChip(
                  label: Text('${l.listType} (V${l.versionNo} — ${l.name})'),
                  selected: l.listType == typed,
                  onSelected: (_) {
                    controller.text = l.listType;
                    onChanged();
                  },
                ),
            ],
          ),
        ],
        if (typed.isNotEmpty && brandId != null) ...[
          const SizedBox(height: 6),
          if (same != null)
            Text(
              'إصدار جديد V${same.versionNo + 1} من "${same.listType}": يحل محل V${same.versionNo} من تاريخ السريان، '
              'وتنتقل إليه خصومات الموردين وسياسات البيع.',
              style: TextStyle(color: scheme.primary, fontWeight: FontWeight.bold),
            )
          else if (lists.isNotEmpty)
            Text(
              'قائمة منفصلة جديدة: القوائم الحالية لهذه الماركة تبقى سارية بجانبها، '
              'ولا يُنقل إليها أي خصم مورد. إذا كانت هذه أسعار محدثة لقائمة موجودة فاختر نوعها من الأعلى.',
              style: TextStyle(color: scheme.error, fontWeight: FontWeight.bold),
            ),
        ],
      ],
    );
  }
}
