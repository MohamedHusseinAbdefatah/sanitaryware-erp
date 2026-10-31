import 'digits.dart';

// Quantities are always an integer number of thousandths of a unit
// (1000 = 1 piece, 1 box or 1 meter; 1500 = 1.5 meters).
// Never use double for quantities.

/// Thousandths in one whole unit.
const qtyScale = 1000;

/// Builds a quantity from whole units: qtyOf(3) -> 3000.
int qtyOf(int wholeUnits) => wholeUnits * qtyScale;

/// True when [qty] is a whole number of units (no fraction).
bool isWholeQty(int qty) => qty % qtyScale == 0;

/// 2000 -> "2", 1500 -> "1.5", 1250 -> "1.25", 1234000 -> "1,234", -250 -> "-0.25"
String formatQty(int qty) {
  final negative = qty < 0;
  final abs = qty.abs();
  final whole = groupThousands(abs ~/ qtyScale);
  final frac = (abs % qtyScale)
      .toString()
      .padLeft(3, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  final sign = negative ? '-' : '';
  return frac.isEmpty ? '$sign$whole' : '$sign$whole.$frac';
}

/// Parses a typed quantity ("2", "1.5", "١٫٢٥") into thousandths.
/// When [allowDecimal] is false (pieces, boxes, sets) any fraction is
/// rejected. Returns null if the text is not a valid quantity.
int? parseQty(String input, {bool allowDecimal = true}) {
  final qty = parseScaled(input, decimals: 3, maxWholeDigits: 9);
  if (qty == null) return null;
  if (!allowDecimal && !isWholeQty(qty)) return null;
  return qty;
}

/// Money value of [qty] at [unitPrice] piastres per whole unit, rounded
/// once to the nearest piastre (halves away from zero). This is the one
/// shared rounding point for every line total.
int lineAmount(int qty, int unitPrice) {
  final raw = qty * unitPrice;
  final half = qtyScale ~/ 2;
  return raw >= 0 ? (raw + half) ~/ qtyScale : -((-raw + half) ~/ qtyScale);
}
