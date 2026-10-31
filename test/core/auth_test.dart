import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/auth/auth_service.dart';
import 'package:sanitaryware_erp/core/auth/password_hasher.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/services/settings_service.dart';

void main() {
  late AppDatabase db;
  late AuthService auth;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    // Few iterations keep the tests fast; the app uses the default.
    auth = AuthService(db, hasher: const PasswordHasher(iterations: 10));
  });

  tearDown(() => db.close());

  Future<User> setupAdmin() => auth.firstRunSetup(
        company: const CompanyInfo(name: 'معرض النيل', phone: '0100'),
        fullName: 'محمد',
        username: 'Admin',
        password: 'secret1',
      );

  group('password hasher', () {
    const hasher = PasswordHasher(iterations: 10);

    test('verifies the right password only', () async {
      final salt = hasher.newSalt();
      final hash = await hasher.hash('pass', salt);
      expect(await hasher.verify('pass', salt, hash), isTrue);
      expect(await hasher.verify('Pass', salt, hash), isFalse);
      expect(await hasher.verify('pass', hasher.newSalt(), hash), isFalse);
    });

    test('never stores the plain password', () async {
      final hash = await hasher.hash('pass', hasher.newSalt());
      expect(hash, isNot(contains('pass')));
      expect(hash, startsWith('pbkdf2-sha256\$10\$'));
    });

    test('matches the RFC 7914 PBKDF2-HMAC-SHA256 test vector', () async {
      const one = PasswordHasher(iterations: 1);
      expect(
        await one.hash('passwd', 'salt'),
        endsWith('55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc'),
      );
    });
  });

  group('first run', () {
    test('creates the admin and saves company data', () async {
      expect(await auth.hasAnyUser(), isFalse);
      final admin = await setupAdmin();
      expect(admin.isAdmin, isTrue);
      expect(admin.username, 'admin');
      expect(await auth.hasAnyUser(), isTrue);
      expect((await SettingsService(db).company()).name, 'معرض النيل');
    });

    test('cannot run twice', () async {
      await setupAdmin();
      await expectLater(setupAdmin(), throwsA(isA<AuthException>()));
    });

    test('a bad password saves nothing', () async {
      await expectLater(
        auth.firstRunSetup(
          company: const CompanyInfo(name: 'X'),
          fullName: 'محمد',
          username: 'admin',
          password: '12',
        ),
        throwsA(isA<AuthException>()),
      );
      expect(await auth.hasAnyUser(), isFalse);
      expect((await SettingsService(db).company()).name, '');
    });
  });

  group('login', () {
    test('accepts the right password, ignoring username case', () async {
      await setupAdmin();
      final user = await auth.login(' ADMIN ', 'secret1');
      expect(user.fullName, 'محمد');
    });

    test('rejects a wrong password or unknown user', () async {
      await setupAdmin();
      await expectLater(auth.login('admin', 'wrong'), throwsA(isA<AuthException>()));
      await expectLater(auth.login('nobody', 'secret1'), throwsA(isA<AuthException>()));
    });

    test('rejects an inactive user', () async {
      await setupAdmin();
      final cashier = await auth.createUser(
        fullName: 'أحمد',
        username: 'cashier',
        password: '1234',
        role: UserRole.cashier,
      );
      await (db.update(db.users)..where((t) => t.id.equals(cashier.id)))
          .write(const UsersCompanion(isActive: Value(false)));
      await expectLater(auth.login('cashier', '1234'), throwsA(isA<AuthException>()));
    });

    test('writes success and failure to the audit log', () async {
      await setupAdmin();
      await auth.login('admin', 'secret1');
      await expectLater(auth.login('admin', 'bad'), throwsA(isA<AuthException>()));
      final actions = (await db.select(db.auditLogs).get()).map((r) => r.action);
      expect(actions, ['setup', 'login', 'login_failed']);
    });

    test('duplicate usernames are rejected', () async {
      await setupAdmin();
      await expectLater(
        auth.createUser(
          fullName: 'x',
          username: 'ADMIN',
          password: '1234',
          role: UserRole.cashier,
        ),
        throwsA(isA<AuthException>()),
      );
    });
  });
}
