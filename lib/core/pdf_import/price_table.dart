/// Finds a price table in the lines of a supplier's PDF: rows with a product
/// code and one or more prices in columns. Pure Dart.
///
/// What it trusts: codes, Latin descriptions and prices. Arabic text in these
/// files is often stored in broken pieces, so it is never used for a name.
/// What it never does: guess. A price that does not sit under a column, or a
/// row that cannot be read cleanly, is stopped for a person with the reason.
library;

import 'pdf_layout.dart';
import 'pdf_reader.dart';

/// A price column across the document, named by the header above it.
class PdfPriceColumn {
  PdfPriceColumn(this.label, this.count);

  /// Numbers that line up on a page that has price headers, but under none of
  /// them: often measures, sometimes a price whose header is unreadable. The
  /// person decides; they are left out unless chosen.
  bool get unnamed => label.startsWith(unnamedPrefix);

  /// From the header (أبيض، برجامون، السعر...), or "عمود 1", "عمود 2"... on
  /// pages whose header could not be read.
  final String label;

  /// How many prices are under it.
  int count;
}

/// One product row.
class PdfPriceRow {
  PdfPriceRow({required this.page, required this.code, required this.name, required this.prices, this.issue});

  final int page;
  final String code;
  final String name;

  /// Column label -> the price exactly as printed.
  final Map<String, String> prices;

  /// Why the row needs a person; null when it read cleanly.
  final String? issue;
}

class PdfPriceTable {
  const PdfPriceTable({
    required this.columns,
    required this.rows,
    required this.pagesRead,
    required this.scannedPages,
  });

  final List<PdfPriceColumn> columns;
  final List<PdfPriceRow> rows;
  final List<int> pagesRead;

  /// Pages with no text at all: pictures, which cannot be read safely.
  final List<int> scannedPages;

  bool get allScanned => pagesRead.isNotEmpty && scannedPages.length == pagesRead.length;
}

/// Generic price headers, which mean "the price" and name no colour.
const genericPriceLabel = 'السعر';

/// Columns found only because numbers line up, on pages with no header.
const numberedPrefix = 'عمود ';

/// Numbers lined up beside the headed columns, with no header of their own.
const unnamedPrefix = 'عمود بدون عنوان ';

/// Header words for a price column, in the forms these lists print them.
String? _labelOf(String word) {
  final w = word.toLowerCase().replaceAll(RegExp(r'[()\[\]:]'), '');
  if (w == 'white' || w == 'wihte' || w.contains('أبيض') || w.contains('ابيض')) return 'أبيض';
  if (w.startsWith('pergamon') || w.contains('جامون')) return 'برجامون';
  if (w == 'colour' || w == 'color' || w == 'colours' || w == 'colors' || w == 'ألوان' || w == 'الوان') return 'ألوان';
  if (w == 'price' || w == 'prices' || w == 'le' || w == 'l.e.' || w == 'l.e' || w == 'egp' ||
      w.contains('السعر') || w.contains('جنيه')) {
    return genericPriceLabel;
  }
  return null;
}

const _headerWords = {'code', 'model', 'model-no.', 'description', 'كود', 'الكود', 'الموديل'};

final _price = RegExp(r'^[1-9]\d{0,2}(,\d{3})+$|^[1-9]\d{1,6}$');
final _code = RegExp(r'^(?=.*\d)[A-Za-z0-9][A-Za-z0-9\-/.]{3,}$');
final _measure = RegExp(r'^\d*[xX×]\d+$|^[xX×]\d+|^\d+[xX×]$|^Ø');
final _codeSuffix = RegExp(r'^(xx|XX|\d{2})$');
final _latinWord = RegExp(r'^[A-Za-z][A-Za-z\-&/(),.]*$');
const _noise = {'mm', 'x', 'X', 'cm', 'LE', 'L/R', 'L.E.', 'KG', 'W.T', 'xx', 'XX'};
const _units = {'x', 'X', '×', 'mm', 'cm', 'سم', 'مم'};

