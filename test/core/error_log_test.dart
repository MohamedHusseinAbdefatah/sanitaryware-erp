import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sanitaryware_erp/core/error_log.dart';
import 'package:sanitaryware_erp/core/version.dart';

void main() {
  late Directory dataDir;

  setUp(() async => dataDir = await Directory.systemTemp.createTemp('erp_log'));
  tearDown(() async {
    ErrorLog.stopForTest();
    await dataDir.delete(recursive: true);
  });

  test('errors go to logs/errors.log with time, version, place and stack', () {
    ErrorLog.start(dataDir);
    ErrorLog.record(StateError('boom'), StackTrace.current, where: 'saving an invoice');
    final text = File(p.join(dataDir.path, 'logs', 'errors.log')).readAsStringSync();
    expect(text, contains('v$appVersion'));
    expect(text, contains('saving an invoice'));
    expect(text, contains('Bad state: boom'));
    expect(text, contains('error_log_test.dart')); // the stack trace
  });

  test('a big log is moved to errors.old.log and a new one started', () {
    ErrorLog.start(dataDir);
    final log = File(p.join(dataDir.path, 'logs', 'errors.log'))
      ..writeAsStringSync('x' * (ErrorLog.maxBytes + 1));
    ErrorLog.record('new error', null);
    expect(File(p.join(dataDir.path, 'logs', 'errors.old.log')).lengthSync(), greaterThan(ErrorLog.maxBytes));
    expect(log.readAsStringSync(), contains('new error'));
    expect(log.lengthSync(), lessThan(1000));
  });

  test('recording never throws, even when the folder is gone', () async {
    ErrorLog.start(dataDir);
    await Directory(p.join(dataDir.path, 'logs')).delete(recursive: true);
    expect(() => ErrorLog.record('x', null), returnsNormally);
  });
}
