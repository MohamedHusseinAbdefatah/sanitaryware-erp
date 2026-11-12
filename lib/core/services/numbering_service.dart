import 'package:drift/drift.dart';

import '../db/database.dart';

/// Sequential, system-generated document numbers. A number is never reused.
class NumberingService {
  NumberingService(this.db);

  final AppDatabase db;

  static const prefixes = {
    'sales': 'S',
    'purchase': 'P',
    'purchase_order': 'PO',
    'sales_order': 'SO',
    'payment': 'R',
    'return': 'T',
    'supplier_advance': 'SA',
  };

  /// Returns the next number for [kind], e.g. "S-000001".
  /// Safe to call inside a larger transaction (it nests).
  Future<String> next(String kind) {
    final prefix = prefixes[kind];
    if (prefix == null) {
      throw ArgumentError.value(kind, 'kind', 'Unknown document kind');
    }
    return db.transaction(() async {
      final key = 'next_${kind}_no';
      final row = await (db.select(db.appSettings)
            ..where((t) => t.keyName.equals(key)))
          .getSingleOrNull();
      final n = row == null ? 1 : int.parse(row.val);
      await db.into(db.appSettings).insertOnConflictUpdate(
            AppSettingsCompanion(
              keyName: Value(key),
              val: Value('${n + 1}'),
            ),
          );
      return '$prefix-${n.toString().padLeft(6, '0')}';
    });
  }
}
