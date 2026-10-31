import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/dates.dart';
import '../../core/l10n/strings.dart';
import '../../core/providers.dart';
import '../../core/search_text.dart';
import '../../core/services/audit_service.dart';
import '../../core/widgets/data_list.dart';
import '../../core/widgets/date_range_bar.dart';

String auditActionLabel(String action) => switch (action) {
      AuditAction.setup => 'إعداد البرنامج',
      AuditAction.login => 'تسجيل دخول',
      AuditAction.loginFailed => 'محاولة دخول فاشلة',
      AuditAction.create => 'إضافة',
      AuditAction.update => 'تعديل',
      AuditAction.cancel => 'إلغاء',
      AuditAction.backup => 'نسخة احتياطية',
      AuditAction.restore => 'استعادة نسخة',
      _ => action,
    };

String auditEntityLabel(String entity) => switch (entity) {
      'app' => 'البرنامج',
      'user' => 'مستخدم',
      'product' => 'صنف',
      'stock' => 'المخزون',
      'customer' => 'عميل',
      'supplier' => 'مورد',
      'sales_invoice' => 'فاتورة بيع',
      'purchase_invoice' => 'فاتورة شراء',
      'payment' => 'دفعة',
      'cheque' => 'شيك',
      'return' => 'مرتجع',
      'expense' => 'مصروف',
      'database' => 'قاعدة البيانات',
      'import' => 'استيراد',
      _ => entity,
    };

/// Read-only list of who did what and when.
class AuditTab extends ConsumerStatefulWidget {
  const AuditTab({super.key});

  @override
  ConsumerState<AuditTab> createState() => _AuditTabState();
}

class _AuditTabState extends ConsumerState<AuditTab> {
  DayRange _range = DayRange.today();
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(_auditProvider(_range));
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
          child: Wrap(
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DateRangeBar(value: _range, onChanged: (r) => setState(() => _range = r)),
              SearchBox(hint: Strings.searchAudit, onChanged: (v) => setState(() => _search = v)),
            ],
          ),
        ),
        Expanded(
          child: rows.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('$e')),
            data: (all) => DataList<AuditRow>(
              rows: all
                  .where((r) => matchesSearch(_search, [
                        r.userName,
                        auditActionLabel(r.log.action),
                        auditEntityLabel(r.log.entity),
                        r.log.details,
                      ]))
                  .toList(),
              emptyText: Strings.noData,
              rowColor: (r) => r.log.action == AuditAction.cancel || r.log.action == AuditAction.loginFailed
                  ? scheme.errorContainer.withValues(alpha: 0.25)
                  : null,
              columns: [
                DataListColumn(Strings.date, flex: 2, (r) => Text(formatDateTime(r.log.at))),
                DataListColumn(Strings.user, flex: 2, (r) => Text(r.userName ?? '—')),
                DataListColumn(Strings.action, flex: 2, (r) => Text(auditActionLabel(r.log.action))),
                DataListColumn(Strings.onWhat, flex: 2, (r) => Text(auditEntityLabel(r.log.entity))),
                DataListColumn(Strings.details, flex: 5, (r) => Text(r.log.details ?? '')),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

final _auditProvider = StreamProvider.autoDispose.family<List<AuditRow>, DayRange>(
  (ref, range) => AuditService(ref.watch(databaseProvider)).watch(from: range.from, to: range.to),
);