int? _priceValue(String t) => _price.hasMatch(t) ? int.tryParse(t.replaceAll(',', '')) : null;

/// True when the word next to [i] makes it a measure ("460 X 550", "60 cm").
bool _isMeasure(List<PdfWord> w, int i) {
  bool unit(int k) => k >= 0 && k < w.length && _units.contains(w[k].text);
  return unit(i - 1) || unit(i + 1);
}

/// Index of the code on a line, or -1.
int _codeIndex(List<PdfWord> w) {
  for (var k = 0; k < w.length; k++) {
    final t = w[k].text;
    if (_measure.hasMatch(t)) continue;
    // A letter-and-digit code, or a long digit-only one (Duravit, spare parts).
    if ((_code.hasMatch(t) && RegExp(r'[A-Za-z]').hasMatch(t)) || RegExp(r'^\d{6,}$').hasMatch(t)) return k;
  }
  return -1;
}

/// Prices on a line: positions of words that read as a price.
List<int> _priceIndexes(List<PdfWord> w, int codeAt) => [
      for (var k = 0; k < w.length; k++)
        if (k != codeAt && (_priceValue(w[k].text) ?? 0) >= 50 && !_isMeasure(w, k)) k,
    ];

class _PageColumn {
  _PageColumn(this.center, this.label);
  double center;
  String label;
}

