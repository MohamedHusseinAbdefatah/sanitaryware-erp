import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets/feedback.dart';

/// Deletes products entered or imported by mistake. Those nothing used go
/// for good; those with stock or documents stay, and are offered to be
/// switched off instead. Returns true when anything changed.
Future<bool> deleteProducts(BuildContext context, WidgetRef ref, List<int> ids) async {
  if (ids.isEmpty) return false;
  final service = ref.read(productServiceProvider);
  final user = ref.read(currentUserProvider)!;
  final used = await service.usage(ids);
  final db = ref.read(databaseProvider);
  final names = {
    for (final p in await (db.select(db.products)..where((t) => t.id.isIn(used.keys.toList()))).get())
      p.id: '${p.code} — ${p.nameAr}',
  };
  if (!context.mounted) return false;
  final free = ids.length - used.length;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(ids.length == 1 ? 'حذف الصنف' : 'حذف ${ids.length} صنف'),
      content: SizedBox(
        width: 460,
        child: Text([
          if (free > 0) '$free صنف لم يُستخدم في أي مستند أو حركة مخزون: يُحذف نهائياً مع صورته.',
          if (used.isNotEmpty)
            '${used.length} صنف مستخدم (فاتورة أو مخزون أو أمر) فلا يُحذف حتى تبقى المستندات صحيحة؛ '
                'يمكن إيقافه بعد ذلك فيختفي من البيع والقوائم.',
          'لا يمكن التراجع عن الحذف.',
        ].join('\n')),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: AppColors.bad),
          onPressed: free == 0 ? null : () => Navigator.pop(context, true),
          icon: const Icon(Icons.delete_outline),
          label: const Text('حذف'),
        ),
        if (free == 0)
          FilledButton(onPressed: () => Navigator.pop(context, false), child: const Text('حسناً')),
      ],
    ),
  );
  var changed = false;
  if (ok == true && context.mounted) {
    final r = await runGuarded(context, () => service.deleteUnused(ids, user: user));
    if (r == null || !context.mounted) return false;
    changed = r.deleted > 0;
    showToast(context, 'حُذف ${r.deleted} صنف${r.kept.isEmpty ? '' : '، وبقي ${r.kept.length} مستخدم'}');
  }
  // Used ones: offer to switch them off.
  if (used.isNotEmpty && context.mounted) {
    final off = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('أصناف مستخدمة'),
        content: SizedBox(
          width: 460,
          height: 260,
          child: ListView(children: [
            const Text('هذه الأصناف عليها مستندات أو مخزون فلا تُحذف. إيقافها يخفيها من البيع والقوائم ويحتفظ بتاريخها:'),
            const SizedBox(height: 8),
            for (final e in used.entries)
              Text('• ${names[e.key] ?? e.key}: ${e.value}', style: const TextStyle(fontSize: 13, color: AppColors.muted)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('اتركها')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('إيقافها')),
        ],
      ),
    );
    if (off == true && context.mounted) {
      await runGuarded(context, () => service.setActive(used.keys, false, userId: user.id));
      changed = true;
      if (context.mounted) showToast(context, 'أُوقف ${used.length} صنف');
    }
  }
  return changed;
}
