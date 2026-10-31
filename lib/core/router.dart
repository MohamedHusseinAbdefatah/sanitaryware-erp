import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/login_screen.dart';
import '../features/setup/setup_screen.dart';
import '../features/shell/home_shell.dart';
import '../features/shell/sections.dart';
import 'auth/auth_service.dart';
import 'auth/session.dart';

/// Guards, in order: first-run setup, then login, then role.
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier(0);
  ref.onDispose(refresh.dispose);
  ref.listen(currentUserProvider, (_, _) => refresh.value++);
  ref.listen(setupNeededProvider, (_, _) => refresh.value++);

  final router = GoRouter(
    initialLocation: appSections.first.path,
    refreshListenable: refresh,
    redirect: (context, state) {
      final location = state.matchedLocation;
      if (ref.read(setupNeededProvider)) {
        return location == '/setup' ? null : '/setup';
      }
      final user = ref.read(currentUserProvider);
      if (user == null) return location == '/login' ? null : '/login';
      if (location == '/setup' || location == '/login') {
        return appSections.first.path;
      }
      final section = appSections
          .where((s) => location == s.path || location.startsWith('${s.path}/'))
          .firstOrNull;
      if (section != null && section.adminOnly && !user.isAdmin) {
        return appSections.first.path;
      }
      return null;
    },
    routes: [
      GoRoute(path: '/setup', builder: (_, _) => const SetupScreen()),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => HomeShell(navigationShell: shell),
        branches: [
          for (final section in appSections)
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: section.path,
                  builder: (context, _) => section.builder(context),
                  routes: section.routes,
                ),
              ],
            ),
        ],
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
