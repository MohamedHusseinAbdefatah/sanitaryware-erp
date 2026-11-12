import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/services/directory_service.dart';
import '../../core/services/doc_types.dart';
import '../../core/services/selling_policy_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/data_list.dart';
import '../../core/widgets/list_kit.dart';
import '../payments/payment_dialog.dart';
import '../purchases/supplier_advances_dialog.dart';
import 'party_form_dialog.dart';
import 'statement_dialog.dart';

/// A customer's category name, from the list of categories.
String categoryNameOf(Customer c, List<CustomerCategory> categories) =>
    categories.where((k) => k.id == (c.categoryId ?? walkInCategoryId)).firstOrNull?.name ?? '';

final _customersProvider = StreamProvider.autoDispose<List<Customer>>(
  (ref) => ref.watch(partyServiceProvider).watchCustomers(),
);

final _suppliersProvider = StreamProvider.autoDispose<List<Supplier>>(
  (ref) => ref.watch(partyServiceProvider).watchSuppliers(),
);

final _customerBalancesProvider = StreamProvider.autoDispose<Map<int, int>>(
  (ref) => ref.watch(balanceServiceProvider).watchCustomerBalances(),
);

final _supplierBalancesProvider = StreamProvider.autoDispose<Map<int, int>>(
  (ref) => ref.watch(balanceServiceProvider).watchSupplierBalances(),
);

final _customerActivityProvider = StreamProvider.autoDispose<Map<int, PartyActivity>>(
  (ref) => DirectoryService(ref.watch(databaseProvider)).watchCustomerActivity(),
);

final _supplierActivityProvider = StreamProvider.autoDispose<Map<int, PartyActivity>>(
  (ref) => DirectoryService(ref.watch(databaseProvider)).watchSupplierActivity(),
);

bool _matches(String q, List<String?> fields) {
  final t = q.trim();
  if (t.isEmpty) return true;
  return fields.any((f) => f != null && f.contains(t));
}

enum _Sort { name, balance, last, sales }

const _sortLabels = {
  _Sort.name: 'الاسم',
  _Sort.balance: 'الرصيد',
  _Sort.last: 'آخر تعامل',
  _Sort.sales: 'تعاملات هذا العام',
};

Widget _sortMenu(_Sort value, ValueChanged<_Sort> onChanged) => PopupMenuButton<_Sort>(
      tooltip: 'ترتيب',
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (_) => [for (final s in _Sort.values) PopupMenuItem(value: s, child: Text(_sortLabels[s]!))],
      child: Chip(avatar: const Icon(Icons.sort, size: 18), label: Text('ترتيب: ${_sortLabels[value]}')),
    );

/// A balance in bold; a credit (negative) in green, zero muted.
Widget balanceText(int? b, {double size = 14}) {
  if (b == null) return const Text('…');
  return Text(
    formatMoney(b),
    style: TextStyle(
      fontSize: size,
      fontWeight: b != 0 ? FontWeight.w800 : FontWeight.w400,
      color: b < 0 ? AppColors.good : (b > 0 ? AppColors.ink : AppColors.muted),
    ),
  );
}

// ------------------------------------------------------------- customers

enum _CustomerFilter { all, owing, overLimit, credit, inactive }

class CustomersScreen extends ConsumerStatefulWidget {
  const CustomersScreen({super.key});

