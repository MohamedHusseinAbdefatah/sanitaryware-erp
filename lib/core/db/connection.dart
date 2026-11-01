import 'dart:io';

import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

import '../backup/backup_service.dart';
import 'data_dir.dart';
import 'database.dart';

/// Where the data lives: %APPDATA%\SanitarywareERP (see data_dir.dart),
/// not next to the program files, so installing an update never touches it.
class AppPaths {
  const AppPaths(this.dataDir);

  final Directory dataDir;

  File get databaseFile => File(p.join(dataDir.path, 'erp.sqlite'));
  Directory get backupDir => Directory(p.join(dataDir.path, 'backups'));

  static Future<AppPaths> resolve() async {
    final appData = Platform.environment['APPDATA'] ?? (await getApplicationSupportDirectory()).path;
    return AppPaths(await prepareDataDir(appData));
  }
}

class StartupResult {
  const StartupResult({
    required this.db,
    required this.integrityOk,
    required this.restored,
  });

  final AppDatabase db;
  final bool integrityOk;
  final bool restored;
}

/// Startup order matters:
/// 1. swap in a restore staged by the previous run,
/// 2. back up the file if this version is about to migrate it,
/// 3. open the database and let SQLite check the file.
Future<StartupResult> openAppDatabase(AppPaths paths, BackupService backups) async {
  final file = paths.databaseFile;
  final restored = await BackupService.applyPendingRestore(file);

  if (await file.exists()) {
    final version = _fileSchemaVersion(file);
    if (version > 0 && version < AppDatabase.latestSchemaVersion) {
      await backups.backupClosedFile(file, reason: BackupReason.beforeMigration);
    }
  }

  final db = AppDatabase(
    NativeDatabase(
      file,
      setup: (raw) {
        // Write-ahead logging is safer if the computer shuts down mid-save.
        raw.execute('PRAGMA journal_mode = WAL;');
      },
    ),
  );
  return StartupResult(
    db: db,
    integrityOk: await db.integrityOk(),
    restored: restored,
  );
}

int _fileSchemaVersion(File file) {
  final raw = sql.sqlite3.open(file.path, mode: sql.OpenMode.readOnly);
  try {
    return raw.userVersion;
  } finally {
    raw.dispose();
  }
}
