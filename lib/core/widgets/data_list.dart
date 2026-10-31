import 'package:flutter/material.dart';

/// One column of a [DataList].
class DataListColumn<T> {
  const DataListColumn(
    this.title,
    this.cell, {
    this.flex = 1,
    this.numeric = false,
  });

  final String title;
  final Widget Function(T row) cell;
  final int flex;

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

  Widget _cell(DataListColumn<T> column, Widget child) => Expanded(
        flex: column.flex,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Align(
            alignment: column.numeric ? Alignment.center : AlignmentDirectional.centerStart,
            child: child,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Container(
          color: theme.colorScheme.surfaceContainerHigh,
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              for (final c in columns)
                _cell(c, Text(c.title, style: const TextStyle(fontWeight: FontWeight.bold))),
              if (trailing != null) const SizedBox(width: 48),
            ],
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? Center(child: Text(emptyText ?? ''))
              : ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final row = rows[i];
                    return Material(
                      color: rowColor?.call(row) ?? Colors.transparent,
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
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      child: Row(
        children: [
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
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search),
          hintText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}
