@Timeout(Duration(seconds: 120))
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sanitaryware_erp/app.dart';
import 'package:sanitaryware_erp/core/auth/session.dart';
import 'package:sanitaryware_erp/core/backup/backup_service.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/l10n/strings.dart';
import 'package:sanitaryware_erp/core/providers.dart';
import 'package:sanitaryware_erp/core/router.dart';
import 'package:sanitaryware_erp/features/shell/sections.dart';

import '../support/fixture.dart';

void main() {
  late Shop shop;

  setUp(() async {
    shop = await Shop.open();
  });

  tearDown(() => shop.close());

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpApp(WidgetTester tester, User user) async {
    tester.view.physicalSize = const Size(1100, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(shop.db),
          databaseFileProvider.overrideWithValue(File('unused.sqlite')),
          backupServiceProvider.overrideWithValue(BackupService(dir: Directory('unused'))),
          setupNeededProvider.overrideWith((ref) => false),
          currentUserProvider.overrideWith((ref) => user),
        ],
        child: const App(),
      ),
    );
    await settle(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  }

  GoRouter router(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(App))).read(routerProvider);

  testWidgets('every settings tab opens without layout errors', (tester) async {
    await pumpApp(tester, shop.admin);
    final entry = find.descendant(of: find.byType(SingleChildScrollView).first, matching: find.text(Strings.settings));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await settle(tester);
    for (final tab in [Strings.usersTab, Strings.importTab, Strings.auditTab, Strings.generalTab]) {
      await tester.tap(find.text(tab));
      await settle(tester);
      expect(tester.takeException(), isNull, reason: tab);
    }
    // The users tab lists both users.
    await tester.tap(find.text(Strings.usersTab));
    await settle(tester);
    expect(find.textContaining('الكاشير'), findsWidgets);
    await unmount(tester);
  });

  testWidgets('every sidebar entry fits and really opens its page', (tester) async {
    await pumpApp(tester, shop.admin);
    final sidebar = find.byType(SingleChildScrollView).first;
    for (final s in appSections) {
      final entry = find.descendant(of: sidebar, matching: find.text(s.title));
      // No scrolling needed at the smallest window size.
      expect(tester.getRect(entry).bottom, lessThan(700 - 60), reason: s.title);
      await tester.tap(entry);
      await settle(tester);
      expect(router(tester).state.matchedLocation, s.path, reason: s.title);
    }
    await unmount(tester);
  });

  testWidgets('a cashier typing an admin address lands on the dashboard', (tester) async {
    await pumpApp(tester, shop.cashier);
    for (final path in ['/purchases/new', '/purchases/1', '/settings', '/reports', '/expenses', '/suppliers']) {
      router(tester).go(path);
      await settle(tester);
      expect(router(tester).state.matchedLocation, '/dashboard', reason: path);
    }
    // Allowed pages stay.
    router(tester).go('/sales/new');
    await settle(tester);
    expect(router(tester).state.matchedLocation, '/sales/new');
    await unmount(tester);
  });
}
