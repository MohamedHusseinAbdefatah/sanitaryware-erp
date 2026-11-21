import 'package:flutter/material.dart';

import '../theme.dart';

/// What a list or page shows when it has nothing: an icon, what is missing,
/// what to do about it, and (where it helps) a button that does it.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    this.message,
    this.icon = Icons.inbox_outlined,
    this.action,
    this.compact = false,
  });

  final String title;
  final String? message;
  final IconData icon;

  /// Usually a FilledButton or OutlinedButton that adds the first record.
  final Widget? action;

  /// Smaller, for a panel inside a page.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 40.0 : 56.0;
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(compact ? AppSpace.lg : AppSpace.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: size,
                height: size,
                decoration: const BoxDecoration(color: AppColors.brandSoft, shape: BoxShape.circle),
                child: Icon(icon, size: size * .5, color: AppColors.brand),
              ),
              SizedBox(height: compact ? AppSpace.sm : AppSpace.md),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.ink, fontWeight: FontWeight.w700),
              ),
              if (message != null && message!.isNotEmpty) ...[
                const SizedBox(height: AppSpace.xs),
                Text(message!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.muted, height: 1.6)),
              ],
              if (action != null) ...[const SizedBox(height: AppSpace.lg), action!],
            ],
          ),
        ),
      ),
    );
  }
}

/// A calm loading indicator with an optional line of what is loading.
class LoadingState extends StatelessWidget {
  const LoadingState({super.key, this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
          if (label != null) ...[
            const SizedBox(height: AppSpace.md),
            Text(label!, style: const TextStyle(color: AppColors.muted)),
          ],
        ]),
      ),
    );
  }
}

/// Something failed to load: what happened, and a way to try again.
class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 52,
              height: 52,
              decoration: const BoxDecoration(color: AppColors.badBg, shape: BoxShape.circle),
              child: const Icon(Icons.error_outline, color: AppColors.bad, size: 28),
            ),
            const SizedBox(height: AppSpace.md),
            const Text('تعذّر تحميل البيانات', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpace.xs),
            SelectableText(message, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.muted)),
            if (onRetry != null) ...[
              const SizedBox(height: AppSpace.lg),
              OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('إعادة المحاولة')),
            ],
          ]),
        ),
      ),
    );
  }
}

/// A titled group of form fields inside a dialog or page, so long forms read
/// as a few short ones.
class FormSection extends StatelessWidget {
  const FormSection({super.key, required this.title, required this.children, this.icon, this.trailing});

  final String title;
  final IconData? icon;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          if (icon != null) ...[Icon(icon, size: 18, color: AppColors.brand), const SizedBox(width: AppSpace.sm)],
          Expanded(
            child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.ink, fontSize: 14.5)),
          ),
          if (trailing != null) trailing!,
        ]),
        const SizedBox(height: AppSpace.xs),
        const Divider(),
        const SizedBox(height: AppSpace.md),
        ...children,
      ]),
    );
  }
}
