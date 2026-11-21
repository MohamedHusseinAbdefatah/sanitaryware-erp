import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/version.dart';
import 'command_palette.dart';
import 'sections.dart';

/// Sidebar groups: section paths in the order shown.
const _groups = <(String, List<String>)>[
  ('', ['/dashboard']),
  ('العمليات اليومية', ['/sales', '/customers', '/projects', '/returns', '/payments']),
  ('المخزون والمشتريات', ['/inventory', '/products', '/suppliers', '/purchases', '/price-lists']),
  ('المالية والإدارة', ['/accounting', '/expenses', '/reports', '/settings']),
];

const _collapsedKey = 'ui.sidebar_collapsed';

/// Whether the sidebar shows icons only. Remembered on this computer.
final sidebarCollapsedProvider = StateProvider<bool>((ref) => false);

final _companyNameProvider = FutureProvider.autoDispose<String>(
  (ref) async => (await ref.watch(settingsServiceProvider).company()).name,
);

/// How the sidebar is shown for the window's width.
enum _NavMode { full, rail, drawer }

/// Main window: a dark sidebar on the right (RTL), a top bar with where you
/// are, the quick search and quick actions, then the page.
///
/// Wide windows show the full sidebar (it can be folded to icons with
/// Ctrl+B); medium windows show icons only; narrow windows hide it behind a
/// menu button. F9 opens a new sale, Ctrl+K the quick search, F1 the list
/// of shortcuts, Alt+→ goes back a level.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  final _scaffold = GlobalKey<ScaffoldState>();

  /// Groups the person folded away in this session.
  final _closedGroups = <String>{};

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final folded = await ref.read(settingsServiceProvider).getBool(_collapsedKey);
      if (mounted && folded) ref.read(sidebarCollapsedProvider.notifier).state = true;
    });
  }

  void _toggleSidebar() {
    final folded = !ref.read(sidebarCollapsedProvider);
    ref.read(sidebarCollapsedProvider.notifier).state = folded;
    ref.read(settingsServiceProvider).setBool(_collapsedKey, folded);
  }

  void _goBranch(int i) {
    widget.navigationShell.goBranch(i);
    if (_scaffold.currentState?.isDrawerOpen ?? false) Navigator.of(context).pop();
  }

  Future<void> _logout() async {
    // Logging out also forgets this computer's remembered sign-in.
    final store = ref.read(rememberStoreProvider);
    final token = await store.read();
    if (token != null) await ref.read(rememberServiceProvider).revoke(token);
    await store.clear();
    ref.read(currentUserProvider.notifier).state = null;
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final company = ref.watch(_companyNameProvider).valueOrNull ?? '';
    final folded = ref.watch(sidebarCollapsedProvider);
    final location = GoRouterState.of(context).uri.path;
    final trail = breadcrumbFor(location);

    void back() {
      if (trail.length > 1) context.go(trail[trail.length - 2].$2);
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f9): () {
          if (user != null && user.can(Perm.sell)) context.go('/sales/new');
        },
        // Back one level (the arrow points right in Arabic).
        const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): back,
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () => showCommandPalette(context),
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): _toggleSidebar,
        const SingleActivator(LogicalKeyboardKey.f1): () => showShortcutsHelp(context),
      },
      child: LayoutBuilder(builder: (context, c) {
        final mode = c.maxWidth < 720
            ? _NavMode.drawer
            : (c.maxWidth < 1000 || folded ? _NavMode.rail : _NavMode.full);
        Widget sidebar(_NavMode m) => _Sidebar(
              user: user,
              company: company,
              rail: m == _NavMode.rail,
              currentIndex: widget.navigationShell.currentIndex,
              closedGroups: _closedGroups,
              onToggleGroup: (g) => setState(() => _closedGroups.contains(g) ? _closedGroups.remove(g) : _closedGroups.add(g)),
              onSelect: _goBranch,
              onLogout: _logout,
              // On a medium window the rail cannot be widened.
              onToggleFold: m == _NavMode.drawer || c.maxWidth < 1000 ? null : _toggleSidebar,
            );
        return Scaffold(
          key: _scaffold,
          drawer: mode == _NavMode.drawer ? Drawer(width: 280, child: sidebar(_NavMode.full)) : null,
          body: Row(
            children: [
              if (mode != _NavMode.drawer) sidebar(mode),
              Expanded(
                child: Column(
                  children: [
                    _TopBar(
                      user: user,
                      trail: trail,
                      onBack: back,
                      onMenu: mode == _NavMode.drawer ? () => _scaffold.currentState?.openDrawer() : null,
                    ),
                    Expanded(child: widget.navigationShell),
                  ],
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}

/// The dark navigation column: the program's name, the sections in groups,
/// and who is signed in. [rail] shows icons only, with the names as tips.
class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.user,
    required this.company,
    required this.rail,
    required this.currentIndex,
    required this.closedGroups,
    required this.onToggleGroup,
    required this.onSelect,
    required this.onLogout,
    required this.onToggleFold,
  });

  final User? user;
  final String company;
  final bool rail;
  final int currentIndex;
  final Set<String> closedGroups;
  final ValueChanged<String> onToggleGroup;
  final ValueChanged<int> onSelect;
  final VoidCallback onLogout;
  final VoidCallback? onToggleFold;

  @override
  Widget build(BuildContext context) {
    final u = user;
    final byPath = {for (var i = 0; i < appSections.length; i++) appSections[i].path: i};
    bool shown(String p) => byPath[p] != null && u != null && appSections[byPath[p]!].allows(u);

    final items = <Widget>[];
    for (final (label, paths) in _groups) {
      final visible = paths.where(shown).toList();
      if (visible.isEmpty) continue;
      final holdsCurrent = visible.any((p) => byPath[p] == currentIndex);
      // The group of the open page always stays open.
      final open = label.isEmpty || holdsCurrent || !closedGroups.contains(label);
      if (label.isNotEmpty) {
        items.add(rail
            ? const Padding(
                padding: EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                child: Divider(color: AppColors.sideDivider, height: 1),
              )
            : _GroupHeading(label: label, open: open, onTap: holdsCurrent ? null : () => onToggleGroup(label)));
      }
      if (open || rail) {
        for (final p in visible) {
          items.add(_NavEntry(
            section: appSections[byPath[p]!],
            selected: byPath[p] == currentIndex,
            rail: rail,
            onTap: () => onSelect(byPath[p]!),
          ));
        }
      }
    }
    // Any section not placed in a group still shows.
    for (var i = 0; i < appSections.length; i++) {
      if (!_groups.any((g) => g.$2.contains(appSections[i].path)) && u != null && appSections[i].allows(u)) {
        items.add(_NavEntry(section: appSections[i], selected: i == currentIndex, rail: rail, onTap: () => onSelect(i)));
      }
    }

    return AnimatedContainer(
      duration: AppMotion.normal,
      curve: Curves.easeOut,
      width: rail ? 76 : 248,
      color: AppColors.brandDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Brand(company: company, rail: rail, onToggleFold: onToggleFold),
          // A Column (not a lazy list) so no entry is ever left unbuilt.
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: items),
            ),
          ),
          if (u != null) _UserCard(user: u, rail: rail, onLogout: onLogout),
        ],
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.company, required this.rail, required this.onToggleFold});

  final String company;
  final bool rail;
  final VoidCallback? onToggleFold;

  @override
  Widget build(BuildContext context) {
    final logo = Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF14A0AB), AppColors.brand],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Icon(Icons.water_drop, color: Colors.white, size: 22),
    );
    final fold = onToggleFold == null
        ? null
        : IconButton(
            tooltip: rail ? 'إظهار القائمة كاملة (Ctrl+B)' : 'طي القائمة (Ctrl+B)',
            onPressed: onToggleFold,
            icon: Icon(rail ? Icons.keyboard_double_arrow_left : Icons.keyboard_double_arrow_right,
                color: AppColors.sideText, size: 20),
          );
    if (rail) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 14, 8, 6),
        child: Column(children: [Tooltip(message: Strings.appTitle, child: logo), if (fold != null) fold]),
      );
    }
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 6, 10),
      child: Row(
        children: [
          logo,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  Strings.appTitle,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15, height: 1.2),
                ),
                Text(
                  company.isEmpty ? 'الإصدار $appVersion' : company,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.sideText, fontSize: 12),
                ),
              ],
            ),
          ),
          if (fold != null) fold,
        ],
      ),
    );
  }
}

