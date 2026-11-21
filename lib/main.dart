import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/auth/auth_service.dart';
import 'core/auth/remember_service.dart';
import 'core/auth/session.dart';
import 'core/backup/backup_actions.dart';
import 'core/backup/backup_service.dart';
import 'core/db/connection.dart';
import 'core/db/database.dart';
import 'core/error_log.dart';
import 'core/l10n/strings.dart';
import 'core/providers.dart';
import 'features/startup/startup_error_app.dart';

/// How often the open program takes a timed backup.
const scheduledBackupEvery = Duration(hours: 2);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: Size(1280, 800),
    minimumSize: Size(1100, 700),
    center: true,
    title: Strings.appTitle,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  final paths = await AppPaths.resolve();
  ErrorLog.start(paths.dataDir);
  final backups = BackupService(dir: paths.backupDir);

  StartupResult startup;
  try {
    startup = await openAppDatabase(paths, backups);
  } catch (e, stack) {
    ErrorLog.record(e, stack, where: 'opening the database');
    runApp(StartupErrorApp(
      message: '${Strings.startupFailed}\n$e',
      backups: backups,
      databaseFile: paths.databaseFile,
    ));
    return;
  }
  final db = startup.db;
  if (!startup.integrityOk) {
    runApp(StartupErrorApp(
      message: Strings.startupDamaged,
      backups: backups,
      databaseFile: paths.databaseFile,
      db: db,
    ));
    return;
  }

  final setupNeeded = !await AuthService(db).hasAnyUser();
  // "Remember me": a token kept in this Windows user's data folder signs in
  // without the password (and is replaced at once by a new one).
  final rememberStore = RememberStore(File('${paths.dataDir.path}${Platform.pathSeparator}login.remember'));
  User? remembered;
  if (!setupNeeded) {
    try {
      final token = await rememberStore.read();
      if (token != null) {
        final resumed = await RememberService(db).resume(token, device: Platform.localHostname);
        if (resumed == null) {
          await rememberStore.clear();
        } else {
          remembered = resumed.$1;
          await rememberStore.write(resumed.$2);
        }
      }
    } catch (e, stack) {
      ErrorLog.record(e, stack, where: 'remembered login');
      await rememberStore.clear();
    }
  }
  final actions = BackupActions(
    db: db,
    backups: backups,
    databaseFile: paths.databaseFile,
  );
  await windowManager.setPreventClose(true);
  windowManager.addListener(_BackupOnClose(db, actions));
  // A timed backup while the program is open (blueprint 9.3), so a power cut
  // or a crash loses at most two hours of work.
  Timer.periodic(scheduledBackupEvery, (_) async {
    try {
      if (await AuthService(db).hasAnyUser()) await actions.backupNow(reason: BackupReason.scheduled);
    } catch (e, stack) {
      ErrorLog.record(e, stack, where: 'scheduled backup');
    }
  });

  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        databaseFileProvider.overrideWithValue(paths.databaseFile),
        backupServiceProvider.overrideWithValue(backups),
        setupNeededProvider.overrideWith((ref) => setupNeeded),
        rememberStoreProvider.overrideWithValue(rememberStore),
        if (remembered != null) currentUserProvider.overrideWith((ref) => remembered),
      ],
      child: const App(),
    ),
  );
}

/// Takes the automatic backup when the window closes, then really closes.
class _BackupOnClose with WindowListener {
  _BackupOnClose(this.db, this.actions);

  final AppDatabase db;
  final BackupActions actions;
  bool _closing = false;

  @override
  Future<void> onWindowClose() async {
    if (_closing) return;
    _closing = true;
    try {
      // Nothing worth keeping before the first-run setup.
      if (await AuthService(db).hasAnyUser()) {
        await actions.backupNow(reason: BackupReason.onClose);
      }
    } catch (e, stack) {
      // Never block closing the program because a backup failed, but keep
      // a record: a silent backup failure is how data gets lost.
      ErrorLog.record(e, stack, where: 'backup on close');
    }
    await db.close();
    await windowManager.destroy();
  }
}
