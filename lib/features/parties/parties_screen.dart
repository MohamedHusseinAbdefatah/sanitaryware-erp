import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/services/product_service.dart';
import '../../core/widgets/data_list.dart';
import 'party_form_dialog.dart';

String priceLevelLabel(String level) => switch (level) {
      PriceLevel.wholesale => Strings.priceWholesale,
      PriceLevel.contractor => Strings.priceContractor,
      _ => Strings.priceRetail,
    };

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
          columns: [
            DataListColumn(Strings.name, flex: 3, (c) => _NameCell(c.name, c.isActive)),
            DataListColumn(Strings.phone, flex: 2, (c) => Text(c.phone ?? '', textDirection: TextDirection.ltr)),
            DataListColumn(Strings.address, flex: 3, (c) => Text(c.address ?? '')),
            DataListColumn(Strings.priceLevel, numeric: true, (c) => Text(priceLevelLabel(c.priceLevel))),
            if (isAdmin)
              DataListColumn(Strings.creditLimit, numeric: true,
                  (c) => Text(c.creditLimit == 0 ? '—' : formatMoney(c.creditLimit))),
            DataListColumn(Strings.openingBalance, numeric: true, (c) => Text(formatMoney(c.openingBalance))),
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
          columns: [
            DataListColumn(Strings.name, flex: 3, (s) => _NameCell(s.name, s.isActive)),
            DataListColumn(Strings.phone, flex: 2, (s) => Text(s.phone ?? '', textDirection: TextDirection.ltr)),
            DataListColumn(Strings.address, flex: 3, (s) => Text(s.address ?? '')),
            DataListColumn(Strings.openingBalance, numeric: true, (s) => Text(formatMoney(s.openingBalance))),
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
