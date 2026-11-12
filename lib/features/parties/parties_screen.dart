import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/services/doc_types.dart';
import '../../core/services/selling_policy_service.dart';
import '../../core/widgets/data_list.dart';
import 'party_form_dialog.dart';
import 'statement_dialog.dart';

/// A customer's category name, from the list of categories.
String categoryNameOf(Customer c, List<CustomerCategory> categories) =>
    categories.where((k) => k.id == (c.categoryId ?? walkInCategoryId)).firstOrNull?.name ?? '';

class CustomersScreen extends ConsumerStatefulWidget {
  const CustomersScreen({super.key});

  @override
  ConsumerState<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends ConsumerState<CustomersScreen> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(currentUserProvider)?.isAdmin ?? false;
    final rows = ref.watch(_customersProvider(_search));
    final customerBalances = ref.watch(_customerBalancesProvider).valueOrNull ?? const <int, int>{};
    final categories = ref.watch(customerCategoriesProvider).valueOrNull ?? const <CustomerCategory>[];
    return _PartyPage(
      title: Strings.customers,
      newLabel: Strings.newCustomer,
      onNew: () => showCustomerForm(context),
      onSearch: (v) => setState(() => _search = v),
      list: rows.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) => DataList<Customer>(
          rows: list,
          emptyText: Strings.noCustomers,
          onTap: (c) => showCustomerForm(context, existing: c),
          trailing: (c) => _PartyMenu(
            onEdit: () => showCustomerForm(context, existing: c),
            onStatement: () => showStatement(context, partyType: PartyType.customer, partyId: c.id),
          ),
          columns: [
            DataListColumn(Strings.name, flex: 3, (c) => _NameCell(c.name, c.isActive)),
            DataListColumn(Strings.phone, flex: 2, (c) => Text(c.phone ?? '', textDirection: TextDirection.ltr)),
            DataListColumn(Strings.address, flex: 3, (c) => Text(c.address ?? '')),
            DataListColumn('الفئة', numeric: true, (c) => Text(categoryNameOf(c, categories))),
            if (isAdmin)
              DataListColumn(Strings.creditLimit, numeric: true,
                  (c) => Text(c.creditLimit == 0 ? '—' : formatMoney(c.creditLimit))),
            DataListColumn(Strings.balance, numeric: true, (c) => _BalanceCell(customerBalances[c.id])),
          ],
        ),
      ),
    );
  }
}

class SuppliersScreen extends ConsumerStatefulWidget {
  const SuppliersScreen({super.key});

  @override
  ConsumerState<SuppliersScreen> createState() => _SuppliersScreenState();
}

class _SuppliersScreenState extends ConsumerState<SuppliersScreen> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(_suppliersProvider(_search));
    final supplierBalances = ref.watch(_supplierBalancesProvider).valueOrNull ?? const <int, int>{};
    return _PartyPage(
      title: Strings.suppliers,
      newLabel: Strings.newSupplier,
      onNew: () => showSupplierForm(context),
      onSearch: (v) => setState(() => _search = v),
      list: rows.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) => DataList<Supplier>(
          rows: list,
          emptyText: Strings.noSuppliers,
          onTap: (s) => showSupplierForm(context, existing: s),
          trailing: (s) => _PartyMenu(
            onEdit: () => showSupplierForm(context, existing: s),
            onStatement: () => showStatement(context, partyType: PartyType.supplier, partyId: s.id),
          ),
          columns: [
            DataListColumn(Strings.name, flex: 3, (s) => _NameCell(s.name, s.isActive)),
            DataListColumn(Strings.phone, flex: 2, (s) => Text(s.phone ?? '', textDirection: TextDirection.ltr)),
            DataListColumn(Strings.address, flex: 3, (s) => Text(s.address ?? '')),
            DataListColumn(Strings.balance, numeric: true, (s) => _BalanceCell(supplierBalances[s.id])),
          ],
        ),
      ),
    );
  }
}

class _PartyPage extends StatelessWidget {
  const _PartyPage({
    required this.title,
    required this.newLabel,
    required this.onNew,
    required this.onSearch,
    required this.list,
  });

  final String title;
  final String newLabel;
  final VoidCallback onNew;
  final ValueChanged<String> onSearch;
  final Widget list;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: title,
          actions: [
            SearchBox(hint: Strings.searchParties, onChanged: onSearch),
            FilledButton.icon(onPressed: onNew, icon: const Icon(Icons.add), label: Text(newLabel)),
          ],
        ),
        Expanded(child: list),
      ],
    );
  }
}

class _NameCell extends StatelessWidget {
  const _NameCell(this.name, this.active);

  final String name;
  final bool active;

  @override
  Widget build(BuildContext context) {
    if (active) return Text(name);
    return Text(
      '$name (${Strings.inactive})',
      style: TextStyle(color: Theme.of(context).disabledColor),
    );
  }
}

final _customersProvider = StreamProvider.autoDispose.family<List<Customer>, String>(
  (ref, search) => ref.watch(partyServiceProvider).watchCustomers(search: search),
);

final _suppliersProvider = StreamProvider.autoDispose.family<List<Supplier>, String>(
  (ref, search) => ref.watch(partyServiceProvider).watchSuppliers(search: search),
);

/// What the party owes (customers) or is owed (suppliers); credit in green.
class _BalanceCell extends StatelessWidget {
  const _BalanceCell(this.balance);

  final int? balance;

  @override
  Widget build(BuildContext context) {
    final b = balance;
    if (b == null) return const Text('…');
    final scheme = Theme.of(context).colorScheme;
    return Text(
      formatMoney(b),
      style: TextStyle(
        fontWeight: b != 0 ? FontWeight.bold : null,
        color: b < 0 ? Colors.green.shade700 : (b > 0 ? scheme.onSurface : scheme.outline),
      ),
    );
  }
}

final _customerBalancesProvider = StreamProvider.autoDispose<Map<int, int>>(
  (ref) => ref.watch(balanceServiceProvider).watchCustomerBalances(),
);

final _supplierBalancesProvider = StreamProvider.autoDispose<Map<int, int>>(
  (ref) => ref.watch(balanceServiceProvider).watchSupplierBalances(),
);

class _PartyMenu extends StatelessWidget {
  const _PartyMenu({required this.onEdit, required this.onStatement});

  final VoidCallback onEdit;
  final VoidCallback onStatement;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<VoidCallback>(
      onSelected: (f) => f(),
      itemBuilder: (_) => [
        PopupMenuItem(value: onStatement, child: const Text(Strings.statement)),
        PopupMenuItem(value: onEdit, child: const Text(Strings.edit)),
      ],
    );
  }
}
