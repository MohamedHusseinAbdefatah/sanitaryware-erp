import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'version.dart';

/// Writes unexpected errors to `logs\errors.log` in the data folder, so a
/// problem the client reports can be looked at afterwards: what failed,
/// when, in which version, and where in the code.
///
/// The file is kept small: past [maxBytes] it is renamed to `errors.old.log`
/// (replacing the previous one) and a new file is started.
class ErrorLog {
  ErrorLog._();

  static const maxBytes = 1024 * 1024;

  static File? _file;

  static File? get file => _file;

  /// Starts logging into [dataDir] and catches errors Flutter and Dart
  /// would otherwise only print to a console nobody sees.
  static void start(Directory dataDir) {
    final dir = Directory(p.join(dataDir.path, 'logs'))..createSync(recursive: true);
    _file = File(p.join(dir.path, 'errors.log'));

    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      record(details.exception, details.stack, where: 'Flutter: ${details.context ?? ''}');
      previous?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      record(error, stack, where: 'Dart');
      return false; // keep the default handling as well
    };
  }

  /// Appends one entry. Never throws: logging must not cause a second error.
  static void record(Object error, StackTrace? stack, {String where = ''}) {
    final f = _file;
    if (f == null) return;
    try {
      if (f.existsSync() && f.lengthSync() > maxBytes) {
        f.renameSync(p.join(f.parent.path, 'errors.old.log'));
      }
      f.writeAsStringSync(
        '==== ${DateTime.now().toIso8601String()}  v$appVersion  $where\n'
        '$error\n'
        '${stack ?? ''}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Disk full, folder removed...: nothing sensible left to do.
    }
  }

  /// For tests: stop writing anywhere.
  @visibleForTesting
  static void stopForTest() => _file = null;
}
