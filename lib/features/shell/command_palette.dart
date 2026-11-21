import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/db/database.dart';
import '../../core/providers.dart';
import '../../core/search_text.dart';
import '../../core/services/global_search_service.dart';
import '../../core/theme.dart';
import 'sections.dart';

/// A page that can be opened from the quick search, besides the sidebar
/// sections: the "new" screens and the pages under a section.
class _Page {
  const _Page(this.path, this.title, this.icon, {this.perm, this.keywords = ''});

  final String path;
  final String title;
  final IconData icon;
  final Perm? perm;
  final String keywords;
}

const _subPages = <_Page>[
  _Page('/sales/new', 'بيع جديد', Icons.point_of_sale, perm: Perm.sell, keywords: 'فاتورة بيع كاشير'),
  _Page('/sales/orders', 'أوامر البيع وعروض الأسعار', Icons.request_quote_outlined, keywords: 'عرض سعر'),
  _Page('/sales/deliveries', 'التوصيلات', Icons.local_shipping_outlined, keywords: 'توصيل تسليم'),
  _Page('/customers/leads', 'العملاء المحتملون', Icons.person_search_outlined, keywords: 'فرص'),
  _Page('/purchases/new', 'فاتورة شراء جديدة', Icons.add_shopping_cart, perm: Perm.purchase),
  _Page('/purchases/orders', 'أوامر الشراء', Icons.assignment_outlined, perm: Perm.purchase),
  _Page('/returns/new', 'مرتجع جديد', Icons.assignment_return_outlined),
  _Page('/projects/calendar', 'الخطة الأسبوعية والشهرية', Icons.calendar_view_week_outlined, keywords: 'مهام مواعيد'),
];

/// The pages [user] may open, sidebar sections first.
List<(String, String, IconData)> pagesFor(User user) {
  bool sectionAllows(String path) {
    final s = appSections.where((s) => path == s.path || path.startsWith('${s.path}/')).firstOrNull;
    return s != null && s.allows(user);
  }

  return [
    for (final s in appSections)
      if (s.allows(user)) (s.path, s.title, s.icon),
    for (final p in _subPages)
      if (sectionAllows(p.path) && (p.perm == null || user.can(p.perm!))) (p.path, p.title, p.icon),
  ];
}

String _keywordsOf(String path) => _subPages.where((p) => p.path == path).firstOrNull?.keywords ?? '';

/// Which kinds of record [user] may open from the search.
Set<SearchKind> searchableFor(User user) {
  bool open(String path) => appSections.any((s) => s.path == path && s.allows(user));
  return {
    if (open('/products')) SearchKind.product,
    if (open('/customers')) SearchKind.customer,
    if (open('/suppliers')) SearchKind.supplier,
    if (open('/sales')) SearchKind.sale,
    if (open('/purchases')) SearchKind.purchase,
    if (open('/projects')) SearchKind.project,
  };
}

final globalSearchServiceProvider =
    Provider<GlobalSearchService>((ref) => GlobalSearchService(ref.watch(databaseProvider)));

/// Opens the quick search over the current page.
Future<void> showCommandPalette(BuildContext context) {
  final router = GoRouter.of(context);
  return showDialog<void>(
    context: context,
    barrierColor: const Color(0x660A2F34),
    builder: (_) => CommandPalette(onOpen: router.go),
  );
}

class _Entry {
  const _Entry(this.title, this.subtitle, this.icon, this.path, this.group);

  final String title;
  final String subtitle;
  final IconData icon;
  final String path;
  final String group;
}

/// Type to find a page or a record; arrows move, Enter opens, Esc closes.
class CommandPalette extends ConsumerStatefulWidget {
  const CommandPalette({super.key, required this.onOpen});

  final ValueChanged<String> onOpen;

