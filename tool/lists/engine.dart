// Turns the positioned lines of a supplier's PDF into product rows. Each
// list gets a small configuration: where its codes, prices and names sit.
import 'pdf_text.dart';

class Row {
  Row(this.page, this.code, this.nameEn, this.nameAr, this.prices, {this.pack, this.section});

  final int page;
  String code;
  String nameEn;
  String nameAr;

  /// Colour label -> price text as printed.
  final Map<String, String> prices;
  String? pack;
  String? section;
  final issues = <String>[];

  String get name => nameEn.isNotEmpty ? nameEn : nameAr;
}

class Cfg {
  const Cfg({
    required this.code,
    this.codeSuffix,
    required this.codeX,
    required this.priceX,
    this.enX,
    this.arX,
    this.packX,
    this.defaultLabel = 'السعر',
    this.labels = const {},
    this.pages,
    this.nameAbove = true,
    this.maxAbove = 12,
    this.stopWords = const {},
    this.inheritTitle = false,
    this.noteGap = 12,
    this.noteWords = const {},
    this.pageTitle = false,
    this.codeGap = 14,
    this.trailGap = 0,
    this.minPriceDigits = 1,
    this.rowWord,
    this.headLettersOnly = false,
  });

  /// Each name starts with the page's product title: the last line above
  /// the table with an English and an Arabic title on it.
  final bool pageTitle;

  /// Largest gap between the parts of one code.
  final double codeGap;

  /// Arabic lines closer than this under a row are its Arabic name (0: none).
  final double trailGap;

  /// A price without a thousands comma has at least this many digits.
  final int minPriceDigits;

  /// Which words of the price line itself belong to the name.
  final bool Function(Word w, Line line)? rowWord;

  /// Only words with letters from the lines above a row (labels, not
  /// stray numbers).
  final bool headLettersOnly;

  /// Words that open a note box (its lines are not names).
  final Set<String> noteWords;

  /// Lines closer than this under a note belong to the note.
  final double noteGap;

  /// A row with no title lines of its own takes the title above it (a
  /// size or variant under one product).
  final bool inheritTitle;

  final RegExp code;
  final RegExp? codeSuffix;
  final (double, double) codeX;
  final (double, double) priceX;
  final (double, double)? enX;
  final (double, double)? arX;
  final (double, double)? packX;
  final String defaultLabel;

  /// Header word (lower case) -> colour label.
  final Map<String, String> labels;
  final Set<int>? pages;

  /// Whether lines above a row (since the previous row) are part of its name.
  final bool nameAbove;
  final int maxAbove;

  /// Lines containing these words end a name block (notes, headers).
  final Set<String> stopWords;
}

final priceRe = RegExp(r'^(\d{1,3}(,\d{3})+(\.\d{1,2})?|\d+(\.\d{1,2})?|\d+,\d{2})$');

bool inX((double, double)? r, Word w) => r != null && w.left >= r.$1 && w.left <= r.$2;

class _Col {
  _Col(this.x, this.label, [this.li = -1]);
  double x;
  String label;

  /// The line it heads from on its page; -1 when carried from a page before.
  int li;
}

/// The header word over a price column, with a colour number after it
/// ("white 22") kept as part of the name.
String? _headerLabel(Cfg c, List<Word> ws, int i) {
  final key = ws[i].text.toLowerCase().replaceAll(RegExp(r'[():]'), '');
  final l = c.labels[key];
  if (l == null) return null;
  if (i + 1 < ws.length && RegExp(r'^\d{2}$').hasMatch(ws[i + 1].text) && ws[i + 1].left - ws[i].right < 12) {
    return '$l ${ws[i + 1].text}';
  }
  return l;
}

