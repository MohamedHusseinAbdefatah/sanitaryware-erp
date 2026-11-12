import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/db/database.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/reports/report_table.dart';
import '../../core/services/ledger_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/data_list.dart';
import '../../core/widgets/date_range_bar.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/list_kit.dart';
import '../../core/widgets/number_fields.dart';
import 'accounting_kit.dart';

/// Where an entry made from a document opens that document.
String? sourcePath(JournalEntry e) => switch (e.refType) {
      'sales_invoice' => '/sales/${e.refId}',
      'purchase_invoice' => '/purchases/${e.refId}',
      'customer_opening' => '/customers/${e.refId}',
      'supplier_opening' => '/suppliers/${e.refId}',
      'payment' => '/payments',
      'return' => '/returns',
      'expense' => '/expenses',
      'stock_movement' => '/inventory',
      _ => null,
    };

String sourceLabel(JournalEntry e) => e.source == 'manual'
    ? 'يدوي'
    : switch (e.refType) {
        'sales_invoice' => 'فاتورة بيع',
        'purchase_invoice' => 'فاتورة شراء',
        'payment' => 'دفعة',
        'return' => 'مرتجع',
        'expense' => 'مصروف',
        'stock_movement' => 'مخزون',
        'customer_opening' || 'supplier_opening' => 'رصيد افتتاحي',
        _ => 'تلقائي',
      };

// ------------------------------------------------------ chart of accounts

class ChartOfAccountsTab extends ConsumerStatefulWidget {
  const ChartOfAccountsTab({super.key});

  @override
  ConsumerState<ChartOfAccountsTab> createState() => _ChartOfAccountsTabState();
}

class _ChartOfAccountsTabState extends ConsumerState<ChartOfAccountsTab> {
  String _query = '';
  bool _hideEmpty = false;