  @override
  ConsumerState<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends ConsumerState<CommandPalette> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;
  List<_Entry> _records = const [];
  bool _searching = false;
  int _index = 0;
  int _generation = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<_Entry> _pages(User user) {
    final q = _controller.text.trim();
    return [
      for (final (path, title, icon) in pagesFor(user))
        if (q.isEmpty || matchesSearch(q, [title, _keywordsOf(path)])) _Entry(title, 'صفحة', icon, path, 'الصفحات'),
    ];
  }

  void _changed(String _) {
    setState(() => _index = 0);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), _search);
  }

  Future<void> _search() async {
    final user = ref.read(currentUserProvider);
    final q = _controller.text.trim();
    if (user == null || q.isEmpty) {
      if (mounted) setState(() => _records = const []);
      return;
    }
    final generation = ++_generation;
    setState(() => _searching = true);
    try {
      final hits = await ref.read(globalSearchServiceProvider).search(q, allowed: searchableFor(user));
      if (!mounted || generation != _generation) return;
      setState(() => _records = [for (final h in hits) _entryOf(h)]);
    } finally {
      if (mounted && generation == _generation) setState(() => _searching = false);
    }
  }

  static _Entry _entryOf(SearchHit h) => switch (h.kind) {
        SearchKind.product => _Entry(h.title, h.subtitle, Icons.inventory_2_outlined, '/products/${h.id}', 'الأصناف'),
        SearchKind.customer => _Entry(h.title, h.subtitle, Icons.person_outline, '/customers/${h.id}', 'العملاء'),
        SearchKind.supplier => _Entry(h.title, h.subtitle, Icons.local_shipping_outlined, '/suppliers/${h.id}', 'الموردون'),
        SearchKind.sale => _Entry(h.title, h.subtitle, Icons.receipt_long_outlined, '/sales/${h.id}', 'فواتير البيع'),
        SearchKind.purchase => _Entry(h.title, h.subtitle, Icons.shopping_cart_outlined, '/purchases/${h.id}', 'فواتير الشراء'),
        SearchKind.project => _Entry(h.title, h.subtitle, Icons.apartment_outlined, '/projects/${h.id}', 'المشروعات'),
      };

  void _open(_Entry e) {
    Navigator.of(context).pop();
    widget.onOpen(e.path);
  }

  void _move(int by, int count) {
    if (count == 0) return;
    setState(() => _index = (_index + by) % count); // wraps round both ways
    // Keep the chosen row in view (rows are 52 high, headings 30).
    if (_scroll.hasClients) {
      final target = (_index * 52.0) - 120;
      _scroll.animateTo(target.clamp(0, _scroll.position.maxScrollExtent).toDouble(),
          duration: AppMotion.fast, curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    if (user == null) return const SizedBox.shrink();
    final entries = [..._pages(user).take(_controller.text.trim().isEmpty ? 30 : 8), ..._records];
    if (_index >= entries.length) _index = entries.isEmpty ? 0 : entries.length - 1;

    final rows = <Widget>[];
    String? group;
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if (e.group != group) {
        group = e.group;
        rows.add(Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 10, 16, 4),
          child: Text(e.group, style: const TextStyle(color: AppColors.muted, fontSize: 12, fontWeight: FontWeight.w700)),
        ));
      }
      final selected = i == _index;
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Material(
          color: selected ? AppColors.brandSoft : Colors.transparent,
          borderRadius: AppRadius.mdAll,
          child: InkWell(
            borderRadius: AppRadius.mdAll,
            onTap: () => _open(e),
            onHover: (h) {
              if (h && _index != i) setState(() => _index = i);
            },
            child: SizedBox(
              height: 48,
              child: Row(children: [
                const SizedBox(width: 10),
                Icon(e.icon, size: 20, color: selected ? AppColors.brand : AppColors.muted),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(e.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: FontWeight.w700, color: selected ? AppColors.brandDark : AppColors.ink)),
                      if (e.subtitle.isNotEmpty && e.group != 'الصفحات')
                        Text(e.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: AppColors.muted, fontSize: 12)),
                    ],
                  ),
                ),
                if (selected) const Icon(Icons.keyboard_return, size: 16, color: AppColors.brand),
                const SizedBox(width: 12),
              ]),
            ),
          ),
        ),
      ));
    }

    final q = _controller.text.trim();
    return Align(
      alignment: const Alignment(0, -0.6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Material(
          color: AppColors.surface,
          elevation: 12,
          shadowColor: const Color(0x330B2A2E),
          borderRadius: AppRadius.xlAll,
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640, maxHeight: 540),
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1, entries.length),
                const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1, entries.length),
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: TextField(
                      controller: _controller,
                      autofocus: true,
                      onChanged: _changed,
                      onSubmitted: (_) {
                        if (entries.isNotEmpty) _open(entries[_index]);
                      },
                      style: const TextStyle(fontSize: 16),
                      decoration: InputDecoration(
                        hintText: 'ابحث عن صفحة أو صنف أو عميل أو مورد أو رقم فاتورة…',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _searching
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                              )
                            : null,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  Flexible(
                    child: entries.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(32),
                            child: Column(mainAxisSize: MainAxisSize.min, children: [
                              const Icon(Icons.search_off, size: 36, color: AppColors.subtle),
                              const SizedBox(height: 8),
                              Text(_searching ? 'جارٍ البحث…' : 'لا نتائج لـ "$q"',
                                  style: const TextStyle(color: AppColors.muted)),
                            ]),
                          )
                        : ListView(
                            controller: _scroll,
                            shrinkWrap: true,
                            padding: const EdgeInsets.only(bottom: 8),
                            children: rows,
                          ),
                  ),
                  const Divider(height: 1),
                  Container(
                    color: AppColors.zebra,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    child: const Wrap(spacing: 16, runSpacing: 4, children: [
                      KeyHint('↑ ↓', 'للتنقل'),
                      KeyHint('Enter', 'للفتح'),
                      KeyHint('Esc', 'للإغلاق'),
                    ]),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A keyboard key drawn as a small key cap, with what it does.
class KeyHint extends StatelessWidget {
  const KeyHint(this.keys, this.label, {super.key, this.dark = false});

  final String keys;
  final String label;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      KeyCap(keys, dark: dark),
      const SizedBox(width: 6),
      Text(label, style: TextStyle(fontSize: 12, color: dark ? AppColors.sideText : AppColors.muted)),
    ]);
  }
}

