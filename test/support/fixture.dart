import 'package:drift/native.dart';
import 'package:sanitaryware_erp/core/auth/auth_service.dart';
import 'package:sanitaryware_erp/core/auth/password_hasher.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/services/balance_service.dart';
import 'package:sanitaryware_erp/core/services/party_service.dart';
import 'package:sanitaryware_erp/core/services/product_service.dart';
import 'package:sanitaryware_erp/core/services/settings_service.dart';
import 'package:sanitaryware_erp/core/services/stock_service.dart';

/// An in-memory shop: admin and cashier, a mixer sold by the piece and a
/// pipe sold by the meter (both with no stock and no cost yet), one
/// customer and one supplier.
class Shop {
  Shop._(this.db);

  final AppDatabase db;
  late final User admin;
  late final User cashier;
  late final Product mixer;
  late final Product pipe;
  late final int customerId;
  late final int supplierId;

  static Future<Shop> open({int customerCreditLimit = 0}) async {
    final shop = Shop._(AppDatabase(NativeDatabase.memory()));
    final db = shop.db;
    final auth = AuthService(db, hasher: const PasswordHasher(iterations: 1));
    shop.admin = await auth.firstRunSetup(
      company: const CompanyInfo(name: 'معرض'),
      fullName: 'المدير',
      username: 'admin',
      password: '1234',
    );
    shop.cashier = await auth.createUser(
      fullName: 'الكاشير',
      username: 'cashier',
      password: '1234',
      role: UserRole.cashier,
    );
    final units = await db.select(db.units).get();
    final products = ProductService(db);
    shop.mixer = await products.create(ProductInput(
      code: 'M1',
      nameAr: 'خلاط',
      unitId: units.firstWhere((u) => !u.allowDecimal).id,
      priceRetail: 50000,
    ));
    shop.pipe = await products.create(ProductInput(
      code: 'P1',
      nameAr: 'ماسورة',
      unitId: units.firstWhere((u) => u.allowDecimal).id,
      priceRetail: 3500,
    ));
    final parties = PartyService(db);
    shop.customerId = await parties.saveCustomer(
      CustomerInput(name: 'عميل', creditLimit: customerCreditLimit),
    );
    shop.supplierId = await parties.saveSupplier(const SupplierInput(name: 'مورد'));
    return shop;
  }

  Future<void> close() => db.close();

  Future<int> stockOf(Product p) => StockService(db).currentStock(p.id);

  Future<int> costOf(Product p) async =>
      (await (db.select(db.products)..where((t) => t.id.equals(p.id))).getSingle()).costPrice;

  Future<int> customerBalance() => BalanceService(db).customerBalance(customerId);

  Future<int> supplierBalance() => BalanceService(db).supplierBalance(supplierId);

  int pieces(int n) => qtyOf(n);
}
