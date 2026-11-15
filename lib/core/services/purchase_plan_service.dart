import 'package:drift/drift.dart';

import '../db/database.dart';
import '../quantity.dart';
import 'buying_policy_service.dart';
import 'doc_types.dart';
import 'errors.dart';
import 'purchase_order_service.dart';
import 'settings_service.dart';

/// One supplier's offer for a planned product: the list price less that
/// supplier's recorded discount. Null [netCost] when the supplier has no
/// recorded discount for it (nothing is assumed).
class SupplierOffer {
  const SupplierOffer({
    required this.supplierId,
    required this.supplierName,
    required this.leadTimeDays,
    this.listPrice,
    this.netCost,
  });

  final int supplierId;
  final String supplierName;
  final int leadTimeDays;
  final int? listPrice;
  final int? netCost;
}

/// One product of the purchase plan (blueprint 4.1).
class PlanRow {
  PlanRow({
    required this.productId,
    required this.code,
    required this.name,
    required this.unitAllowsDecimal,
    required this.stock,
    required this.reserved,
    required this.onOrder,
    required this.minStock,
    required this.sold30,
    required this.sold60,
    required this.sold90,
    required this.offers,
    required this.lastSupplierId,
    required this.lastCost,
    required this.safetyDays,
  }) {
    // Start with the supplier last bought from, else the cheapest offer.
    final priced = offers.where((o) => o.netCost != null).toList()..sort((a, b) => a.netCost!.compareTo(b.netCost!));
    supplierId = offers.any((o) => o.supplierId == lastSupplierId)
        ? lastSupplierId
        : (priced.isNotEmpty ? priced.first.supplierId : offers.firstOrNull?.supplierId);
    qty = suggested;
  }

  final int productId;
  final String code;
  final String name;
  final bool unitAllowsDecimal;

  /// Thousandths of a unit.
  final int stock, reserved, onOrder, minStock, sold30, sold60, sold90;
  final List<SupplierOffer> offers;
  final int? lastSupplierId;

  /// The cost of the newest stock layer; an estimate when no offer is priced.
  final int lastCost;
  final int safetyDays;

  /// The supplier chosen for this line, and the quantity to order (the
  /// person may change both).
  int? supplierId;
  int qty = 0;
  bool selected = true;

  int get available => stock - reserved;

  /// Average sold per day over the last 90 days (thousandths).
  double get dailyRate => sold90 / 90;

  SupplierOffer? get offer => offers.where((o) => o.supplierId == supplierId).firstOrNull;

  int get leadTimeDays => offer?.leadTimeDays ?? 0;

  /// What the shelf should hold to last until a new order arrives:
  /// sales over the lead time plus the safety days, never below the minimum.
  int get target {
    final cover = (dailyRate * (leadTimeDays + safetyDays)).ceil();
    return cover > minStock ? cover : minStock;
  }

  /// Target plus what customers are promised, less what is on the shelf and
  /// on order, rounded up to whole units. Zero when nothing is needed.
  int get suggested {
    final need = target + reserved - stock - onOrder;
    if (need <= 0) return 0;
    return unitAllowsDecimal ? need : ((need + qtyScale - 1) ~/ qtyScale) * qtyScale;
  }

  /// Unit cost for the estimate: the chosen supplier's net cost, else the
  /// last cost paid.
  int get unitCost => offer?.netCost ?? lastCost;
  bool get costIsEstimate => offer?.netCost == null;
}

/// Purchase planning: what to buy now, from whom, and at what cost, from the
/// stock, reservations, open orders, recent sales, lead times and the
/// minimum levels. Nothing is ordered until the person saves the plan as
/// draft purchase orders, which are approved as usual.
class PurchasePlanService {
  PurchasePlanService(this.db);

  final AppDatabase db;

  static const safetyDaysKey = 'plan_safety_days';

  Future<int> safetyDays() async => int.tryParse(await SettingsService(db).get(safetyDaysKey) ?? '') ?? 0;

  Future<void> setSafetyDays(int days) async {
    if (days < 0 || days > 365) throw ValidationException('أيام الأمان بين 0 و 365');
    await SettingsService(db).set(safetyDaysKey, '$days');
  }

