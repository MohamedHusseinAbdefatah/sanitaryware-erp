import 'package:drift/drift.dart';

import '../db/database.dart';
import '../services/audit_service.dart';
import '../services/catalog_service.dart';
import '../services/errors.dart';
import '../services/expense_service.dart';
import '../services/settings_service.dart';
import 'password_hasher.dart';

/// The roles of the blueprint (9.3). 'cashier' is the sales role (its old
/// name is kept so existing users keep working).
abstract final class UserRole {
  static const admin = 'admin';
  static const cashier = 'cashier';
  static const accountant = 'accountant';
  static const purchasing = 'purchasing';
  static const warehouse = 'warehouse';
  static const viewer = 'viewer';

  static const all = [admin, accountant, purchasing, warehouse, cashier, viewer];

  static String label(String role) => switch (role) {
        admin => 'المالك / المدير',
        accountant => 'محاسب',
        purchasing => 'مشتريات',
        warehouse => 'مخزن',
        cashier => 'مبيعات / كاشير',
        viewer => 'اطلاع فقط',
        _ => role,
      };

  static String describe(String role) => switch (role) {
        admin => 'كل الشاشات والصلاحيات والموافقات',
        accountant => 'المحاسبة والمصروفات والمدفوعات والتقارير، ويرى التكلفة والربح',
        purchasing => 'الموردون والمشتريات وقوائم الأسعار والأصناف، ويرى التكلفة',
        warehouse => 'المخزون والأصناف والتحويل والجرد، بدون تكلفة أو أرباح',
        cashier => 'البيع والتحصيل والعملاء والمرتجعات، بدون تكلفة أو أرباح',
        viewer => 'يرى الشاشات والتقارير ولا يسجل أو يعدل شيئاً',
        _ => '',
      };
}

/// What a role may do. The owner may do everything.
enum Perm {
  /// Sell, take payments, sale returns.
  sell,

  /// Purchase invoices and orders, supplier advances, buying policies,
  /// purchase returns.
  purchase,

  /// Products, photos, price lists.
  catalog,

  /// Stock adjustments, transfers, stock count.
  stock,

  /// Chart of accounts, manual entries, period closing.
  accounts,

  /// Expenses.
  expenses,

  /// Pay suppliers, cancel payments, set cheque states.
  payOut,

  /// Projects.
  projects,

  /// Cost, profit and margins.
  seeCost,

  /// Cancel invoices and returns.
  cancel,
}

const _perms = <String, Set<Perm>>{
  UserRole.accountant: {Perm.accounts, Perm.expenses, Perm.payOut, Perm.projects, Perm.seeCost, Perm.cancel, Perm.sell},
  UserRole.purchasing: {Perm.purchase, Perm.catalog, Perm.projects, Perm.seeCost},
  UserRole.warehouse: {Perm.stock, Perm.catalog},
  UserRole.cashier: {Perm.sell},
  UserRole.viewer: {},
};

extension UserRoleX on User {
  bool get isAdmin => role == UserRole.admin;

  bool can(Perm p) => isAdmin || (_perms[role]?.contains(p) ?? false);

  bool get seesCost => can(Perm.seeCost);

  /// Sees screens but records nothing.
  bool get readOnly => role == UserRole.viewer;
}

/// A login or account problem; [message] is shown as-is.
class AuthException extends ValidationException {
  AuthException(super.message);
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
      await CatalogService(db).seedDefaultUnits();
      await ExpenseService(db).seedDefaultCategories();
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
    if (!UserRole.all.contains(role)) {
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

  Stream<List<User>> watchUsers() =>
      (db.select(db.users)..orderBy([(t) => OrderingTerm(expression: t.fullName)])).watch();

  /// Admin only. Adds a user (cashier or admin).
  Future<User> addUser({
    required String fullName,
    required String username,
    required String password,
    required String role,
    required User by,
  }) {
    return db.transaction(() async {
      if (!by.isAdmin) throw AuthException('إدارة المستخدمين للمدير فقط');
      final user = await createUser(fullName: fullName, username: username, password: password, role: role);
      await AuditService(db).log(
        action: AuditAction.create,
        entity: 'user',
        entityId: user.id,
        userId: by.id,
        details: '${user.username} ($role)',
      );
      return user;
    });
  }

  /// Admin only. The shop must always keep at least one active admin, so
  /// the last one cannot be demoted or stopped.
  Future<void> updateUser(
    int userId, {
    required String fullName,
    required String role,
    required bool isActive,
    required User by,
  }) {
    return db.transaction(() async {
      if (!by.isAdmin) throw AuthException('إدارة المستخدمين للمدير فقط');
      if (fullName.trim().isEmpty) throw AuthException('الاسم مطلوب');
      if (!UserRole.all.contains(role)) throw ArgumentError.value(role, 'role');
      final user = await (db.select(db.users)..where((t) => t.id.equals(userId))).getSingle();
      final losesAdmin = user.isAdmin && user.isActive && (role != UserRole.admin || !isActive);
      if (losesAdmin) {
        final admins = await (db.select(db.users)
              ..where((t) => t.role.equals(UserRole.admin) & t.isActive.equals(true)))
            .get();
        if (admins.length <= 1) throw AuthException('يجب أن يبقى مدير واحد نشط على الأقل');
      }
      await (db.update(db.users)..where((t) => t.id.equals(userId))).write(UsersCompanion(
            fullName: Value(fullName.trim()),
            role: Value(role),
            isActive: Value(isActive),
            updatedAt: Value(DateTime.now()),
          ));
      await AuditService(db).log(
        action: AuditAction.update,
        entity: 'user',
        entityId: userId,
        userId: by.id,
        details: '${user.username}: $role${isActive ? '' : ' (موقوف)'}',
      );
    });
  }

  /// Admin only (also for their own password).
  Future<void> resetPassword(int userId, String newPassword, {required User by}) {
    return db.transaction(() async {
      if (!by.isAdmin) throw AuthException('إدارة المستخدمين للمدير فقط');
      if (newPassword.length < minPasswordLength) {
        throw AuthException('كلمة المرور يجب ألا تقل عن $minPasswordLength أحرف');
      }
      final salt = hasher.newSalt();
      final hash = await hasher.hash(newPassword, salt);
      await (db.update(db.users)..where((t) => t.id.equals(userId))).write(
        UsersCompanion(passwordHash: Value(hash), salt: Value(salt), updatedAt: Value(DateTime.now())),
      );
      await AuditService(db).log(
        action: AuditAction.update,
        entity: 'user',
        entityId: userId,
        userId: by.id,
        details: 'تغيير كلمة المرور',
      );
    });
  }

  String _normalizeUsername(String username) => username.trim().toLowerCase();
}

/// Refuses when [userId] is a read-only user: they see, they never record.
Future<void> refuseReadOnly(AppDatabase db, int? userId) async {
  if (userId == null) return;
  final u = await (db.select(db.users)..where((t) => t.id.equals(userId))).getSingleOrNull();
  if (u != null && u.readOnly) throw ValidationException('هذا المستخدم للاطلاع فقط ولا يسجل عمليات');
}

/// Refuses unless [userId] may adjust and move stock.
Future<void> requireStockRights(AppDatabase db, int? userId) async {
  if (userId == null) return;
  final u = await (db.select(db.users)..where((t) => t.id.equals(userId))).getSingleOrNull();
  if (u != null && !u.can(Perm.stock)) throw ValidationException('تسويات المخزون لصلاحية المخزن أو المدير');
}
