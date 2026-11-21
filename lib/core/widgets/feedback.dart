import 'package:flutter/material.dart';

import '../error_log.dart';
import '../money.dart';
import '../theme.dart';
import '../l10n/strings.dart';
import '../services/errors.dart';

/// What a toast reports, which decides its icon and colour.
enum ToastKind { success, info, warning, error }

/// A short message at the bottom of the window that goes away by itself:
/// "saved", "copied"... Problems that need a decision use [showMessage].
void showToast(BuildContext context, String text, {ToastKind kind = ToastKind.success}) {
  final (icon, accent) = switch (kind) {
    ToastKind.success => (Icons.check_circle, const Color(0xFF6FD39C)),
    ToastKind.info => (Icons.info, AppColors.sideAccent),
    ToastKind.warning => (Icons.warning_amber_rounded, const Color(0xFFF2C14E)),
    ToastKind.error => (Icons.error, const Color(0xFFFF8A80)),
  };
  final width = MediaQuery.sizeOf(context).width;
  final side = width > 560 ? (width - 520) / 2 : 12.0;
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    behavior: SnackBarBehavior.floating,
    margin: EdgeInsets.fromLTRB(side, 0, side, 16),
    duration: Duration(seconds: kind == ToastKind.error ? 6 : 3),
    showCloseIcon: true,
    closeIconColor: AppColors.sideText,
    content: Row(children: [
      Icon(icon, color: accent, size: 20),
      const SizedBox(width: 10),
      Expanded(child: Text(text)),
    ]),
  ));
}

/// Asks before something that matters: says what will happen and what it
/// changes, with the safe choice first. True only if the person agrees.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = Strings.confirm,
  bool destructive = false,
  IconData? icon,
}) async {
  final tone = destructive ? AppColors.bad : AppColors.brand;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: Icon(icon ?? (destructive ? Icons.warning_amber_rounded : Icons.help_outline), color: tone, size: 32),
      title: Text(title, textAlign: TextAlign.center),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Text(message, textAlign: TextAlign.center, style: const TextStyle(height: 1.6, color: AppColors.muted)),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        OutlinedButton(autofocus: true, onPressed: () => Navigator.pop(context, false), child: const Text(Strings.cancel)),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: AppColors.bad) : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok == true;
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

/// A short explanation in a tinted box, for what a form will do before it
/// is saved (a historical date, a correction that changes balances...).
class InfoNote extends StatelessWidget {
  const InfoNote(this.text, {super.key, this.warning = false});

  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final color = warning ? AppColors.warn : AppColors.info;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: warning ? AppColors.warnBg : AppColors.infoBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(warning ? Icons.warning_amber_rounded : Icons.info_outline, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyle(color: color, height: 1.5))),
      ]),
    );
  }
}

/// Asks for one amount of money (piastres). Null if cancelled.
Future<int?> askAmount(
  BuildContext context, {
  required String title,
  String? hint,
  int? initial,
  bool allowZero = false,
}) async {
  final controller = TextEditingController(
      text: initial == null || initial <= 0 ? '' : formatMoney(initial).replaceAll(',', ''));
  final value = await showDialog<int>(
    context: context,
    builder: (context) {
      String? error;
      return StatefulBuilder(builder: (context, setState) {
        void submit() {
          final v = parseMoney(controller.text.trim().isEmpty && allowZero ? '0' : controller.text);
          if (v == null || v < 0 || (v == 0 && !allowZero)) {
            setState(() => error = Strings.invalidAmount);
            return;
          }
          Navigator.pop(context, v);
        }

        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 380,
            child: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: 'المبلغ (جنيه)', helperText: hint, errorText: error),
              onSubmitted: (_) => submit(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.cancel)),
            FilledButton(onPressed: submit, child: const Text(Strings.confirm)),
          ],
        );
      });
    },
  );
  controller.dispose();
  return value;
}
