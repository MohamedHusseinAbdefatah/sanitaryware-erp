import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../db/database.dart';
import '../services/audit_service.dart';
import '../services/errors.dart';
import '../services/settings_service.dart';
import 'auth_service.dart';

/// The setting that allows "remember me" ('0' turns it off for everyone).
const rememberLoginKey = 'remember_login_enabled';

/// A remembered sign-in, with its user's name.
class RememberedRow {
  const RememberedRow(this.login, this.userName);

  final RememberedLogin login;
  final String userName;
}

/// "Remember me" on this computer. A random 256-bit token is kept in a file
/// in the Windows user's own data folder; the database holds only its
/// SHA-256 hash, never a password. A token lasts [lifetime], is replaced by
/// a new one each time it is used, and stops working when revoked, when the
/// user is stopped or their password changes, or when the owner turns the
/// feature off.
class RememberService {
  RememberService(this.db, {this.lifetime = const Duration(days: 30)});

  final AppDatabase db;
  final Duration lifetime;

  static String hashOf(String token) => sha256.convert(utf8.encode(token)).toString();

  static String _newToken() {
    final r = Random.secure();
    return base64Url.encode(List.generate(32, (_) => r.nextInt(256))).replaceAll('=', '');
  }

  Future<bool> enabled() async => await SettingsService(db).get(rememberLoginKey) != '0';

  /// Owner: allows or stops "remember me". Stopping it ends every remembered
  /// sign-in at once.
  Future<void> setEnabled(bool on, {required User by}) {
    return db.transaction(() async {
      if (!by.isAdmin) throw ValidationException('إعدادات الدخول للمالك فقط');
      await SettingsService(db).set(rememberLoginKey, on ? '1' : '0');
      if (!on) await _revokeWhere(null);
      await AuditService(db).log(
        action: on ? AuditAction.activate : AuditAction.deactivate,
        entity: 'remembered_login',
        userId: by.id,
        details: 'تذكر الدخول على الجهاز',
      );
    });
  }

  /// A new remembered sign-in for [user]; returns the token to keep locally.
  Future<String> issue(User user, {String? device}) async {
    if (!await enabled()) throw ValidationException('تذكر الدخول موقوف من المالك');
    final token = _newToken();
    await db.into(db.rememberedLogins).insert(RememberedLoginsCompanion.insert(
          userId: user.id,
          tokenHash: hashOf(token),
          deviceName: Value(device),
          expiresAt: DateTime.now().add(lifetime),
        ));
    return token;
  }

  /// Signs in with a remembered token. Returns the user and the replacement
  /// token, or null when the token is unknown, expired, revoked, or its user
  /// is stopped (the caller then shows the login screen).
  Future<(User, String)?> resume(String token, {String? device}) {
    return db.transaction(() async {
      if (token.isEmpty || !await enabled()) return null;
      final row = await (db.select(db.rememberedLogins)..where((t) => t.tokenHash.equals(hashOf(token))))
          .getSingleOrNull();
      if (row == null || row.revokedAt != null || row.expiresAt.isBefore(DateTime.now())) return null;
      final user = await (db.select(db.users)..where((t) => t.id.equals(row.userId))).getSingleOrNull();
      if (user == null || !user.isActive) return null;
      // One use only: the old token ends, a new one carries on.
      await (db.update(db.rememberedLogins)..where((t) => t.id.equals(row.id)))
          .write(RememberedLoginsCompanion(revokedAt: Value(DateTime.now()), lastUsedAt: Value(DateTime.now())));
      final fresh = await issue(user, device: device ?? row.deviceName);
      await AuditService(db).log(
        action: AuditAction.login,
        entity: 'user',
        userId: user.id,
        details: 'دخول تلقائي (تذكرني)${device == null ? '' : ' — $device'}',
      );
      return (user, fresh);
    });
  }

  /// Ends one remembered sign-in (logging out on this computer).
  Future<void> revoke(String token) async {
    await (db.update(db.rememberedLogins)
          ..where((t) => t.tokenHash.equals(hashOf(token)) & t.revokedAt.isNull()))
        .write(RememberedLoginsCompanion(revokedAt: Value(DateTime.now())));
  }

  /// Ends every remembered sign-in of [userId] ("log out everywhere"). The
  /// owner may do it for anyone, a user for themselves.
  Future<int> revokeAllFor(int userId, {required User by}) {
    return db.transaction(() async {
      if (!by.isAdmin && by.id != userId) throw ValidationException('للمالك أو للمستخدم نفسه فقط');
      final n = await _revokeWhere(userId);
      await AuditService(db).log(
        action: AuditAction.cancel,
        entity: 'remembered_login',
        entityId: userId,
        userId: by.id,
        details: 'إلغاء الدخول المحفوظ: $n',
      );
      return n;
    });
  }

  Future<int> _revokeWhere(int? userId) => (db.update(db.rememberedLogins)
        ..where((t) => t.revokedAt.isNull() & (userId == null ? const Constant(true) : t.userId.equals(userId))))
      .write(RememberedLoginsCompanion(revokedAt: Value(DateTime.now())));

  /// Remembered sign-ins still in force, newest first.
  Stream<List<RememberedRow>> watchActive() {
    final q = db.select(db.rememberedLogins).join([
      innerJoin(db.users, db.users.id.equalsExp(db.rememberedLogins.userId)),
    ])
      ..where(db.rememberedLogins.revokedAt.isNull() &
          db.rememberedLogins.expiresAt.isBiggerThanValue(DateTime.now()))
      ..orderBy([OrderingTerm.desc(db.rememberedLogins.id)]);
    return q.watch().map((rows) => [
          for (final r in rows) RememberedRow(r.readTable(db.rememberedLogins), r.readTable(db.users).fullName),
        ]);
  }
}

/// Where this computer keeps its remembered token: a small file in the
/// Windows user's data folder (never in a backup).
class RememberStore {
  RememberStore(this.file);

  /// Null in tests and when there is no data folder: nothing is kept.
  final File? file;

  Future<String?> read() async {
    final f = file;
    if (f == null || !await f.exists()) return null;
    final t = (await f.readAsString()).trim();
    return t.isEmpty ? null : t;
  }

  Future<void> write(String token) async {
    final f = file;
    if (f == null) return;
    await f.writeAsString(token, flush: true);
  }

  Future<void> clear() async {
    final f = file;
    if (f != null && await f.exists()) await f.delete();
  }
}
