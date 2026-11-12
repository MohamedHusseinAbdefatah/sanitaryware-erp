import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../money.dart';
import '../theme.dart';

/// One series of a [BarChart].
class ChartSeries {
  const ChartSeries(this.name, this.color, this.values);

  final String name;
  final Color color;

  /// Piastres, one per label.
  final List<int> values;
}

/// Grouped vertical bars (months side by side), with a legend, a zero line
/// for negative values, and the value of each bar on hover.
class BarChart extends StatelessWidget {
  const BarChart({super.key, required this.labels, required this.series, this.height = 240});

  final List<String> labels;
  final List<ChartSeries> series;
  final double height;

  @override
  Widget build(BuildContext context) {
    final all = [for (final s in series) ...s.values];
    final top = all.isEmpty ? 0 : all.reduce(math.max);
    final bottom = all.isEmpty ? 0 : math.min(0, all.reduce(math.min));
    final span = (top - bottom) == 0 ? 1 : top - bottom;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(spacing: 16, children: [
          for (final s in series)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 12, height: 12, decoration: BoxDecoration(color: s.color, borderRadius: BorderRadius.circular(3))),
              const SizedBox(width: 6),
              Text(s.name, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
            ]),
        ]),
        const SizedBox(height: 12),
        SizedBox(
          height: height,
          child: LayoutBuilder(builder: (context, box) {
            final zeroY = box.maxHeight * top / span;
            return Stack(children: [
              Positioned(
                left: 0,
                right: 0,
                top: zeroY,
                child: Container(height: 1, color: AppColors.border),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < labels.length; i++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final s in series)
                              Expanded(
                                child: _Bar(
                                  value: s.values[i],
                                  color: s.color,
                                  zeroY: zeroY,
                                  scale: box.maxHeight / span,
                                  tip: '${s.name} — ${labels[i]}\n${formatMoney(s.values[i])}',
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ]);
          }),
        ),
        const SizedBox(height: 6),
        Row(children: [
          for (final l in labels)
            Expanded(
              child: Text(l, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
            ),
        ]),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.value, required this.color, required this.zeroY, required this.scale, required this.tip});

  final int value;
  final Color color;
  final double zeroY;
  final double scale;
  final String tip;

  @override
  Widget build(BuildContext context) {
    final h = (value.abs() * scale).clamp(value == 0 ? 0.0 : 2.0, double.infinity);
    return Tooltip(
      message: tip,
      child: Stack(children: [
        Positioned(
          left: 1,
          right: 1,
          top: value >= 0 ? zeroY - h : zeroY,
          height: h,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: value < 0 ? AppColors.bad : color,
              borderRadius: value >= 0
                  ? const BorderRadius.vertical(top: Radius.circular(3))
                  : const BorderRadius.vertical(bottom: Radius.circular(3)),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Horizontal bars, biggest first: where money went, who owes most.
class RankBars extends StatelessWidget {
  const RankBars({super.key, required this.rows, this.color = AppColors.brand, this.max = 8});

  final List<(String, int)> rows;
  final Color color;
  final int max;

  @override
  Widget build(BuildContext context) {
    final list = [...rows]..sort((a, b) => b.$2.abs().compareTo(a.$2.abs()));
    final shown = list.take(max).toList();
    final top = shown.isEmpty ? 1 : math.max(1, shown.first.$2.abs());
    if (shown.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('لا توجد بيانات', style: TextStyle(color: AppColors.muted)),
      );
    }
    return Column(children: [
      for (final (label, v) in shown)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            SizedBox(width: 150, child: Text(label, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
            Expanded(
              child: LayoutBuilder(
                builder: (_, box) => Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Container(
                    height: 14,
                    width: math.max(2, box.maxWidth * v.abs() / top),
                    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 110,
              child: Text(formatMoney(v), textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            ),
          ]),
        ),
    ]);
  }
}

/// One stacked bar split into coloured parts, with a legend under it.
class SplitBar extends StatelessWidget {
  const SplitBar({super.key, required this.parts});

  final List<(String, int, Color)> parts;

  @override
  Widget build(BuildContext context) {
    final total = parts.fold(0, (s, p) => s + math.max(0, p.$2));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          height: 18,
          child: total == 0
              ? Container(color: AppColors.canvas)
              : Row(children: [
                  for (final (_, v, c) in parts)
                    if (v > 0) Expanded(flex: math.max(1, (v * 1000 / total).round()), child: Container(color: c)),
                ]),
        ),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 14, runSpacing: 4, children: [
        for (final (label, v, c) in parts)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 5),
            Text('$label: ${formatMoney(v)}', style: const TextStyle(fontSize: 12)),
          ]),
      ]),
    ]);
  }
}

/// A white bordered card with a title, used for charts and statements.
class PanelCard extends StatelessWidget {
  const PanelCard({super.key, required this.title, required this.child, this.action, this.padding = 16});

  final String title;
  final Widget child;
  final Widget? action;
  final double padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      padding: EdgeInsets.all(padding),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
          if (action != null) action!,
        ]),
        const SizedBox(height: 12),
        child,
      ]),
    );
  }
}
