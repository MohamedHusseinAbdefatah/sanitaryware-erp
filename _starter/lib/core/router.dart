import 'package:go_router/go_router.dart';

import '../features/shell/home_shell.dart';

final GoRouter appRouter = GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const HomeShell(),
    ),
  ],
);
