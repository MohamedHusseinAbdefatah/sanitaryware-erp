// Developer tool: set a new password for a user when nobody can log in
// (for example the only admin forgot theirs). Run it through
// reset_password.bat, which asks for the values; the program must be closed.
//
// Environment:
//   ERP_DB        path of erp.sqlite (default: this Windows user's data folder)
//   ERP_USER      username; leave empty to only list the users
//   ERP_PASSWORD  the new password (at least 4 characters)
//
// The database is backed up first (reason "before-reset"), the user is
// re-activated, and the change is written to the audit log. Nothing else
// is touched.
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sanitaryware_erp/core/auth/auth_service.dart';
import 'package:sanitaryware_erp/core/auth/password_hasher.dart';
import 'package:sanitaryware_erp/core/backup/backup_service.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/services/audit_service.dart';

String _defaultDb() =>
    p.join(Platform.environment['APPDATA'] ?? '', 'com.erp', 'sanitaryware_erp', 'SanitarywareERP', 'erp.sqlite');

void main() {
  test('reset password', () async {
    final env = Platform.environment;
    final dbFile = File((env['ERP_DB'] ?? '').trim().isEmpty ? _defaultDb() : env['ERP_DB']!.trim());
    final username = (env['ERP_USER'] ?? '').trim().toLowerCase();
    final password = env['ERP_PASSWORD'] ?? '';

    if (!dbFile.existsSync()) fail('No database at ${dbFile.path}');

    final db = AppDatabase(NativeDatabase(dbFile));
    try {
      final users = await db.select(db.users).get();
      // ignore: avoid_print
      print('USERS: ${users.map((u) => '${u.username} (${u.isAdmin ? 'admin' : 'cashier'}'
          '${u.isActive ? '' : ', stopped'})').join(', ')}');
      if (username.isEmpty) return;

      final user = users.where((u) => u.username == username).firstOrNull;
      if (user == null) fail('No user "$username"');
      if (password.length < AuthService.minPasswordLength) {
        fail('The password must be at least ${AuthService.minPasswordLength} characters');
      }

      final backup = await BackupService(dir: Directory(p.join(dbFile.parent.path, 'backups')))
          .backup(db, reason: BackupReason.beforeReset);
      // ignore: avoid_print
      print('BACKUP: ${backup.path}');

      const hasher = PasswordHasher();
      final salt = hasher.newSalt();
      final hash = await hasher.hash(password, salt);
      await db.transaction(() async {
        await (db.update(db.users)..where((t) => t.id.equals(user.id))).write(UsersCompanion(
              passwordHash: Value(hash),
              salt: Value(salt),
              isActive: const Value(true),
              updatedAt: Value(DateTime.now()),
            ));
        await AuditService(db).log(
          action: AuditAction.update,
          entity: 'user',
          entityId: user.id,
          details: 'إعادة تعيين كلمة المرور بأداة المطور',
        );
      });

      // Prove it: the new password logs in.
      final ok = await AuthService(db).login(username, password);
      // ignore: avoid_print
      print('DONE: ${ok.username} can log in with the new password');
    } finally {
      await db.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