  @override
  Widget build(BuildContext context) {
    return LedgerBuilder<List<AccountBalance>>(
      load: (l) => l.balances(),
      builder: (context, rows) {
        final rolled = LedgerService.rollUp(rows);
        final byId = {for (final r in rows) r.account.id: r.account};
        int depth(Account a) {
          var d = 0;
          var p = a.parentId;
          while (p != null) {
            d++;
            p = byId[p]?.parentId;
          }
          return d;
        }

        final q = _query.trim();
        final shown = rows.where((r) {
          final total = rolled[r.account.id]!;
          if (_hideEmpty && total.closing == 0 && total.debit == 0 && total.credit == 0) return false;
          if (q.isEmpty) return true;
          return r.account.nameAr.contains(q) || r.account.code.startsWith(q);
        }).toList();
        int kindTotal(String kind) => rows
            .where((r) => r.account.parentId == null && r.account.kind == kind)
            .fold(0, (s, r) => s + rolled[r.account.id]!.natural);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SummaryStrip(items: [
            for (final k in AccountKind.all)
              SummaryItem(AccountKind.label(k), formatMoney(kindTotal(k)),
                  icon: switch (k) {
                    AccountKind.asset => Icons.account_balance_wallet_outlined,
                    AccountKind.liability => Icons.call_made,
                    AccountKind.equity => Icons.person_outline,
                    AccountKind.income => Icons.trending_up,
                    _ => Icons.trending_down,
                  }),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SearchBox(onChanged: (v) => setState(() => _query = v), hint: 'بحث بالكود أو الاسم'),
              FilterChip(
                label: const Text('إخفاء الحسابات بلا حركة'),
                selected: _hideEmpty,
                onSelected: (v) => setState(() => _hideEmpty = v),
              ),
              FilledButton.icon(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => _AccountDialog(groups: rows.map((r) => r.account).where((a) => a.isGroup).toList()),
                ),
                icon: const Icon(Icons.add),
                label: const Text('حساب جديد'),
              ),
            ]),
          ),
          Expanded(
            child: DataList<AccountBalance>(
              rows: shown,
              emptyText: 'لا توجد حسابات',
              rowColor: (r) => r.account.isGroup ? AppColors.zebra : null,
              onTap: (r) => context.go('/accounting/accounts/${r.account.id}'),
              trailing: (r) => r.account.systemKey == null || r.account.systemKey!.startsWith('expense:')
                  ? IconButton(
                      tooltip: 'تعديل الاسم',
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      onPressed: () => _rename(r.account),
                    )
                  : const Tooltip(
                      message: 'حساب أساسي يستخدمه النظام',
                      child: Padding(padding: EdgeInsets.all(8), child: Icon(Icons.lock_outline, size: 16, color: AppColors.muted)),
                    ),
              columns: [
                DataListColumn('الكود', width: 90, (r) => Text(r.account.code,
                    style: TextStyle(fontWeight: r.account.isGroup ? FontWeight.w800 : FontWeight.w400))),
                DataListColumn('الحساب', flex: 4, (r) => Padding(
                      padding: EdgeInsetsDirectional.only(start: depth(r.account) * 18.0),
                      child: Row(children: [
                        Icon(r.account.isGroup ? Icons.folder_outlined : Icons.description_outlined,
                            size: 16, color: AppColors.muted),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(r.account.nameAr,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontWeight: r.account.isGroup ? FontWeight.w800 : FontWeight.w400)),
                        ),
                      ]),
                    )),
                DataListColumn('النوع', (r) => Text(AccountKind.label(r.account.kind))),
                DataListColumn('مدين', numeric: true, (r) => Text(formatMoney(rolled[r.account.id]!.debit + rolled[r.account.id]!.openingDebit))),
                DataListColumn('دائن', numeric: true, (r) => Text(formatMoney(rolled[r.account.id]!.credit + rolled[r.account.id]!.openingCredit))),
                DataListColumn('الرصيد', numeric: true, (r) {
                  final v = rolled[r.account.id]!.natural;
                  return Text(formatMoney(v),
                      style: TextStyle(fontWeight: FontWeight.w700, color: v < 0 ? AppColors.bad : null));
                }),
              ],
            ),
          ),
        ]);
      },
    );
  }

  Future<void> _rename(Account a) async {
    final c = TextEditingController(text: a.nameAr);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('تعديل اسم ${a.code}'),
        content: SizedBox(width: 360, child: TextField(controller: c, autofocus: true)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('حفظ')),
        ],
      ),
    );
    if (name == null || !mounted) return;
    await runGuarded(context, () => ref.read(ledgerServiceProvider).renameAccount(a.id, name, user: ref.read(currentUserProvider)!));
  }
}

class _AccountDialog extends ConsumerStatefulWidget {
  const _AccountDialog({required this.groups});

  final List<Account> groups;

  @override
  ConsumerState<_AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends ConsumerState<_AccountDialog> {
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _note = TextEditingController();
  int? _parent;
  bool _group = false;

  Future<void> _save() async {
    if (_parent == null) {
      await showMessage(context, 'اختر الحساب الرئيسي');
      return;
    }
    final ok = await runGuarded(context, () async {
      await ref.read(ledgerServiceProvider).addAccount(
            code: _code.text,
            name: _name.text,
            parentId: _parent!,
            isGroup: _group,
            note: _note.text,
            user: ref.read(currentUserProvider)!,
          );
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('حساب جديد'),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          DropdownButtonFormField<int>(
            initialValue: _parent,
            decoration: const InputDecoration(labelText: 'تحت الحساب الرئيسي'),
            items: [
              for (final g in widget.groups) DropdownMenuItem(value: g.id, child: Text('${g.code}  ${g.nameAr}')),
            ],
            onChanged: (v) {
              setState(() => _parent = v);
              final g = widget.groups.firstWhere((a) => a.id == v);
              if (_code.text.isEmpty) _code.text = g.code.length < 2 ? '${g.code}1' : '${g.code}0';
            },
          ),
          const SizedBox(height: 12),
          TextField(controller: _code, decoration: const InputDecoration(labelText: 'الكود')),
          const SizedBox(height: 12),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'اسم الحساب')),
          const SizedBox(height: 12),
          TextField(controller: _note, decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)')),
          const SizedBox(height: 8),
          CheckboxListTile(
            value: _group,
            onChanged: (v) => setState(() => _group = v ?? false),
            title: const Text('حساب رئيسي (يجمع حسابات تحته ولا يُقيد عليه)'),
            contentPadding: EdgeInsets.zero,
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(onPressed: _save, child: const Text('حفظ')),
      ],
    );
  }
}

