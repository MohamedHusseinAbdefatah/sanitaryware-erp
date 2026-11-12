import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n/strings.dart';
import '../../core/services/doc_types.dart';
import '../dashboard/dashboard_screen.dart';
import '../inventory/inventory_screen.dart';
import '../expenses/expenses_screen.dart';
import '../parties/customer_page.dart';
import '../parties/parties_screen.dart';
import '../parties/supplier_page.dart';
import '../products/product_page.dart';
import '../payments/payments_screen.dart';
import '../price_lists/price_lists_screen.dart';
import '../products/products_screen.dart';
import '../reports/reports_screen.dart';
import '../purchases/purchase_entry_screen.dart';
import '../purchases/purchase_list_screen.dart';
import '../purchases/purchase_view_screen.dart';
import '../returns/return_entry_screen.dart';
import '../returns/returns_screen.dart';
import '../sales/orders_screens.dart';
import '../sales/sale_entry_screen.dart';
import '../sales/sale_view_screen.dart';
import '../sales/sales_list_screen.dart';
import '../settings/settings_tabs.dart';
import 'coming_soon_page.dart';

/// One sidebar entry and its page. Cashiers do not see [adminOnly] sections
/// and the router sends them away if they try to open one. [routes] are
/// pages under the section (e.g. /sales/new) that keep its sidebar entry.
class AppSection {
  const AppSection({
    required this.path,
    required this.title,
    required this.icon,
    required this.builder,
    this.adminOnly = false,
    this.routes = const [],
  });

  final String path;
  final String title;
  final IconData icon;
  final WidgetBuilder builder;
  final bool adminOnly;
  final List<RouteBase> routes;
}

final appSections = <AppSection>[
  AppSection(
    path: '/dashboard',
    title: Strings.dashboard,
    icon: Icons.dashboard_outlined,
    builder: (_) => const DashboardScreen(),
  ),
  AppSection(
    path: '/inventory',
    title: Strings.inventory,
    icon: Icons.warehouse_outlined,
    builder: (_) => const InventoryScreen(),
  ),
  AppSection(
    path: '/products',
    title: Strings.products,
    icon: Icons.inventory_2_outlined,
    builder: (_) => const ProductsScreen(),
    routes: [
      GoRoute(
        path: ':id',
        builder: (_, state) {
          final id = int.tryParse(state.pathParameters['id'] ?? '');
          return id == null
              ? const ComingSoonPage(title: Strings.products)
              : ProductPage(key: ValueKey(id), productId: id);
        },
      ),
    ],
  ),
  AppSection(
    path: '/customers',
    title: Strings.customers,
    icon: Icons.people_outline,
    builder: (_) => const CustomersScreen(),
    routes: [
      GoRoute(
        path: ':id',
        builder: (_, state) {
          final id = int.tryParse(state.pathParameters['id'] ?? '');
          return id == null
              ? const ComingSoonPage(title: Strings.customers)
              : CustomerPage(key: ValueKey(id), customerId: id);
        },
      ),
    ],
  ),
  AppSection(
    path: '/suppliers',
    title: Strings.suppliers,
    icon: Icons.local_shipping_outlined,
    adminOnly: true,
    builder: (_) => const SuppliersScreen(),
    routes: [
      GoRoute(
        path: ':id',
        builder: (_, state) {
          final id = int.tryParse(state.pathParameters['id'] ?? '');
          return id == null
              ? const ComingSoonPage(title: Strings.suppliers)
              : SupplierPage(key: ValueKey(id), supplierId: id);
        },
      ),
    ],
  ),
  AppSection(
    path: '/sales',
    title: Strings.sales,
    icon: Icons.receipt_long_outlined,
    builder: (_) => const SalesListScreen(),
    routes: [
      GoRoute(
        path: 'new',
        builder: (_, state) => SaleEntryScreen(
          key: ValueKey(state.uri.query),
          customerId: int.tryParse(state.uri.queryParameters['customer'] ?? ''),
        ),
      ),
      GoRoute(path: 'orders', builder: (_, _) => const SalesOrdersScreen()),
      GoRoute(
        path: ':id',
        builder: (_, state) {
          final id = int.tryParse(state.pathParameters['id'] ?? '');
          return id == null
              ? const ComingSoonPage(title: Strings.sales)
              : SaleViewScreen(key: ValueKey(id), invoiceId: id);
        },
      ),
    ],
  ),
  AppSection(
    path: '/purchases',
    title: Strings.purchases,
    icon: Icons.shopping_cart_outlined,
    adminOnly: true,
    builder: (_) => const PurchaseListScreen(),
    routes: [
      GoRoute(
        path: 'new',
        builder: (_, state) => PurchaseEntryScreen(
          key: ValueKey(state.uri.query),
          supplierId: int.tryParse(state.uri.queryParameters['supplier'] ?? ''),
        ),
      ),
      GoRoute(path: 'orders', builder: (_, _) => const PurchaseOrdersScreen()),
      GoRoute(
        path: ':id',
        builder: (_, state) {
          final id = int.tryParse(state.pathParameters['id'] ?? '');
          return id == null
              ? const ComingSoonPage(title: Strings.purchases)
              : PurchaseViewScreen(key: ValueKey(id), invoiceId: id);
        },
      ),
    ],
  ),
  AppSection(
    path: '/price-lists',
    title: 'قوائم الأسعار',
    icon: Icons.price_change_outlined,
    adminOnly: true,
    builder: (_) => const PriceListsScreen(),
  ),
  AppSection(
    path: '/returns',
    title: Strings.returns,
    icon: Icons.assignment_return_outlined,
    builder: (_) => const ReturnsScreen(),
    routes: [
      GoRoute(
        path: 'new',
        builder: (_, state) => ReturnEntryScreen(
          key: ValueKey(state.uri.query),
          kind: state.uri.queryParameters['kind'] == ReturnKind.purchase
              ? ReturnKind.purchase
              : ReturnKind.sale,
          invoiceId: int.tryParse(state.uri.queryParameters['invoice'] ?? ''),
        ),
      ),
    ],
  ),
  AppSection(
    path: '/payments',
    title: Strings.payments,
    icon: Icons.payments_outlined,
    builder: (_) => const PaymentsScreen(),
  ),
  AppSection(
    path: '/expenses',
    title: Strings.expenses,
    icon: Icons.money_off_outlined,
    adminOnly: true,
    builder: (_) => const ExpensesScreen(),
  ),
  AppSection(
    path: '/reports',
    title: Strings.reports,
    icon: Icons.bar_chart_outlined,
    adminOnly: true,
    builder: (_) => const ReportsScreen(),
  ),
  AppSection(
    path: '/settings',
    title: Strings.settings,
    icon: Icons.settings_outlined,
    adminOnly: true,
    builder: (_) => const SettingsScreen(),
  ),
];
