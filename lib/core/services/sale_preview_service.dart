import '../db/database.dart';
import '../pricing_math.dart';
import '../quantity.dart';
import 'fifo_service.dart';
import 'sales_service.dart';
import 'selling_policy_service.dart';
import 'stock_service.dart';

/// One discount on a line and where it came from.
class DiscountStep {
  const DiscountStep(this.label, this.source, {this.bp, this.amount});

  final String label;
  final String source;
  final int? bp;

  /// Piastres, for a discount typed as money or the invoice discount share.
  final int? amount;
}

/// What blueprint 3.4 requires shown for a line before approval.
class SaleLinePreview {
  const SaleLinePreview({
    required this.product,
    required this.qty,
    required this.discounts,
    required this.finalUnitPrice,
    required this.netTotal,
    required this.approvals,
    this.listPrice,
    this.listLabel,
    this.vatStatus,
    this.vatRateBp,
    this.vatAmount,
    this.expectedCost,
    this.netForProfit,
    this.maxDiscountBp,
    this.minMarginBp,
  });

  final Product product;
  final int qty;

  /// Null = no approved list price.
  final int? listPrice;
  final String? listLabel;
  final List<DiscountStep> discounts;

  /// Per whole unit, after every discount including the invoice's share.
  final int finalUnitPrice;
  final int netTotal;
  final String? vatStatus;
  final int? vatRateBp;

  /// Null = VAT basis or rate not verified.
  final int? vatAmount;

  /// FIFO cost of this quantity; expected, since stock can move before saving.
  /// Null = the product has never had a cost.
  final int? expectedCost;

  /// The sale without VAT when verified, else the amount as entered.
  final int? netForProfit;
  final int? maxDiscountBp;
  final int? minMarginBp;

  /// Why this line needs a manager. Empty = none.
  final List<String> approvals;

  int? get grossProfit => expectedCost == null ? null : (netForProfit ?? netTotal) - expectedCost!;
  int? get margin => expectedCost == null ? null : marginBp(netForProfit ?? netTotal, expectedCost!);
  int? get markup => expectedCost == null ? null : markupBp(netForProfit ?? netTotal, expectedCost!);
}

class SalePreview {
  const SalePreview(this.lines, this.invoiceDiscount);

  final List<SaleLinePreview> lines;
  final int invoiceDiscount;

  int get total => lines.fold(0, (s, l) => s + l.netTotal);
  int? get totalVat => lines.any((l) => l.vatAmount == null) ? null : lines.fold<int>(0, (s, l) => s + l.vatAmount!);
  int? get totalCost =>
      lines.any((l) => l.expectedCost == null) ? null : lines.fold<int>(0, (s, l) => s + l.expectedCost!);
  int? get grossProfit =>
      lines.any((l) => l.grossProfit == null) ? null : lines.fold<int>(0, (s, l) => s + l.grossProfit!);
  int? get margin {
    final cost = totalCost;
    if (cost == null) return null;
    return marginBp(lines.fold<int>(0, (s, l) => s + (l.netForProfit ?? l.netTotal)), cost);
  }

  int? get markup {
    final cost = totalCost;
    if (cost == null) return null;
    return markupBp(lines.fold<int>(0, (s, l) => s + (l.netForProfit ?? l.netTotal)), cost);
  }

  bool get needsApproval => lines.any((l) => l.approvals.isNotEmpty);
}

/// Works out the display shown before a sale is approved. It reads only; it
/// uses the same checks and allocation the posting does.
class SalePreviewService {
  SalePreviewService(this.db);

  final AppDatabase db;

  Future<SalePreview> preview(SaleInput input) async {
    final customer = input.customerId == null
        ? null
        : await (db.select(db.customers)..where((t) => t.id.equals(input.customerId!))).getSingleOrNull();
    final date = input.date ?? DateTime.now();
    final policies = SellingPolicyService(db);
    final fifo = FifoService(db);
    final sellable = await StockService(db).sellableLocationIds();
    final shares = allocateProportionally(input.discount, [for (final l in input.lines) l.total]);
    final lines = <SaleLinePreview>[];
    final wanted = <int, int>{};
    for (var n = 0; n < input.lines.length; n++) {
      final line = input.lines[n];
      final product = await (db.select(db.products)..where((t) => t.id.equals(line.productId))).getSingle();
      final net = line.total - shares[n];
      final check = await policies.check(
        product: product,
        qty: line.qty,
        unitPrice: line.unitPrice,
        lineTotal: line.total,
        netTotal: net,
        priceListId: line.priceListId,
        locked: line.locked,
        customer: customer,
        date: date,
      );
      final snap = check.snapshot;
      final vat = vatOf(net, snap.vatStatus, snap.vatRateBp);
      final netForProfit = vat?.netOfVat ?? net;

      // The same product on two lines: the second line's cost starts after the first's.
      final before = wanted[line.productId] ?? 0;
      wanted[line.productId] = before + line.qty;
      int? cost;
      final places = line.locationId == null ? sellable : [line.locationId!];
      final upTo = await fifo.peek(line.productId, before + line.qty, locationIds: places);
      if (upTo != null) {
        if (before == 0) {
          cost = upTo.totalCost;
        } else {
          final earlier = await fifo.peek(line.productId, before, locationIds: places);
          cost = upTo.totalCost - (earlier?.totalCost ?? 0);
        }
      }

      final policyLabel = snap.sellingPolicyId == null ? 'لا توجد سياسة مسجلة' : 'سياسة بيع رقم ${snap.sellingPolicyId}';
      final steps = <DiscountStep>[
        if (snap.policyBp > 0)
          DiscountStep('خصم السياسة (${PricingType.label(snap.pricingType ?? PricingType.b2c)})', policyLabel,
              bp: snap.policyBp),
        if (snap.customerBp > 0) DiscountStep('خصم العميل', 'بطاقة العميل', bp: snap.customerBp),
        if (snap.extraBp > 0) DiscountStep('خصم إضافي (تفاوض)', 'مدخل على السطر', bp: snap.extraBp),
        if (snap.priceListId == null && line.discount > 0)
          DiscountStep('خصم السطر', 'مدخل على السطر', amount: line.discount),
        if (shares[n] > 0) DiscountStep('نصيب السطر من خصم الفاتورة', 'موزع بالتناسب', amount: shares[n]),
      ];

      final margin = cost == null ? null : marginBp(netForProfit, cost);
      final approvals = <String>[
        if (check.manualPrice) 'السعر غير معتمد من قائمة أسعار',
        if (check.overDiscountLimit) 'الخصم أكبر من الحد المسموح',
        if (check.minMarginBp != null && margin != null && margin < check.minMarginBp!)
          'الهامش أقل من الحد الأدنى',
        if (cost != null && netForProfit < cost) 'البيع أقل من تكلفة FIFO — يلزم استثناء مكتوب من المالك',
      ];
      lines.add(SaleLinePreview(
        product: product,
        qty: line.qty,
        listPrice: snap.listPrice,
        listLabel: check.listLabel,
        discounts: steps,
        finalUnitPrice: line.qty == 0 ? 0 : (net * qtyScale / line.qty).round(),
        netTotal: net,
        vatStatus: snap.vatStatus,
        vatRateBp: snap.vatRateBp,
        vatAmount: vat?.vat,
        expectedCost: cost,
        netForProfit: netForProfit,
        maxDiscountBp: check.maxDiscountBp,
        minMarginBp: check.minMarginBp,
        approvals: approvals,
      ));
    }
    return SalePreview(lines, input.discount);
  }
}