// ---------------------------------------------------------------- journal

class JournalTab extends ConsumerStatefulWidget {
  const JournalTab({super.key});

  @override
  ConsumerState<JournalTab> createState() => _JournalTabState();
}

class _JournalTabState extends ConsumerState<JournalTab> {
  DayRange _range = DayRange.thisMonth();
  bool _manualOnly = false;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
        child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          DateRangeBar(value: _range, onChanged: (r) => setState(() => _range = r)),
          SearchBox(onChanged: (v) => setState(() => _query = v), hint: 'رقم القيد أو البيان', width: 220),
          FilterChip(
            label: const Text('القيود اليدوية فقط'),
            selected: _manualOnly,
            onSelected: (v) => setState(() => _manualOnly = v),
          ),
          FilledButton.icon(
            onPressed: () => showDialog<void>(context: context, builder: (_) => const ManualEntryDialog()),
            icon: const Icon(Icons.add),
            label: const Text('قيد يدوي جديد'),
          ),
        ]),
      ),
      Expanded(
        child: LedgerBuilder<List<(JournalEntry, List<(JournalLine, Account)>)>>(
          reloadKey: (_range, _manualOnly),
          load: (l) => l.entries(from: _range.from, to: _range.to, manualOnly: _manualOnly),
          builder: (context, list) {
            final q = _query.trim();
            final shown = q.isEmpty
                ? list
                : list.where((e) => e.$1.number.contains(q) || (e.$1.memo ?? '').contains(q)).toList();
            final posted = shown.where((e) => e.$1.status == 'posted');
            final total = posted.fold(0, (s, e) => s + e.$2.fold(0, (t, l) => t + l.$1.debit));
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SummaryStrip(items: [
                SummaryItem('عدد القيود', '${posted.length}', icon: Icons.numbers),
                SummaryItem('إجمالي الحركة', formatMoney(total), icon: Icons.swap_vert),
                SummaryItem('قيود يدوية', '${posted.where((e) => e.$1.source == 'manual').length}', icon: Icons.edit_note),
                SummaryItem('ملغاة', '${shown.where((e) => e.$1.status == 'void').length}', icon: Icons.block, tone: AppColors.bad),
              ]),
              Expanded(
                child: DataList<(JournalEntry, List<(JournalLine, Account)>)>(
                  rows: shown,
                  emptyText: 'لا توجد قيود في هذه الفترة',
                  rowColor: (e) => e.$1.status == 'void' ? AppColors.canvas : null,
                  onTap: (e) => showDialog<void>(context: context, builder: (_) => EntryDialog(entry: e.$1, lines: e.$2)),
                  columns: [
                    DataListColumn('التاريخ', width: 104, (e) => Text(formatDate(e.$1.date))),
                    DataListColumn('رقم القيد', width: 110, (e) => Text(e.$1.number, style: const TextStyle(fontWeight: FontWeight.w700))),
                    DataListColumn('المصدر', width: 110, (e) => e.$1.source == 'manual' ? StatusPill.warn(sourceLabel(e.$1)) : StatusPill(sourceLabel(e.$1))),
                    DataListColumn('البيان', flex: 3, (e) => Text(e.$1.memo ?? '', overflow: TextOverflow.ellipsis)),
                    DataListColumn('الحسابات', flex: 3, (e) => Text(
                          e.$2.map((l) => l.$2.nameAr).toSet().join('، '),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: AppColors.muted, fontSize: 12),
                        )),
                    DataListColumn('المبلغ', numeric: true, (e) => Text(
                          formatMoney(e.$2.fold(0, (s, l) => s + l.$1.debit)),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        )),
                    DataListColumn('الحالة', numeric: true,
                        (e) => e.$1.status == 'void' ? StatusPill.bad('ملغى') : StatusPill.good('مرحّل')),
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

/// One entry with its lines; a manual one can be voided from here.
class EntryDialog extends ConsumerWidget {
  const EntryDialog({super.key, required this.entry, required this.lines});

  final JournalEntry entry;
  final List<(JournalLine, Account)> lines;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = sourcePath(entry);
    final dr = lines.fold(0, (s, l) => s + l.$1.debit);
    final cr = lines.fold(0, (s, l) => s + l.$1.credit);
    const head = TextStyle(fontWeight: FontWeight.w700, color: AppColors.muted, fontSize: 12);
    return AlertDialog(
      title: Row(children: [
        Text('قيد ${entry.number}'),
        const SizedBox(width: 12),
        entry.status == 'void' ? StatusPill.bad('ملغى') : StatusPill.good('مرحّل'),
        const SizedBox(width: 8),
        StatusPill(sourceLabel(entry)),
      ]),
      content: SizedBox(
        width: 720,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${formatDate(entry.date)} — ${entry.memo ?? ''}'),
          const SizedBox(height: 12),
          StatementCard(children: [
            Container(
              color: AppColors.zebra,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: const Row(children: [
                Expanded(flex: 3, child: Text('الحساب', style: head)),
                Expanded(flex: 2, child: Text('البيان', style: head)),
                SizedBox(width: 120, child: Text('مدين', textAlign: TextAlign.end, style: head)),
                SizedBox(width: 120, child: Text('دائن', textAlign: TextAlign.end, style: head)),
              ]),
            ),
            for (final (l, a) in lines)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(children: [
                  Expanded(
                    flex: 3,
                    child: InkWell(
                      onTap: () {
                        Navigator.pop(context);
                        context.go('/accounting/accounts/${a.id}');
                      },
                      child: Padding(
                        padding: EdgeInsetsDirectional.only(start: l.credit > 0 ? 24 : 0),
                        child: Text('${a.code}  ${a.nameAr}', style: const TextStyle(color: AppColors.info)),
                      ),
                    ),
                  ),
                  Expanded(flex: 2, child: Text(l.memo ?? '', style: const TextStyle(fontSize: 12, color: AppColors.muted))),
                  SizedBox(width: 120, child: Text(l.debit == 0 ? '' : formatMoney(l.debit), textAlign: TextAlign.end)),
                  SizedBox(width: 120, child: Text(l.credit == 0 ? '' : formatMoney(l.credit), textAlign: TextAlign.end)),
                ]),
              ),
            Container(
              color: AppColors.canvas,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(children: [
                const Expanded(flex: 5, child: Text('الإجمالي', style: TextStyle(fontWeight: FontWeight.w800))),
                SizedBox(width: 120, child: Text(formatMoney(dr), textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w800))),
                SizedBox(width: 120, child: Text(formatMoney(cr), textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w800))),
              ]),
            ),
          ]),
          if (entry.source == 'auto')
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text('هذا القيد يُنشأ تلقائياً من المستند ويتغير معه؛ يُلغى بإلغاء المستند.',
                  style: TextStyle(color: AppColors.muted, fontSize: 12)),
            ),
        ]),
      ),
      actions: [
        if (path != null)
          OutlinedButton.icon(
            onPressed: () {
              Navigator.pop(context);
              context.go(path);
            },
            icon: const Icon(Icons.open_in_new),
            label: const Text('فتح المستند'),
          ),
        if (entry.source == 'manual' && entry.status == 'posted')
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: AppColors.bad),
            onPressed: () async {
              final reason = await askReason(context, title: 'إلغاء القيد ${entry.number}');
              if (reason == null || !context.mounted) return;
              final ok = await runGuarded(context, () async {
                await ref.read(ledgerServiceProvider).voidManual(entry.id, reason: reason, user: ref.read(currentUserProvider)!);
                return true;
              });
              if (ok == true && context.mounted) {
                ref.read(ledgerRevisionProvider.notifier).state++;
                Navigator.pop(context);
              }
            },
            icon: const Icon(Icons.block),
            label: const Text('إلغاء القيد'),
          ),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق')),
      ],
    );
  }
}