class KeyCap extends StatelessWidget {
  const KeyCap(this.keys, {super.key, this.dark = false});

  final String keys;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: dark ? AppColors.sideHover : AppColors.surface,
        borderRadius: AppRadius.smAll,
        border: Border.all(color: dark ? AppColors.sideDivider : AppColors.borderStrong),
      ),
      child: Text(keys,
          textDirection: TextDirection.ltr,
          style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: dark ? AppColors.sideText : AppColors.muted,
              fontFamily: 'Cairo')),
    );
  }
}

/// The keyboard shortcuts of the program (F1).
Future<void> showShortcutsHelp(BuildContext context) {
  const keys = [
    ('Ctrl + K', 'البحث السريع عن صفحة أو صنف أو عميل أو فاتورة'),
    ('F9', 'فاتورة بيع جديدة'),
    ('Alt + →', 'رجوع خطوة'),
    ('Ctrl + B', 'إظهار أو طي القائمة الجانبية'),
    ('Tab / Shift + Tab', 'الانتقال بين الحقول'),
    ('Enter', 'تأكيد / حفظ في النوافذ'),
    ('Esc', 'إغلاق النافذة'),
    ('F1', 'هذه القائمة'),
  ];
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.keyboard_outlined, color: AppColors.brand, size: 30),
      title: const Text('اختصارات لوحة المفاتيح'),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final (k, what) in keys)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                SizedBox(width: 150, child: Align(alignment: AlignmentDirectional.centerStart, child: KeyCap(k))),
                Expanded(child: Text(what)),
              ]),
            ),
        ]),
      ),
      actions: [FilledButton(autofocus: true, onPressed: () => Navigator.pop(context), child: const Text('حسناً'))],
    ),
  );
}
