import 'package:drift/drift.dart';

/// Bind values for the SQL fragment
///   `(? IS NULL OR date >= ?) AND (? IS NULL OR date < ?)`
/// covering whole days from [from] to [to] inclusive; null means open-ended.
List<Variable> dateRangeVariables(DateTime? from, DateTime? to) {
  final start = from == null ? null : DateTime(from.year, from.month, from.day);
  final end = to == null ? null : DateTime(to.year, to.month, to.day + 1);
  return [
    Variable<DateTime>(start),
    Variable<DateTime>(start),
    Variable<DateTime>(end),
    Variable<DateTime>(end),
  ];
}
