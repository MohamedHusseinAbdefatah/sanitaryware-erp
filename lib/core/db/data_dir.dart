import 'dart:io';

import 'package:path/path.dart' as p;

/// Where the data lives: %APPDATA%\SanitarywareERP. Fixed on purpose.
///
/// Earlier builds let Windows name the folder after the company and product
/// names inside the program, so changing those names (as was done for the
/// installer) silently started an empty database somewhere else. Those
/// folders are listed in [legacyDataDirs] and copied over once.
const dataFolderName = 'SanitarywareERP';

List<String> legacyDataDirs(String appData) => [
      p.join(appData, 'Mohamed Hussien', 'Sanitaryware ERP', dataFolderName),
      p.join(appData, 'com.erp', 'sanitaryware_erp', dataFolderName),
    ];

/// Returns the data folder under [appData], creating it. The first time,
/// if an older build's folder has a database, the most recently used one
/// is copied in (database, backups, logo). The old folder is left as it is.
Future<Directory> prepareDataDir(String appData) async {
  final dir = Directory(p.join(appData, dataFolderName));
  if (File(p.join(dir.path, 'erp.sqlite')).existsSync()) return dir;

  Directory? newest;
  DateTime? newestTime;
  for (final path in legacyDataDirs(appData)) {
    final legacy = Directory(path);
    if (!File(p.join(path, 'erp.sqlite')).existsSync()) continue;
    final used = _lastUsed(legacy);
    if (newestTime == null || used.isAfter(newestTime)) {
      newest = legacy;
      newestTime = used;
    }
  }
  await dir.create(recursive: true);
  if (newest != null) await _copyTree(newest, dir);
  return dir;
}

/// The newest modification time of anything in [dir] (the database file's
/// own date can lag while the program has it open; backups are written at
/// every close).
DateTime _lastUsed(Directory dir) {
  var latest = DateTime.fromMillisecondsSinceEpoch(0);
  for (final e in dir.listSync(recursive: true)) {
    final t = e.statSync().modified;
    if (t.isAfter(latest)) latest = t;
  }
  return latest;
}

Future<void> _copyTree(Directory from, Directory to) async {
  await for (final e in from.list(recursive: true)) {
    final target = p.join(to.path, p.relative(e.path, from: from.path));
    if (e is Directory) {
      await Directory(target).create(recursive: true);
    } else if (e is File) {
      await Directory(p.dirname(target)).create(recursive: true);
      await e.copy(target);
    }
  }
}
