import 'package:flutter/material.dart';

import '../error_log.dart';
import '../l10n/strings.dart';
import '../services/errors.dart';

void showToast(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

/// Runs [action]; a [ValidationException] is shown in a dialog (its message
/// is meant for the person), anything else as an unexpected error.
/// Returns the result, or null if it failed.
Future<T?> runGuarded<T>(BuildContext context, Future<T> Function() action) async {
  try {
    return await action();
  } on ValidationException catch (e) {
    if (context.mounted) await showMessage(context, e.message);
  } catch (e, stack) {
    if ('$e'.contains('PERIOD_LOCKED')) {
      if (context.mounted) {
        await showMessage(context,
            'هذا التاريخ داخل فترة مقفلة؛ لا يُضاف فيها أو يُلغى شيء.\nيمكن للمدير إعادة فتح الفترة من: المحاسبة ← إقفال الفترات.');
      }
      return null;
    }
    ErrorLog.record(e, stack, where: 'action');
    if (context.mounted) await showMessage(context, '${Strings.unexpectedError}\n$e');
  }
  return null;
}

Future<void> showMessage(BuildContext context, String message) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      content: SelectableText(message),
      actions: [
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context),
          child: const Text(Strings.ok),
        ),
      ],
    ),
  );
}

/// Asks for a required reason (cancel, stock adjustment). Null if cancelled.
Future<String?> askReason(BuildContext context, {required String title}) async {
  final controller = TextEditingController();
  final reason = await showDialog<String>(
    context: context,
    builder: (context) {
      void submit() {
        if (controller.text.trim().isNotEmpty) Navigator.pop(context, controller.text.trim());
      }

      return AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 400,
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: Strings.reason),
            onSubmitted: (_) => submit(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.cancel)),
          FilledButton(onPressed: submit, child: const Text(Strings.confirm)),
        ],
      );
    },
  );
  controller.dispose();
  return reason;
}
