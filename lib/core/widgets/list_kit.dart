import 'package:flutter/material.dart';

import '../services/doc_types.dart';
import '../theme.dart';

/// Where an invoice stands with its money.
enum PayState { paid, partial, unpaid, overdue, cancelled }

PayState payStateOf({required int total, required int paid, required String status, DateTime? dueDate}) {
  if (status == DocStatus.cancelled) return PayState.cancelled;
  if (total - paid <= 0) return PayState.paid;
  if (dueDate != null && dueDate.isBefore(DateTime.now())) return PayState.overdue;
  return paid > 0 ? PayState.partial : PayState.unpaid;
}

String payStateLabel(PayState s) => switch (s) {
      PayState.paid => 'مدفوعة',
      PayState.partial => 'مدفوعة جزئياً',
      PayState.unpaid => 'غير مدفوعة',
      PayState.overdue => 'متأخرة',
      PayState.cancelled => 'ملغاة',
    };

Widget payStatePill(PayState s) => switch (s) {
      PayState.paid => StatusPill.good(payStateLabel(s)),
      PayState.partial => StatusPill.warn(payStateLabel(s)),
      PayState.unpaid => StatusPill(payStateLabel(s)),
      PayState.overdue => StatusPill.bad(payStateLabel(s)),
      PayState.cancelled => StatusPill.bad(payStateLabel(s)),
    };

/// A figure in the strip above a list.
class SummaryItem {
  const SummaryItem(this.label, this.value, {this.tone, this.icon});

  final String label;
  final String value;
  final Color? tone;
  final IconData? icon;
}

/// A row of small figure cards above a list: totals for what is shown.
class SummaryStrip extends StatelessWidget {
  const SummaryStrip({super.key, required this.items});

  final List<SummaryItem> items;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: LayoutBuilder(builder: (context, c) {
        final perRow = items.length <= 5 && c.maxWidth > 760 ? items.length : 3;
        final w = (c.maxWidth - 12 * (perRow - 1)) / perRow;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final i in items)
              SizedBox(
                width: w,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Row(
                      children: [
                        if (i.icon != null) ...[
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: (i.tone ?? AppColors.brand).withValues(alpha: .10),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(i.icon, size: 20, color: i.tone ?? AppColors.brand),
                          ),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(i.label,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: AppColors.muted, fontSize: 12.5)),
                              Text(i.value,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 17, fontWeight: FontWeight.w700, color: i.tone ?? AppColors.ink)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      }),
    );
  }
}

/// Filter chips with how many rows each one shows.
class CountChips<T> extends StatelessWidget {
  const CountChips({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
  });

  /// (value, label, count)
  final List<(T, String, int)> options;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          for (final (value, label, count) in options)
            ChoiceChip(
              label: Text('$label  $count'),
              selected: value == selected,
              showCheckmark: false,
              onSelected: (_) => onSelected(value),
            ),
        ],
      ),
    );
  }
}

/// "today", "yesterday", "5 days ago"... for last-activity columns.
String sinceText(DateTime? d) {
  if (d == null) return '—';
  final now = DateTime.now();
  final days = DateTime(now.year, now.month, now.day).difference(DateTime(d.year, d.month, d.day)).inDays;
  if (days <= 0) return 'اليوم';
  if (days == 1) return 'أمس';
  if (days < 11) return 'منذ $days أيام';
  if (days < 31) return 'منذ $days يوماً';
  final months = days ~/ 30;
  if (months < 12) return months == 1 ? 'منذ شهر' : 'منذ $months شهور';
  return 'منذ ${days ~/ 365} سنة';
}

/// A round badge with a name's first letters, coloured by the name.
class NameAvatar extends StatelessWidget {
  const NameAvatar(this.name, {super.key, this.size = 34});

  final String name;
  final double size;

  static const _tones = [
    Color(0xFF0E7C86),
    Color(0xFF1F5FA8),
    Color(0xFF7A4FB5),
    Color(0xFFB0632B),
    Color(0xFF2E7D4F),
    Color(0xFFA23B5B),
  ];

  @override
  Widget build(BuildContext context) {
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final letters = words.isEmpty ? '؟' : words.take(2).map((w) => w.characters.first).join(' ');
    final tone = _tones[name.hashCode.abs() % _tones.length];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: tone.withValues(alpha: .12), shape: BoxShape.circle),
      child: Text(letters, style: TextStyle(color: tone, fontWeight: FontWeight.w800, fontSize: size * .36)),
    );
  }
}

/// A name with a smaller second line (phone, code...) and an optional
/// leading picture or avatar.
class TitleCell extends StatelessWidget {
  const TitleCell(this.title, {super.key, this.subtitle, this.leading, this.muted = false});

  final String title;
  final String? subtitle;
  final Widget? leading;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        if (leading != null) ...[leading!, const SizedBox(width: 10)],
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(title,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.w700, color: muted ? AppColors.muted : AppColors.ink)),
            if (subtitle != null && subtitle!.isNotEmpty)
              Text(subtitle!,
                  overflow: TextOverflow.ellipsis,
                  textDirection: TextDirection.rtl,
                  style: const TextStyle(fontSize: 12, color: AppColors.muted)),
          ]),
        ),
      ]),
    );
  }
}

/// How much of a limit is used: a thin bar with the percentage.
class UsageBar extends StatelessWidget {
  const UsageBar({super.key, required this.used, required this.limit});

  final int used;
  final int limit;

  @override
  Widget build(BuildContext context) {
    if (limit <= 0) return const Text('—', style: TextStyle(color: AppColors.muted));
    final share = used <= 0 ? 0.0 : used / limit;
    final tone = share > 1 ? AppColors.bad : (share > .8 ? AppColors.warn : AppColors.good);
    return Row(children: [
      Expanded(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: share.clamp(0, 1).toDouble(),
            minHeight: 7,
            backgroundColor: AppColors.canvas,
            color: tone,
          ),
        ),
      ),
      const SizedBox(width: 6),
      Text('${(share * 100).round()}%', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: tone)),
    ]);
  }
}

/// Switches a list between rows and cards.
class ViewToggle extends StatelessWidget {
  const ViewToggle({super.key, required this.cards, required this.onChanged});

  final bool cards;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<bool>(
      showSelectedIcon: false,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      segments: const [
        ButtonSegment(value: false, icon: Icon(Icons.view_list_outlined), tooltip: 'قائمة'),
        ButtonSegment(value: true, icon: Icon(Icons.grid_view_outlined), tooltip: 'بطاقات'),
      ],
      selected: {cards},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}

/// Cards laid out in as many columns as fit, scrolling, for the card view
/// of a list.
class CardGrid<T> extends StatelessWidget {
  const CardGrid({super.key, required this.rows, required this.card, this.emptyText, this.width = 270, this.height = 150});

  final List<T> rows;
  final Widget Function(T row) card;
  final String? emptyText;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return Center(child: Text(emptyText ?? '', style: const TextStyle(color: AppColors.muted)));
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: width,
        mainAxisExtent: height,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: rows.length,
      itemBuilder: (_, i) => card(rows[i]),
    );
  }
}

/// A white bordered card that highlights on hover and opens on tap.
class TapCard extends StatelessWidget {
  const TapCard({super.key, required this.child, this.onTap, this.padding = 14});

  final Widget child;
  final VoidCallback? onTap;
  final double padding;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: Padding(padding: EdgeInsets.all(padding), child: child)),
    );
  }
}
