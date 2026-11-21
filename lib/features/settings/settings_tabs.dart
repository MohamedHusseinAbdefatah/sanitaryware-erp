import 'package:flutter/material.dart';

import '../../core/l10n/strings.dart';
import '../../core/widgets/data_list.dart';
import 'audit_tab.dart';
import 'import_tab.dart';
import 'settings_screen.dart';
import 'users_tab.dart';

/// Admin only (the section is): general settings, users, data import and
/// the audit log.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(
            title: Strings.settings,
            icon: Icons.settings_outlined,
            subtitle: 'بيانات المحل والطباعة والنسخ الاحتياطي والمستخدمون وسجل التعديلات',
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(child: _TabLabel(Icons.tune, Strings.generalTab)),
                Tab(child: _TabLabel(Icons.manage_accounts_outlined, Strings.usersTab)),
                Tab(child: _TabLabel(Icons.upload_file_outlined, Strings.importTab)),
                Tab(child: _TabLabel(Icons.history, Strings.auditTab)),
              ],
            ),
          ),
          const Expanded(
            child: TabBarView(children: [
              GeneralSettingsTab(),
              UsersTab(),
              ImportTab(),
              AuditTab(),
            ]),
          ),
        ],
      ),
    );
  }
}

/// A tab's icon and name side by side, so the tab stays one line high.
class _TabLabel extends StatelessWidget {
  const _TabLabel(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 18),
        const SizedBox(width: 6),
        Text(text),
      ]);
}
