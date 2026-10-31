import 'package:drift/drift.dart';

import '../db/database.dart';

abstract final class AuditAction {
  static const setup = 'setup';
  static const login = 'login';
  static const loginFailed = 'login_failed';
  static const create = 'create';
  static const update = 'update';
  static const cancel = 'cancel';
  static const backup = 'backup';
  static const restore = 'restore';
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
  }) {
    return db.into(db.auditLogs).insert(
          AuditLogsCompanion.insert(
            action: action,
            entity: entity,
            userId: Value(userId),
            entityId: Value(entityId),
            details: Value(details),
          ),
        );
  }
}
