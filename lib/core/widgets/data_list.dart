import 'package:flutter/material.dart';

import '../theme.dart';

/// One column of a [DataList].
class DataListColumn<T> {
  const DataListColumn(this.title, this.cell, {this.flex = 1, this.numeric = false, this.width});

  final String title;
  final Widget Function(T row) cell;
  final int flex;

  /// A fixed width instead of a share of the row (a photo, an icon).
  final double? width;

  /// Numbers are centred; text starts at the right (RTL).
  final bool numeric;
}

/// A header plus a lazily built list of rows: fast with thousands of rows,
/// unlike DataTable. Rows highlight on hover and open on tap.
class DataList<T> extends StatelessWidget {
  const DataList({
    super.key,
    required this.columns,
    required this.rows,
    this.onTap,
    this.trailing,
    this.emptyText,
    this.rowColor,
  });

  final List<DataListColumn<T>> columns;
  final List<T> rows;
  final void Function(T row)? onTap;
  final Widget Function(T row)? trailing;
  final String? emptyText;
  final Color? Function(T row)? rowColor;

  Widget _cell(DataListColumn<T> column, Widget child) {
    final inner = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Align(alignment: column.numeric ? Alignment.center : AlignmentDirectional.centerStart, child: child),
    );
    return column.width != null ? SizedBox(width: column.width, child: inner) : Expanded(flex: column.flex, child: inner);
  }

  @override
  Widget build(BuildContext context) {
    // A bordered card with a tinted header and lightly striped rows.
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Column(
            children: [
              Container(
                color: AppColors.canvas,
                padding: const EdgeInsets.symmetric(vertical: 11),
                child: Row(
                  children: [
                    for (final c in columns)
                      _cell(
                        c,
                        Text(
                          c.title,
                          style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.muted, fontSize: 13),
                        ),
                      ),
                    if (trailing != null) const SizedBox(width: 48),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: rows.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.inbox_outlined, size: 40, color: AppColors.border),
                            const SizedBox(height: 8),
                            Text(emptyText ?? '', style: const TextStyle(color: AppColors.muted)),
                          ],
                        ),
                      )
                    : ListView.separated(
                        itemCount: rows.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final row = rows[i];
                          return Material(
                            color: rowColor?.call(row) ?? (i.isOdd ? AppColors.zebra : Colors.transparent),
                            child: InkWell(
                              onTap: onTap == null ? null : () => onTap!(row),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(minHeight: 44),
                                child: Row(
                                  children: [
                                    for (final c in columns) _cell(c, c.cell(row)),
                                    if (trailing != null) SizedBox(width: 48, child: trailing!(row)),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Title row at the top of a section page, with actions at the end. The
/// actions wrap onto a second line when the window is narrow.
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.actions = const []});

  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 14),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 26,
            decoration: BoxDecoration(color: AppColors.brand, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 10),
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(width: 16),
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: actions,
            ),
          ),
        ],
      ),
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
