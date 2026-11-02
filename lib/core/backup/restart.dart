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
  // --after-restart: the new copy waits for this one to exit instead of
  // refusing to start because "the program is already open" (main.cpp).
  await Process.start(
    Platform.resolvedExecutable,
    const ['--after-restart'],
    mode: ProcessStartMode.detached,
  );
  exit(0);
}
