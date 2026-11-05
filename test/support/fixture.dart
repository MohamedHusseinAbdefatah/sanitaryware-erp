import 'package:drift/native.dart';
import 'package:sanitaryware_erp/core/auth/auth_service.dart';
import 'package:sanitaryware_erp/core/auth/password_hasher.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/services/balance_service.dart';
import 'package:sanitaryware_erp/core/services/catalog_service.dart';
import 'package:sanitaryware_erp/core/services/fifo_service.dart';
import 'package:sanitaryware_erp/core/services/party_service.dart';
import 'package:sanitaryware_erp/core/services/price_list_service.dart';
import 'package:sanitaryware_erp/core/services/product_service.dart';
import 'package:sanitaryware_erp/core/services/settings_service.dart';
import 'package:sanitaryware_erp/core/services/stock_service.dart';

/// An in-memory shop: admin and cashier, a mixer sold by the piece and a
/// pipe sold by the meter (both with no stock and no cost yet, both priced in
/// one approved list: 500.00 and 35.00), one customer and one supplier.
class Shop {
  Shop._(this.db);

  final AppDatabase db;
  late final User admin;
  late final User cashier;
  late final Product mixer;
  late final Product pipe;
  late final int customerId;
  late final int supplierId;
  late final int brandId;

  /// The approved price list holding the mixer and the pipe.
  late final int priceListId;

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
    shop.brandId = await CatalogService(db).saveBrand(name: 'ماركة');
    shop.mixer = await products.create(ProductInput(
      code: 'M1',
      manufacturerCode: 'M1',
      nameAr: 'خلاط',
      brandId: shop.brandId,
      unitId: units.firstWhere((u) => !u.allowDecimal).id,
    ));
    shop.pipe = await products.create(ProductInput(
      code: 'P1',
      manufacturerCode: 'P1',
      nameAr: 'ماسورة',
      brandId: shop.brandId,
      unitId: units.firstWhere((u) => u.allowDecimal).id,
    ));
    shop.priceListId = (await PriceListService(db).createVersion(
      PriceListHeader(
        name: 'قائمة',
        brandId: shop.brandId,
        listType: 'عام',
        effectiveFrom: DateTime(2020),
      ),
      rows: [
        PriceRowInput(name: 'خلاط', price: 50000, manufacturerCode: 'M1', productId: shop.mixer.id),
        PriceRowInput(name: 'ماسورة', price: 3500, manufacturerCode: 'P1', productId: shop.pipe.id),
      ],
      user: shop.admin,
    ))
        .id;
    final parties = PartyService(db);
    shop.customerId = await parties.saveCustomer(
      CustomerInput(name: 'عميل', creditLimit: customerCreditLimit),
    );
    shop.supplierId = await parties.saveSupplier(const SupplierInput(name: 'مورد'));
    return shop;
  }

  Future<void> close() => db.close();

  Future<int> stockOf(Product p) => StockService(db).currentStock(p.id);

  /// The next unit's FIFO cost, or the last known cost when no stock is left.
  Future<int> costOf(Product p) async {
    final next = await FifoService(db).peek(p.id, qtyOf(1));
    return next?.averageUnitCost ?? 0;
  }

  Future<int> customerBalance() => BalanceService(db).customerBalance(customerId);

  Future<int> supplierBalance() => BalanceService(db).supplierBalance(supplierId);

  int pieces(int n) => qtyOf(n);
}