  @override
  ConsumerState<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends ConsumerState<CustomersScreen> {
  String _search = '';
  _CustomerFilter _filter = _CustomerFilter.all;
  int? _category;
  _Sort _sort = _Sort.name;
  bool _cards = false;

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(currentUserProvider)?.seesCost ?? false;
    final all = ref.watch(_customersProvider);
    final balances = ref.watch(_customerBalancesProvider).valueOrNull ?? const <int, int>{};
    final activity = ref.watch(_customerActivityProvider).valueOrNull ?? const <int, PartyActivity>{};
    final categories = ref.watch(customerCategoriesProvider).valueOrNull ?? const <CustomerCategory>[];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeader(title: Strings.customers, actions: [
        SearchBox(hint: 'بحث بالاسم أو التليفون أو العنوان', onChanged: (v) => setState(() => _search = v)),
        OutlinedButton.icon(
          onPressed: () => context.go('/customers/leads'),
          icon: const Icon(Icons.person_search_outlined),
          label: const Text('الفرص'),
        ),
        ViewToggle(cards: _cards, onChanged: (v) => setState(() => _cards = v)),
        FilledButton.icon(
          onPressed: () => showCustomerForm(context),
          icon: const Icon(Icons.person_add_alt),
          label: const Text(Strings.newCustomer),
        ),
      ]),
      Expanded(
        child: all.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
          data: (customers) {
            int bal(Customer c) => balances[c.id] ?? 0;
            bool over(Customer c) => c.creditLimit > 0 && bal(c) > c.creditLimit;
            bool pass(Customer c, _CustomerFilter f) => switch (f) {
                  _CustomerFilter.all => c.isActive,
                  _CustomerFilter.owing => c.isActive && bal(c) > 0,
                  _CustomerFilter.overLimit => over(c),
                  _CustomerFilter.credit => bal(c) < 0,
                  _CustomerFilter.inactive => !c.isActive,
                };
            final base = customers.where((c) =>
                (_category == null || (c.categoryId ?? walkInCategoryId) == _category) &&
                _matches(_search, [c.name, c.phone, c.address]));
            final rows = base.where((c) => pass(c, _filter)).toList()
              ..sort((a, b) => switch (_sort) {
                    _Sort.name => a.name.compareTo(b.name),
                    _Sort.balance => bal(b).compareTo(bal(a)),
                    _Sort.last =>
                      (activity[b.id]?.last ?? DateTime(1900)).compareTo(activity[a.id]?.last ?? DateTime(1900)),
                    _Sort.sales => (activity[b.id]?.thisYear ?? 0).compareTo(activity[a.id]?.thisYear ?? 0),
                  });
            final active = customers.where((c) => c.isActive);
            final owing = active.fold(0, (s, c) => s + (bal(c) > 0 ? bal(c) : 0));
            final year = activity.values.fold(0, (s, a) => s + a.thisYear);
            void open(Customer c) => context.go('/customers/${c.id}');
            Widget menu(Customer c) => _PartyMenu(items: [
                  ('فاتورة بيع', Icons.point_of_sale, () => context.go('/sales/new?customer=${c.id}')),
                  (Strings.receivePayment, Icons.payments_outlined,
                      () => showPaymentDialog(context, partyType: PartyType.customer, partyId: c.id)),
                  (Strings.statement, Icons.receipt_long_outlined,
                      () => showStatement(context, partyType: PartyType.customer, partyId: c.id)),
                  (Strings.edit, Icons.edit_outlined, () => showCustomerForm(context, existing: c)),
                ]);
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SummaryStrip(items: [
                SummaryItem('عملاء نشطون', '${active.length}', icon: Icons.people_outline),
                SummaryItem('مستحق لنا', formatMoney(owing), icon: Icons.call_received, tone: AppColors.warn),
                SummaryItem('تجاوزوا حد الائتمان', '${customers.where(over).length}',
                    icon: Icons.warning_amber_rounded, tone: customers.any(over) ? AppColors.bad : null),
                SummaryItem('مبيعات هذا العام', formatMoney(year), icon: Icons.trending_up, tone: AppColors.good),
              ]),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
                child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  for (final (f, label) in const [
                    (_CustomerFilter.all, 'الكل'),
                    (_CustomerFilter.owing, 'عليهم رصيد'),
                    (_CustomerFilter.overLimit, 'تجاوزوا الحد'),
                    (_CustomerFilter.credit, 'لهم رصيد دائن'),
                    (_CustomerFilter.inactive, 'موقوفون'),
                  ])
                    ChoiceChip(
                      showCheckmark: false,
                      label: Text('$label  ${base.where((c) => pass(c, f)).length}'),
                      selected: _filter == f,
                      onSelected: (_) => setState(() => _filter = f),
                    ),
                  const SizedBox(width: 8),
                  PopupMenuButton<int>(
                    tooltip: 'الفئة',
                    onSelected: (v) => setState(() => _category = v == -1 ? null : v),
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: -1, child: Text('كل الفئات')),
                      for (final k in categories) PopupMenuItem(value: k.id, child: Text(k.name)),
                    ],
                    child: Chip(
                      avatar: const Icon(Icons.category_outlined, size: 18),
                      label: Text(_category == null
                          ? 'كل الفئات'
                          : categories.where((k) => k.id == _category).firstOrNull?.name ?? ''),
                    ),
                  ),
                  _sortMenu(_sort, (s) => setState(() => _sort = s)),
                ]),
              ),
              Expanded(
                child: _cards
                    ? CardGrid<Customer>(
                        rows: rows,
                        emptyText: Strings.noCustomers,
                        height: 186,
                        card: (c) => _PartyCard(
                          name: c.name,
                          subtitle: c.phone,
                          pill: StatusPill(categoryNameOf(c, categories)),
                          balance: balances[c.id],
                          balanceLabel: 'الرصيد',
                          warn: over(c),
                          activity: activity[c.id],
                          activityLabel: 'مبيعات العام',
                          inactive: !c.isActive,
                          menu: menu(c),
                          onTap: () => open(c),
                        ),
                      )
                    : DataList<Customer>(
                        rows: rows,
                        emptyText: Strings.noCustomers,
                        onTap: open,
                        rowColor: (c) => over(c) ? AppColors.badBg.withValues(alpha: .5) : null,
                        trailing: menu,
                        columns: [
                          DataListColumn(Strings.name, flex: 4, (c) => TitleCell(
                                c.isActive ? c.name : '${c.name} (${Strings.inactive})',
                                subtitle:
                                    [c.phone, c.address].whereType<String>().where((s) => s.isNotEmpty).join('  ·  '),
                                leading: NameAvatar(c.name),
                                muted: !c.isActive,
                              )),
                          DataListColumn('الفئة', flex: 2, (c) => StatusPill(categoryNameOf(c, categories))),
                          DataListColumn('آخر شراء', numeric: true, (c) => Text(sinceText(activity[c.id]?.last),
                              style: const TextStyle(fontSize: 13, color: AppColors.muted))),
                          DataListColumn('مبيعات العام', numeric: true,
                              (c) => Text(formatMoney(activity[c.id]?.thisYear ?? 0))),
                          if (isAdmin)
                            DataListColumn(Strings.creditLimit, flex: 2,
                                (c) => UsageBar(used: bal(c), limit: c.creditLimit)),
                          DataListColumn(Strings.balance, numeric: true, (c) => balanceText(balances[c.id])),
                        ],
                      ),
              ),
            ]);
          },
        ),
      ),
    ]);
  }
}

