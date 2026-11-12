import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/dates.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/l10n/strings.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/version.dart';
import 'sections.dart';

/// Sidebar groups: section paths in the order shown.
const _groups = <(String, List<String>)>[
  ('', ['/dashboard']),
  ('العمليات اليومية', ['/sales', '/customers', '/projects', '/returns', '/payments']),
  ('المخزون والمشتريات', ['/inventory', '/products', '/suppliers', '/purchases', '/price-lists']),
  ('المالية والإدارة', ['/accounting', '/expenses', '/reports', '/settings']),
];

final _companyNameProvider = FutureProvider.autoDispose<String>(
  (ref) async => (await ref.watch(settingsServiceProvider).company()).name,
);

/// Main window: a dark sidebar on the right (RTL), a top bar, and the page.
/// F9 opens a new sale from anywhere.
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final company = ref.watch(_companyNameProvider).valueOrNull ?? '';

    Widget entry(int i) {
      final s = appSections[i];
      final selected = i == navigationShell.currentIndex;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
        child: Material(
          color: selected ? AppColors.sideSelected : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => navigationShell.goBranch(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3.5),
              child: Row(
                children: [
                  Icon(s.icon, size: 20, color: selected ? AppColors.sideAccent : AppColors.sideText),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      s.title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.2,
                        color: selected ? Colors.white : AppColors.sideText,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final byPath = {for (var i = 0; i < appSections.length; i++) appSections[i].path: i};
    final sidebar = Container(
      width: 236,
      color: AppColors.brandDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(color: AppColors.brand, borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Icons.water_drop, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        Strings.appTitle,
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15, height: 1.2),
                      ),
                      Text(
                        company.isEmpty ? 'الإصدار $appVersion' : company,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.sideText, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // A Column (not a lazy list) so no entry is ever left unbuilt.
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (label, paths) in _groups) ...[
                    if (label.isNotEmpty &&
                        paths.any((p) => byPath[p] != null && user != null && appSections[byPath[p]!].allows(user)))
                      Padding(
                        padding: const EdgeInsets.fromLTRB(22, 8, 22, 2),
                        child: Text(
                          label,
                          style: const TextStyle(
                            color: AppColors.sideAccent,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: .3,
                          ),
                        ),
                      ),
                    for (final p in paths)
                      if (byPath[p] != null && user != null && appSections[byPath[p]!].allows(user)) entry(byPath[p]!),
                  ],
                  // Any section not placed in a group still shows.
                  for (var i = 0; i < appSections.length; i++)
                    if (!_groups.any((g) => g.$2.contains(appSections[i].path)) &&
                        (user != null && appSections[i].allows(user)))
                      entry(i),
                ],
              ),
            ),
          ),
          if (user != null)
            Container(
              margin: const EdgeInsets.all(8),
              padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
              decoration: BoxDecoration(color: AppColors.sideSelected, borderRadius: BorderRadius.circular(10)),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: AppColors.brand,
                    child: Text(
                      user.fullName.trim().isEmpty ? '?' : user.fullName.trim().characters.first,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user.fullName,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                        ),
                        Text(
                          UserRole.label(user.role),
                          style: const TextStyle(color: AppColors.sideText, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: Strings.logout,
                    icon: const Icon(Icons.logout, color: AppColors.sideText, size: 20),
                    onPressed: () => ref.read(currentUserProvider.notifier).state = null,
                  ),
                ],
              ),
            ),
        ],
      ),
    );

    final now = DateTime.now();
    final topBar = Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          const Icon(Icons.calendar_today_outlined, size: 16, color: AppColors.muted),
          const SizedBox(width: 8),
          Text(formatLongDate(now), style: const TextStyle(color: AppColors.muted)),
          const Spacer(),
          if (user != null && user.can(Perm.sell))
            FilledButton.tonalIcon(
              onPressed: () => context.go('/sales/new'),
              icon: const Icon(Icons.point_of_sale, size: 18),
              label: const Text('بيع جديد (F9)'),
            ),
        ],
      ),
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f9): () {
          if (user != null && user.can(Perm.sell)) context.go('/sales/new');
        },
      },
      child: Scaffold(
        body: Row(
          children: [
            sidebar,
            Expanded(
              child: Column(
                children: [
                  topBar,
                  Expanded(child: navigationShell),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