class _GroupHeading extends StatelessWidget {
  const _GroupHeading({required this.label, required this.open, required this.onTap});

  final String label;
  final bool open;

  /// Null when the group holds the open page and so cannot be folded.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
      child: InkWell(
        borderRadius: AppRadius.smAll,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(color: AppColors.sideAccent, fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: .3),
              ),
            ),
            if (onTap != null)
              Icon(open ? Icons.expand_less : Icons.expand_more, size: 14, color: AppColors.sideText),
          ]),
        ),
      ),
    );
  }
}

/// One section in the sidebar. The open one is lit, with a bar at its edge.
class _NavEntry extends StatelessWidget {
  const _NavEntry({required this.section, required this.selected, required this.rail, required this.onTap});

  final AppSection section;
  final bool selected;
  final bool rail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final iconColor = selected ? AppColors.sideAccent : AppColors.sideText;
    final body = rail
        ? SizedBox(height: 40, child: Center(child: Icon(section.icon, size: 22, color: iconColor)))
        : Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 12, 4),
            child: Row(
              children: [
                Icon(section.icon, size: 20, color: iconColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    section.title,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.2,
                      color: selected ? Colors.white : AppColors.sideText,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          );
    final tile = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: Semantics(
        selected: selected,
        button: true,
        label: rail ? section.title : null,
        child: Material(
          color: selected ? AppColors.sideSelected : Colors.transparent,
          borderRadius: AppRadius.mdAll,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            hoverColor: AppColors.sideHover,
            focusColor: AppColors.sideSelected,
            onTap: onTap,
            child: Stack(children: [
              body,
              // The lit edge of the open page.
              PositionedDirectional(
                start: 0,
                top: 8,
                bottom: 8,
                child: AnimatedContainer(
                  duration: AppMotion.fast,
                  width: selected ? 3 : 0,
                  decoration: const BoxDecoration(
                    color: AppColors.sideAccent,
                    borderRadius: BorderRadiusDirectional.horizontal(end: Radius.circular(3)),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
    return rail ? Tooltip(message: section.title, preferBelow: false, child: tile) : tile;
  }
}

class _UserCard extends StatelessWidget {
  const _UserCard({required this.user, required this.rail, required this.onLogout});

  final User user;
  final bool rail;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final avatar = CircleAvatar(
      radius: 16,
      backgroundColor: AppColors.brand,
      child: Text(
        user.fullName.trim().isEmpty ? '?' : user.fullName.trim().characters.first,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
      ),
    );
    final logout = IconButton(
      tooltip: Strings.logout,
      icon: const Icon(Icons.logout, color: AppColors.sideText, size: 20),
      onPressed: onLogout,
    );
    if (rail) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(children: [
          const Divider(color: AppColors.sideDivider, height: 12),
          Tooltip(message: '${user.fullName} — ${UserRole.label(user.role)}', child: avatar),
          logout,
        ]),
      );
    }
    return Container(
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
      decoration: BoxDecoration(color: AppColors.sideHover, borderRadius: BorderRadius.circular(10)),
      child: Row(
        children: [
          avatar,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.fullName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                ),
                Text(UserRole.label(user.role), style: const TextStyle(color: AppColors.sideText, fontSize: 12)),
              ],
            ),
          ),
          logout,
        ],
      ),
    );
  }
}

