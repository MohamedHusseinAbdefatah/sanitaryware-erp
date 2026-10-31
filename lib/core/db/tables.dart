import 'package:drift/drift.dart';

// All money columns are INTEGER PIASTRES (100 piastres = 1 EGP).
// All quantity columns are INTEGER THOUSANDTHS of a unit (1000 = 1 piece,
// 1500 = 1.5 meters); see lib/core/quantity.dart. Unit prices and costs are
// per whole unit.
// Financial records are never hard-deleted: they carry a `status`.

mixin Timestamps on Table {
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

class Users extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get username => text().unique()();
  TextColumn get passwordHash => text()();
  TextColumn get salt => text()();
  TextColumn get fullName => text()();
  // 'admin' or 'cashier'
  TextColumn get role => text().withDefault(const Constant('cashier'))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
}

@DataClassName('AppSetting')
class AppSettings extends Table {
  TextColumn get keyName => text()();
  TextColumn get val => text()();

  @override
  Set<Column> get primaryKey => {keyName};
}

class Categories extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get nameAr => text()();
  IntColumn get parentId => integer().nullable().references(Categories, #id)();
}

class Brands extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
}

class Units extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get nameAr => text()();
  // True for units sold in fractions (meter); false for piece, box, set.
  BoolColumn get allowDecimal => boolean().withDefault(const Constant(false))();
}

