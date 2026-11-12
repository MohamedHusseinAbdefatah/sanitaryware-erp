import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/auth/auth_service.dart';
import 'package:sanitaryware_erp/core/auth/password_hasher.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/expense_service.dart';
import 'package:sanitaryware_erp/core/services/ledger_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_service.dart';
import 'package:sanitaryware_erp/core/services/sales_service.dart';
import 'package:sanitaryware_erp/core/services/stock_service.dart';
import 'package:sanitaryware_erp/features/shell/sections.dart';

import '../support/fixture.dart';

void main() {
  late Shop shop;
  late Map<String, User> users;

  setUp(() async {
    shop = await Shop.open();
    final auth = AuthService(shop.db, hasher: const PasswordHasher(iterations: 1));
    users = {
      for (final r in [UserRole.accountant, UserRole.purchasing, UserRole.warehouse, UserRole.viewer])
        r: await auth.addUser(fullName: r, username: r, password: '123456', role: r, by: shop.admin),
    };
  });
  tearDown(() => shop.close());

  PurchaseInput buy(int n) => PurchaseInput(
        supplierId: shop.supplierId,
        lines: [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(n), unitCost: 30000)],
      );

  test('each role sees its own sections', () {
    bool sees(String role, String path) => appSections.firstWhere((s) => s.path == path).allows(
          role == UserRole.admin ? shop.admin : (role == UserRole.cashier ? shop.cashier : users[role]!),
        );
    expect(sees(UserRole.accountant, '/accounting'), isTrue);
    expect(sees(UserRole.accountant, '/price-lists'), isFalse);
    expect(sees(UserRole.purchasing, '/purchases'), isTrue);
    expect(sees(UserRole.purchasing, '/accounting'), isFalse);
    expect(sees(UserRole.warehouse, '/inventory'), isTrue);
    expect(sees(UserRole.warehouse, '/purchases'), isFalse);
    expect(sees(UserRole.cashier, '/reports'), isFalse);
    expect(sees(UserRole.viewer, '/reports'), isTrue);
    expect(sees(UserRole.viewer, '/settings'), isFalse);
    expect(sees(UserRole.admin, '/settings'), isTrue);
  });

  test('services follow the roles', () async {
    await PurchaseService(shop.db).post(buy(5), user: users[UserRole.purchasing]!);
    await expectLater(PurchaseService(shop.db).post(buy(1), user: users[UserRole.warehouse]!),
        throwsA(isA<ValidationException>()));
    final cat = (await shop.db.select(shop.db.expenseCategories).get()).first;
    await ExpenseService(shop.db).add(ExpenseInput(categoryId: cat.id, amount: 100), user: users[UserRole.accountant]!);
    await expectLater(
        ExpenseService(shop.db).add(ExpenseInput(categoryId: cat.id, amount: 100), user: users[UserRole.purchasing]!),
        throwsA(isA<ValidationException>()));
    await LedgerService(shop.db).closeUntil(DateTime(2020), user: users[UserRole.accountant]!);
    // Reopening a closed period stays with the owner.
    await expectLater(
        LedgerService(shop.db).reopenFrom(DateTime(2020), reason: 'x', user: users[UserRole.accountant]!),
        throwsA(isA<ValidationException>()));
    await expectLater(
      SalesService(shop.db).post(
        SaleInput(
          customerId: shop.customerId,
          lines: [SaleLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitPrice: 50000, priceListId: shop.priceListId)],
        ),
        userId: users[UserRole.viewer]!.id,
      ),
      throwsA(isA<ValidationException>()),
      reason: 'read-only never records',
    );
    expect(users[UserRole.accountant]!.seesCost, isTrue);
    expect(users[UserRole.warehouse]!.seesCost, isFalse);
    expect(shop.cashier.seesCost, isFalse);
  });

  test('a stock count turns differences into adjustments, all at once', () async {
    await PurchaseService(shop.db).post(buy(10), user: shop.admin);
    await PurchaseService(shop.db).post(
      PurchaseInput(
        supplierId: shop.supplierId,
        lines: [PurchaseLineInput(productId: shop.pipe.id, qty: qtyOf(50), unitCost: 2000)],
      ),
      user: shop.admin,
    );
    final stock = StockService(shop.db);
    final n = await stock.postCount(
      locationId: mainLocationId,
      counted: {shop.mixer.id: qtyOf(8), shop.pipe.id: qtyOf(50)},
      note: 'جرد نهاية الشهر',
      userId: users[UserRole.warehouse]!.id,
    );
    expect(n, 1, reason: 'only the mixer differs');
    expect(await shop.stockOf(shop.mixer), qtyOf(8));
    final m = (await shop.db.select(shop.db.stockMovements).get()).last;
    expect(m.note, contains('جرد نهاية الشهر'));
    await expectLater(
      stock.postCount(locationId: mainLocationId, counted: {shop.mixer.id: qtyOf(7)}, note: 'x', userId: shop.cashier.id),
      throwsA(isA<ValidationException>()),
      reason: 'a cashier cannot count stock',
    );
    // The ledger takes the loss at its FIFO cost.
    final rows = await LedgerService(shop.db).balances();
    expect(rows.firstWhere((r) => r.account.systemKey == 'stock_loss').closing, 60000);
  });
}
