import 'package:drift/drift.dart';

import '../db/database.dart';
import 'errors.dart';

abstract final class ApprovalKind {
  static const extraDiscount = 'extra_discount';
  static const belowCost = 'below_cost';
  static const priceOverride = 'price_override';
  static const lowMargin = 'low_margin';
  static const creditLimit = 'credit_limit';
}

/// One log of every exception a manager allowed (extra discount above the
/// cashier limit, a sale below cost, a price override), with who and why.
class ApprovalService {
  ApprovalService(this.db);

  final AppDatabase db;

  Future<int> record({
    required String kind,
    required String docType,
    required int docId,
    required String reason,
    int? requestedBy,
    int? approvedBy,
  }) {
    final why = reason.trim();
    if (why.isEmpty) throw ValidationException('اكتب سبب الموافقة');
    return db.into(db.approvals).insert(ApprovalsCompanion.insert(
          kind: kind,
          docType: docType,
          docId: docId,
          reason: why,
          requestedBy: Value(requestedBy),
          approvedBy: Value(approvedBy),
        ));
  }

  Future<List<Approval>> forDocument(String docType, int docId) {
    return (db.select(db.approvals)
          ..where((t) => t.docType.equals(docType) & t.docId.equals(docId)))
        .get();
  }

  Stream<List<Approval>> watchAll() {
    return (db.select(db.approvals)..orderBy([(t) => OrderingTerm.desc(t.id)])).watch();
  }
}
