import 'package:flutter/material.dart';

import '../theme.dart';
import 'states.dart';

/// One column of a [DataList].
class DataListColumn<T> {
  const DataListColumn(this.title, this.cell, {this.flex = 1, this.numeric = false, this.width, this.sortValue});

  final String title;
  final Widget Function(T row) cell;
  final int flex;

  /// A fixed width instead of a share of the row (a photo, an icon).
  final double? width;

  /// Numbers are centred; text starts at the right (RTL).
  final bool numeric;

  /// When given, clicking the heading sorts the rows by this value (again to
  /// reverse, a third time back to the list's own order).
  final Comparable<Object?>? Function(T row)? sortValue;
}

/// A header plus a lazily built list of rows: fast with thousands of rows,
/// unlike DataTable. The heading stays in place while the rows scroll; rows
/// highlight on hover and open on tap; sortable headings show an arrow; a
/// footer says how many rows are shown.
class DataList<T> extends StatefulWidget {
  const DataList({
    super.key,
    required this.columns,
    required this.rows,
    this.onTap,
    this.trailing,
    this.emptyText,
    this.emptyHint,
    this.emptyIcon = Icons.inbox_outlined,
    this.emptyAction,
    this.rowColor,
    this.showCount = true,
  });

  final List<DataListColumn<T>> columns;
  final List<T> rows;
  final void Function(T row)? onTap;
  final Widget Function(T row)? trailing;
  final String? emptyText;

  /// A second line under [emptyText]: what to do next.
  final String? emptyHint;
  final IconData emptyIcon;
  final Widget? emptyAction;
  final Color? Function(T row)? rowColor;
  final bool showCount;

  @override
  State<DataList<T>> createState() => _DataListState<T>();
}

class _DataListState<T> extends State<DataList<T>> {
  int? _sortColumn;
  bool _ascending = true;

  void _sortBy(int i) {
    setState(() {
      if (_sortColumn != i) {
        _sortColumn = i;
        _ascending = true;
      } else if (_ascending) {
        _ascending = false;
      } else {
        _sortColumn = null;
      }
    });
  }

  List<T> get _rows {
    final i = _sortColumn;
    if (i == null || i >= widget.columns.length) return widget.rows;
    final key = widget.columns[i].sortValue;
    if (key == null) return widget.rows;
    // Sorted by the value, ties kept in the list's own order.
    final indexed = [for (var n = 0; n < widget.rows.length; n++) (n, widget.rows[n], key(widget.rows[n]))];
    indexed.sort((a, b) {
      final x = a.$3;
      final y = b.$3;
      int c;
      if (x == null && y == null) {
        c = 0;
      } else if (x == null) {
        return 1; // blanks last either way
      } else if (y == null) {
        return -1;
      } else {
        c = x.compareTo(y);
        if (!_ascending) c = -c;
      }
      return c != 0 ? c : a.$1 - b.$1;
    });
    return [for (final r in indexed) r.$2];
  }