  /// Every active product that sells, is promised, has a minimum level or is
  /// on order. [onlyNeeded] keeps those with something to order.
  Future<List<PlanRow>> build({bool onlyNeeded = true, DateTime? now}) async {
    final today = now ?? DateTime.now();
    int secs(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;
    final d30 = secs(today.subtract(const Duration(days: 30)));
    final d60 = secs(today.subtract(const Duration(days: 60)));
    final d90 = secs(today.subtract(const Duration(days: 90)));
    final rows = await db.customSelect(
      '''
      SELECT p.id, p.code, p.name_ar, p.min_stock, p.brand_id, COALESCE(u.allow_decimal, 0) AS dec,
        COALESCE((SELECT SUM(m.qty) FROM stock_movements m WHERE m.product_id = p.id
                  AND m.location_id IN (SELECT id FROM locations WHERE is_sellable = 1)), 0) AS stock,
        COALESCE((SELECT SUM(r.qty) FROM reservations r WHERE r.product_id = p.id AND r.status = 'active'
                  AND (r.expires_at IS NULL OR r.expires_at > ?)), 0) AS reserved,
        COALESCE((SELECT SUM(MAX(l.qty - l.qty_received, 0)) FROM purchase_order_lines l
                  JOIN purchase_orders o ON o.id = l.order_id
                  WHERE l.product_id = p.id AND o.status IN ('approved', 'partly_received')), 0) AS on_order,
        COALESCE((SELECT SUM(CASE WHEN s.date >= ? THEN i.qty ELSE 0 END) FROM sales_invoice_items i
                  JOIN sales_invoices s ON s.id = i.invoice_id
                  WHERE i.product_id = p.id AND s.status = '${DocStatus.active}' AND i.direct_supplier_id IS NULL), 0) AS s30,
        COALESCE((SELECT SUM(CASE WHEN s.date >= ? THEN i.qty ELSE 0 END) FROM sales_invoice_items i
                  JOIN sales_invoices s ON s.id = i.invoice_id
                  WHERE i.product_id = p.id AND s.status = '${DocStatus.active}' AND i.direct_supplier_id IS NULL), 0) AS s60,
        COALESCE((SELECT SUM(CASE WHEN s.date >= ? THEN i.qty ELSE 0 END) FROM sales_invoice_items i
                  JOIN sales_invoices s ON s.id = i.invoice_id
                  WHERE i.product_id = p.id AND s.status = '${DocStatus.active}' AND i.direct_supplier_id IS NULL), 0) AS s90,
        COALESCE((SELECT l.unit_cost FROM cost_layers l WHERE l.product_id = p.id
                  ORDER BY l.received_at DESC, l.id DESC LIMIT 1), 0) AS last_cost,
        (SELECT pi.supplier_id FROM purchase_invoice_items it JOIN purchase_invoices pi ON pi.id = it.invoice_id
          WHERE it.product_id = p.id AND pi.status = '${DocStatus.active}' ORDER BY pi.date DESC, pi.id DESC LIMIT 1) AS last_supplier
      FROM products p LEFT JOIN units u ON u.id = p.unit_id
      WHERE p.is_active = 1
      ORDER BY p.name_ar
      ''',
      variables: [
        Variable.withInt(secs(today)),
        Variable.withInt(d30),
        Variable.withInt(d60),
        Variable.withInt(d90),
      ],
    ).get();

    final safety = await safetyDays();
    final suppliers = {for (final s in await db.select(db.suppliers).get()) s.id: s};
    // Suppliers with an active discount on each brand: the ones to compare.
    final byBrand = <int, Set<int>>{};
    for (final p in await (db.select(db.buyingPolicies)..where((t) => t.isActive.equals(true))).get()) {
      if (p.brandId == null || suppliers[p.supplierId]?.isActive != true) continue;
      (byBrand[p.brandId!] ??= {}).add(p.supplierId);
    }
    final buying = BuyingPolicyService(db);

    final out = <PlanRow>[];
    for (final r in rows) {
      final minStock = r.read<int>('min_stock');
      final reserved = r.read<int>('reserved');
      final onOrder = r.read<int>('on_order');
      final s90 = r.read<int>('s90');
      final lastSupplier = r.readNullable<int>('last_supplier');
      if (minStock <= 0 && reserved <= 0 && s90 <= 0 && onOrder <= 0) continue;
      final productId = r.read<int>('id');
      final candidates = {...?byBrand[r.readNullable<int>('brand_id')], ?lastSupplier};
      final offers = <SupplierOffer>[];
      for (final sid in candidates) {
        final s = suppliers[sid];
        if (s == null || !s.isActive) continue;
        final quotes = await buying.quotes(productId, supplierId: sid, asOf: today);
        final q = quotes.firstOrNull;
        offers.add(SupplierOffer(
          supplierId: sid,
          supplierName: s.name,
          leadTimeDays: s.leadTimeDays,
          listPrice: q?.listPrice,
          netCost: q?.netCost,
        ));
      }
      offers.sort((a, b) => (a.netCost ?? 1 << 60).compareTo(b.netCost ?? 1 << 60));
      final row = PlanRow(
        productId: productId,
        code: r.read<String>('code'),
        name: r.read<String>('name_ar'),
        unitAllowsDecimal: r.read<int>('dec') == 1,
        stock: r.read<int>('stock'),
        reserved: reserved,
        onOrder: onOrder,
        minStock: minStock,
        sold30: r.read<int>('s30'),
        sold60: r.read<int>('s60'),
        sold90: s90,
        offers: offers,
        lastSupplierId: lastSupplier,
        lastCost: r.read<int>('last_cost'),
        safetyDays: safety,
      );
      if (onlyNeeded && row.suggested <= 0) continue;
      out.add(row);
    }
    return out;
  }

  /// Saves the chosen lines as draft purchase orders, one per supplier. The
  /// drafts are the purchase requisition: nothing is owed and no stock moves
  /// until each is approved. Returns the new order ids.
  Future<List<int>> saveDrafts(List<PlanRow> rows, {required User user}) async {
    final chosen = rows.where((r) => r.selected && r.qty > 0).toList();
    if (chosen.isEmpty) throw ValidationException('اختر صنفاً واحداً على الأقل بكمية أكبر من صفر');
    final missing = chosen.where((r) => r.supplierId == null).map((r) => r.name).toList();
    if (missing.isNotEmpty) throw ValidationException('اختر المورد لكل صنف: ${missing.take(5).join('، ')}');
    final bySupplier = <int, List<PlanRow>>{};
    for (final r in chosen) {
      (bySupplier[r.supplierId!] ??= []).add(r);
    }
    final orders = PurchaseOrderService(db);
    final ids = <int>[];
    await db.transaction(() async {
      for (final e in bySupplier.entries) {
        ids.add(await orders.createDraft(
          supplierId: e.key,
          lines: [for (final r in e.value) PoLineInput(productId: r.productId, qty: r.qty)],
          notes: 'من تخطيط الشراء',
          user: user,
        ));
      }
    });
    return ids;
  }
}
