import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/l10n/strings.dart';
import 'sections.dart';

/// Main window: sidebar on the right (RTL) and the selected page on the left.
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final user = ref.watch(currentUserProvider);
    final isAdmin = user?.isAdmin ?? false;

    return Scaffold(
      body: Row(
        children: [
          Container(
            width: 230,
            color: scheme.surfaceContainerHighest,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    Strings.appTitle,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
                Expanded(
                  child: ListView(
                    children: [
                      for (var i = 0; i < appSections.length; i++)
                        if (isAdmin || !appSections[i].adminOnly)
                          ListTile(
                            leading: Icon(appSections[i].icon),
                            title: Text(appSections[i].title),
                            selected: i == navigationShell.currentIndex,
                            onTap: () => navigationShell.goBranch(i),
                          ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                if (user != null)
                  ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: Text(user.fullName),
                    subtitle: Text(isAdmin ? Strings.roleAdmin : Strings.roleCashier),
                    trailing: IconButton(
                      tooltip: Strings.logout,
                      icon: const Icon(Icons.logout),
                      onPressed: () =>
                          ref.read(currentUserProvider.notifier).state = null,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(child: navigationShell),
        ],
      ),
    );
  }
}
