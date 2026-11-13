// The text of a supplier's PDF page in logical order, with Arabic ligatures
// (لا، طى...) put back in the right order. PDFium gives a two-letter
// ligature as two characters, the second with zero width at the first's
// edge, in visual order; swapping exactly those pairs restores the word.
import 'dart:io';

import 'package:pdfrx/pdfrx.dart';

bool _arabic(String c) {
  final u = c.codeUnitAt(0);
  return u >= 0x0600 && u <= 0x06FF;
}

Future<List<List<String>>> readPdfLines(File file, {Set<int>? pages}) async {
  final doc = await PdfDocument.openFile(file.path);
  try {
    final out = <List<String>>[];
    for (var p = 0; p < doc.pages.length; p++) {
      if (pages != null && !pages.contains(p + 1)) {
        out.add(const []);
        continue;
      }
      final t = await doc.pages[p].loadText();
      final chars = t.fullText.split('');
      final rects = List<PdfRect?>.filled(chars.length, null);
      for (final f in t.fragments) {
        for (var k = 0; k < f.text.length && k < f.charRects.length; k++) {
          if (f.index + k < rects.length) rects[f.index + k] = f.charRects[k];
        }
      }
      for (var i = 0; i + 1 < chars.length; i++) {
        final a = rects[i], b = rects[i + 1];
        if (a == null || b == null) continue;
        if (!_arabic(chars[i]) || !_arabic(chars[i + 1])) continue;
        final zero = (b.right - b.left).abs() < 0.05;
        if (zero && (b.left - a.right).abs() < 0.6) {
          final c = chars[i];
          chars[i] = chars[i + 1];
          chars[i + 1] = c;
          i++;
        }
      }
      out.add(chars.join().replaceAll('\r', '').split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList());
    }
    return out;
  } finally {
    await doc.dispose();
  }
}

/// A word with its box (PDF points; top > bottom).
class Word {
  Word(this.text, this.left, this.right, this.top, this.bottom, [this.order = 0]);

  /// Where the word starts in the page's content: what is painted later
  /// is on top.
  final int order;

  String text;
  double left, right, top, bottom;
  double get cy => (top + bottom) / 2;
  double get h => (top - bottom).abs();
  bool get isArabic => text.runes.any((r) => r >= 0x0600 && r <= 0x06FF);

  @override
  String toString() => '$text@${left.round()}';
}

/// One visual line: words left to right.
class Line {
  Line(this.words);

  final List<Word> words;
  double get cy => words.map((w) => w.cy).reduce((a, b) => a + b) / words.length;
  String get text => words.map((w) => w.text).join(' ');

  @override
  String toString() => words.join('  ');
}

/// Pages as lines of positioned words, ligatures fixed, Arabic kept whole.
/// Words dropped because other text was painted over them, by the last read.
int overpainted = 0;

/// Words dropped because they leave no ink on the page (hidden text).
int invisible = 0;