class _LineRow {
  int? accountId;
  final debit = TextEditingController();
  final credit = TextEditingController();
  final memo = TextEditingController();
}

/// A manual entry: capital, loans, owner's drawings, fixed assets,
/// depreciation, bank charges, corrections.
class ManualEntryDialog extends ConsumerStatefulWidget {
  const ManualEntryDialog({super.key});

  @override
  ConsumerState<ManualEntryDialog> createState() => _ManualEntryDialogState();
}

class _ManualEntryDialogState extends ConsumerState<ManualEntryDialog> {
  final _memo = TextEditingController();
  DateTime _date = DateTime.now();
  final _lines = [_LineRow(), _LineRow()];
  List<Account>? _accounts;

  @override
  void initState() {
    super.initState();
    ref.read(ledgerServiceProvider).accounts().then((a) {
      if (mounted) {
        setState(() => _accounts = a
            .where((x) => !x.isGroup && x.isActive && !LedgerService.documentOnlyKeys.contains(x.systemKey))
            .toList());
      }
    });
  }

  int _sum(TextEditingController Function(_LineRow) f) => _lines.fold(0, (s, l) => s + (parseMoney(f(l).text) ?? 0));

  void _template(String a, String b, String memo) {
    final byKey = {for (final x in _accounts!) x.systemKey ?? x.code: x.id};
    setState(() {
      _memo.text = memo;
      _lines
        ..clear()
        ..addAll([_LineRow()..accountId = byKey[a], _LineRow()..accountId = byKey[b]]);
    });
  }

