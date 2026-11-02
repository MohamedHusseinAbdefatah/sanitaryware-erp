import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/auth/auth_service.dart';
import 'core/auth/session.dart';
import 'core/backup/backup_actions.dart';
import 'core/backup/backup_service.dart';
import 'core/db/connection.dart';
import 'core/db/database.dart';
import 'core/error_log.dart';
import 'core/l10n/strings.dart';
import 'core/providers.dart';
import 'features/startup/startup_error_app.dart';

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
  final actions = BackupActions(
    db: db,
    backups: backups,
    databaseFile: paths.databaseFile,
  );
  await windowManager.setPreventClose(true);
  windowManager.addListener(_BackupOnClose(db, actions));

  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        databaseFileProvider.overrideWithValue(paths.databaseFile),
        backupServiceProvider.overrideWithValue(backups),
        setupNeededProvider.overrideWith((ref) => setupNeeded),
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