  Widget _cell(DataListColumn<T> column, Widget child) {
    final inner = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Align(alignment: column.numeric ? Alignment.center : AlignmentDirectional.centerStart, child: child),
    );
    return column.width != null ? SizedBox(width: column.width, child: inner) : Expanded(flex: column.flex, child: inner);
  }

  Widget _heading(int i) {
    final c = widget.columns[i];
    const style = TextStyle(fontWeight: FontWeight.w700, color: AppColors.muted, fontSize: 13);
    if (c.sortValue == null) return Text(c.title, style: style);
    final active = _sortColumn == i;
    return Tooltip(
      message: 'ترتيب حسب ${c.title}',
      child: InkWell(
        borderRadius: AppRadius.smAll,
        onTap: () => _sortBy(i),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
              child: Text(c.title,
                  overflow: TextOverflow.ellipsis,
                  style: active ? style.copyWith(color: AppColors.brand) : style),
            ),
            const SizedBox(width: 2),
            Icon(
              active ? (_ascending ? Icons.arrow_upward : Icons.arrow_downward) : Icons.unfold_more,
              size: 14,
              color: active ? AppColors.brand : AppColors.subtle,
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final w = widget;
    // A bordered card with a tinted header and lightly striped rows. The
    // count footer shows only when there is room for rows as well.
    return LayoutBuilder(builder: (context, box) {
      final roomy = box.maxHeight > 180;
      return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: AppRadius.lgAll,
          border: Border.all(color: AppColors.border),
          boxShadow: AppShadows.card,
        ),
        child: ClipRRect(
          borderRadius: AppRadius.lgAll,
          child: Column(
            children: [
              Container(
                color: AppColors.canvas,
                padding: const EdgeInsets.symmetric(vertical: 11),
                child: Row(
                  children: [
                    for (var i = 0; i < w.columns.length; i++) _cell(w.columns[i], _heading(i)),
                    if (w.trailing != null) const SizedBox(width: 48),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: rows.isEmpty
                    ? EmptyState(
                        title: w.emptyText ?? 'لا توجد سجلات هنا بعد',
                        message: w.emptyHint,
                        icon: w.emptyIcon,
                        action: w.emptyAction,
                        compact: true,
                      )
                    : ListView.separated(
                        itemCount: rows.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final row = rows[i];
                          return Material(
                            color: w.rowColor?.call(row) ?? (i.isOdd ? AppColors.zebra : Colors.transparent),
                            child: InkWell(
                              onTap: w.onTap == null ? null : () => w.onTap!(row),
                              hoverColor: AppColors.brand.withValues(alpha: .06),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(minHeight: 44),
                                child: Row(
                                  children: [
                                    for (final c in w.columns) _cell(c, c.cell(row)),
                                    if (w.trailing != null) SizedBox(width: 48, child: w.trailing!(row)),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              if (w.showCount && roomy && rows.isNotEmpty) ...[
                const Divider(height: 1),
                Container(
                  color: AppColors.zebra,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                  child: Row(children: [
                    Text('${rows.length} سجل', style: const TextStyle(color: AppColors.muted, fontSize: 12)),
                    const Spacer(),
                    if (_sortColumn != null)
                      InkWell(
                        onTap: () => setState(() => _sortColumn = null),
                        child: const Text('إلغاء الترتيب',
                            style: TextStyle(color: AppColors.brand, fontSize: 12, fontWeight: FontWeight.w600)),
                      ),
                  ]),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    });
  }
}

/// Title row at the top of a section page, with actions at the end. The
/// actions wrap onto a second line when the window is narrow. An optional
/// [subtitle] says in one line what the page is for.
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.subtitle, this.icon, this.actions = const []});

  final String title;
  final String? subtitle;
  final IconData? icon;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final heading = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null)
          Container(
            width: 38,
            height: 38,
            decoration: const BoxDecoration(color: AppColors.brandSoft, borderRadius: AppRadius.mdAll),
            child: Icon(icon, color: AppColors.brand, size: 21),
          )
        else
          Container(
            width: 4,
            height: 26,
            decoration: BoxDecoration(color: AppColors.brand, borderRadius: BorderRadius.circular(2)),
          ),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              if (subtitle != null && subtitle!.isNotEmpty)
                Text(subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.muted, fontSize: 13)),
            ],
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 14),
      child: LayoutBuilder(builder: (context, c) {
        final bar = Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: actions,
        );
        // Narrow: title above, actions below, so neither is squeezed.
        if (c.maxWidth < 640 && actions.isNotEmpty) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            heading,
            const SizedBox(height: 10),
            Align(alignment: AlignmentDirectional.centerStart, child: bar),
          ]);
        }
        return Row(
          children: [
            ConstrainedBox(constraints: BoxConstraints(maxWidth: c.maxWidth * .6), child: heading),
            const SizedBox(width: 16),
            Expanded(child: bar),
          ],
        );
      }),
    );
  }
}

/// Search box used above lists.
class SearchBox extends StatelessWidget {
  const SearchBox({super.key, required this.onChanged, required this.hint, this.width = 280});

  final ValueChanged<String> onChanged;
  final String hint;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: TextField(
        onChanged: onChanged,
        decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: hint, isDense: true),
      ),
    );
  }
}
