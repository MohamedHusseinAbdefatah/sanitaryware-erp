import 'dart:io';

import '../db/database.dart';
import '../services/audit_service.dart';
import '../services/settings_service.dart';
import 'backup_service.dart';

/// What the backup buttons do: back up (also to the external folder if one
/// is set), and restore with a safety backup of the current data first.
class BackupActions {
  BackupActions({
    required this.db,
    required this.backups,
    required this.databaseFile,
  });

  final AppDatabase db;
  final BackupService backups;
  final File databaseFile;

  Future<Directory?> externalFolder() async {
    final path = await SettingsService(db).get(SettingKey.backupExternalFolder);
    return path == null || path.isEmpty ? null : Directory(path);
  }

  /// For the startup warning: is there a recent copy outside this computer?
  Future<ExternalBackupStatus> externalStatus({DateTime? now}) async {
    final folder = await externalFolder();
    if (folder == null) return const ExternalBackupStatus(ExternalBackupState.notSet);
    if (!await folder.exists()) return const ExternalBackupStatus(ExternalBackupState.unavailable);
    final latest = (await BackupService(dir: folder).list()).firstOrNull?.time;
    final age = latest == null ? null : (now ?? DateTime.now()).difference(latest).inDays;
    return ExternalBackupStatus(
      age == null || age > ExternalBackupStatus.maxAgeDays ? ExternalBackupState.old : ExternalBackupState.ok,
      lastBackup: latest,
      ageDays: age,
    );
  }

  Future<void> setExternalFolder(String? path) =>
      SettingsService(db).set(SettingKey.backupExternalFolder, path ?? '');

  Future<File> backupNow({
    int? userId,
    String reason = BackupReason.manual,
  }) async {
    final file = await backups.backup(
      db,
      reason: reason,
      copyTo: await externalFolder(),
    );
    await AuditService(db).log(
      action: AuditAction.backup,
      entity: 'database',
      userId: userId,
      details: reason,
    );
    return file;
  }

  /// Checks [zip], backs up the current data, and stages the restore.
  /// The app must restart afterwards for the restore to take effect.
  Future<void> restore(File zip, {int? userId}) async {
    // Check first so a bad file never costs the user a backup slot.
    await backups.stageRestore(
      zip,
      dbFile: databaseFile,
      currentSchemaVersion: db.schemaVersion,
    );
    try {
      await backupNow(userId: userId, reason: BackupReason.beforeRestore);
    } catch (_) {
      // Without a safety copy, do not replace the data.
      final pending = BackupService.pendingFile(databaseFile);
      if (await pending.exists()) await pending.delete();
      rethrow;
    }
    await AuditService(db).log(
      action: AuditAction.restore,
      entity: 'database',
      userId: userId,
      details: zip.path,
    );
  }
}

enum ExternalBackupState {
  ok,

  /// No external folder chosen in Settings.
  notSet,

  /// The folder is chosen but not reachable (USB drive unplugged).
  unavailable,

  /// No copy there, or the newest is older than [ExternalBackupStatus.maxAgeDays].
  old,
}

class ExternalBackupStatus {
  const ExternalBackupStatus(this.state, {this.lastBackup, this.ageDays});

  static const maxAgeDays = 7;

  final ExternalBackupState state;
  final DateTime? lastBackup;
  final int? ageDays;
}
