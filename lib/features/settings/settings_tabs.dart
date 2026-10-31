import 'package:flutter/material.dart';

import '../../core/l10n/strings.dart';
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
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: Text(Strings.settings, style: Theme.of(context).textTheme.headlineSmall),
          ),
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: Strings.generalTab),
              Tab(text: Strings.usersTab),
              Tab(text: Strings.importTab),
              Tab(text: Strings.auditTab),
            ],
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
