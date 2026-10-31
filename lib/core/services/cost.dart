/// Weighted average cost, the plan's formula:
///   (old stock × old cost + new qty × new cost) / (old stock + new qty)
/// Quantities are thousandths, costs piastres per whole unit; the result is
/// rounded to the nearest piastre. With no stock on hand (or negative stock)
/// the new cost simply replaces the old one.
int averageCostAfterAdding({
  required int stock,
  required int cost,
  required int qty,
  required int unitCost,
}) {
  if (stock <= 0) return unitCost;
  return _divRound(stock * cost + qty * unitCost, stock + qty);
}

/// The reverse: the average before [qty] at [unitCost] was added (used when
/// a purchase is cancelled or goods go back to the supplier). If nothing
/// would be left, the current cost is kept.
int averageCostAfterRemoving({
  required int stock,
  required int cost,
  required int qty,
  required int unitCost,
}) {
  final left = stock - qty;
  if (left <= 0) return cost;
  final value = stock * cost - qty * unitCost;
  return value <= 0 ? cost : _divRound(value, left);
}

int _divRound(int numerator, int denominator) => (numerator + denominator ~/ 2) ~/ denominator;
