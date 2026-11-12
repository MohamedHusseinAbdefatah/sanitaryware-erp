// Values stored in text columns, kept in one place so a typo cannot
// silently create a new status or type.

abstract final class DocStatus {
  static const active = 'active';
  static const cancelled = 'cancelled';
}

abstract final class PaymentMethod {
  static const cash = 'cash';
  static const bank = 'bank';
  static const cheque = 'cheque';
}

abstract final class PaymentDirection {
  /// Money received (from a customer, or a refund from a supplier).
  static const inbound = 'in';

  /// Money paid (to a supplier, or a refund to a customer).
  static const outbound = 'out';
}

abstract final class PartyType {
  static const customer = 'customer';
  static const supplier = 'supplier';
}

abstract final class ChequeStatus {
  static const pending = 'pending';
  static const cleared = 'cleared';
  static const bounced = 'bounced';
  static const cancelled = 'cancelled';
}

abstract final class ReturnKind {
  static const sale = 'sale';
  static const purchase = 'purchase';
}

/// Values used to link payments and stock movements back to a document.
abstract final class RefType {
  static const salesInvoice = 'sales_invoice';
  static const purchaseInvoice = 'purchase_invoice';
  static const returnDoc = 'return';

  /// An advance paid or received against an order before any invoice.
  static const purchaseOrder = 'purchase_order';
  static const salesOrder = 'sales_order';

  /// Money paid to a supplier ahead, locked to that day's price lists.
  static const supplierAdvance = 'supplier_advance';
}

/// Party id on a payment for a cash sale with no named customer. It never
/// matches a real customer, so it never affects anyone's balance.
const walkInCustomerId = 0;