Future<List<List<Line>>> readPdfWords(File file, {Set<int>? pages, bool inkCheck = true}) async {
  overpainted = 0;
  invisible = 0;
  final doc = await PdfDocument.openFile(file.path);
  try {
    final out = <List<Line>>[];
    for (var p = 0; p < doc.pages.length; p++) {
      if (pages != null && !pages.contains(p + 1)) {
        out.add(const []);
        continue;
      }
      final t = await doc.pages[p].loadText();
      final chars = t.fullText.split('');
      final rects = List<PdfRect?>.filled(chars.length, null);
      for (final f in t.fragments) {
        for (var k = 0; k < f.text.length && k < f.charRects.length; k++) {
          if (f.index + k < rects.length) rects[f.index + k] = f.charRects[k];
        }
      }
      // A ligature glyph (لا، طى، لمخ...) comes as its first drawn letter
      // followed by zero-width letters at its edge, in visual order: the
      // whole run is reversed to read in logical order.
      for (var i = 0; i + 1 < chars.length; i++) {
        final a = rects[i];
        if (a == null || !_arabic(chars[i])) continue;
        var j = i + 1;
        while (j < chars.length) {
          final b = rects[j];
          if (b == null || !_arabic(chars[j])) break;
          if ((b.right - b.left).abs() >= 0.05 || (b.left - a.right).abs() >= 0.6) break;
          j++;
        }
        if (j - i < 2) continue;
        final cs = chars.sublist(i, j).reversed.toList();
        final rs = rects.sublist(i, j).reversed.toList();
        for (var k = 0; k < cs.length; k++) {
          chars[i + k] = cs[k];
          rects[i + k] = rs[k];
        }
        i = j - 1;
      }
      // Words: runs of non-space characters in text order, split where the
      // text breaks a line or jumps far away.
      final words = <Word>[];
      Word? cur;
      for (var i = 0; i < chars.length; i++) {
        final c = chars[i];
        final r = rects[i];
        if (c.trim().isEmpty || r == null || (r.top - r.bottom).abs() < 0.01) {
          if (c == ' ' || c == '\n' || c == '\r' || r == null) cur = null;
          if (c.trim().isEmpty) continue;
          if (r == null) continue;
        }
        final rt = r.top, rb = r.bottom;
        final hgt = (rt - rb).abs();
        if (cur != null) {
          final sameLine = ((rt + rb) / 2 - cur.cy).abs() < 0.6 * (hgt > cur.h ? hgt : cur.h) + 1;
          final near = r.left <= cur.right + hgt * 0.6 + 1 && r.right >= cur.left - hgt * 0.6 - 1;
          if (!sameLine || !near) cur = null;
        }
        if (cur == null) {
          cur = Word(c, r.left, r.right, rt, rb, i);
          words.add(cur);
        } else {
          cur.text += c;
          if (r.left < cur.left) cur.left = r.left;
          if (r.right > cur.right) cur.right = r.right;
          if (rt > cur.top) cur.top = rt;
          if (rb < cur.bottom) cur.bottom = rb;
        }
      }
      // Text painted over other text (an old layer under a new one): the
      // word painted last is the one seen; the one under it is dropped.
      final hidden = <Word>{};
      for (var a = 0; a < words.length; a++) {
        for (var b = a + 1; b < words.length; b++) {
          final x = words[a], y = words[b];
          if ((x.cy - y.cy).abs() > 2) continue;
          final overlap = (x.right < y.right ? x.right : y.right) - (x.left > y.left ? x.left : y.left);
          final narrow = (x.right - x.left) < (y.right - y.left) ? (x.right - x.left) : (y.right - y.left);
          final wide = (x.right - x.left) > (y.right - y.left) ? (x.right - x.left) : (y.right - y.left);
          if (narrow <= 0 || overlap < 0.6 * narrow || narrow < 0.6 * wide) continue;
          hidden.add(x.order < y.order ? x : y);
        }
      }
      overpainted += hidden.length;
      words.removeWhere(hidden.contains);
      // Text that leaves no ink (white, clipped, under a picture) is not
      // what a person reads on the page.
      if (inkCheck && words.isNotEmpty) {
        const scale = 2.0;
        final page = doc.pages[p];
        final w = (page.width * scale).round(), h = (page.height * scale).round();
        final img = await page.render(width: w, height: h, fullWidth: w.toDouble(), fullHeight: h.toDouble());
        if (img != null) {
          final px = img.pixels;
          bool inked(Word x) {
            final x0 = (x.left * scale).floor().clamp(0, w - 1), x1 = (x.right * scale).ceil().clamp(0, w - 1);
            final y0 = ((page.height - x.top) * scale).floor().clamp(0, h - 1);
            final y1 = ((page.height - x.bottom) * scale).ceil().clamp(0, h - 1);
            for (var yy = y0; yy <= y1; yy++) {
              for (var xx = x0; xx <= x1; xx++) {
                final i = (yy * w + xx) * 4;
                final lum = (px[i] + px[i + 1] + px[i + 2]) / 3;
                if (lum < 150) return true;
              }
            }
            return false;
          }

          final gone = words.where((x) => !inked(x)).toList();
          invisible += gone.length;
          words.removeWhere(gone.contains);
          img.dispose();
        }
      }
      // Lines: words whose middles sit within half a word height.
      words.sort((a, b) => b.cy.compareTo(a.cy));
      final lines = <List<Word>>[];
      for (final w in words) {
        final hit = lines.where((l) {
          final cy = l.map((x) => x.cy).reduce((a, b) => a + b) / l.length;
          final h = l.map((x) => x.h).reduce((a, b) => a > b ? a : b);
          return (w.cy - cy).abs() < 0.5 * (h > w.h ? h : w.h);
        }).firstOrNull;
        if (hit != null) {
          hit.add(w);
        } else {
          lines.add([w]);
        }
      }
      out.add([for (final l in lines) Line(l..sort((a, b) => a.left.compareTo(b.left)))]);
    }
    return out;
  } finally {
    await doc.dispose();
  }
}

