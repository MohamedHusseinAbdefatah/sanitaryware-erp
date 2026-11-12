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

  void _reload() => setState(() => _rules = ref.read(sellingPolicyServiceProvider).rows());

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
                      trailing: Switch(
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
