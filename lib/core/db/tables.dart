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

// Where stock is kept (schema 4). Id 1 is the main warehouse and always exists.
class Locations extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  // 'warehouse', 'showroom_display', 'showroom_storage' or 'other'
  TextColumn get kind => text().withDefault(const Constant('warehouse'))();
  // Only sellable locations count as available to sell.
  BoolColumn get isSellable => boolean().withDefault(const Constant(true))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
}

// FIFO cost layers (schema 4): one layer per receipt of a product in a
// location. A sale takes from the oldest layer first.
@TableIndex(name: 'idx_cost_layers_fifo', columns: {#productId, #locationId, #receivedAt})
class CostLayers extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get productId => integer().references(Products, #id)();
  IntColumn get locationId => integer().references(Locations, #id)();
  // Thousandths. qtyRemaining counts down as the layer is used.
  IntColumn get qtyReceived => integer()();
  IntColumn get qtyRemaining => integer()();
  // Piastres per whole unit.
  IntColumn get unitCost => integer()();
  DateTimeColumn get receivedAt => dateTime()();
  IntColumn get supplierId => integer().nullable().references(Suppliers, #id)();
  // 'opening', 'purchase', 'transfer', 'adjustment', 'return'
  TextColumn get sourceType => text().nullable()();
  IntColumn get sourceId => integer().nullable()();
}

// Which layers each use of stock took, so cost of goods sold is exact.
@TableIndex(name: 'idx_layer_consumptions_ref', columns: {#refType, #refId})
class LayerConsumptions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get layerId => integer().references(CostLayers, #id)();
  // Thousandths. Negative when a use is reversed.
  IntColumn get qty => integer()();
  IntColumn get unitCost => integer()();
  // 'sale', 'transfer', 'adjustment', ...
  TextColumn get refType => text()();
  IntColumn get refId => integer().nullable()();
  DateTimeColumn get date => dateTime().withDefault(currentDateAndTime)();
}

// A supplier's price list as it was issued on a date (schema 5). A new
// edition is a new list; old ones are kept.
class PriceLists extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get supplierId => integer().references(Suppliers, #id)();
  IntColumn get brandId => integer().nullable().references(Brands, #id)();
  TextColumn get name => text()();
  // The date the supplier's list takes effect.
  DateTimeColumn get effectiveDate => dateTime()();
  BoolColumn get vatIncluded => boolean().withDefault(const Constant(false))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  TextColumn get note => text().nullable()();
}

// One line of a list. productId stays empty until the line is matched to
// a product in the shop's catalogue.
@TableIndex(name: 'idx_price_list_items_list', columns: {#priceListId})
@TableIndex(name: 'idx_price_list_items_product', columns: {#productId})
class PriceListItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get priceListId => integer().references(PriceLists, #id)();
  IntColumn get productId => integer().nullable().references(Products, #id)();
  TextColumn get supplierCode => text().withDefault(const Constant(''))();
  TextColumn get name => text()();
  // 'white', 'pergamon', ... one line per colour.
  TextColumn get colour => text().nullable()();
  // Piastres per unit.
  IntColumn get price => integer()();
  // Pieces in a carton or pack, if the supplier sells that way.
  IntColumn get packSize => integer().nullable()();
}

// An optional discount a supplier gives us. The most specific rule wins:
// product, then category, then brand, then the whole supplier.
@TableIndex(name: 'idx_discount_rules_supplier', columns: {#supplierId})
class DiscountRules extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get supplierId => integer().references(Suppliers, #id)();
  // 'supplier', 'brand', 'category' or 'product'
  TextColumn get scope => text()();
  IntColumn get brandId => integer().nullable().references(Brands, #id)();
  IntColumn get categoryId => integer().nullable().references(Categories, #id)();
  IntColumn get productId => integer().nullable().references(Products, #id)();
  // Basis points: 2100 = 21%.
  IntColumn get percentBp => integer()();
  DateTimeColumn get validFrom => dateTime().nullable()();
  DateTimeColumn get validTo => dateTime().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  TextColumn get note => text().nullable()();
}

// Stock held back for a customer (schema 7). Reserved stock is still in the
// warehouse; it just is not available to promise to anyone else.
@TableIndex(name: 'idx_reservations_product', columns: {#productId})
class Reservations extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get productId => integer().references(Products, #id)();
  IntColumn get customerId => integer().nullable().references(Customers, #id)();
  IntColumn get locationId => integer().withDefault(const Constant(1))();
  // Thousandths of a unit.
  IntColumn get qty => integer()();
  // 'active', 'released' (given back) or 'fulfilled' (sold)
  TextColumn get status => text().withDefault(const Constant('active'))();
  DateTimeColumn get expiresAt => dateTime().nullable()();
  TextColumn get note => text().nullable()();
}

// Purchase orders (schema 8). The price is frozen when the order is approved;
// each receipt becomes an ordinary purchase invoice.
// Status: draft, approved, partly_received, received, cancelled.
class PurchaseOrders extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get number => text().unique()();
  IntColumn get supplierId => integer().references(Suppliers, #id)();
  TextColumn get status => text().withDefault(const Constant('draft'))();
  DateTimeColumn get orderDate => dateTime()();
  DateTimeColumn get expectedDate => dateTime().nullable()();
  TextColumn get notes => text().nullable()();
  IntColumn get approvedBy => integer().nullable().references(Users, #id)();
  DateTimeColumn get approvedAt => dateTime().nullable()();
  IntColumn get createdBy => integer().nullable().references(Users, #id)();
}

@TableIndex(name: 'idx_po_lines_order', columns: {#orderId})
class PurchaseOrderLines extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get orderId => integer().references(PurchaseOrders, #id)();
  IntColumn get productId => integer().references(Products, #id)();
  // Thousandths of a unit.
  IntColumn get qty => integer()();
  IntColumn get qtyReceived => integer().withDefault(const Constant(0))();
  // Copied at approval (the price lock); 0 / null until then.
  IntColumn get priceListId => integer().nullable()();
  IntColumn get listPrice => integer().nullable()();
  IntColumn get discountBp => integer().withDefault(const Constant(0))();
  IntColumn get unitCost => integer().withDefault(const Constant(0))();
}

class PurchaseOrderReceipts extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get orderId => integer().references(PurchaseOrders, #id)();
  IntColumn get invoiceId => integer().references(PurchaseInvoices, #id)();
  DateTimeColumn get receivedAt => dateTime()();
}

// Sales orders (schema 9). Confirming locks the price; each delivery becomes
// an ordinary sales invoice.
// Status: draft, confirmed, partly_delivered, delivered, cancelled.
class SalesOrders extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get number => text().unique()();
  IntColumn get customerId => integer().references(Customers, #id)();
  // 'showroom', 'shopify', 'whatsapp', 'phone' or 'project'
  TextColumn get channel => text().withDefault(const Constant('showroom'))();
  TextColumn get status => text().withDefault(const Constant('draft'))();
  DateTimeColumn get orderDate => dateTime()();
  TextColumn get notes => text().nullable()();
  // Order id in the outside system (Shopify ...); stops duplicate imports.
  TextColumn get externalId => text().nullable()();
  IntColumn get confirmedBy => integer().nullable().references(Users, #id)();
  DateTimeColumn get confirmedAt => dateTime().nullable()();
  IntColumn get createdBy => integer().nullable().references(Users, #id)();
}

@TableIndex(name: 'idx_so_lines_order', columns: {#orderId})
class SalesOrderLines extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get orderId => integer().references(SalesOrders, #id)();
  IntColumn get productId => integer().references(Products, #id)();
  // Thousandths of a unit.
  IntColumn get qty => integer()();
  IntColumn get qtyDelivered => integer().withDefault(const Constant(0))();
  // Basis points. Extra is typed on the order; base comes from the customer.
  IntColumn get extraDiscountBp => integer().withDefault(const Constant(0))();
  // Copied at confirmation (the price lock); 0 until then.
  IntColumn get listPrice => integer().withDefault(const Constant(0))();
  IntColumn get baseDiscountBp => integer().withDefault(const Constant(0))();
  IntColumn get unitPrice => integer().withDefault(const Constant(0))();
}

class SalesOrderDeliveries extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get orderId => integer().references(SalesOrders, #id)();
  IntColumn get invoiceId => integer().references(SalesInvoices, #id)();
  DateTimeColumn get deliveredAt => dateTime()();
}

// Every exception a manager allowed (schema 10).
// kind: extra_discount, below_cost or price_override.
@TableIndex(name: 'idx_approvals_doc', columns: {#docType, #docId})
class Approvals extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get kind => text()();
  TextColumn get docType => text()();
  IntColumn get docId => integer()();
  IntColumn get requestedBy => integer().nullable().references(Users, #id)();
  IntColumn get approvedBy => integer().nullable().references(Users, #id)();
  TextColumn get reason => text()();
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
  // Where the stock is (schema 4). 1 is the main warehouse.
  IntColumn get locationId => integer().withDefault(const Constant(1))();
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
  /// Customer's usual discount in basis points (1000 = 10%); 0 = none.
  IntColumn get discountBp => integer().withDefault(const Constant(0))();
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
// "What has been paid on this invoice" is asked for every row of the sales
// and purchase lists (added in schema 3).
@TableIndex(name: 'idx_payments_invoice_ref', columns: {#invoiceRefType, #invoiceRefId})
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
