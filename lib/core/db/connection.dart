import 'dart:io';

import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'database.dart';

/// The single database file, kept in the user's app-data folder
/// (not next to the program files, so updates never touch it).
Future<File> appDatabaseFile() async {
  final support = await getApplicationSupportDirectory();
  final dir = Directory(p.join(support.path, 'SanitarywareERP'));
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return File(p.join(dir.path, 'erp.sqlite'));
}

Future<AppDatabase> openAppDatabase() async {
  final file = await appDatabaseFile();
  return AppDatabase(
    NativeDatabase(
      file,
      setup: (raw) {
        // Write-ahead logging is safer if the computer shuts down mid-save.
        raw.execute('PRAGMA journal_mode = WAL;');
      },
    ),
  );
}
