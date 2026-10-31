import 'package:flutter/material.dart';

import '../../core/l10n/strings.dart';

class _NavItem {
  const _NavItem(this.title, this.icon);
  final String title;
  final IconData icon;
}

const _items = <_NavItem>[
  _NavItem(Strings.dashboard, Icons.dashboard_outlined),
  _NavItem(Strings.products, Icons.inventory_2_outlined),
  _NavItem(Strings.customers, Icons.people_outline),
  _NavItem(Strings.suppliers, Icons.local_shipping_outlined),
  _NavItem(Strings.sales, Icons.receipt_long_outlined),
  _NavItem(Strings.purchases, Icons.shopping_cart_outlined),
  _NavItem(Strings.payments, Icons.payments_outlined),
  _NavItem(Strings.expenses, Icons.money_off_outlined),
  _NavItem(Strings.reports, Icons.bar_chart_outlined),
  _NavItem(Strings.settings, Icons.settings_outlined),
];

/// Main window: sidebar on the right (RTL) and the selected page on the left.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Row(
        children: [
          Container(
            width: 230,
            color: scheme.surfaceContainerHighest,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    Strings.appTitle,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _items.length,
                    itemBuilder: (context, i) {
                      final item = _items[i];
                      return ListTile(
                        leading: Icon(item.icon),
                        title: Text(item.title),
                        selected: i == _selected,
                        onTap: () => setState(() => _selected = i),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _items[_selected].title,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text(Strings.comingSoon),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
