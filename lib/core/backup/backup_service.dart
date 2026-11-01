import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sql;

import '../db/database.dart';

abstract final class BackupReason {
  static const manual = 'manual';
  static const onClose = 'auto';
  static const beforeMigration = 'before-migration';
  static const beforeRestore = 'before-restore';
  static const beforeReset = 'before-reset';
}

class BackupInfo {
  const BackupInfo(this.file, this.time, this.reason, this.sizeBytes);

  final File file;
  final DateTime time;
  final String reason;
  final int sizeBytes;
}

/// A backup is a zip holding one consistent copy of the database, named
/// `erp-YYYYMMDD-HHMMSS-mmm-<reason>.zip`. Only the newest [keep] are kept.
///
/// Restore is two steps because the open database cannot be swapped in
/// place: [stageRestore] checks the backup and puts it next to the database
/// as `<db>.pending`, and [applyPendingRestore] swaps it in on the next start,
/// before the database is opened.
class BackupService {
  BackupService({required this.dir, this.keep = 10});

  final Directory dir;
  final int keep;

  static const _entryName = 'erp.sqlite';
  static final _namePattern =
      RegExp(r'^erp-(\d{8})-(\d{6})-(\d{3})-([a-z-]+)\.zip$');

  /// Backs up the open database. [copyTo] is an optional second folder
  /// (USB or cloud-synced); a failure to copy there does not fail the backup.
  Future<File> backup(
    AppDatabase db, {
    String reason = BackupReason.manual,
    Directory? copyTo,
  }) async {
    return _backupWith(
      (target) => db.customStatement('VACUUM INTO ?', [target]),
      reason,
      copyTo,
    );
  }

  /// Backs up a database file that is not open (used before a migration).
  Future<File> backupClosedFile(File dbFile, {required String reason}) {
    return _backupWith((target) async {
      final raw = sql.sqlite3.open(dbFile.path, mode: sql.OpenMode.readOnly);
      try {
        raw.execute('VACUUM INTO ?', [target]);
      } finally {
        raw.dispose();
      }
    }, reason, null);
  }

  Future<File> _backupWith(
    Future<void> Function(String target) copy,
    String reason,
    Directory? copyTo,
  ) async {
    await dir.create(recursive: true);
    final now = DateTime.now();
    final temp = File(p.join(dir.path, '.tmp-${now.microsecondsSinceEpoch}.sqlite'));
    try {
      // VACUUM INTO writes a clean, consistent copy even while WAL is in use.
      await copy(temp.path);
      final bytes = await temp.readAsBytes();
      final archive = Archive()..addFile(ArchiveFile(_entryName, bytes.length, bytes));
      final zip = File(p.join(dir.path, _fileName(now, reason)));
      await zip.writeAsBytes(ZipEncoder().encode(archive)!, flush: true);
      await prune();
      if (copyTo != null) {
        try {
          await copyTo.create(recursive: true);
          await zip.copy(p.join(copyTo.path, p.basename(zip.path)));
        } on FileSystemException {
          // The external folder may be an unplugged USB drive.
        }
      }
      return zip;
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  /// Newest first.
  Future<List<BackupInfo>> list() async {
    if (!await dir.exists()) return [];
    final result = <BackupInfo>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final m = _namePattern.firstMatch(p.basename(entity.path));
      if (m == null) continue;
      final d = m.group(1)!, t = m.group(2)!;
      final time = DateTime(
        int.parse(d.substring(0, 4)),
        int.parse(d.substring(4, 6)),
        int.parse(d.substring(6, 8)),
        int.parse(t.substring(0, 2)),
        int.parse(t.substring(2, 4)),
        int.parse(t.substring(4, 6)),
        int.parse(m.group(3)!),
      );
      result.add(BackupInfo(entity, time, m.group(4)!, await entity.length()));
    }
    result.sort((a, b) => b.time.compareTo(a.time));
    return result;
  }

  Future<void> prune() async {
    final all = await list();
    for (final old in all.skip(keep)) {
      await old.file.delete();
    }
  }

  /// Checks [zip] and stages it to replace [dbFile] on the next start.
  /// Throws [BackupException] if the file is not a usable backup.
  Future<void> stageRestore(
    File zip, {
    required File dbFile,
    required int currentSchemaVersion,
  }) async {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
    } on Object {
      throw BackupException('الملف ليس نسخة احتياطية صالحة');
    }
    final entry = archive.findFile(_entryName);
    if (entry == null) throw BackupException('الملف ليس نسخة احتياطية صالحة');

    final staging = File('${dbFile.path}.restore-tmp');
    await staging.writeAsBytes(entry.content as List<int>, flush: true);
    try {
      _check(staging, currentSchemaVersion);
      await staging.rename(pendingFile(dbFile).path);
    } finally {
      if (await staging.exists()) await staging.delete();
    }
  }

  void _check(File file, int currentSchemaVersion) {
    final sql.Database raw;
    try {
      raw = sql.sqlite3.open(file.path, mode: sql.OpenMode.readOnly);
    } on Object {
      throw BackupException('الملف ليس نسخة احتياطية صالحة');
    }
    try {
      final integrity = raw.select('PRAGMA integrity_check').first.values.first;
      if (integrity != 'ok') throw BackupException('النسخة الاحتياطية تالفة');
      final hasUsers = raw
          .select("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'users'")
          .isNotEmpty;
      if (!hasUsers) throw BackupException('الملف ليس نسخة احتياطية من هذا البرنامج');
      if (raw.userVersion > currentSchemaVersion) {
        throw BackupException('النسخة من إصدار أحدث من البرنامج؛ حدّث البرنامج أولاً');
      }
    } on sql.SqliteException {
      throw BackupException('الملف ليس نسخة احتياطية صالحة');
    } finally {
      raw.dispose();
    }
  }

  static File pendingFile(File dbFile) => File('${dbFile.path}.pending');

  /// Call at startup before opening the database. Returns true if a staged
  /// restore was swapped in.
  static Future<bool> applyPendingRestore(File dbFile) async {
    final pending = pendingFile(dbFile);
    if (!await pending.exists()) return false;
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File('${dbFile.path}$suffix');
      if (await f.exists()) await f.delete();
    }
    await pending.rename(dbFile.path);
    return true;
  }

  static String _fileName(DateTime t, String reason) {
    String two(int v) => v.toString().padLeft(2, '0');
    final date = '${t.year}${two(t.month)}${two(t.day)}';
    final time = '${two(t.hour)}${two(t.minute)}${two(t.second)}';
    final ms = t.millisecond.toString().padLeft(3, '0');
    return 'erp-$date-$time-$ms-$reason.zip';
  }
}

class BackupException implements Exception {
  BackupException(this.message);
  final String message;
  @override
  String toString() => message;
}
