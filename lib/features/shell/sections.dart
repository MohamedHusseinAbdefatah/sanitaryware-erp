import 'package:flutter/material.dart';

import '../../core/l10n/strings.dart';
import '../settings/settings_screen.dart';
import 'coming_soon_page.dart';

/// One sidebar entry and its page. Cashiers do not see [adminOnly] sections
/// and the router sends them away if they try to open one.
class AppSection {
  const AppSection({
    required this.path,
    required this.title,
    required this.icon,
    required this.builder,
    this.adminOnly = false,
  });

  final String path;
  final String title;
  final IconData icon;
  final WidgetBuilder builder;
  final bool adminOnly;
}

final appSections = <AppSection>[
  AppSection(
    path: '/dashboard',
    title: Strings.dashboard,
    icon: Icons.dashboard_outlined,
    builder: (_) => const ComingSoonPage(title: Strings.dashboard),
  ),
  AppSection(
    path: '/products',
    title: Strings.products,
    icon: Icons.inventory_2_outlined,
    builder: (_) => const ComingSoonPage(title: Strings.products),
  ),
  AppSection(
    path: '/customers',
    title: Strings.customers,
    icon: Icons.people_outline,
    builder: (_) => const ComingSoonPage(title: Strings.customers),
  ),
  AppSection(
    path: '/suppliers',
    title: Strings.suppliers,
    icon: Icons.local_shipping_outlined,
    builder: (_) => const ComingSoonPage(title: Strings.suppliers),
  ),
  AppSection(
    path: '/sales',
    title: Strings.sales,
    icon: Icons.receipt_long_outlined,
    builder: (_) => const ComingSoonPage(title: Strings.sales),
  ),
  AppSection(
    path: '/purchases',
    title: Strings.purchases,
    icon: Icons.shopping_cart_outlined,
    adminOnly: true,
    builder: (_) => const ComingSoonPage(title: Strings.purchases),
  ),
  AppSection(
    path: '/payments',
    title: Strings.payments,
    icon: Icons.payments_outlined,
    builder: (_) => const ComingSoonPage(title: Strings.payments),
  ),
  AppSection(
    path: '/expenses',
    title: Strings.expenses,
    icon: Icons.money_off_outlined,
    adminOnly: true,
    builder: (_) => const ComingSoonPage(title: Strings.expenses),
  ),
  AppSection(
    path: '/reports',
    title: Strings.reports,
    icon: Icons.bar_chart_outlined,
    adminOnly: true,
    builder: (_) => const ComingSoonPage(title: Strings.reports),
  ),
  AppSection(
    path: '/settings',
    title: Strings.settings,
    icon: Icons.settings_outlined,
    adminOnly: true,
    builder: (_) => const SettingsScreen(),
  ),
];
