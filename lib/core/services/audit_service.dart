import 'package:drift/drift.dart';

import '../db/database.dart';
import 'query_helpers.dart';

abstract final class AuditAction {
  static const setup = 'setup';
  static const login = 'login';
  static const loginFailed = 'login_failed';
  static const create = 'create';
  static const update = 'update';
  static const cancel = 'cancel';
  static const backup = 'backup';
  static const restore = 'restore';

  /// A correction of a saved record by the owner (old, new and reason kept).
  static const correct = 'correct';
  static const activate = 'activate';
  static const deactivate = 'deactivate';

  /// A record removed for good (only one nothing used: a wrong product, an
  /// unused price list, a party with no dealings).
  static const delete = 'delete';
}

/// "field: before ← after" for every field that changed, for the audit log.
/// Null when nothing changed.
String? auditChanges(Map<String, dynamic> before, Map<String, dynamic> after) {
  final changes = <String>[
    for (final key in after.keys)
      if (key != 'updatedAt' && before[key] != after[key]) '$key: ${before[key] ?? '—'} ← ${after[key] ?? '—'}',
  ];
  return changes.isEmpty ? null : changes.join('، ');
}

/// Writes one row to `audit_logs`. Call it inside the same transaction as
/// the change it describes.
class AuditService {
  AuditService(this.db);

  final AppDatabase db;

  Future<void> log({
    required String action,
    required String entity,
    int? userId,
    int? entityId,
    String? details,
    String? oldValue,
    String? newValue,
    String? reason,
  }) {
    return db.into(db.auditLogs).insert(
          AuditLogsCompanion.insert(
            action: action,
            entity: entity,
            userId: Value(userId),
            entityId: Value(entityId),
            details: Value(details),
            oldValue: Value(oldValue),
            newValue: Value(newValue),
            reason: Value(reason),
          ),
        );
  }
}

class AuditRow {
  const AuditRow(this.log, this.userName);
  final AuditLog log;
  final String? userName;
}

extension AuditQueries on AuditService {
  /// Newest first, between two days (inclusive), at most [limit] rows.
  Stream<List<AuditRow>> watch({DateTime? from, DateTime? to, int limit = 2000}) {
    return db.customSelect(
      '''
      SELECT a.*, u.full_name AS user_name FROM audit_logs a
      LEFT JOIN users u ON u.id = a.user_id
      WHERE (? IS NULL OR a."at" >= ?) AND (? IS NULL OR a."at" < ?)
      ORDER BY a.id DESC LIMIT ?
      ''',
      variables: [...dateRangeVariables(from, to), Variable.withInt(limit)],
      readsFrom: {db.auditLogs, db.users},
    ).watch().map((rows) => [
          for (final r in rows) AuditRow(db.auditLogs.map(r.data), r.readNullable<String>('user_name')),
        ]);
  }
}
