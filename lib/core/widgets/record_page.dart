import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme.dart';

/// A figure at the top of a record page: what is owed, bought, in stock...
class StatTile {
  const StatTile(this.label, this.value, {this.hint, this.tone, this.icon});

  final String label;
  final String value;
  final String? hint;
  final Color? tone;
  final IconData? icon;
}

/// One tab of a record page, with an optional count shown beside its name.
class RecordTab {
  const RecordTab(this.label, this.child, {this.count, this.icon});

  final String label;
  final Widget child;
  final int? count;
  final IconData? icon;
}

/// The page of one record (a supplier, a customer, a product), in the manner
/// of a big ERP: a trail back to the list, the record's header with its
/// actions, its key figures, and tabs with everything linked to it.
class RecordPage extends StatelessWidget {
  const RecordPage({
    super.key,
    required this.backLabel,
    required this.backPath,
    required this.title,
    this.subtitle,
    this.leading,
    this.pills = const [],
    this.actions = const [],
    this.stats = const [],
    required this.tabs,
    this.onRefresh,
  });

  final String backLabel;
  final String backPath;
  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> pills;
  final List<Widget> actions;
  final List<StatTile> stats;
  final List<RecordTab> tabs;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DefaultTabController(
      length: tabs.length,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Trail back to the list.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 24, 0),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: () => context.go(backPath),
                  icon: const Icon(Icons.arrow_forward, size: 18),
                  label: Text(backLabel),
                ),
                const Icon(Icons.chevron_left, size: 18, color: AppColors.muted),
                Flexible(
                  child: Text(title, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.muted)),
                ),
                const Spacer(),
                if (onRefresh != null)
                  IconButton(tooltip: 'تحديث', onPressed: onRefresh, icon: const Icon(Icons.refresh)),
              ],
            ),
          ),
          // Header.
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  runSpacing: 12,
                  spacing: 24,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (leading != null) ...[leading!, const SizedBox(width: 16)],
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(title, style: theme.textTheme.headlineSmall),
                            if (subtitle != null && subtitle!.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(subtitle!, style: const TextStyle(color: AppColors.muted)),
                              ),
                            if (pills.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Wrap(spacing: 6, runSpacing: 6, children: pills),
                            ],
                          ],
                        ),
                      ],
                    ),
                    Wrap(spacing: 8, runSpacing: 8, children: actions),
                  ],
                ),
              ),
            ),
          ),
          // Key figures.
          if (stats.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
              child: LayoutBuilder(builder: (context, c) {
                final perRow = c.maxWidth > 880 ? 6 : (c.maxWidth > 640 ? 4 : 3);
                final shown = stats.length < perRow ? stats.length : perRow;
                final w = (c.maxWidth - 12 * (shown - 1)) / shown;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [for (final s in stats) SizedBox(width: w, child: _Stat(s))],
                );
              }),
            ),
          const SizedBox(height: 8),
          // Everything linked to it.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                for (final t in tabs)
                  Tab(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (t.icon != null) ...[Icon(t.icon, size: 18), const SizedBox(width: 6)],
                        Text(t.label),
                        if (t.count != null) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                            decoration: BoxDecoration(
                              color: AppColors.canvas,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: AppColors.border),
                            ),
                            child: Text('${t.count}', style: const TextStyle(fontSize: 12)),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(child: TabBarView(children: [for (final t in tabs) t.child])),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.s);

  final StatTile s;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (s.icon != null) ...[Icon(s.icon, size: 16, color: AppColors.muted), const SizedBox(width: 6)],
                Expanded(
                  child: Text(s.label,
                      overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              s.value,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: s.tone ?? AppColors.ink),
            ),
            if (s.hint != null)
              Text(s.hint!, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.muted, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// A record's plain fields, label beside value, in a card.
class RecordDetails extends StatelessWidget {
  const RecordDetails({super.key, required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            child: Column(
              children: [
                for (final (k, v) in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: 180, child: Text(k, style: const TextStyle(color: AppColors.muted))),
                        Expanded(child: Text(v.isEmpty ? '—' : v)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A round badge with a name's first letters, for a record with no photo.
class InitialsAvatar extends StatelessWidget {
  const InitialsAvatar(this.name, {super.key, this.size = 56, this.icon});

  final String name;
  final double size;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    // "الشركة المصرية" gives "ش م", not "ا ا".
    final words = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .map((w) => w.startsWith('ال') && w.length > 3 ? w.substring(2) : w)
        .toList();
    final letters = words.isEmpty ? '' : words.take(2).map((w) => w.characters.first).join(' ');
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(color: AppColors.infoBg, shape: BoxShape.circle),
      child: icon != null && letters.isEmpty
          ? Icon(icon, color: AppColors.brand)
          : Text(letters,
              style: TextStyle(fontSize: size * .32, fontWeight: FontWeight.w700, color: AppColors.brand)),
    );
  }
}
