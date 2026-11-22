import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets/feedback.dart';

/// Deletes a customer or supplier entered by mistake. Only one with no
/// dealings is deleted; one with dealings is offered to be switched off.
/// Returns true when it was deleted.
Future<bool> deleteParty(BuildContext context, WidgetRef ref,
    {required bool customer, required int id, required String name}) async {
  final parties = ref.read(partyServiceProvider);
  final used = await parties.usage(customer: customer, id: id);
  if (!context.mounted) return false;
  final what = customer ? 'العميل' : 'المورد';
  if (used.isNotEmpty) {
    await showMessage(
      context,
      'لا يمكن حذف $what "$name" لأنه مستخدم في: $used.\n'
      'حتى لا تختل الفواتير والأرصدة. يمكنك إيقافه من «تعديل» (إلغاء «نشط») فيختفي من القوائم.',
    );
    return false;
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('حذف $what'),
      content: Text('حذف "$name" نهائياً؟ ليس له أي تعاملات في البرنامج.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: AppColors.bad),
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.delete_outline),
          label: const Text('حذف'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return false;
  final done = await runGuarded(context, () async {
    await parties.deleteParty(customer: customer, id: id, userId: ref.read(currentUserProvider)?.id);
    return true;
  });
  if (done == true && context.mounted) showToast(context, 'حُذف $what "$name"');
  return done == true;
}
