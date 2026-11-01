import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sanitaryware_erp/core/db/data_dir.dart';

void main() {
  late Directory appData;

  setUp(() async => appData = await Directory.systemTemp.createTemp('appdata'));
  tearDown(() => appData.delete(recursive: true));

  Future<void> legacy(String path, String content, DateTime when) async {
    final dir = Directory(path)..createSync(recursive: true);
    File(p.join(dir.path, 'erp.sqlite')).writeAsStringSync(content);
    File(p.join(dir.path, 'backups', 'b.zip'))
      ..createSync(recursive: true)
      ..writeAsStringSync('backup');
    for (final f in dir.listSync(recursive: true).whereType<File>()) {
      f.setLastModifiedSync(when);
    }
  }

  test('a new install gets an empty fixed folder', () async {
    final dir = await prepareDataDir(appData.path);
    expect(dir.path, p.join(appData.path, 'SanitarywareERP'));
    expect(dir.existsSync(), isTrue);
    expect(dir.listSync(), isEmpty);
  });

  test('the most recently used older folder is copied in, once', () async {
    final [renamed, original] = legacyDataDirs(appData.path);
    await legacy(original, 'old empty db', DateTime(2026, 10, 31));
    await legacy(renamed, 'db with the account', DateTime(2026, 11, 1));

    final dir = await prepareDataDir(appData.path);
    expect(File(p.join(dir.path, 'erp.sqlite')).readAsStringSync(), 'db with the account');
    expect(File(p.join(dir.path, 'backups', 'b.zip')).existsSync(), isTrue);
    expect(File(p.join(renamed, 'erp.sqlite')).existsSync(), isTrue); // left in place

    // Later starts use the fixed folder as it is.
    File(p.join(dir.path, 'erp.sqlite')).writeAsStringSync('new work');
    await prepareDataDir(appData.path);
    expect(File(p.join(dir.path, 'erp.sqlite')).readAsStringSync(), 'new work');
  });
}