@TableIndex(name: 'idx_products_name_ar', columns: {#nameAr})
class Products extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get code => text().unique()();
  TextColumn get nameAr => text()();
  IntColumn get categoryId => integer().nullable().references(Categories, #id)();
  IntColumn get brandId => integer().nullable().references(Brands, #id)();
  IntColumn get unitId => integer().nullable().references(Units, #id)();
  // Weighted average cost, updated on each purchase.
  IntColumn get costPrice => integer().withDefault(const Constant(0))();
  IntColumn get priceRetail => integer().withDefault(const Constant(0))();
  IntColumn get priceWholesale => integer().withDefault(const Constant(0))();
  IntColumn get priceContractor => integer().withDefault(const Constant(0))();
  // Thousandths, like every quantity.
  IntColumn get minStock => integer().withDefault(const Constant(0))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  TextColumn get notes => text().nullable()();
}

// Source of truth for stock: current stock = SUM(qty) per product.
// Types: opening, purchase, sale, sale_return, purchase_return, adjustment
@TableIndex(name: 'idx_stock_movements_product', columns: {#productId})
class StockMovements extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get productId => integer().references(Products, #id)();
  TextColumn get type => text()();
  // Thousandths. Positive adds stock, negative removes it.
  IntColumn get qty => integer()();
  IntColumn get unitCost => integer().withDefault(const Constant(0))();
  TextColumn get refType => text().nullable()();
  IntColumn get refId => integer().nullable()();
  DateTimeColumn get date => dateTime().withDefault(currentDateAndTime)();
  TextColumn get note => text().nullable()();
  IntColumn get createdBy => integer().nullable().references(Users, #id)();
}

class Customers extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get phone => text().nullable()();
  TextColumn get address => text().nullable()();
  IntColumn get openingBalance => integer().withDefault(const Constant(0))();
  IntColumn get creditLimit => integer().withDefault(const Constant(0))();
  // 'retail', 'wholesale' or 'contractor'
  TextColumn get priceLevel => text().withDefault(const Constant('retail'))();
  TextColumn get notes => text().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
}

class Suppliers extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get phone => text().nullable()();
  TextColumn get address => text().nullable()();
  IntColumn get openingBalance => integer().withDefault(const Constant(0))();
  TextColumn get notes => text().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
}

@TableIndex(name: 'idx_sales_invoices_customer_date', columns: {#customerId, #date})
class SalesInvoices extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get number => text().unique()();
  DateTimeColumn get date => dateTime()();
  // Null means a cash sale to an unnamed customer.
  IntColumn get customerId => integer().nullable().references(Customers, #id)();
  IntColumn get subtotal => integer()();
  IntColumn get discount => integer().withDefault(const Constant(0))();
  IntColumn get total => integer()();
  IntColumn get paidAmount => integer().withDefault(const Constant(0))();
  // 'active' or 'cancelled'
  TextColumn get status => text().withDefault(const Constant('active'))();
  TextColumn get notes => text().nullable()();
  IntColumn get createdBy => integer().nullable().references(Users, #id)();
}

class SalesInvoiceItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get invoiceId => integer().references(SalesInvoices, #id)();
  IntColumn get productId => integer().references(Products, #id)();
  IntColumn get qty => integer()();
  // Copied from the product at sale time so later changes never alter history.
  IntColumn get unitPrice => integer()();
  IntColumn get unitCost => integer().withDefault(const Constant(0))();
  IntColumn get discount => integer().withDefault(const Constant(0))();
  IntColumn get lineTotal => integer()();
}

@TableIndex(name: 'idx_purchase_invoices_supplier_date', columns: {#supplierId, #date})
class PurchaseInvoices extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get number => text().unique()();
  TextColumn get supplierInvoiceNo => text().nullable()();
  DateTimeColumn get date => dateTime()();
  IntColumn get supplierId => integer().references(Suppliers, #id)();
  IntColumn get subtotal => integer()();
  IntColumn get discount => integer().withDefault(const Constant(0))();
  IntColumn get total => integer()();
  IntColumn get paidAmount => integer().withDefault(const Constant(0))();
  TextColumn get status => text().withDefault(const Constant('active'))();
  TextColumn get notes => text().nullable()();
  IntColumn get createdBy => integer().nullable().references(Users, #id)();
}

class PurchaseInvoiceItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get invoiceId => integer().references(PurchaseInvoices, #id)();
  IntColumn get productId => integer().references(Products, #id)();
  IntColumn get qty => integer()();
  IntColumn get unitCost => integer()();
  IntColumn get lineTotal => integer()();
}

@DataClassName('ReturnDoc')
class Returns extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get number => text().unique()();
  // 'sale' or 'purchase'
  TextColumn get kind => text()();
  DateTimeColumn get date => dateTime()();
  // customer id for a sale return, supplier id for a purchase return
  IntColumn get partyId => integer().nullable()();
  IntColumn get originalInvoiceId => integer().nullable()();
  IntColumn get total => integer()();
  // Cash actually paid back; the rest reduces the party's balance.
  IntColumn get refundAmount => integer().withDefault(const Constant(0))();
  TextColumn get status => text().withDefault(const Constant('active'))();
  TextColumn get notes => text().nullable()();
}

class ReturnItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get returnId => integer().references(Returns, #id)();
  IntColumn get productId => integer().references(Products, #id)();
  IntColumn get qty => integer()();
  IntColumn get unitPrice => integer()();
  IntColumn get lineTotal => integer()();
}

@TableIndex(name: 'idx_payments_party', columns: {#partyType, #partyId})
class Payments extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get number => text().unique()();
  DateTimeColumn get date => dateTime()();
  // 'in' = received from a customer, 'out' = paid to a supplier
  TextColumn get direction => text()();
  // 'customer' or 'supplier'
  TextColumn get partyType => text()();
  IntColumn get partyId => integer()();
  IntColumn get amount => integer()();
  // 'cash', 'bank' or 'cheque'
  TextColumn get method => text()();
  TextColumn get invoiceRefType => text().nullable()();
  IntColumn get invoiceRefId => integer().nullable()();
  TextColumn get status => text().withDefault(const Constant('active'))();
  TextColumn get notes => text().nullable()();
  IntColumn get createdBy => integer().nullable().references(Users, #id)();
}

class Cheques extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get paymentId => integer().references(Payments, #id)();
  TextColumn get chequeNo => text()();
  TextColumn get bank => text().nullable()();
  DateTimeColumn get dueDate => dateTime()();
  // 'pending', 'cleared' or 'bounced'
  TextColumn get status => text().withDefault(const Constant('pending'))();
}

class ExpenseCategories extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get nameAr => text()();
}

class Expenses extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get date => dateTime()();
  IntColumn get categoryId => integer().references(ExpenseCategories, #id)();
  IntColumn get amount => integer()();
  TextColumn get method => text().withDefault(const Constant('cash'))();
  TextColumn get description => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('active'))();
  IntColumn get createdBy => integer().nullable().references(Users, #id)();
}

class AuditLogs extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get userId => integer().nullable().references(Users, #id)();
  TextColumn get action => text()();
  TextColumn get entity => text()();
  IntColumn get entityId => integer().nullable()();
  TextColumn get details => text().nullable()();
  DateTimeColumn get at => dateTime().withDefault(currentDateAndTime)();
}