// ------------------------------------------------------------- suppliers

enum _SupplierFilter { all, owed, credit, inactive }

class SuppliersScreen extends ConsumerStatefulWidget {
  const SuppliersScreen({super.key});

  @override
  ConsumerState<SuppliersScreen> createState() => _SuppliersScreenState();
}

class _SuppliersScreenState extends ConsumerState<SuppliersScreen> {
  String _search = '';
  _SupplierFilter _filter = _SupplierFilter.all;
  _Sort _sort = _Sort.name;
  bool _cards = false;

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(_suppliersProvider);
    final balances = ref.watch(_supplierBalancesProvider).valueOrNull ?? const <int, int>{};
    final activity = ref.watch(_supplierActivityProvider).valueOrNull ?? const <int, PartyActivity>{};
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeader(title: Strings.suppliers, actions: [
        SearchBox(hint: 'بحث بالاسم أو التليفون أو العنوان', onChanged: (v) => setState(() => _search = v)),
        ViewToggle(cards: _cards, onChanged: (v) => setState(() => _cards = v)),
        FilledButton.icon(
          onPressed: () => showSupplierForm(context),
          icon: const Icon(Icons.add_business_outlined),
          label: const Text(Strings.newSupplier),
        ),
      ]),
      Expanded(
        child: all.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
          data: (suppliers) {
            int bal(Supplier s) => balances[s.id] ?? 0;
            bool pass(Supplier s, _SupplierFilter f) => switch (f) {
                  _SupplierFilter.all => s.isActive,
                  _SupplierFilter.owed => s.isActive && bal(s) > 0,
                  _SupplierFilter.credit => bal(s) < 0,
                  _SupplierFilter.inactive => !s.isActive,
                };
            final base = suppliers.where((s) => _matches(_search, [s.name, s.phone, s.address]));
            final rows = base.where((s) => pass(s, _filter)).toList()
              ..sort((a, b) => switch (_sort) {
                    _Sort.name => a.name.compareTo(b.name),
                    _Sort.balance => bal(b).compareTo(bal(a)),
                    _Sort.last =>
                      (activity[b.id]?.last ?? DateTime(1900)).compareTo(activity[a.id]?.last ?? DateTime(1900)),
                    _Sort.sales => (activity[b.id]?.thisYear ?? 0).compareTo(activity[a.id]?.thisYear ?? 0),
                  });
            final active = suppliers.where((s) => s.isActive);
            final owed = active.fold(0, (t, s) => t + (bal(s) > 0 ? bal(s) : 0));
            final year = activity.values.fold(0, (t, a) => t + a.thisYear);
            void open(Supplier s) => context.go('/suppliers/${s.id}');
            Widget menu(Supplier s) => _PartyMenu(items: [
                  ('فاتورة شراء', Icons.shopping_cart_outlined, () => context.go('/purchases/new?supplier=${s.id}')),
                  ('دفع للمورد', Icons.payments_outlined,
                      () => showPaymentDialog(context, partyType: PartyType.supplier, partyId: s.id)),
                  (Strings.statement, Icons.receipt_long_outlined,
                      () => showStatement(context, partyType: PartyType.supplier, partyId: s.id)),
                  ('دفعات مقدمة بسعر قائمة', Icons.lock_clock_outlined, () => showSupplierAdvances(context, s)),
                  (Strings.edit, Icons.edit_outlined, () => showSupplierForm(context, existing: s)),
                ]);
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SummaryStrip(items: [
                SummaryItem('موردون نشطون', '${active.length}', icon: Icons.local_shipping_outlined),
                SummaryItem('مستحق علينا', formatMoney(owed), icon: Icons.call_made, tone: AppColors.warn),
                SummaryItem('مشتريات هذا العام', formatMoney(year), icon: Icons.shopping_cart_outlined),
                SummaryItem('رصيدهم دائن لنا', '${suppliers.where((s) => bal(s) < 0).length}', icon: Icons.savings_outlined),
              ]),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
                child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  for (final (f, label) in const [
                    (_SupplierFilter.all, 'الكل'),
                    (_SupplierFilter.owed, 'مستحق لهم'),
                    (_SupplierFilter.credit, 'رصيدهم دائن لنا'),
                    (_SupplierFilter.inactive, 'موقوفون'),
                  ])
                    ChoiceChip(
                      showCheckmark: false,
                      label: Text('$label  ${base.where((s) => pass(s, f)).length}'),
                      selected: _filter == f,
                      onSelected: (_) => setState(() => _filter = f),
                    ),
                  const SizedBox(width: 8),
                  _sortMenu(_sort, (s) => setState(() => _sort = s)),
                ]),
              ),
              Expanded(
                child: _cards
                    ? CardGrid<Supplier>(
                        rows: rows,
                        emptyText: Strings.noSuppliers,
                        height: 186,
                        card: (s) => _PartyCard(
                          name: s.name,
                          subtitle: s.phone,
                          balance: balances[s.id],
                          balanceLabel: 'المستحق له',
                          activity: activity[s.id],
                          activityLabel: 'مشتريات العام',
                          inactive: !s.isActive,
                          menu: menu(s),
                          onTap: () => open(s),
                        ),
                      )
                    : DataList<Supplier>(
                        rows: rows,
                        emptyText: Strings.noSuppliers,
                        onTap: open,
                        trailing: menu,
                        columns: [
                          DataListColumn(Strings.name, flex: 4, (s) => TitleCell(
                                s.isActive ? s.name : '${s.name} (${Strings.inactive})',
                                subtitle:
                                    [s.phone, s.address].whereType<String>().where((x) => x.isNotEmpty).join('  ·  '),
                                leading: NameAvatar(s.name),
                                muted: !s.isActive,
                              )),
                          DataListColumn('عدد الفواتير', numeric: true, (s) => Text('${activity[s.id]?.count ?? 0}')),
                          DataListColumn('آخر شراء', numeric: true, (s) => Text(sinceText(activity[s.id]?.last),
                              style: const TextStyle(fontSize: 13, color: AppColors.muted))),
                          DataListColumn('مشتريات العام', numeric: true,
                              (s) => Text(formatMoney(activity[s.id]?.thisYear ?? 0))),
                          DataListColumn('المستحق له', numeric: true, (s) => balanceText(balances[s.id])),
                        ],
                      ),
              ),
            ]);
          },
        ),
      ),
    ]);
  }
}