List<Row> extract(List<List<Line>> pages, Cfg c) {
  final rows = <Row>[];
  var headers = <_Col>[];
  var titleEn = '', titleAr = '';
  for (var pi = 0; pi < pages.length; pi++) {
    if (c.pages != null && !c.pages!.contains(pi + 1)) continue;
    final lines = [...pages[pi]]..sort((a, b) => b.cy.compareTo(a.cy));

    // Pass 1: row lines (a code and at least one price) and header words.
    final rowAt = <int, (int, List<int>, List<int>)>{}; // line -> (code index, code parts, price indexes)
    final pageHeaders = <_Col>[];
    for (var li = 0; li < lines.length; li++) {
      final ws = lines[li].words;
      final ci = ws.indexWhere((w) => inX(c.codeX, w) && c.code.hasMatch(w.text));
      final used = <int>[];
      if (ci >= 0) {
        used.add(ci);
        var k = ci + 1;
        while (c.codeSuffix != null && k < ws.length && used.length < 4 && c.codeSuffix!.hasMatch(ws[k].text) &&
            ws[k].left - ws[k - 1].right < c.codeGap) {
          used.add(k);
          k++;
        }
      }
      final pw = [
        for (var k = 0; k < ws.length; k++)
          if (!used.contains(k) && inX(c.priceX, ws[k]) && priceRe.hasMatch(ws[k].text) &&
              (ws[k].text.contains(',') || ws[k].text.replaceAll(RegExp(r'\D'), '').length >= c.minPriceDigits))
            k,
      ];
      if (ci >= 0 && pw.isNotEmpty) {
        rowAt[li] = (ci, used, pw);
      } else {
        for (var i = 0; i < ws.length; i++) {
          if (!inX(c.priceX, ws[i])) continue;
          final l = _headerLabel(c, ws, i);
          if (l != null) pageHeaders.add(_Col((ws[i].left + ws[i].right) / 2, l, li));
        }
        // Colour numbers over a column ("18 - 43 - 53"): the colours it prices.
        var g = <Word>[];
        void flush() {
          final nums = g.where((w) => RegExp(r'^\d{2}$').hasMatch(w.text)).map((w) => w.text).toList();
          if (nums.length >= 2) {
            pageHeaders.add(_Col((g.first.left + g.last.right) / 2, 'ألوان ${nums.join('-')}', li));
          }
          g = [];
        }
        for (final w in ws) {
          final part = inX(c.priceX, w) && RegExp(r'^(\d{2}|-)$').hasMatch(w.text);
          if (part && (g.isEmpty || w.left - g.last.right < 10)) {
            g.add(w);
          } else {
            flush();
            if (part) g.add(w);
          }
        }
        flush();
      }
    }
    if (rowAt.isEmpty) continue;
    // Headers from earlier pages still name columns until this page names them.
    final active = [for (final h in headers) _Col(h.x, h.label), ...pageHeaders];
    if (pageHeaders.isNotEmpty) headers = pageHeaders;

    // Pass 2: price columns where the prices line up, named by the header
    // closest above them; a column with no header is the plain price.
    final xs = <double>[
      for (final e in rowAt.entries)
        for (final j in e.value.$3) (lines[e.key].words[j].left + lines[e.key].words[j].right) / 2,
    ]..sort();
    final cols = <_Col>[];
    for (final x in xs) {
      final near = cols.where((k) => (k.x - x).abs() <= 16).firstOrNull;
      if (near == null) cols.add(_Col(x, ''));
    }
    // A price takes the nearest header above its own row over its column.
    String labelFor(double x, int rowLi) {
      _Col? best;
      for (final h in active) {
        if (h.label == 'السعر' || (h.x - x).abs() > 20 || h.li >= rowLi) continue;
        if (best == null || h.li > best.li || (h.li == best.li && (h.x - x).abs() < (best.x - x).abs())) best = h;
      }
      return best?.label ?? c.defaultLabel;
    }

    // The page title, for lists that name products by their page.
    var pageEn = '', pageAr = '';
    if (c.pageTitle) {
      final first = lines.indexWhere((l) => l.words.any((w) => c.stopWords.contains(w.text.toLowerCase())));
      for (var i = 0; i < (first < 0 ? lines.length : first); i++) {
        final ws = lines[i].words;
        final en = ws.where((w) => !w.isArabic && RegExp(r'[A-Za-z]{3}').hasMatch(w.text)).toList();
        final ar = ws.where((w) => w.isArabic).toList();
        if (en.isNotEmpty && ar.isNotEmpty) {
          pageEn = tidyLatin(ws
              .where((w) => !w.isArabic && (c.enX == null || inX(c.enX, w)) && !RegExp(r'^[A-Z]$').hasMatch(w.text))
              .where((w) => RegExp(r'[A-Za-z]').hasMatch(w.text))
              .map((w) => w.text)
              .join(' '));
          pageAr = (ar..sort((a, b) => b.left.compareTo(a.left))).map((w) => w.text).join(' ');
        }
      }
    }

    // Pass 3: rows.
    var blockStart = 0;
    var noteUntil = -1;
    for (var li = 0; li < lines.length; li++) {
      final ws = lines[li].words;
      final hit = rowAt[li];
      if (hit == null) {
        // Notes and column headers are not names; a note box runs on over
        // the lines packed right under it.
        final note = ws.any((w) => c.noteWords.contains(w.text.toLowerCase())) ||
            (li > 0 && noteUntil == li - 1 && (lines[li - 1].cy - lines[li].cy) < c.noteGap);
        if (note) noteUntil = li;
        if (note || ws.any((w) => c.stopWords.contains(w.text.toLowerCase()))) blockStart = li + 1;
        continue;
      }
      noteUntil = -1;
      final (ci, used, pw) = hit;
      final prices = <String, String>{};
      final issues = <String>[];
      for (final j in pw) {
        final x = (ws[j].left + ws[j].right) / 2;
        final col = cols.reduce((a, b) => (a.x - x).abs() <= (b.x - x).abs() ? a : b);
        final label = labelFor(col.x, li);
        if (prices.containsKey(label)) {
          issues.add('سعران تحت عمود $label');
          continue;
        }
        prices[label] = ws[j].text;
      }
      bool skip(Word w) => used.any((u) => identical(ws[u], w)) || pw.any((p) => identical(ws[p], w));
      final start = blockStart.clamp(0, li);
      final head = c.nameAbove ? lines.sublist(start, li) : <Line>[];
      final headTrim = head.length > c.maxAbove ? head.sublist(head.length - c.maxAbove) : head;
      bool rowSkip(Word w) => skip(w) || (c.rowWord != null && !c.rowWord!(w, lines[li]));
      final rowEn = c.enX == null ? '' : latinIn([lines[li]], c.enX!.$1, c.enX!.$2, skip: rowSkip);
      final rowAr = c.arX == null ? '' : arabicIn([lines[li]], c.arX!.$1, c.arX!.$2, skip: skip);
      final headEn = c.enX == null
          ? ''
          : latinIn(headTrim, c.enX!.$1, c.enX!.$2,
              skip: c.headLettersOnly ? (w) => !headTrim.any((l) => l.words.contains(w) && inPhrase(w, l)) : null);
      final headAr = c.arX == null ? '' : arabicIn(headTrim, c.arX!.$1, c.arX!.$2);
      if (c.inheritTitle) {
        if (headEn.isNotEmpty || headAr.isNotEmpty) {
          titleEn = headEn;
          titleAr = headAr;
        }
      } else {
        titleEn = headEn;
        titleAr = headAr;
      }
      String join(String a, String b) =>
          b.isNotEmpty && a.endsWith(b) ? a : [a, b].where((s) => s.isNotEmpty).join(' ');
      String? pack;
      if (c.packX != null) {
        pack = ws.where((w) => inX(c.packX, w) && RegExp(r'^\d+$').hasMatch(w.text)).firstOrNull?.text;
      }
      final row = Row(pi + 1, [for (final u in used) ws[u].text].join(' '), tidyLatin(join(pageEn, join(titleEn, rowEn))),
          join(pageAr, join(titleAr, rowAr)), prices, pack: pack);
      row.issues.addAll(issues);
      rows.add(row);
      blockStart = li + 1;
      // The Arabic line printed right under the row belongs to it.
      if (c.trailGap > 0 && c.arX != null) {
        var k = li + 1;
        while (k < lines.length && !rowAt.containsKey(k) &&
            lines[k].words.any((w) => w.isArabic) &&
            !lines[k].words.any((w) => RegExp(r'[A-Za-z]').hasMatch(w.text)) &&
            lines[k - 1].cy - lines[k].cy < c.trailGap) {
          final more = arabicIn([lines[k]], c.arX!.$1, c.arX!.$2);
          if (more.isNotEmpty) row.nameAr = [row.nameAr, more].where((s) => s.isNotEmpty).join(' ');
          k++;
        }
        blockStart = k;
      }
    }
  }
  return rows;
}

