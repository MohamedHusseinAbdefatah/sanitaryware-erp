import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/auth/auth_service.dart';
import 'package:sanitaryware_erp/core/auth/password_hasher.dart';
import 'package:sanitaryware_erp/core/services/audit_service.dart';

import '../support/fixture.dart';

void main() {
  late Shop shop;
  late AuthService auth;

  setUp(() async {
    shop = await Shop.open();
    auth = AuthService(shop.db, hasher: const PasswordHasher(iterations: 1));
  });

  tearDown(() => shop.close());

  test('admin adds a user who can then log in', () async {
    await auth.addUser(fullName: 'سعيد', username: 'saeed', password: '9999', role: UserRole.cashier, by: shop.admin);
    expect((await auth.login('saeed', '9999')).fullName, 'سعيد');
  });

  test('a cashier cannot manage users', () async {
    await expectLater(
      auth.addUser(fullName: 'x', username: 'x', password: '1234', role: UserRole.admin, by: shop.cashier),
      throwsA(isA<AuthException>()),
    );
    await expectLater(auth.resetPassword(shop.admin.id, '0000', by: shop.cashier), throwsA(isA<AuthException>()));
  });

  test('the last active admin cannot be demoted or stopped', () async {
    await expectLater(
      auth.updateUser(shop.admin.id, fullName: 'المدير', role: UserRole.cashier, isActive: true, by: shop.admin),
      throwsA(isA<AuthException>()),
    );
    await expectLater(
      auth.updateUser(shop.admin.id, fullName: 'المدير', role: UserRole.admin, isActive: false, by: shop.admin),
      throwsA(isA<AuthException>()),
    );
    // With a second admin it is allowed.
    final second = await auth.addUser(
        fullName: 'مدير 2', username: 'boss2', password: '1234', role: UserRole.admin, by: shop.admin);
    await auth.updateUser(shop.admin.id, fullName: 'المدير', role: UserRole.cashier, isActive: true, by: second);
  });

  test('a stopped user cannot log in; a reset password works', () async {
    await auth.updateUser(shop.cashier.id, fullName: 'الكاشير', role: UserRole.cashier, isActive: false, by: shop.admin);
    await expectLater(auth.login('cashier', '1234'), throwsA(isA<AuthException>()));
    await auth.updateUser(shop.cashier.id, fullName: 'الكاشير', role: UserRole.cashier, isActive: true, by: shop.admin);
    await auth.resetPassword(shop.cashier.id, 'new-pass', by: shop.admin);
    await expectLater(auth.login('cashier', '1234'), throwsA(isA<AuthException>()));
    expect((await auth.login('cashier', 'new-pass')).id, shop.cashier.id);
    await expectLater(auth.resetPassword(shop.cashier.id, '12', by: shop.admin), throwsA(isA<AuthException>()));
  });

  test('the audit log lists actions newest first with the user name', () async {
    await auth.resetPassword(shop.cashier.id, 'abcd', by: shop.admin);
    final rows = await AuditService(shop.db).watch().first;
    expect(rows.first.log.details, 'تغيير كلمة المرور');
    expect(rows.first.userName, 'المدير');
    expect(rows.last.log.action, AuditAction.setup);
  });
}