/// A quick "create" action in the top bar.
class _Create {
  const _Create(this.path, this.label, this.icon);

  final String path;
  final String label;
  final IconData icon;
}

/// The bar above every page: the way back, where you are, the quick search,
/// quick actions, today's date and a new sale.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.user,
    required this.trail,
    required this.onBack,
    required this.onMenu,
  });

  final User? user;
  final List<(String, String)> trail;
  final VoidCallback onBack;
  final VoidCallback? onMenu;

  List<_Create> _creates(User u) {
    bool opens(String path) => appSections.any((s) => path.startsWith(s.path) && s.allows(u));
    return [
      if (u.can(Perm.sell)) const _Create('/sales/orders', 'عرض سعر / أمر بيع', Icons.request_quote_outlined),
      if (u.can(Perm.purchase) && opens('/purchases')) const _Create('/purchases/new', 'فاتورة شراء', Icons.add_shopping_cart),
      if (opens('/returns')) const _Create('/returns/new', 'مرتجع', Icons.assignment_return_outlined),
      if (opens('/payments')) const _Create('/payments', 'تحصيل أو دفع', Icons.payments_outlined),
      if (opens('/customers')) const _Create('/customers', 'عميل', Icons.person_add_alt_outlined),
      if (u.can(Perm.catalog) && opens('/products')) const _Create('/products', 'صنف', Icons.add_box_outlined),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final u = user;
    final creates = u == null ? const <_Create>[] : _creates(u);
    return Container(
      height: 56,
      padding: const EdgeInsetsDirectional.only(start: 16, end: 16),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      // Labels, the wide search box and the date show only when there is
      // room, so the trail of where you are is never squeezed out.
      child: LayoutBuilder(builder: (context, c) {
        final compact = c.maxWidth < 1150;
        final showDate = c.maxWidth >= 1380;
        return Row(
        children: [
          if (onMenu != null) ...[
            IconButton(tooltip: 'القائمة', onPressed: onMenu, icon: const Icon(Icons.menu)),
            const SizedBox(width: 4),
          ],
          // Where you are, and the way back (also Alt + →).
          if (trail.length > 1) ...[
            IconButton.filledTonal(
              tooltip: 'رجوع (Alt + →)',
              onPressed: onBack,
              icon: const Icon(Icons.arrow_forward),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (var i = 0; i < trail.length; i++) ...[
                  if (i > 0)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 2),
                      child: Icon(Icons.chevron_left, size: 18, color: AppColors.subtle),
                    ),
                  i == trail.length - 1
                      ? Text(trail[i].$1,
                          style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.ink, fontSize: 15))
                      : InkWell(
                          borderRadius: AppRadius.smAll,
                          onTap: () => context.go(trail[i].$2),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                            child: Text(trail[i].$1,
                                style: const TextStyle(color: AppColors.brand, fontWeight: FontWeight.w600)),
                          ),
                        ),
                ],
              ]),
            ),
          ),
          const SizedBox(width: 12),
          _SearchButton(compact: compact),
          if (creates.isNotEmpty) ...[
            const SizedBox(width: 8),
            PopupMenuButton<_Create>(
              tooltip: 'إنشاء سريع',
              position: PopupMenuPosition.under,
              onSelected: (c) => context.go(c.path),
              itemBuilder: (_) => [
                for (final c in creates)
                  PopupMenuItem(
                    value: c,
                    child: Row(children: [
                      Icon(c.icon, size: 20, color: AppColors.brand),
                      const SizedBox(width: 12),
                      Text(c.label),
                    ]),
                  ),
              ],
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  borderRadius: AppRadius.mdAll,
                  border: Border.all(color: AppColors.borderStrong),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.add, size: 20, color: AppColors.brand),
                  if (!compact) ...[
                    const SizedBox(width: 6),
                    const Text('إنشاء', style: TextStyle(fontWeight: FontWeight.w700)),
                  ],
                  const Icon(Icons.arrow_drop_down, size: 20, color: AppColors.muted),
                ]),
              ),
            ),
          ],
          if (showDate) ...[
            const SizedBox(width: 14),
            const Icon(Icons.calendar_today_outlined, size: 16, color: AppColors.muted),
            const SizedBox(width: 8),
            Text(formatLongDate(DateTime.now()), style: const TextStyle(color: AppColors.muted)),
          ],
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'اختصارات لوحة المفاتيح (F1)',
            onPressed: () => showShortcutsHelp(context),
            icon: const Icon(Icons.keyboard_outlined, color: AppColors.muted),
          ),
          if (u != null && u.can(Perm.sell)) ...[
            const SizedBox(width: 6),
            FilledButton.icon(
              onPressed: () => context.go('/sales/new'),
              icon: const Icon(Icons.point_of_sale, size: 18),
              label: Text(compact ? 'بيع (F9)' : 'بيع جديد (F9)'),
            ),
          ],
        ],
      );
      }),
    );
  }
}