  Future<void> _save() async {
    final lines = [
      for (final l in _lines)
        if (l.accountId != null)
          ManualLine(
            accountId: l.accountId!,
            debit: parseMoney(l.debit.text) ?? 0,
            credit: parseMoney(l.credit.text) ?? 0,
            memo: l.memo.text.trim().isEmpty ? null : l.memo.text.trim(),
          ),
    ];
    final ok = await runGuarded(context, () async {
      await ref.read(ledgerServiceProvider).addManual(
            date: _date,
            memo: _memo.text,
            lines: lines,
            user: ref.read(currentUserProvider)!,
          );
      return true;
    });
    if (ok == true && mounted) {
      ref.read(ledgerRevisionProvider.notifier).state++;
      Navigator.pop(context);
      showToast(context, 'تم ترحيل القيد');
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = _accounts;
    final dr = _sum((l) => l.debit);
    final cr = _sum((l) => l.credit);
    return AlertDialog(
      title: const Text('قيد يدوي جديد'),
      content: SizedBox(
        width: 860,
        child: accounts == null
            ? const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Wrap(spacing: 8, runSpacing: 6, children: [
                    const Text('نماذج سريعة:', style: TextStyle(color: AppColors.muted)),
                    ActionChip(label: const Text('رصيد افتتاحي للخزنة'), onPressed: () => _template('cash', 'opening', 'رصيد الخزنة أول المدة')),
                    ActionChip(label: const Text('رصيد افتتاحي للبنك'), onPressed: () => _template('bank', 'opening', 'رصيد البنك أول المدة')),
                    ActionChip(label: const Text('إيداع رأس مال'), onPressed: () => _template('cash', 'capital', 'إيداع رأس مال')),
                    ActionChip(label: const Text('مسحوبات المالك'), onPressed: () => _template('drawings', 'cash', 'مسحوبات شخصية')),
                    ActionChip(label: const Text('إيداع نقدية بالبنك'), onPressed: () => _template('bank', 'cash', 'إيداع بالبنك')),
                    ActionChip(label: const Text('سحب من البنك'), onPressed: () => _template('cash', 'bank', 'سحب من البنك')),
                    ActionChip(label: const Text('شراء أصل ثابت'), onPressed: () => _template('1201', 'cash', 'شراء أثاث للمعرض')),
                    ActionChip(label: const Text('إهلاك'), onPressed: () => _template('5301', '1209', 'إهلاك الفترة')),
                    ActionChip(label: const Text('مصروفات بنكية'), onPressed: () => _template('5302', 'bank', 'مصروفات بنكية')),
                  ]),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(child: TextField(controller: _memo, decoration: const InputDecoration(labelText: 'بيان القيد'))),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final d = await showDatePicker(
                            context: context, firstDate: DateTime(2000), lastDate: DateTime(2100), initialDate: _date);
                        if (d != null) setState(() => _date = DateTime(d.year, d.month, d.day, 12));
                      },
                      icon: const Icon(Icons.event),
                      label: Text(formatDate(_date)),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  for (var i = 0; i < _lines.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(children: [
                        Expanded(
                          flex: 4,
                          child: DropdownButtonFormField<int>(
                            key: ValueKey(('acc', i, _lines[i].accountId)),
                            initialValue: _lines[i].accountId,
                            isExpanded: true,
                            decoration: const InputDecoration(labelText: 'الحساب', isDense: true),
                            items: [
                              for (final a in accounts)
                                DropdownMenuItem(value: a.id, child: Text('${a.code}  ${a.nameAr}', overflow: TextOverflow.ellipsis)),
                            ],
                            onChanged: (v) => setState(() => _lines[i].accountId = v),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(flex: 2, child: MoneyField(controller: _lines[i].debit, label: 'مدين', dense: true, onChanged: (_) => setState(() {}))),
                        const SizedBox(width: 8),
                        Expanded(flex: 2, child: MoneyField(controller: _lines[i].credit, label: 'دائن', dense: true, onChanged: (_) => setState(() {}))),
                        const SizedBox(width: 8),
                        Expanded(flex: 3, child: TextField(controller: _lines[i].memo, decoration: const InputDecoration(labelText: 'بيان السطر', isDense: true))),
                        IconButton(
                          tooltip: 'حذف السطر',
                          onPressed: _lines.length <= 2 ? null : () => setState(() => _lines.removeAt(i)),
                          icon: const Icon(Icons.close),
                        ),
                      ]),
                    ),
                  Row(children: [
                    TextButton.icon(
                      onPressed: () => setState(() => _lines.add(_LineRow())),
                      icon: const Icon(Icons.add),
                      label: const Text('سطر'),
                    ),
                    const Spacer(),
                    Text('مدين ${formatMoney(dr)}   دائن ${formatMoney(cr)}   ',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    dr == cr && dr > 0 ? StatusPill.good('متوازن') : StatusPill.bad('الفرق ${formatMoney(dr - cr)}'),
                  ]),
                  const SizedBox(height: 8),
                  const Text(
                    'العملاء والموردون والمخزون والشيكات والدفعات المقدمة تتحرك من مستنداتها فقط، لذلك لا تظهر هنا.',
                    style: TextStyle(color: AppColors.muted, fontSize: 12),
                  ),
                ]),
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(onPressed: dr == cr && dr > 0 ? _save : null, child: const Text('ترحيل القيد')),
      ],
    );
  }
}

// ---------------------------------------------------------- account ledger

class AccountLedgerPage extends ConsumerStatefulWidget {
  const AccountLedgerPage({super.key, required this.accountId});

