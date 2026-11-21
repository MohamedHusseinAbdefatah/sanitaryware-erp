import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/auth/auth_service.dart';
import 'package:sanitaryware_erp/core/auth/password_hasher.dart';
import 'package:sanitaryware_erp/core/auth/remember_service.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';

import '../support/fixture.dart';

/// "Remember me": a token on this computer, only its hash in the database.
void main() {
  late Shop shop;
  late RememberService remember;

  setUp(() async {
    shop = await Shop.open();
    remember = RememberService(shop.db);
  });
  tearDown(() => shop.close());

  test('a remembered sign-in works once and hands over a new token; no password is stored', () async {
    final token = await remember.issue(shop.cashier, device: 'PC-1');
    final rows = await shop.db.select(shop.db.rememberedLogins).get();
    expect(rows.single.tokenHash, RememberService.hashOf(token));
    expect(rows.single.tokenHash, isNot(contains(token)));

    final first = await remember.resume(token);
    expect(first!.$1.id, shop.cashier.id);
    expect(first.$2, isNot(token));
    expect(await remember.resume(token), isNull, reason: 'a used token never works again');
    expect((await remember.resume(first.$2))!.$1.id, shop.cashier.id);
  });

  test('logging out, an expired token, a new password or a stopped user all end it', () async {
    final a = await remember.issue(shop.cashier);
    await remember.revoke(a);
    expect(await remember.resume(a), isNull);

    final old = RememberService(shop.db, lifetime: const Duration(seconds: -1));
    expect(await remember.resume(await old.issue(shop.cashier)), isNull);

    final auth = AuthService(shop.db, hasher: const PasswordHasher(iterations: 1));
    final b = await remember.issue(shop.cashier);
    await auth.resetPassword(shop.cashier.id, '9999', by: shop.admin);
    expect(await remember.resume(b), isNull);

    final c = await remember.issue(shop.cashier);
    await auth.updateUser(shop.cashier.id, fullName: shop.cashier.fullName, role: shop.cashier.role, isActive: false, by: shop.admin);
    expect(await remember.resume(c), isNull);
  });

  test('the owner can end every sign-in of a user, or turn the feature off', () async {
    final a = await remember.issue(shop.cashier);
    final b = await remember.issue(shop.cashier);
    await expectLater(remember.revokeAllFor(shop.admin.id, by: shop.cashier), throwsA(isA<ValidationException>()));
    expect(await remember.revokeAllFor(shop.cashier.id, by: shop.admin), 2);
    expect(await remember.resume(a), isNull);
    expect(await remember.resume(b), isNull);

    final c = await remember.issue(shop.admin);
    await remember.setEnabled(false, by: shop.admin);
    expect(await remember.enabled(), isFalse);
    expect(await remember.resume(c), isNull);
    await expectLater(remember.issue(shop.admin), throwsA(isA<ValidationException>()));
    await expectLater(remember.setEnabled(true, by: shop.cashier), throwsA(isA<ValidationException>()));
  });
}