/// Looks like a search box; opens the quick search (Ctrl+K).
class _SearchButton extends StatelessWidget {
  const _SearchButton({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'بحث سريع (Ctrl+K)',
      child: Material(
        color: AppColors.canvas,
        borderRadius: AppRadius.mdAll,
        child: InkWell(
          borderRadius: AppRadius.mdAll,
          onTap: () => showCommandPalette(context),
          child: Container(
            height: 40,
            width: compact ? 44 : 260,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(borderRadius: AppRadius.mdAll, border: Border.all(color: AppColors.border)),
            child: Row(children: [
              const Icon(Icons.search, size: 20, color: AppColors.muted),
              if (!compact) ...[
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('ابحث في البرنامج…', overflow: TextOverflow.ellipsis, style: TextStyle(color: AppColors.subtle)),
                ),
                const KeyCap('Ctrl K'),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

/// The trail of pages to [path]: the section, then each level under it, each
/// with where it leads. "/sales/12" gives المبيعات › فاتورة.
List<(String, String)> breadcrumbFor(String path) {
  final section = appSections
      .where((s) => path == s.path || path.startsWith('${s.path}/'))
      .firstOrNull;
  if (section == null) return const [];
  final trail = <(String, String)>[(section.title, section.path)];
  final rest = path.substring(section.path.length).split('/').where((p) => p.isNotEmpty).toList();
  var at = section.path;
  for (final part in rest) {
    at = '$at/$part';
    final label = switch (part) {
      'new' => 'جديد',
      'orders' => 'الأوامر وعروض الأسعار',
      'deliveries' => 'التوصيل',
      'leads' => 'العملاء المحتملون',
      'calendar' => 'الخطة الأسبوعية والشهرية',
      'accounts' => 'حساب',
      _ => int.tryParse(part) != null ? 'التفاصيل' : part,
    };
    // "accounts" alone is not a page: its id is the next part.
    if (part == 'accounts') continue;
    trail.add((label, at));
  }
  return trail;
}
