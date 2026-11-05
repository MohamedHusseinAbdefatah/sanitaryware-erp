/// Small pure rules used by pricing, kept apart from the database so they can
/// be read and tested on their own. Money is piastres; percentages are basis
/// points (2100 = 21%).
library;

/// price minus [bp] basis points, rounded to the piastre.
int applyDiscount(int price, int bp) => price - (price * bp + 5000) ~/ 10000;

/// The pricing types of blueprint 3.4.
abstract final class PricingType {
  static const b2c = 'b2c';
  static const b2b = 'b2b';
  static const project = 'project';

  static const all = [b2c, b2b, project];

  /// A customer's price level. The mapping is listed for the owner to confirm
  /// in docs/section3_product_master_price_lists.md.
  static String ofLevel(String? level) => switch (level) {
        'wholesale' => b2b,
        'contractor' => project,
        _ => b2c,
      };

  static String label(String type) => switch (type) {
        b2b => 'B2B (جملة)',
        project => 'Project (مشروعات ومقاولون)',
        _ => 'B2C (قطاعي)',
      };
}

/// The VAT status of a price list (blueprint 3.3).
abstract final class VatStatus {
  static const inclusive = 'inclusive';
  static const exclusive = 'exclusive';
  static const unverified = 'unverified';

  static const all = [inclusive, exclusive, unverified];

  static String label(String? status) => switch (status) {
        inclusive => 'شامل الضريبة',
        exclusive => 'غير شامل الضريبة',
        _ => 'الضريبة غير متحقق منها',
      };
}

/// The VAT inside or on top of an [amount].
class VatSplit {
  const VatSplit(this.netOfVat, this.vat);

  /// The amount without VAT: what profit is measured on.
  final int netOfVat;
  final int vat;
}

/// Null unless both the basis and the rate are verified: no VAT is invented.
VatSplit? vatOf(int amount, String? status, int? rateBp) {
  if (rateBp == null) return null;
  switch (status) {
    case VatStatus.exclusive:
      return VatSplit(amount, (amount * rateBp + 5000) ~/ 10000);
    case VatStatus.inclusive:
      final net = (amount * 10000 + (10000 + rateBp) ~/ 2) ~/ (10000 + rateBp);
      return VatSplit(net, amount - net);
    default:
      return null;
  }
}

/// Splits [total] over lines in proportion to [weights]. The parts add up to
/// [total] exactly: leftover piastres go to the largest remainders, ties to
/// the earlier line.
List<int> allocateProportionally(int total, List<int> weights) {
  final sum = weights.fold<int>(0, (s, w) => s + w);
  if (weights.isEmpty) return const [];
  if (sum == 0) {
    // Nothing to weigh by: spread evenly.
    return allocateProportionally(total, List.filled(weights.length, 1));
  }
  final parts = <int>[];
  final remainders = <(int, int)>[];
  var given = 0;
  for (var i = 0; i < weights.length; i++) {
    final exact = total * weights[i];
    final part = exact ~/ sum;
    parts.add(part);
    given += part;
    remainders.add((exact % sum, i));
  }
  remainders.sort((a, b) => a.$1 != b.$1 ? b.$1.compareTo(a.$1) : a.$2.compareTo(b.$2));
  for (var k = 0; k < total - given; k++) {
    parts[remainders[k % remainders.length].$2]++;
  }
  return parts;
}

/// Gross profit as a share of the sale, in basis points. Null with no sale.
int? marginBp(int netSale, int cost) =>
    netSale == 0 ? null : ((netSale - cost) * 10000 / netSale).round();

/// Gross profit as a share of the cost, in basis points. Null with no cost.
/// Margin and markup are different numbers and are never mixed.
int? markupBp(int netSale, int cost) =>
    cost == 0 ? null : ((netSale - cost) * 10000 / cost).round();

/// A maker's code normalized for search and for stopping duplicates: spaces
/// gone, letters in one case, Arabic and Persian digits as 0-9. Leading zeros,
/// letters and hyphens are kept, so "0123" is not "123" and "A-1" is not "A1".
String matchKeyOf(String code) {
  final b = StringBuffer();
  for (final r in code.runes) {
    if (r == 0x20 || r == 0xA0 || r == 0x09) continue;
    if (r >= 0x0660 && r <= 0x0669) {
      b.writeCharCode(0x30 + r - 0x0660);
    } else if (r >= 0x06F0 && r <= 0x06F9) {
      b.writeCharCode(0x30 + r - 0x06F0);
    } else {
      b.writeCharCode(r);
    }
  }
  return b.toString().toUpperCase();
}

/// The Variant part of a match: blank and case do not matter.
String variantKeyOf(String? variant) => (variant ?? '').trim().toUpperCase();

/// Midnight at the start of [d]'s day.
DateTime dayOf(DateTime d) => DateTime(d.year, d.month, d.day);
