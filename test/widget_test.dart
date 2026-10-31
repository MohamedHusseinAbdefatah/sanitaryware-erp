import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/app.dart';
import 'package:sanitaryware_erp/core/auth/auth_service.dart';
import 'package:sanitaryware_erp/core/auth/password_hasher.dart';
import 'package:sanitaryware_erp/core/auth/session.dart';
import 'package:sanitaryware_erp/core/backup/backup_service.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/l10n/strings.dart';
import 'package:sanitaryware_erp/core/providers.dart';
import 'package:sanitaryware_erp/core/services/settings_service.dart';

void main() {
  late AppDatabase db;
  late AuthService auth;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    auth = AuthService(db, hasher: const PasswordHasher(iterations: 10));
  });

  tearDown(() => db.close());

  /// Alternates real time (for drift's queries) with frames. pumpAndSettle
  /// would wait forever while a loading spinner (the dashboard) is on screen.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Unmounts so drift closes its streams before the database does.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  }

  Future<void> pumpApp(
    WidgetTester tester, {
    required bool setupNeeded,
    User? user,
  }) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          databaseFileProvider.overrideWithValue(File('unused.sqlite')),
          backupServiceProvider.overrideWithValue(
            BackupService(dir: Directory('unused-backups')),
          ),
          authServiceProvider.overrideWithValue(auth),
          setupNeededProvider.overrideWith((ref) => setupNeeded),
          currentUserProvider.overrideWith((ref) => user),
        ],
        child: const App(),
      ),
    );
    await settle(tester);
  }

  Future<User> makeUser(WidgetTester tester, String role) async {
    return (await tester.runAsync(() async {
      if (!await auth.hasAnyUser()) {
        await auth.firstRunSetup(
          company: const CompanyInfo(name: 'معرض'),
          fullName: 'المدير',
          username: 'admin',
          password: '1234',
        );
      }
      if (role == UserRole.admin) return auth.login('admin', '1234');
      return auth.createUser(
        fullName: 'الكاشير',
        username: 'cashier',
        password: '1234',
        role: UserRole.cashier,
      );
    }))!;
  }

  testWidgets('first start shows the setup screen', (tester) async {
    await pumpApp(tester, setupNeeded: true);
    expect(find.text(Strings.setupTitle), findsOneWidget);
  });

  testWidgets('after setup, a logged-out user sees the login screen', (tester) async {
    await pumpApp(tester, setupNeeded: false);
    expect(find.text(Strings.loginTitle), findsOneWidget);
  });

  testWidgets('logging in opens the sidebar', (tester) async {
    await makeUser(tester, UserRole.admin);
    await pumpApp(tester, setupNeeded: false);

    await tester.enterText(find.byType(TextField).at(0), 'admin');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.runAsync(() async {
      await tester.tap(find.text(Strings.login));
      // Let the password check finish on its background isolate.
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await settle(tester);

    expect(find.text(Strings.products), findsOneWidget);
    expect(find.text('المدير'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a wrong password shows an error and stays on login', (tester) async {
    await makeUser(tester, UserRole.admin);
    await pumpApp(tester, setupNeeded: false);

    await tester.enterText(find.byType(TextField).at(0), 'admin');
    await tester.enterText(find.byType(TextField).at(1), 'nope');
    await tester.runAsync(() async {
      await tester.tap(find.text(Strings.login));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await settle(tester);

    expect(find.text(Strings.loginTitle), findsOneWidget);
    expect(find.text('اسم المستخدم أو كلمة المرور غير صحيحة'), findsOneWidget);
  });

  testWidgets('admin sees admin-only sections', (tester) async {
    final admin = await makeUser(tester, UserRole.admin);
    await pumpApp(tester, setupNeeded: false, user: admin);
    expect(find.text(Strings.settings), findsOneWidget);
    expect(find.text(Strings.purchases), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('cashier does not see admin-only sections', (tester) async {
    final cashier = await makeUser(tester, UserRole.cashier);
    await pumpApp(tester, setupNeeded: false, user: cashier);
    expect(find.text(Strings.sales), findsOneWidget);
    expect(find.text(Strings.settings), findsNothing);
    expect(find.text(Strings.purchases), findsNothing);
    expect(find.text(Strings.reports), findsNothing);
    await unmount(tester);
  });

  testWidgets('logging out returns to the login screen', (tester) async {
    final admin = await makeUser(tester, UserRole.admin);
    await pumpApp(tester, setupNeeded: false, user: admin);
    await tester.tap(find.byTooltip(Strings.logout));
    await settle(tester);
    expect(find.text(Strings.loginTitle), findsOneWidget);
  });
}
