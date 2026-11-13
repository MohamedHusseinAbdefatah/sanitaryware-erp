import 'engine.dart';
import 'pdf_text.dart';

const _colourLabels = {
  'white': 'أبيض',
  'white-00': 'أبيض',
  'wihte': 'أبيض',
  'أبيض': 'أبيض',
  'ابيض': 'أبيض',
  'pergamon': 'برجامون',
  'برجامون': 'برجامون',
  'colour': 'ألوان',
  'colours': 'ألوان',
  'color': 'ألوان',
  'colors': 'ألوان',
  'ألوان': 'ألوان',
  'black': 'أسود',
  'أسود': 'أسود',
  'platinum': 'بلاتينيوم',
  'chrome': 'كروم',
  'كروم': 'كروم',
  'le': 'السعر',
  'price': 'السعر',
  'prices': 'السعر',
  'السعر': 'السعر',
};

/// Duravit lists (ceramics, bathtubs): 6-digit model numbers with 2-digit
/// parts, prices to the right.
final duravit = Cfg(
  code: RegExp(r'^(\d{6}|\d{8}|\d{10}|WF\d{10}|[A-Z]{1,3}\d{3,5}[A-Z]{0,2}|[A-Z]{2})$'),
  codeSuffix: RegExp(r'^(\d{2}|\d{4}|[A-Z]{2}|L/R|xx)$'),
  codeX: (405, 470),
  inheritTitle: true,
  priceX: (462, 580),
  enX: (100, 300),
  arX: (255, 378),
  labels: _colourLabels,
  minPriceDigits: 3,
  stopWords: {'description', 'ملليميتر', 'model-no.', 'جنيه'},
  noteWords: {'infobox:', 'infobox'},
);

const configs = <String, Cfg Function()>{};

/// Duravit bathtubs and shower trays: the page title names the product,
/// codes are "820208 .. 0990000" (".." = the colour digits).
final duravitBath = Cfg(
  code: RegExp(r'^\d{6}$'),
  codeSuffix: RegExp(r'^(\.\.|\d{2}|\d{7})$'),
  codeX: (355, 390),
  priceX: (455, 580),
  enX: (38, 360),
  arX: (38, 360),
  labels: _colourLabels,
  minPriceDigits: 3,
  stopWords: {'length', 'الطول'},
  noteWords: {'note', 'ملحوظة', 'ملحوظة:'},
  pageTitle: true,
  inheritTitle: true,
  rowWord: _bathRowWord,
  headLettersOnly: true,
  codeGap: 30,
  trailGap: 14,
);

/// On a bathtub price line the name is its label (letters) and its size
/// phrase ("1700 x 800 mm"): the numbers drawn together with its "mm". Other
/// numbers on the line (length, width, height, stray drawing text) are not.
bool _bathRowWord(Word w, Line line) {
  if (inPhrase(w, line)) return true;
  final mm = line.words.where((x) => x.text == 'mm' && x.left >= 195).firstOrNull;
  return mm != null && w.left >= 195 && w.left <= mm.right && (w.order - mm.order).abs() <= 30;
}