// ---------------------------------------------------------------- shared

class _PartyCard extends StatelessWidget {
  const _PartyCard({
    required this.name,
    this.subtitle,
    this.pill,
    required this.balance,
    required this.balanceLabel,
    this.warn = false,
    this.activity,
    required this.activityLabel,
    this.inactive = false,
    required this.menu,
    required this.onTap,
  });

  final String name;
  final String? subtitle;
  final Widget? pill;
  final int? balance;
  final String balanceLabel;
  final bool warn;
  final PartyActivity? activity;
  final String activityLabel;
  final bool inactive;
  final Widget menu;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TapCard(
      onTap: onTap,
      padding: 12,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          NameAvatar(name, size: 40),
          const SizedBox(width: 10),
          Expanded(child: TitleCell(name, subtitle: subtitle, muted: inactive)),
          SizedBox(width: 36, child: menu),
        ]),
        const Spacer(),
        Wrap(spacing: 6, children: [
          if (pill != null) pill!,
          if (inactive) const StatusPill.bad('موقوف'),
          if (warn) const StatusPill.bad('تجاوز الحد'),
        ]),
        const SizedBox(height: 8),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$activityLabel: ${formatMoney(activity?.thisYear ?? 0)}', style: const TextStyle(fontSize: 12)),
              Text('آخر تعامل: ${sinceText(activity?.last)}',
                  style: const TextStyle(fontSize: 11, color: AppColors.muted)),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(balanceLabel, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
            balanceText(balance, size: 17),
          ]),
        ]),
      ]),
    );
  }
}

class _PartyMenu extends StatelessWidget {
  const _PartyMenu({required this.items});

  final List<(String, IconData, VoidCallback)> items;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<VoidCallback>(
      tooltip: 'إجراءات',
      onSelected: (f) => f(),
      itemBuilder: (_) => [
        for (final (label, icon, f) in items)
          PopupMenuItem(
            value: f,
            child: Row(children: [Icon(icon, size: 18, color: AppColors.muted), const SizedBox(width: 10), Text(label)]),
          ),
      ],
    );
  }
}
