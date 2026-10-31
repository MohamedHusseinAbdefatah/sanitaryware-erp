import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth/auth_service.dart';
import 'backup/backup_actions.dart';
import 'backup/backup_service.dart';
import 'db/database.dart';
import 'services/settings_service.dart';

/// Overridden in main.dart with the opened database.
final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('databaseProvider must be overridden'),
);

/// Overridden in main.dart with the real database file.
final databaseFileProvider = Provider<File>(
  (ref) => throw UnimplementedError('databaseFileProvider must be overridden'),
);

/// Overridden in main.dart with the backup folder.
final backupServiceProvider = Provider<BackupService>(
  (ref) => throw UnimplementedError('backupServiceProvider must be overridden'),
);

final authServiceProvider =
    Provider<AuthService>((ref) => AuthService(ref.watch(databaseProvider)));

final settingsServiceProvider =
    Provider<SettingsService>((ref) => SettingsService(ref.watch(databaseProvider)));

final backupActionsProvider = Provider<BackupActions>(
  (ref) => BackupActions(
    db: ref.watch(databaseProvider),
    backups: ref.watch(backupServiceProvider),
    databaseFile: ref.watch(databaseFileProvider),
  ),
);