/// Reads [pages] into a table.
PdfPriceTable extractPriceTable(List<PdfPageLines> pages) {
  final scanned = [for (final p in pages) if (p.characterCount < 20) p.number];
  final rows = <PdfPriceRow>[];
  final counts = <String, int>{};
  final seen = <String>{};

  for (final p in pages) {
    final lines = p.lines;
    final rowLines = <int, int>{}; // line index -> code index
    for (var li = 0; li < lines.length; li++) {
      final ci = _codeIndex(lines[li].words);
      if (ci >= 0 && _priceIndexes(lines[li].words, ci).isNotEmpty) rowLines[li] = ci;
    }
    if (rowLines.isEmpty) continue;

    // Columns on this page: from header words, else from where prices line up.
    final columns = <_PageColumn>[];
    for (var li = 0; li < lines.length; li++) {
      if (rowLines.containsKey(li)) continue;
      final lw = lines[li].words;
      final labels = lw.where((x) => _labelOf(x.text) != null).length;
      // A header line: it names columns (Code, Description...), or it is a short
      // line of price names. A note like "(450 LE)" in a paragraph is not.
      final isHeader = labels >= 2 ||
          (labels >= 1 && lw.any((x) => _headerWords.contains(x.text.toLowerCase()))) ||
          (labels >= 1 && lw.length <= 4);
      if (!isHeader) continue;
      for (final word in lw) {
        final label = _labelOf(word.text);
        if (label == null) continue;
        final near = columns.where((c) => (c.center - word.center).abs() <= 22).firstOrNull;
        if (near == null) {
          columns.add(_PageColumn(word.center, label));
        } else if (near.label == genericPriceLabel && label != genericPriceLabel) {
          // A colour name says more than "price".
          near.label = label;
        }
      }
    }
    if (columns.isEmpty) {
      final xs = <double>[
        for (final e in rowLines.entries)
          for (final k in _priceIndexes(lines[e.key].words, e.value)) lines[e.key].words[k].center,
      ]..sort();
      final groups = <List<double>>[];
      for (final x in xs) {
        final g = groups.where((g) => (g.reduce((a, b) => a + b) / g.length - x).abs() <= 14).firstOrNull;
        if (g == null) {
          groups.add([x]);
        } else {
          g.add(x);
        }
      }
      final kept = groups.where((g) => g.length >= 2).toList()
        ..sort((a, b) => a.first.compareTo(b.first));
      for (var i = 0; i < kept.length; i++) {
        columns.add(_PageColumn(kept[i].reduce((a, b) => a + b) / kept[i].length, '$numberedPrefix${i + 1}'));
      }
    } else {
      // Numbers that line up beside the headed columns but under none of them.
      final loose = <double>[];
      for (final e in rowLines.entries) {
        for (final k in _priceIndexes(lines[e.key].words, e.value)) {
          final x = lines[e.key].words[k].center;
          if (columns.every((c) => (c.center - x).abs() > 28)) loose.add(x);
        }
      }
      loose.sort();
      final groups = <List<double>>[];
      for (final x in loose) {
        final g = groups.where((g) => (g.reduce((a, b) => a + b) / g.length - x).abs() <= 14).firstOrNull;
        if (g == null) {
          groups.add([x]);
        } else {
          g.add(x);
        }
      }
      final kept = groups.where((g) => g.length >= 2).toList()..sort((a, b) => a.first.compareTo(b.first));
      for (var i = 0; i < kept.length; i++) {
        columns.add(_PageColumn(kept[i].reduce((a, b) => a + b) / kept[i].length, '$unnamedPrefix${i + 1}'));
      }
    }
    if (columns.isEmpty) continue;

    for (final e in rowLines.entries) {
      final li = e.key;
      final ci = e.value;
      final w = lines[li].words;

      // The code, with "xx 00" style parts printed apart joined back on.
      final parts = [w[ci].text];
      var k = ci + 1;
      while (k < w.length && parts.length < 3 && _codeSuffix.hasMatch(w[k].text) && w[k].left - w[k - 1].right < 12) {
        parts.add(w[k].text);
        k++;
      }
      final code = parts.join(' ');
      final used = {for (var j = ci; j < k; j++) j};

      final prices = <String, String>{};
      String? issue;
      for (final j in _priceIndexes(w, ci)) {
        if (used.contains(j)) continue;
        _PageColumn? best;
        var bestD = 28.0;
        for (final c in columns) {
          final d = (c.center - w[j].center).abs();
          if (d <= bestD) {
            bestD = d;
            best = c;
          }
        }
        if (best == null) {
          // A number with no column over it may be a measure or another price;
          // it is not dropped silently. The row waits for a person.
          issue ??= 'رقم ${w[j].text} لا يقع تحت عمود سعر';
          continue;
        }
        if (prices.containsKey(best.label)) {
          issue ??= 'سعران تحت نفس العمود';
          continue;
        }
        prices[best.label] = w[j].text;
        used.add(j);
      }
      if (prices.isEmpty) continue;

      // The name: Latin words on the row, else on the lines just above it
      // (some lists print the description over the price line).
      String latin(List<PdfWord> ws, Set<int> skip) => [
            for (var j = 0; j < ws.length; j++)
              if (!skip.contains(j) &&
                  _latinWord.hasMatch(ws[j].text) &&
                  !_noise.contains(ws[j].text) &&
                  !_code.hasMatch(ws[j].text))
                ws[j].text,
          ].join(' ');
      var name = latin(w, used);
      if (name.split(' ').where((s) => s.isNotEmpty).length < 2) {
        final above = <String>[];
        for (var a = li - 1; a >= 0 && a >= li - 6; a--) {
          final aw = lines[a].words;
          if (rowLines.containsKey(a)) break;
          if (aw.any((x) => _headerWords.contains(x.text.toLowerCase()) || _labelOf(x.text) != null)) break;
          final t = latin(aw, const {});
          if (t.isNotEmpty) above.insert(0, t);
        }
        name = [...above, name].where((s) => s.isNotEmpty).join(' ');
      }

      // The same code at the same prices printed twice is one row.
      final key = '$code|${(prices.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).map((e) => '${e.key}=${e.value}').join(',')}';
      if (!seen.add(key)) continue;
      for (final l in prices.keys) {
        counts[l] = (counts[l] ?? 0) + 1;
      }
      rows.add(PdfPriceRow(page: p.number, code: code, name: name.trim(), prices: prices, issue: issue));
    }
  }

  return PdfPriceTable(
    columns: [for (final e in counts.entries) PdfPriceColumn(e.key, e.value)],
    rows: rows,
    pagesRead: [for (final p in pages) p.number],
    scannedPages: scanned,
  );
}
