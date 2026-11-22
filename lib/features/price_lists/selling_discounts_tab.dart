part of 'price_lists_screen.dart';

final _customerCategoriesProvider = customerCategoriesProvider;

/// Selling discounts: each customer category has its usual discount; a
/// special discount can give a category more (or less) on one brand, product
/// category or product. Not tied to any price list version.
class _SellingDiscountsTab extends ConsumerStatefulWidget {
  const _SellingDiscountsTab();

  @override
  ConsumerState<_SellingDiscountsTab> createState() => _SellingDiscountsTabState();
}

class _SellingDiscountsTabState extends ConsumerState<_SellingDiscountsTab> {
  late Future<List<SellingPolicyRow>> _rules = ref.read(sellingPolicyServiceProvider).rows();
  late Future<Map<(int, int), SellingPolicy>> _grid = ref.read(sellingPolicyServiceProvider).brandGrid();

  void _reload() => setState(() {
        _rules = ref.read(sellingPolicyServiceProvider).rows();
        _grid = ref.read(sellingPolicyServiceProvider).brandGrid();
      });

  /// Owner: the discount of one customer category on one brand.
  Future<void> _editCell(CustomerCategory c, Brand b, SellingPolicy? rule) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _BrandCellDialog(category: c, brand: b, rule: rule),
    );
    if (saved == true) _reload();
  }

  Future<void> _correctRule(SellingPolicy rule) async {
    final saved = await showDialog<bool>(context: context, builder: (_) => _CorrectSellingDialog(rule: rule));
    if (saved == true) _reload();
  }

  Widget _brandGrid(List<CustomerCategory> categories, ThemeData theme) {
    final brands = ref.watch(_brandsProvider).valueOrNull ?? const <Brand>[];
    final active = categories.where((c) => c.isActive).toList();
    if (brands.isEmpty || active.isEmpty) {
      return const Padding(padding: EdgeInsets.all(16), child: Text('أضف الماركات وفئات العملاء أولاً.'));
    }
    return FutureBuilder<Map<(int, int), SellingPolicy>>(
      future: _grid,
      builder: (context, snap) {
        if (!snap.hasData) return const LinearProgressIndicator();
        final grid = snap.data!;
        return Card(
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowColor: WidgetStatePropertyAll(theme.colorScheme.surfaceContainerHighest),
                columnSpacing: 24,
                columns: [
                  const DataColumn(label: Text('الماركة', style: TextStyle(fontWeight: FontWeight.bold))),
                  for (final c in active)
                    DataColumn(
                      label: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Text(c.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                        Text('المعتاد ${_percent(c.discountBp)}', style: theme.textTheme.bodySmall),
                      ]),
                    ),
                ],
                rows: [
                  for (final b in brands)
                    DataRow(cells: [
                      DataCell(Text(b.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                      for (final c in active)
                        DataCell(
                          Builder(builder: (context) {
                            final rule = grid[(c.id, b.id)];
                            return Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: rule == null ? null : AppColors.goodBg,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                rule == null ? '${_percent(c.discountBp)} (المعتاد)' : _percent(rule.discountBp),
                                style: TextStyle(
                                  fontWeight: rule == null ? FontWeight.normal : FontWeight.w800,
                                  color: rule == null ? AppColors.muted : AppColors.good,
                                ),
                              ),
                            );
                          }),
                          showEditIcon: true,
                          onTap: () => _editCell(c, b, grid[(c.id, b.id)]),
                        ),
                    ]),
                ],
              ),
            ),
        );
      },
    );
  }

  Future<void> _editCategory([CustomerCategory? c]) async {
    final saved = await showDialog<bool>(context: context, builder: (_) => _CategoryDialog(existing: c));
    if (saved == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(_customerCategoriesProvider).valueOrNull ?? const <CustomerCategory>[];
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'سعر البيع = سعر القائمة ناقص خصم فئة العميل، ثم خصم العميل الخاص (من بطاقته) إن وجد. '
          'الكاشير يستطيع إضافة حتى ${_percent(cashierMaxExtraBp)} فوق ذلك، وما زاد يحتاج المدير. '
          'هذه الخصومات لا ترتبط بإصدار قائمة أسعار، فتبقى كما هي مع كل قائمة جديدة.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: Text('فئات العملاء', style: theme.textTheme.titleMedium)),
            FilledButton.icon(
              onPressed: () => _editCategory(),
              icon: const Icon(Icons.add),
              label: const Text('فئة جديدة'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text('كل عميل له فئة واحدة تختارها في بطاقته. البيع بدون عميل يأخذ الفئة الأولى (قطاعي).'),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              for (final c in categories)
                ListTile(
                  leading: const Icon(Icons.groups_outlined),
                  title: Text(c.name, style: TextStyle(color: c.isActive ? null : theme.disabledColor)),
                  subtitle: Text(c.isActive ? 'الخصم المعتاد ${_percent(c.discountBp)}' : 'موقوفة'),
                  trailing: TextButton.icon(
                    onPressed: () => _editCategory(c),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('تعديل'),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text('خصم البيع حسب الماركة وفئة العميل', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text('لكل ماركة خصمها مع كل فئة عملاء (مثال: Duravit 10% وIdeal Standard 5% للقطاعي). '
            'الخانة الرمادية تعني أن الماركة تأخذ خصم الفئة المعتاد. اضغط أي خانة لتعديلها. '
            'الفواتير المحفوظة تبقى بالخصم الذي بيعت به.'),
        const SizedBox(height: 8),
        _brandGrid(categories, theme),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(child: Text('خصومات خاصة (اختياري)', style: theme.textTheme.titleMedium)),
            OutlinedButton.icon(
              onPressed: categories.isEmpty
                  ? null
                  : () async {
                      final added =
                          await showDialog<bool>(context: context, builder: (_) => const _SpecialDiscountDialog());
                      if (added == true) _reload();
                    },
              icon: const Icon(Icons.add),
              label: const Text('خصم خاص'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text('مثال: المهندسين 15% على Ideal Standard بدلاً من خصمهم المعتاد. '
            'الأولوية: الصنف، ثم التصنيف، ثم كل الأصناف؛ وخصم الماركة قبل خصم كل الماركات.'),
        const SizedBox(height: 8),
        FutureBuilder<List<SellingPolicyRow>>(
          future: _rules,
          builder: (context, snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final rows = snap.data!;
            if (rows.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Text('لا توجد خصومات خاصة. يُطبق الخصم المعتاد لكل فئة.'),
              );
            }
            return Card(
              child: Column(
                children: [
                  for (final r in rows)
                    ListTile(
                      title: Text('${r.customerCategoryName} · ${r.brandName} · '
                          '${PolicyScope.label(r.policy.scope)}${r.targetName.isEmpty ? '' : ' — ${r.targetName}'}'),
                      subtitle: Text('خصم ${_percent(r.policy.discountBp)}'
                          '${r.policy.maxDiscountBp == null ? '' : ' · أقصى خصم ${_percent(r.policy.maxDiscountBp!)}'}'
                          '${r.policy.minMarginBp == null ? '' : ' · أدنى هامش ${_percent(r.policy.minMarginBp!)}'}'
                          '${r.policy.note == null ? '' : ' · ${r.policy.note}'}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          tooltip: 'تعديل',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => _correctRule(r.policy),
                        ),
                        Switch(
                          value: r.policy.isActive,
                          onChanged: (v) async {
                            final ok = await runGuarded(context, () async {
                              await ref
                                  .read(sellingPolicyServiceProvider)
                                  .setActive(r.policy.id, v, user: ref.read(currentUserProvider)!);
                              return true;
                            });
                            if (ok == true) _reload();
                          },
                        ),
                      ]),
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

class _CategoryDialog extends ConsumerStatefulWidget {
  const _CategoryDialog({this.existing});

  final CustomerCategory? existing;

  @override
  ConsumerState<_CategoryDialog> createState() => _CategoryDialogState();
}

class _CategoryDialogState extends ConsumerState<_CategoryDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _discount = TextEditingController(
      text: widget.existing == null ? '' : _percent(widget.existing!.discountBp).replaceAll('%', ''));
  late bool _active = widget.existing?.isActive ?? true;

  @override
  void dispose() {
    _name.dispose();
    _discount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final bp = _discount.text.trim().isEmpty ? 0 : _bp(_discount.text);
    if (bp == null) {
      await showMessage(context, 'النسبة يجب أن تكون بين 0 و 100');
      return;
    }
    final ok = await runGuarded(context, () async {
      await ref.read(sellingPolicyServiceProvider).saveCategory(
            CustomerCategoryInput(name: _name.text, discountBp: bp, isActive: _active),
            id: widget.existing?.id,
            user: ref.read(currentUserProvider)!,
          );
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'فئة عملاء جديدة' : 'تعديل الفئة'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              autofocus: widget.existing == null,
              decoration: const InputDecoration(labelText: 'اسم الفئة (مثال: مهندسين، مشروعات)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _discount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'الخصم المعتاد %', helperText: 'على سعر القائمة لكل الأصناف'),
            ),
            if (widget.existing != null && widget.existing!.id != walkInCategoryId) ...[
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('الفئة مفعّلة'),
                value: _active,
                onChanged: (v) => setState(() => _active = v),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(onPressed: _save, child: const Text('حفظ')),
      ],
    );
  }
}

class _SpecialDiscountDialog extends ConsumerStatefulWidget {
  const _SpecialDiscountDialog();

  @override
  ConsumerState<_SpecialDiscountDialog> createState() => _SpecialDiscountDialogState();
}

class _SpecialDiscountDialogState extends ConsumerState<_SpecialDiscountDialog> {
  int? _customerCategoryId, _brandId, _categoryId;
  ProductRow? _product;
  String _scope = PolicyScope.all;
  final _discount = TextEditingController();
  final _max = TextEditingController();
  final _margin = TextEditingController();
  final _note = TextEditingController();

  @override
  void dispose() {
    for (final c in [_discount, _max, _margin, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_customerCategoryId == null) {
      await showMessage(context, 'اختر فئة العملاء');
      return;
    }
    final d = _discount.text.trim().isEmpty ? null : _bp(_discount.text);
    final max = _max.text.trim().isEmpty ? null : _bp(_max.text);
    final margin = _margin.text.trim().isEmpty ? null : _bp(_margin.text);
    if (d == null || (_max.text.trim().isNotEmpty && max == null) || (_margin.text.trim().isNotEmpty && margin == null)) {
      await showMessage(context, 'اكتب نسبة الخصم، والنسب بين 0 و 100');
      return;
    }
    final ok = await runGuarded(context, () async {
      await ref.read(sellingPolicyServiceProvider).add(
            SellingPolicyInput(
              customerCategoryId: _customerCategoryId!,
              brandId: _brandId,
              scope: _scope,
              categoryId: _categoryId,
              productId: _product?.product.id,
              discountBp: d,
              maxDiscountBp: max,
              minMarginBp: margin,
              note: _note.text,
            ),
            user: ref.read(currentUserProvider)!,
          );
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final groups = (ref.watch(_customerCategoriesProvider).valueOrNull ?? const <CustomerCategory>[])
        .where((c) => c.isActive)
        .toList();
    final brands = ref.watch(_brandsProvider).valueOrNull ?? const <Brand>[];
    final catalog = ref.watch(catalogServiceProvider);
    return AlertDialog(
      title: const Text('خصم بيع خاص'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<int>(
                isExpanded: true,
                initialValue: _customerCategoryId,
                decoration: const InputDecoration(labelText: 'فئة العملاء'),
                items: [for (final c in groups) DropdownMenuItem(value: c.id, child: Text(c.name))],
                onChanged: (v) => setState(() => _customerCategoryId = v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int?>(
                isExpanded: true,
                initialValue: _brandId,
                decoration: const InputDecoration(labelText: 'الماركة'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('كل الماركات')),
                  for (final b in brands) DropdownMenuItem(value: b.id, child: Text(b.name)),
                ],
                onChanged: (v) => setState(() => _brandId = v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: _scope,
                decoration: const InputDecoration(labelText: 'الأصناف'),
                items: [
                  for (final s in PolicyScope.values) DropdownMenuItem(value: s, child: Text(PolicyScope.label(s))),
                ],
                onChanged: (v) => setState(() {
                  _scope = v ?? PolicyScope.all;
                  _categoryId = null;
                  _product = null;
                }),
              ),
              if (_scope == PolicyScope.category) ...[
                const SizedBox(height: 12),
                StreamBuilder<List<Category>>(
                  stream: catalog.watchAllCategories(),
                  builder: (context, snap) => DropdownButtonFormField<int>(
                    isExpanded: true,
                    initialValue: _categoryId,
                    decoration: const InputDecoration(labelText: 'التصنيف'),
                    items: [
                      for (final c in snap.data ?? const <Category>[]) DropdownMenuItem(value: c.id, child: Text(c.nameAr)),
                    ],
                    onChanged: (v) => setState(() => _categoryId = v),
                  ),
                ),
              ],
              if (_scope == PolicyScope.product) ...[
                const SizedBox(height: 12),
                if (_product != null) Text('الصنف: ${_product!.product.code} — ${_product!.product.nameAr}'),
                ProductSearchField(autofocus: false, onSelected: (r) => setState(() => _product = r)),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _discount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'الخصم %', helperText: 'يحل محل الخصم المعتاد للفئة'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _max,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'أقصى خصم بدون موافقة المدير % (اختياري)'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _margin,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'أدنى هامش ربح بدون موافقة % (اختياري)'),
              ),
              const SizedBox(height: 12),
              TextField(controller: _note, decoration: const InputDecoration(labelText: 'ملاحظة')),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(onPressed: _save, child: const Text('حفظ')),
      ],
    );
  }
}

/// One brand and customer category: its own discount, or the category's.
class _BrandCellDialog extends ConsumerStatefulWidget {
  const _BrandCellDialog({required this.category, required this.brand, this.rule});

  final CustomerCategory category;
  final Brand brand;
  final SellingPolicy? rule;

  @override
  ConsumerState<_BrandCellDialog> createState() => _BrandCellDialogState();
}

class _BrandCellDialogState extends ConsumerState<_BrandCellDialog> {
  late final _percentText =
      TextEditingController(text: widget.rule == null ? '' : '${widget.rule!.discountBp / 100}');
  final _reason = TextEditingController();

  @override
  void dispose() {
    _percentText.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save({bool clear = false}) async {
    int? bp;
    if (!clear) {
      bp = _bp(_percentText.text);
      if (bp == null) {
        await showMessage(context, 'النسبة يجب أن تكون رقماً بين 0 و 100');
        return;
      }
    }
    final ok = await runGuarded(context, () async {
      await ref.read(sellingPolicyServiceProvider).setBrandDiscount(
            customerCategoryId: widget.category.id,
            brandId: widget.brand.id,
            discountBp: bp,
            reason: _reason.text,
            user: ref.read(currentUserProvider)!,
          );
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.brand.name} — ${widget.category.name}'),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.rule == null
              ? 'الآن: خصم الفئة المعتاد ${_percent(widget.category.discountBp)}'
              : 'الآن: ${_percent(widget.rule!.discountBp)} لهذه الماركة'),
          const SizedBox(height: 12),
          TextField(
            controller: _percentText,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'خصم البيع لهذه الماركة %', suffixText: '%'),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 8),
          TextField(controller: _reason, decoration: const InputDecoration(labelText: 'سبب التغيير (اختياري)')),
        ]),
      ),
      actions: [
        if (widget.rule != null)
          TextButton(onPressed: () => _save(clear: true), child: const Text('رجوع لخصم الفئة المعتاد')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(onPressed: _save, child: const Text('حفظ')),
      ],
    );
  }
}

/// Owner: corrects a saved special selling discount.
class _CorrectSellingDialog extends ConsumerStatefulWidget {
  const _CorrectSellingDialog({required this.rule});

  final SellingPolicy rule;

  @override
  ConsumerState<_CorrectSellingDialog> createState() => _CorrectSellingDialogState();
}

class _CorrectSellingDialogState extends ConsumerState<_CorrectSellingDialog> {
  late final _discount = TextEditingController(text: '${widget.rule.discountBp / 100}');
  late final _max =
      TextEditingController(text: widget.rule.maxDiscountBp == null ? '' : '${widget.rule.maxDiscountBp! / 100}');
  late final _margin =
      TextEditingController(text: widget.rule.minMarginBp == null ? '' : '${widget.rule.minMarginBp! / 100}');
  late final _note = TextEditingController(text: widget.rule.note ?? '');
  final _reason = TextEditingController();

  @override
  void dispose() {
    for (final c in [_discount, _max, _margin, _note, _reason]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final d = _bp(_discount.text);
    final max = _max.text.trim().isEmpty ? null : _bp(_max.text);
    final margin = _margin.text.trim().isEmpty ? null : _bp(_margin.text);
    if (d == null || (_max.text.trim().isNotEmpty && max == null) || (_margin.text.trim().isNotEmpty && margin == null)) {
      await showMessage(context, 'النسب يجب أن تكون أرقاماً بين 0 و 100');
      return;
    }
    final ok = await runGuarded(context, () async {
      await ref.read(sellingPolicyServiceProvider).correct(
            widget.rule.id,
            discountBp: d,
            maxDiscountBp: max,
            minMarginBp: margin,
            validFrom: widget.rule.validFrom,
            validTo: widget.rule.validTo,
            note: _note.text,
            reason: _reason.text,
            user: ref.read(currentUserProvider)!,
          );
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('تعديل خصم بيع'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: _discount, decoration: const InputDecoration(labelText: 'الخصم %')),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(controller: _max, decoration: const InputDecoration(labelText: 'أقصى خصم % (اختياري)'))),
            const SizedBox(width: 12),
            Expanded(child: TextField(controller: _margin, decoration: const InputDecoration(labelText: 'أدنى هامش % (اختياري)'))),
          ]),
          const SizedBox(height: 8),
          TextField(controller: _note, decoration: const InputDecoration(labelText: 'ملاحظة')),
          const SizedBox(height: 8),
          TextField(controller: _reason, decoration: const InputDecoration(labelText: 'سبب التعديل (اختياري)')),
          const SizedBox(height: 12),
          const InfoNote('فواتير البيع المحفوظة تبقى بالخصم الذي بيعت به.'),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(onPressed: _save, child: const Text('حفظ التعديل')),
      ],
    );
  }
}
