import 'dart:io';

import '../db/database.dart';

/// Closes the database and starts a fresh copy of the program, so a staged
/// restore is applied before anything opens the database again.
Future<Never> restartApp([AppDatabase? db]) async {
  try {
    await db?.close();
  } catch (_) {
    // A damaged database may fail to close; the restart replaces it anyway.
  }
  await Process.start(
    Platform.resolvedExecutable,
    const [],
    mode: ProcessStartMode.detached,
  );
  exit(0);
}
