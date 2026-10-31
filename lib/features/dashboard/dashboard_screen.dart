import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/backup/backup_actions.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/reports/report_service.dart';

/// Today at a glance. Tapping a card opens the screen behind it.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  late Future<DashboardSummary> _summary = _load();
  late final Future<ExternalBackupStatus> _backup = ref.read(backupActionsProvider).externalStatus();

  Future<DashboardSummary> _load() => ref.read(reportServiceProvider).dashboard();

  /// The plan's startup warning: the data lives on this computer only, so
  /// the admin is told when there is no recent copy elsewhere.
  Widget _backupWarning(ExternalBackupStatus s) {
    final text = switch (s.state) {
      ExternalBackupState.notSet => Strings.backupWarnNotSet,
      ExternalBackupState.unavailable => Strings.backupWarnUnavailable,
      ExternalBackupState.old => s.ageDays == null
          ? Strings.backupWarnNone
          : '${Strings.backupWarnOld} ${s.ageDays} ${Strings.days}',
      ExternalBackupState.ok => '',
    };
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: TextStyle(color: scheme.onErrorContainer))),
            TextButton(onPressed: () => context.go('/settings'), child: const Text(Strings.settings)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAdmin = ref.watch(currentUserProvider)?.isAdmin ?? false;
    return FutureBuilder<DashboardSummary>(
      future: _summary,
      builder: (context, snap) {
        final d = snap.data;
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Row(
              children: [
                Text(Strings.dashboard, style: theme.textTheme.headlineSmall),
                const Spacer(),
                IconButton(
                  tooltip: Strings.refresh,
                  icon: const Icon(Icons.refresh),
                  onPressed: () => setState(() {
                    _summary = _load();
                  }),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (isAdmin)
              FutureBuilder<ExternalBackupStatus>(
                future: _backup,
                builder: (context, b) => b.data == null || b.data!.state == ExternalBackupState.ok
                    ? const SizedBox()
                    : Padding(padding: const EdgeInsets.only(bottom: 16), child: _backupWarning(b.data!)),
              ),
            if (snap.hasError) Text('${snap.error}'),
            if (d == null && !snap.hasError) const Center(child: CircularProgressIndicator()),
            if (d != null) ...[
              Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  _Card(
                    icon: Icons.receipt_long_outlined,
                    title: Strings.todaySales,
                    value: formatMoney(d.todaySales),
                    detail: '${d.todayInvoices} ${Strings.invoicesWord}',
                    onTap: () => context.go('/sales'),
                  ),
                  _Card(
                    icon: Icons.payments_outlined,
                    title: Strings.todayReceived,
                    value: formatMoney(d.todayReceived),
                    onTap: () => context.go('/payments'),
                  ),
                  _Card(
                    icon: Icons.inventory_2_outlined,
                    title: Strings.lowStockItems,
                    value: '${d.lowStockCount}',
                    warn: d.lowStockCount > 0,
                    onTap: () => context.go('/products'),
                  ),
                  _Card(
                    icon: Icons.event_note_outlined,
                    title: Strings.chequesDueWeek,
                    value: '${d.chequesInDue} ${Strings.chequeIn} — ${formatMoney(d.chequesInDueTotal)}',
                    detail: isAdmin
                        ? '${d.chequesOutDue} ${Strings.chequeOut} — ${formatMoney(d.chequesOutDueTotal)}'
                        : null,
                    warn: d.chequesInDue + d.chequesOutDue > 0,
                    onTap: () => context.go('/payments'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Text(Strings.topDebtors, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              if (d.topDebtors.isEmpty) const Text(Strings.noDebtors),
              for (final (name, balance) in d.topDebtors)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.person_outline),
                  title: Text(name),
                  trailing: Text(formatMoney(balance), style: const TextStyle(fontWeight: FontWeight.bold)),
                  onTap: () => context.go('/customers'),
                ),
            ],
          ],
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
    this.detail,
    this.warn = false,
  });

  final IconData icon;
  final String title;
  final String value;
  final String? detail;
  final bool warn;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 260,
      child: Card(
        color: warn ? scheme.tertiaryContainer : null,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 20),
                    const SizedBox(width: 8),
                    Expanded(child: Text(title, overflow: TextOverflow.ellipsis)),
                  ],
                ),
                const SizedBox(height: 12),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                ),
                if (detail != null) ...[
                  const SizedBox(height: 4),
                  Text(detail!, style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