  final int accountId;

  @override
  ConsumerState<AccountLedgerPage> createState() => _AccountLedgerPageState();
}

class _AccountLedgerPageState extends ConsumerState<AccountLedgerPage> {
  DayRange _range = DayRange.thisYear();

  @override
  Widget build(BuildContext context) {
    return LedgerBuilder<(Account, int, List<LedgerLine>)>(
      reloadKey: _range,
      load: (l) async {
        final a = (await l.accounts()).firstWhere((x) => x.id == widget.accountId);
        final (opening, lines) = await l.ledger(widget.accountId, from: _range.from, to: _range.to);
        return (a, opening, lines);
      },
      builder: (context, data) {
        final (account, opening, lines) = data;
        final dr = lines.fold(0, (s, l) => s + l.line.debit);
        final cr = lines.fold(0, (s, l) => s + l.line.credit);
        final closing = lines.isEmpty ? opening : lines.first.balance;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Row(children: [
              TextButton.icon(
                onPressed: () => context.go('/accounting?tab=accounts'),
                icon: const Icon(Icons.arrow_forward, size: 18),
                label: const Text('دليل الحسابات'),
              ),
            ]),
          ),
          PageHeader(title: 'دفتر الأستاذ: ${account.code} ${account.nameAr}', actions: [
            StatusPill(AccountKind.label(account.kind)),
            OutlinedButton.icon(
              onPressed: () => exportTable(
                context,
                ref,
                ReportTable(
                  title: 'دفتر أستاذ ${account.nameAr}',
                  columns: const [
                    ReportColumn('التاريخ', ColumnType.date),
                    ReportColumn('القيد', ColumnType.text),
                    ReportColumn('البيان', ColumnType.text),
                    ReportColumn('الطرف', ColumnType.text),
                    ReportColumn('مدين', ColumnType.money, sum: true),
                    ReportColumn('دائن', ColumnType.money, sum: true),
                    ReportColumn('الرصيد', ColumnType.money),
                  ],
                  rows: [
                    for (final l in lines.reversed)
                      [l.entry.date, l.entry.number, l.line.memo ?? l.entry.memo, l.partyName, l.line.debit, l.line.credit, l.balance],
                  ],
                  subtitle: 'رصيد أول الفترة: ${formatMoney(opening)}',
                ),
                from: _range.from,
                to: _range.to,
              ),
              icon: const Icon(Icons.table_view),
              label: const Text('تصدير Excel'),
            ),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: DateRangeBar(value: _range, onChanged: (r) => setState(() => _range = r)),
          ),
          SummaryStrip(items: [
            SummaryItem('رصيد أول الفترة', formatMoney(opening), icon: Icons.first_page),
            SummaryItem('مدين', formatMoney(dr), icon: Icons.add),
            SummaryItem('دائن', formatMoney(cr), icon: Icons.remove),
            SummaryItem('الرصيد الختامي', formatMoney(closing), icon: Icons.account_balance, tone: closing < 0 ? AppColors.bad : AppColors.good),
          ]),
          Expanded(
            child: DataList<LedgerLine>(
              rows: lines,
              emptyText: 'لا حركة على هذا الحساب في الفترة',
              onTap: (l) async {
                final entries = await ref.read(ledgerServiceProvider).entries(limit: 1000000);
                final e = entries.where((x) => x.$1.id == l.entry.id).firstOrNull;
                if (e != null && context.mounted) {
                  await showDialog<void>(context: context, builder: (_) => EntryDialog(entry: e.$1, lines: e.$2));
                }
              },
              columns: [
                DataListColumn('التاريخ', width: 104, (l) => Text(formatDate(l.entry.date))),
                DataListColumn('القيد', (l) => Text(l.entry.number, style: const TextStyle(fontWeight: FontWeight.w700))),
                DataListColumn('المصدر', (l) => Text(sourceLabel(l.entry))),
                DataListColumn('البيان', flex: 3, (l) => Text(l.line.memo ?? l.entry.memo ?? '', overflow: TextOverflow.ellipsis)),
                DataListColumn('الطرف', flex: 2, (l) => Text(l.partyName ?? '')),
                DataListColumn('مدين', numeric: true, (l) => Text(l.line.debit == 0 ? '' : formatMoney(l.line.debit))),
                DataListColumn('دائن', numeric: true, (l) => Text(l.line.credit == 0 ? '' : formatMoney(l.line.credit))),
                DataListColumn('الرصيد', numeric: true,
                    (l) => Text(formatMoney(l.balance), style: TextStyle(fontWeight: FontWeight.w700, color: l.balance < 0 ? AppColors.bad : null))),
              ],
            ),
          ),
        ]);
      },
    );
  }
}
