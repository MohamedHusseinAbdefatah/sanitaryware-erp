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
@TableIndex(name: 'idx_products_match_key', columns: {#matchKey})
class Products extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  // Blueprint 3.1: the internal Product ID. It never changes once given.
  TextColumn get code => text().unique()();
  // The maker's own code, kept as text so leading zeros, letters and hyphens
  // survive. Empty when the item has no maker's code.
  TextColumn get manufacturerCode => text().withDefault(const Constant(''))();
  // manufacturerCode normalized for search and for stopping duplicates.
  TextColumn get matchKey => text().withDefault(const Constant(''))();
  TextColumn get nameAr => text()();
  TextColumn get description => text().nullable()();
  IntColumn get categoryId => integer().nullable().references(Categories, #id)();
  IntColumn get subcategoryId => integer().nullable().references(Categories, #id)();
  IntColumn get brandId => integer().nullable().references(Brands, #id)();
  TextColumn get series => text().nullable()();
  TextColumn get dimensions => text().nullable()();
  // Color or variant.
  TextColumn get variant => text().nullable()();
  TextColumn get finish => text().nullable()();
  IntColumn get unitId => integer().nullable().references(Units, #id)();
  TextColumn get barcode => text().nullable()();
  TextColumn get technicalSpecs => text().nullable()();
  // Filled only when verified: 'inclusive' or 'exclusive', and the rate.
  TextColumn get vatBasis => text().nullable()();
  IntColumn get vatRateBp => integer().nullable()();
  // No price, cost or balance here (blueprint 3.1): prices live in price list
  // versions, cost in FIFO layers, quantities in stock movements.
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
  // The list version this stock came in under, and its list price then: how
  // old-price and new-price stock are told apart. Null = not known; never guessed.
  IntColumn get priceListId => integer().nullable()();
  IntColumn get listPrice => integer().nullable()();
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

// One dated version of an official price list (blueprint 3.3). The id is the
// Price List ID. A later price is a new version; old rows are never overwritten.
class PriceLists extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  // Required by the service; null only on lists brought over from before
  // schema 11, which stay pending until someone reviews them.
  IntColumn get brandId => integer().nullable().references(Brands, #id)();
  // One brand may have several lists: ceramic, bathtubs, premium, economic...
  TextColumn get listType => text()();
  // 1, 2, 3... within one brand and list type.
  IntColumn get versionNo => integer().withDefault(const Constant(1))();
  TextColumn get currency => text().withDefault(const Constant('EGP'))();
  DateTimeColumn get effectiveFrom => dateTime()();
  // Null while open. The next full version closes it.
  DateTimeColumn get effectiveTo => dateTime().nullable()();
  DateTimeColumn get importDate => dateTime()();
  TextColumn get sourceFile => text().nullable()();
  TextColumn get sourcePages => text().nullable()();
  // Rows on the source, including those stopped for review.
  IntColumn get rowCount => integer().withDefault(const Constant(0))();
  // 'inclusive', 'exclusive' or 'unverified'. Set only after checking the source.
  TextColumn get vatStatus => text().withDefault(const Constant('unverified'))();
  IntColumn get vatRateBp => integer().nullable()();
  // 'active', 'pending_review' (not usable yet) or 'withdrawn'.
  TextColumn get status => text().withDefault(const Constant('active'))();
  // Set only on lists made from the old per-level product prices: such a list
  // prices one pricing type only.
  TextColumn get pricingTypeOnly => text().nullable()();
  TextColumn get note => text().nullable()();
}

// One row of a version. A row that could not be matched safely stays 'review'
// and is never used for pricing until a person resolves it.
@TableIndex(name: 'idx_price_list_items_list', columns: {#priceListId})
@TableIndex(name: 'idx_price_list_items_product', columns: {#productId})
class PriceListItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get priceListId => integer().references(PriceLists, #id)();
  IntColumn get productId => integer().nullable().references(Products, #id)();
  TextColumn get manufacturerCode => text().withDefault(const Constant(''))();
  TextColumn get name => text()();
  TextColumn get variant => text().nullable()();
  // Piastres per unit. Null only on a review row whose price is missing or
  // unreadable: a price is never made up.
  IntColumn get price => integer().nullable()();
  // Pieces in a carton or pack, if sold that way.
  IntColumn get packSize => integer().nullable()();
  // 'ok', 'review' or 'skipped'.
  TextColumn get status => text().withDefault(const Constant('ok'))();
  TextColumn get reviewReason => text().nullable()();
  // The row number on the source file.
  IntColumn get sourceRow => integer().nullable()();
}

// What a supplier gives us (blueprint 3.4): Supplier + Brand + Price List, then
// scope. A product rule beats a category rule, which beats an "all" rule.
// Independent of selling policies: changing one never touches the other.
@TableIndex(name: 'idx_buying_policies_supplier', columns: {#supplierId})
class BuyingPolicies extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get supplierId => integer().references(Suppliers, #id)();
  // Required by the service; null only on rules brought over from before
  // schema 11, which stay inactive until reviewed.
  IntColumn get brandId => integer().nullable().references(Brands, #id)();
  IntColumn get priceListId => integer().nullable().references(PriceLists, #id)();
  // 'all', 'category' or 'product'
  TextColumn get scope => text()();
  IntColumn get categoryId => integer().nullable().references(Categories, #id)();
  IntColumn get productId => integer().nullable().references(Products, #id)();
  // Basis points: 2100 = 21%. The two add up.
  IntColumn get baseDiscountBp => integer().withDefault(const Constant(0))();
  IntColumn get extraDiscountBp => integer().withDefault(const Constant(0))();
  DateTimeColumn get validFrom => dateTime().nullable()();
  DateTimeColumn get validTo => dateTime().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  TextColumn get note => text().nullable()();
}

// A group of customers the shop prices alike (schema 13): retail, wholesale,
// projects, engineers... The owner names them. Each has a usual discount.
class CustomerCategories extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().unique()();
  IntColumn get discountBp => integer().withDefault(const Constant(0))();
  // The old fixed pricing type ('b2c', 'b2b', 'project') for the three
  // categories made from the old price levels; lists limited to one use it.
  TextColumn get legacyType => text().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
}

// A special selling discount (schema 13): customer category + brand (null =
// every brand), then scope. A product rule beats a category rule, which beats
// an "all" rule. It is not tied to a price list version, so it holds for
// every new list. Before schema 13 a rule was tied to one version and one of
// three pricing types; those two columns are kept for the record only.
@TableIndex(name: 'idx_selling_policies_customer_category', columns: {#customerCategoryId})
class SellingPolicies extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get customerCategoryId => integer().references(CustomerCategories, #id)();
  IntColumn get brandId => integer().nullable().references(Brands, #id)();
  IntColumn get priceListId => integer().nullable().references(PriceLists, #id)();
  TextColumn get pricingType => text().nullable()();
  // 'all', 'category' or 'product'
  TextColumn get scope => text()();
  IntColumn get categoryId => integer().nullable().references(Categories, #id)();
  IntColumn get productId => integer().nullable().references(Products, #id)();
  IntColumn get discountBp => integer().withDefault(const Constant(0))();
  // Limits: going past either needs a manager's approval. Null = not set.
  IntColumn get maxDiscountBp => integer().nullable()();
  IntColumn get minMarginBp => integer().nullable()();
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
  // Schema 15: the customer order line it holds stock for. Reservations are
  // made by confirming a sales order and by receiving goods ordered for it.
  IntColumn get salesOrderLineId => integer().nullable()();
}

// Money paid to a supplier ahead (schema 15), locked to the price lists of
// the chosen brands in force that day and their discounts. Goods are taken
// against it later at those prices, whatever lists come after.
class SupplierAdvances extends Table with Timestamps {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get number => text().unique()();
  IntColumn get supplierId => integer().references(Suppliers, #id)();
  DateTimeColumn get date => dateTime()();
  IntColumn get amount => integer()();
  IntColumn get paymentId => integer().references(Payments, #id)();
  // 'active' or 'cancelled'
  TextColumn get status => text().withDefault(const Constant('active'))();
  TextColumn get note => text().nullable()();
  IntColumn get createdBy => integer().nullable().references(Users, #id)();
}

/// One locked list of an advance: a brand and the version in force that day.
class SupplierAdvanceLists extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get advanceId => integer().references(SupplierAdvances, #id)();
  IntColumn get brandId => integer().references(Brands, #id)();
  IntColumn get priceListId => integer().references(PriceLists, #id)();
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
  IntColumn get buyingPolicyId => integer().nullable()();
  // The policy's base discount, and its extra purchase discount.
  IntColumn get discountBp => integer().withDefault(const Constant(0))();
  IntColumn get extraDiscountBp => integer().withDefault(const Constant(0))();
  IntColumn get unitCost => integer().withDefault(const Constant(0))();
  // Schema 15: ordered for this customer order line; received goods are
  // reserved for that customer.
  IntColumn get salesOrderLineId => integer().nullable()();
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
  // Basis points, typed on the order (the negotiation).
  IntColumn get extraDiscountBp => integer().withDefault(const Constant(0))();
  // Copied at confirmation (the price lock); 0 / null until then. The order
  // keeps the version it was approved on, whatever comes later.
  IntColumn get priceListId => integer().nullable()();
  IntColumn get listPrice => integer().withDefault(const Constant(0))();
  TextColumn get pricingType => text().nullable()();
  IntColumn get sellingPolicyId => integer().nullable()();
  IntColumn get policyDiscountBp => integer().withDefault(const Constant(0))();
  IntColumn get customerDiscountBp => integer().withDefault(const Constant(0))();
  TextColumn get vatStatus => text().nullable()();
  IntColumn get vatRateBp => integer().nullable()();
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
  // Before schema 13: 'retail', 'wholesale' or 'contractor'. Now the
  // customer's category says how they are priced; this stays for the record.
  TextColumn get priceLevel => text().withDefault(const Constant('retail'))();
  IntColumn get categoryId => integer().nullable().references(CustomerCategories, #id)();
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
  // Fixed at sale time so later changes never alter history.
  IntColumn get unitPrice => integer()();
  IntColumn get unitCost => integer().withDefault(const Constant(0))();
  IntColumn get discount => integer().withDefault(const Constant(0))();
  IntColumn get lineTotal => integer()();
  // The version this line used and where each discount came from (blueprint
  // 3.3, 3.4). Null priceListId = a manual price, logged in approvals.
  IntColumn get priceListId => integer().nullable()();
  IntColumn get listPrice => integer().nullable()();
  TextColumn get pricingType => text().nullable()();
  IntColumn get sellingPolicyId => integer().nullable()();
  IntColumn get policyDiscountBp => integer().withDefault(const Constant(0))();
  IntColumn get customerDiscountBp => integer().withDefault(const Constant(0))();
  IntColumn get extraDiscountBp => integer().withDefault(const Constant(0))();
  // This line's part of the invoice discount, and what is left after it.
  // The shares of an invoice add up exactly to its discount.
  IntColumn get invoiceDiscountShare => integer().withDefault(const Constant(0))();
  IntColumn get netTotal => integer().withDefault(const Constant(0))();
  // Null vatAmount = the VAT basis or rate is not verified; none is invented.
  TextColumn get vatStatus => text().nullable()();
  IntColumn get vatRateBp => integer().nullable()();
  IntColumn get vatAmount => integer().nullable()();
  // The exact FIFO cost of this line. unitCost is a rounded average of it.
  IntColumn get costTotal => integer().withDefault(const Constant(0))();
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
  // Schema 14. Transport, unloading and the like: part of the goods' cost,
  // split over the lines by value. On the supplier's invoice they are owed to
  // the supplier (in [total]); paid to someone else they are a purchase
  // expense linked to this invoice.
  IntColumn get extraCosts => integer().withDefault(const Constant(0))();
  BoolColumn get extraCostsOnSupplier => boolean().withDefault(const Constant(true))();
  // When what is left to pay is due (a credit purchase).
  DateTimeColumn get dueDate => dateTime().nullable()();
  // Schema 15: taken against a supplier advance at its locked prices; the
  // amount of the advance it used counts as paid on this invoice.
  IntColumn get advanceId => integer().nullable()();
  IntColumn get advanceUsed => integer().withDefault(const Constant(0))();
}

class PurchaseInvoiceItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get invoiceId => integer().references(PurchaseInvoices, #id)();
  IntColumn get productId => integer().references(Products, #id)();
  IntColumn get qty => integer()();
  IntColumn get unitCost => integer()();
  IntColumn get lineTotal => integer()();
  // The version and buying policy this cost came from; null = typed by hand.
  IntColumn get priceListId => integer().nullable()();
  IntColumn get listPrice => integer().nullable()();
  IntColumn get buyingPolicyId => integer().nullable()();
  IntColumn get baseDiscountBp => integer().withDefault(const Constant(0))();
  IntColumn get extraDiscountBp => integer().withDefault(const Constant(0))();
  // This line's part of the invoice discount and what is left after it. The
  // cost of the goods is the net, so the shares add up to the discount exactly.
  IntColumn get invoiceDiscountShare => integer().withDefault(const Constant(0))();
  IntColumn get netTotal => integer().withDefault(const Constant(0))();
  // Schema 14: this line's part of the invoice's extra costs. The FIFO cost
  // of the goods is netTotal + extraCostShare; the supplier is owed netTotal.
  IntColumn get extraCostShare => integer().withDefault(const Constant(0))();
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
  // Schema 14: set when this is a purchase invoice's extra cost paid to
  // someone other than the supplier. It is already in the goods' cost, so
  // net profit does not take it off a second time.
  IntColumn get purchaseInvoiceId => integer().nullable()();
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