/// Words of a line in reading order: sub-lines (bands) top to bottom, each
/// left to right; Arabic runs read right to left by the caller.
List<List<Word>> bands(Line l, {double tol = 2.5}) {
  final ws = [...l.words]..sort((a, b) => b.cy.compareTo(a.cy));
  final out = <List<Word>>[];
  for (final w in ws) {
    final hit = out.where((b) => (b.first.cy - w.cy).abs() <= tol).firstOrNull;
    if (hit != null) {
      hit.add(w);
    } else {
      out.add([w]);
    }
  }
  for (final b in out) {
    b.sort((a, c) => a.left.compareTo(c.left));
  }
  return out;
}

final _latin = RegExp(r'[A-Za-z]');

/// Latin text between two x positions, band by band.
String latinIn(Iterable<Line> lines, double minX, double maxX, {bool Function(Word)? skip}) {
  final parts = <String>[];
  for (final l in lines) {
    for (final b in bands(l)) {
      // Numbers on an Arabic line belong to the Arabic text.
      final arabicBand = b.any((w) => w.isArabic);
      for (final w in b) {
        if (w.left < minX || w.left > maxX || w.isArabic) continue;
        if (arabicBand && !_latin.hasMatch(w.text)) continue;
        if (skip != null && skip(w)) continue;
        parts.add(w.text);
      }
    }
  }
  return tidyLatin(parts.join(' '));
}

/// Arabic text between two x positions: each band right to left.
String arabicIn(Iterable<Line> lines, double minX, double maxX, {bool Function(Word)? skip}) {
  final parts = <String>[];
  for (final l in lines) {
    for (final b in bands(l)) {
      final ws = b.where((w) => w.left >= minX && w.left <= maxX && (skip == null || !skip(w))).toList()
        ..sort((a, c) => c.left.compareTo(a.left));
      final keep = ws.where((w) => w.isArabic || RegExp(r'^[\d٠-٩.,/×x()+\-%]+$').hasMatch(w.text)).toList();
      if (keep.any((w) => w.isArabic)) parts.add(keep.map((w) => w.text).join(' '));
    }
  }
  var t = parts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  // Both brackets printed mirrored: the text's first bracket is a ")".
  final firstBracket = RegExp(r'[()]').firstMatch(t)?.group(0);
  if (firstBracket == ')' && ')'.allMatches(t).length == '('.allMatches(t).length) {
    t = t.split('').map((ch) => ch == '(' ? ')' : (ch == ')' ? '(' : ch)).join();
  }
  // A bracket printed mirrored by right-to-left layout: ")8 جيت" is "(8 جيت".
  if (')'.allMatches(t).length > '('.allMatches(t).length) {
    t = t.replaceAllMapped(RegExp(r'\)(?=[\d؀-ۿ])'), (_) => ' (').replaceAll(RegExp(r'\s+'), ' ');
  }
  return t.trim();
}

/// Brackets printed mirrored by right-to-left layout, spaces before commas.
String tidyLatin(String s) {
  var t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  t = t.replaceAllMapped(RegExp(r'(\w+)\('), (m) => '(${m[1]}');
  t = t.replaceAll(',(', '),').replaceAll(' ,', ',').replaceAll('( ', '(').replaceAll(' )', ')');
  return t;
}

/// A word with letters, or a number written inside a phrase ("standard 8
/// water jets", "(8 Water+16 Air)"): touching a word with letters.
bool inPhrase(Word w, Line line) {
  final letters = RegExp('[A-Za-z]');
  if (letters.hasMatch(w.text) && w.text != 'x' && w.text != 'X' && !RegExp(r'^[A-Z]$').hasMatch(w.text)) return true;
  for (final o in line.words) {
    if (identical(o, w) || (o.cy - w.cy).abs() > 2 || !letters.hasMatch(o.text) || o.text == 'x') continue;
    final gap = o.left > w.right ? o.left - w.right : w.left - o.right;
    if (gap >= 0 && gap < 6) return true;
  }
  return false;
}
