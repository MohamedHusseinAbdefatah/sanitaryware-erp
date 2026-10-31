import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sanitaryware_erp/core/backup/backup_service.dart';
import 'package:sanitaryware_erp/core/db/database.dart';

void main() {
  late Directory root;
  late File dbFile;
  late BackupService backups;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('erp_backup_test');
    dbFile = File(p.join(root.path, 'erp.sqlite'));
    backups = BackupService(dir: Directory(p.join(root.path, 'backups')), keep: 3);
  });

  tearDown(() => root.delete(recursive: true));

  AppDatabase open() => AppDatabase(NativeDatabase(dbFile));

  Future<void> addProduct(AppDatabase db, String code) => db
      .into(db.products)
      .insert(ProductsCompanion.insert(code: code, nameAr: 'منتج $code'));

  Future<List<String>> codes(AppDatabase db) async =>
      (await db.select(db.products).get()).map((p) => p.code).toList();

  test('backup creates a zip that lists with its reason', () async {
    final db = open();
    await addProduct(db, 'A1');
    final file = await backups.backup(db);
    await db.close();

    expect(await file.exists(), isTrue);
    final listed = await backups.list();
    expect(listed.single.reason, BackupReason.manual);
    expect(listed.single.sizeBytes, greaterThan(0));
  });

  test('restore returns the exact earlier state', () async {
    var db = open();
    await addProduct(db, 'A1');
    final backup = await backups.backup(db);
    await addProduct(db, 'B2');
    await (db.delete(db.products)..where((t) => t.code.equals('A1'))).go();

    await backups.stageRestore(
      backup,
      dbFile: dbFile,
      currentSchemaVersion: db.schemaVersion,
    );
    await db.close();
    expect(await BackupService.applyPendingRestore(dbFile), isTrue);

    db = open();
    expect(await codes(db), ['A1']);
    await db.close();
    expect(await BackupService.applyPendingRestore(dbFile), isFalse);
  });

  test('old backups are pruned to the newest few', () async {
    final db = open();
    for (var i = 0; i < 5; i++) {
      await backups.backup(db);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await db.close();
    final listed = await backups.list();
    expect(listed, hasLength(3));
    expect(listed.first.time.isAfter(listed.last.time), isTrue);
  });

  test('a closed database file can be backed up (before a migration)', () async {
    final db = open();
    await addProduct(db, 'A1');
    await db.close();
    await backups.backupClosedFile(dbFile, reason: BackupReason.beforeMigration);
    expect((await backups.list()).single.reason, BackupReason.beforeMigration);
  });

  test('a copy goes to the external folder too', () async {
    final external = Directory(p.join(root.path, 'usb'));
    final db = open();
    final file = await backups.backup(db, copyTo: external);
    await db.close();
    expect(await File(p.join(external.path, p.basename(file.path))).exists(), isTrue);
  });

  test('a file that is not a backup is refused and nothing is staged', () async {
    final junk = File(p.join(root.path, 'junk.zip'))..writeAsStringSync('hello');
    await expectLater(
      backups.stageRestore(junk, dbFile: dbFile, currentSchemaVersion: 2),
      throwsA(isA<BackupException>()),
    );
    expect(await BackupService.pendingFile(dbFile).exists(), isFalse);
  });

  test('a backup from a newer app version is refused', () async {
    final db = open();
    final backup = await backups.backup(db);
    await db.close();
    await expectLater(
      backups.stageRestore(backup, dbFile: dbFile, currentSchemaVersion: 1),
      throwsA(isA<BackupException>()),
    );
  });
}
