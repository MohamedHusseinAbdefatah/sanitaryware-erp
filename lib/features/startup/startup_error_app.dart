import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../app.dart';
import '../../core/backup/backup_service.dart';
import '../../core/backup/restart.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/theme.dart';
import '../settings/backup_list.dart';

/// Shown instead of the app when the database cannot be opened or fails
/// SQLite's integrity check. The only way forward is restoring a backup.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({
    super.key,
    required this.message,
    required this.backups,
    required this.databaseFile,
    this.db,
  });

  final String message;
  final BackupService backups;
  final File databaseFile;
  final AppDatabase? db;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: Strings.appTitle,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      locale: appLocale,
      supportedLocales: const [appLocale],
      localizationsDelegates: appLocalizationsDelegates,
      home: _StartupErrorScreen(app: this),
    );
  }
}

class _StartupErrorScreen extends StatefulWidget {
  const _StartupErrorScreen({required this.app});

  final StartupErrorApp app;

  @override
  State<_StartupErrorScreen> createState() => _StartupErrorScreenState();
}

class _StartupErrorScreenState extends State<_StartupErrorScreen> {
  List<BackupInfo> _list = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.app.backups.list().then((l) {
      if (mounted) setState(() => _list = l);
    });
  }

  Future<void> _restore(BackupInfo backup) async {
    if (!await confirmRestore(context)) return;
    final app = widget.app;
    try {
      await app.backups.stageRestore(
        backup.file,
        dbFile: app.databaseFile,
        currentSchemaVersion: AppDatabase.latestSchemaVersion,
      );
      // Keep the damaged file for the developer to inspect.
      if (await app.databaseFile.exists()) {
        final stamp = DateTime.now().millisecondsSinceEpoch;
        await app.databaseFile.copy(
          p.join(app.backups.dir.path, 'damaged-$stamp.sqlite'),
        );
      }
      await restartApp(app.db);
    } on BackupException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.error_outline, color: theme.colorScheme.error),
                      const SizedBox(width: 8),
                      Text(Strings.startupErrorTitle, style: theme.textTheme.titleLarge),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SelectableText(widget.app.message),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                  ],
                  const Divider(height: 32),
                  Text(Strings.backupSection, style: theme.textTheme.titleMedium),
                  Flexible(
                    child: SingleChildScrollView(
                      child: BackupList(backups: _list, onRestore: _restore),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
