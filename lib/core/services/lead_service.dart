import 'package:drift/drift.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import 'audit_service.dart';
import 'errors.dart';
import 'party_service.dart';

abstract final class LeadStage {
  static const newLead = 'new';
  static const contacted = 'contacted';
  static const quoted = 'quoted';
  static const won = 'won';
  static const lost = 'lost';
  static const all = [newLead, contacted, quoted, won, lost];
  static const open = [newLead, contacted, quoted];

  static String label(String s) => switch (s) {
        newLead => 'جديد',
        contacted => 'تم التواصل',
        quoted => 'أُرسل عرض سعر',
        won => 'أصبح عميلاً',
        lost => 'لم يتم',
        _ => s,
      };
}

abstract final class LeadSource {
  static const all = ['showroom', 'whatsapp', 'social', 'website', 'referral', 'other'];

  static String label(String s) => switch (s) {
        'showroom' => 'زيارة المعرض',
        'whatsapp' => 'واتساب',
        'social' => 'سوشيال ميديا',
        'website' => 'الموقع',
        'referral' => 'ترشيح',
        _ => 'أخرى',
      };
}

class LeadInput {
  const LeadInput({
    required this.name,
    this.phone,
    this.source = 'showroom',
    this.interest,
    this.expectedValue = 0,
    this.nextFollowUp,
    this.assignedTo,
    this.notes,
  });

  final String name;
  final String? phone;
  final String source;
  final String? interest;
  final int expectedValue;
  final DateTime? nextFollowUp;
  final int? assignedTo;
  final String? notes;
}

/// Possible customers before they buy (blueprint 6.1): where they came from,
/// what they want, the expected value, the stage and the next follow-up.
class LeadService {
  LeadService(this.db);

  final AppDatabase db;

  String? _blank(String? s) => (s ?? '').trim().isEmpty ? null : s!.trim();

  Stream<List<Lead>> watchAll() => (db.select(db.leads)..orderBy([(l) => OrderingTerm.desc(l.id)])).watch();

  Future<int> save(LeadInput input, {int? id, required User user}) async {
    if (user.readOnly) throw ValidationException('هذا المستخدم للاطلاع فقط ولا يسجل عمليات');
    if (input.name.trim().isEmpty) throw ValidationException('اكتب اسم العميل المحتمل');
    if (!LeadSource.all.contains(input.source)) throw ArgumentError.value(input.source, 'source');
    if (input.expectedValue < 0) throw ValidationException('القيمة المتوقعة لا تكون سالبة');
    final c = LeadsCompanion(
      name: Value(input.name.trim()),
      phone: Value(_blank(input.phone)),
      source: Value(input.source),
      interest: Value(_blank(input.interest)),
      expectedValue: Value(input.expectedValue),
      nextFollowUp: Value(input.nextFollowUp),
      assignedTo: Value(input.assignedTo ?? user.id),
      notes: Value(_blank(input.notes)),
      updatedAt: Value(DateTime.now()),
    );
    if (id == null) {
      final newId = await db.into(db.leads).insert(c);
      await AuditService(db).log(action: AuditAction.create, entity: 'lead', entityId: newId, userId: user.id, details: input.name.trim());
      return newId;
    }
    await (db.update(db.leads)..where((l) => l.id.equals(id))).write(c);
    return id;
  }

  Future<void> setStage(int id, String stage, {String? lostReason, required User user}) async {
    if (user.readOnly) throw ValidationException('هذا المستخدم للاطلاع فقط ولا يسجل عمليات');
    if (!LeadStage.all.contains(stage)) throw ArgumentError.value(stage, 'stage');
    if (stage == LeadStage.won) throw ValidationException('حوّله إلى عميل بزر «تحويل لعميل»');
    if (stage == LeadStage.lost && (lostReason ?? '').trim().isEmpty) throw ValidationException('اكتب سبب عدم الإتمام');
    await (db.update(db.leads)..where((l) => l.id.equals(id))).write(LeadsCompanion(
          stage: Value(stage),
          lostReason: Value(stage == LeadStage.lost ? lostReason!.trim() : null),
          updatedAt: Value(DateTime.now()),
        ));
    await AuditService(db).log(
        action: AuditAction.update, entity: 'lead', entityId: id, userId: user.id, details: LeadStage.label(stage));
  }

  /// Makes the lead a customer (or links an existing one with the same
  /// phone) and marks it won. Returns the customer id.
  Future<int> convert(int id, {required User user}) {
    return db.transaction(() async {
      if (user.readOnly) throw ValidationException('هذا المستخدم للاطلاع فقط ولا يسجل عمليات');
      final lead = await (db.select(db.leads)..where((l) => l.id.equals(id))).getSingle();
      if (lead.customerId != null) return lead.customerId!;
      final same = lead.phone == null
          ? null
          : await (db.select(db.customers)..where((c) => c.phone.equals(lead.phone!))).getSingleOrNull();
      final customerId = same?.id ??
          await PartyService(db).saveCustomer(
            CustomerInput(name: lead.name, phone: lead.phone, notes: lead.interest),
            userId: user.id,
          );
      await (db.update(db.leads)..where((l) => l.id.equals(id))).write(LeadsCompanion(
            stage: const Value(LeadStage.won),
            customerId: Value(customerId),
            updatedAt: Value(DateTime.now()),
          ));
      await AuditService(db).log(
          action: AuditAction.update, entity: 'lead', entityId: id, userId: user.id, details: 'تحويل لعميل $customerId');
      return customerId;
    });
  }
}
