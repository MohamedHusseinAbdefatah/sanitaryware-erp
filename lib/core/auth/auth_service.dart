import 'package:drift/drift.dart';

import '../db/database.dart';
import '../services/audit_service.dart';
import '../services/settings_service.dart';
import 'password_hasher.dart';

abstract final class UserRole {
  static const admin = 'admin';
  static const cashier = 'cashier';
}

extension UserRoleX on User {
  bool get isAdmin => role == UserRole.admin;
}

/// Thrown for a problem the person can fix; [message] is shown as-is.
class AuthException implements Exception {
  AuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AuthService {
  AuthService(this.db, {this.hasher = const PasswordHasher()});

  final AppDatabase db;
  final PasswordHasher hasher;

  static const minPasswordLength = 4;

  Future<bool> hasAnyUser() async {
    final count = db.users.id.count();
    final row = await (db.selectOnly(db.users)..addColumns([count])).getSingle();
    return (row.read(count) ?? 0) > 0;
  }

  /// First run: saves the company data and creates the admin, all or nothing.
  Future<User> firstRunSetup({
    required CompanyInfo company,
    required String fullName,
    required String username,
    required String password,
  }) {
    return db.transaction(() async {
      if (await hasAnyUser()) {
        throw AuthException('تم إعداد البرنامج من قبل');
      }
      await SettingsService(db).saveCompany(company);
      final admin = await createUser(
        fullName: fullName,
        username: username,
        password: password,
        role: UserRole.admin,
      );
      await AuditService(db).log(
        action: AuditAction.setup,
        entity: 'app',
        userId: admin.id,
      );
      return admin;
    });
  }

  Future<User> createUser({
    required String fullName,
    required String username,
    required String password,
    required String role,
  }) async {
    final name = fullName.trim();
    final login = _normalizeUsername(username);
    if (name.isEmpty) throw AuthException('الاسم مطلوب');
    if (login.isEmpty) throw AuthException('اسم المستخدم مطلوب');
    if (password.length < minPasswordLength) {
      throw AuthException('كلمة المرور يجب ألا تقل عن $minPasswordLength أحرف');
    }
    if (role != UserRole.admin && role != UserRole.cashier) {
      throw ArgumentError.value(role, 'role');
    }
    final existing = await (db.select(db.users)
          ..where((t) => t.username.equals(login)))
        .getSingleOrNull();
    if (existing != null) throw AuthException('اسم المستخدم مستخدم من قبل');

    final salt = hasher.newSalt();
    final hash = await hasher.hash(password, salt);
    final id = await db.into(db.users).insert(
          UsersCompanion.insert(
            username: login,
            passwordHash: hash,
            salt: salt,
            fullName: name,
            role: Value(role),
          ),
        );
    return (db.select(db.users)..where((t) => t.id.equals(id))).getSingle();
  }

  /// Returns the user, or throws [AuthException] with one message for any
  /// wrong username or password (so it does not reveal which one was wrong).
  Future<User> login(String username, String password) async {
    final user = await (db.select(db.users)
          ..where((t) => t.username.equals(_normalizeUsername(username))))
        .getSingleOrNull();
    final ok = user != null &&
        user.isActive &&
        await hasher.verify(password, user.salt, user.passwordHash);
    await AuditService(db).log(
      action: ok ? AuditAction.login : AuditAction.loginFailed,
      entity: 'user',
      userId: ok ? user.id : null,
      details: ok ? null : username.trim(),
    );
    if (!ok) throw AuthException('اسم المستخدم أو كلمة المرور غير صحيحة');
    return user;
  }

  String _normalizeUsername(String username) => username.trim().toLowerCase();
}
