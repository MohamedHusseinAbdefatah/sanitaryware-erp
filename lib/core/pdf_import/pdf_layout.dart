/// Turns the characters a PDF page gives (each with its box) into lines of
/// words, in reading order. Pure Dart, so it is tested without any PDF engine.
library;

/// One character and its box, in PDF points. [top] is above [bottom].
class PdfChar {
  const PdfChar(this.text, this.left, this.top, this.right, this.bottom);

  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;

  double get midY => (top + bottom) / 2;
  double get height => (top - bottom).abs();
}

/// A word: characters close together on one line.
class PdfWord {
  PdfWord(this.text, this.left, this.right);

  final String text;
  final double left;
  final double right;

  double get center => (left + right) / 2;

  @override
  String toString() => '$text@${left.round()}-${right.round()}';
}

/// One line of a page, its words left to right.
class PdfLine {
  PdfLine(this.y, this.words);

  /// Middle of the line, PDF points from the bottom of the page.
  final double y;
  final List<PdfWord> words;

  /// The line as it reads, right to left for Arabic text and left to right for the rest.
  String get text => words.map((w) => w.text).join(' ');

  @override
  String toString() => '${y.round()}: ${words.join(' ')}';
}

final _arabic = RegExp(r'[؀-ۿݐ-ݿﭐ-﷿ﹰ-﻿]');

bool isArabic(String s) => _arabic.hasMatch(s);

/// Groups [chars] into lines (by height on the page) and words (by gaps).
/// Arabic words are put back in reading order, since a PDF keeps them left
/// to right as drawn.
List<PdfLine> layoutLines(List<PdfChar> chars) {
  final visible = chars.where((c) => c.text.trim().isNotEmpty && c.right > c.left).toList()
    ..sort((a, b) => b.midY.compareTo(a.midY));
  final lines = <List<PdfChar>>[];
  for (final c in visible) {
    final tolerance = (c.height <= 0 ? 6.0 : c.height) * .55;
    final line = lines.where((l) => (l.first.midY - c.midY).abs() <= tolerance).firstOrNull;
    if (line == null) {
      lines.add([c]);
    } else {
      line.add(c);
    }
  }
  final out = <PdfLine>[];
  for (final l in lines) {
    l.sort((a, b) => a.left.compareTo(b.left));
    final avgH = l.fold<double>(0, (s, c) => s + (c.height <= 0 ? 6 : c.height)) / l.length;
    final words = <PdfWord>[];
    var current = <PdfChar>[];
    void flush() {
      if (current.isEmpty) return;
      var text = current.map((c) => c.text).join();
      // Arabic letters are stored left to right as drawn; read them right to left.
      if (isArabic(text) && !RegExp(r'[A-Za-z0-9]').hasMatch(text)) {
        text = current.reversed.map((c) => c.text).join();
      }
      words.add(PdfWord(text, current.first.left, current.last.right));
      current = [];
    }

    for (final c in l) {
      if (current.isNotEmpty && c.left - current.last.right > avgH * .3) flush();
      current.add(c);
    }
    flush();
    out.add(PdfLine(l.fold<double>(0, (s, c) => s + c.midY) / l.length, words));
  }
  out.sort((a, b) => b.y.compareTo(a.y));
  return out;
}