/// Lines that look like products but did not become rows: a code in the code
/// column, or a price-like number in the price columns. Each must be
/// explained before a list is trusted.
List<String> orphans(List<List<Line>> pages, Cfg c, List<Row> rows) {
  final out = <String>[];
  final rowKeys = {for (final r in rows) '${r.page}|${r.code.split(' ').first}'};
  for (var pi = 0; pi < pages.length; pi++) {
    if (c.pages != null && !c.pages!.contains(pi + 1)) continue;
    // An index of codes with no prices at all is not a price page.
    final hasPrice = pages[pi].any((l) => l.words.any((w) => inX(c.priceX, w) && RegExp(r'^\d{1,3}(,\d{3})+$').hasMatch(w.text)));
    if (!rows.any((r) => r.page == pi + 1) && !hasPrice) continue;
    for (final l in pages[pi]) {
      if (l.words.any((w) => const {'customer', 'service', 'hotline'}.contains(w.text.toLowerCase()))) continue;
      final code = l.words.where((w) => inX(c.codeX, w) && c.code.hasMatch(w.text)).firstOrNull;
      final prices = l.words.where((w) =>
          inX(c.priceX, w) && priceRe.hasMatch(w.text) && (w.text.contains(',') || w.text.replaceAll('.', '').length >= 3));
      if (code != null && rowKeys.contains('${pi + 1}|${code.text}')) continue;
      if (code != null || prices.isNotEmpty) out.add('p${pi + 1}: ${l.words.join('  ')}');
    }
  }
  return out;
}
