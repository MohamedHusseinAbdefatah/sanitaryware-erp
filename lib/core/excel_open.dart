import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';

/// Opens an .xlsx file. Files written by some other programs point to their
/// sheets with a full path or hold empty text cells, which the excel package
/// cannot read; such a file is repaired in memory and opened. Throws if it
/// still cannot be read.
Excel openExcel(List<int> bytes) {
  try {
    return Excel.decodeBytes(bytes);
  } on Object {
    return Excel.decodeBytes(_repaired(bytes));
  }
}

List<int> _repaired(List<int> bytes) {
  final zip = ZipDecoder().decodeBytes(bytes);
  final out = Archive();
  for (final f in zip.files) {
    if (f.name == 'xl/_rels/workbook.xml.rels') {
      final text = utf8.decode(f.content as List<int>).replaceAll('Target="/xl/', 'Target="');
      final fixed = utf8.encode(text);
      out.addFile(ArchiveFile(f.name, fixed.length, fixed));
    } else if (f.name.startsWith('xl/worksheets/') && f.name.endsWith('.xml')) {
      // An empty text cell with no text element in it stops the reader.
      final text = utf8.decode(f.content as List<int>).replaceAllMapped(
            RegExp(r'<c ([^>]*?) ?t="inlineStr"( ?[^>/]*)(?:/>|></c>)'),
            (m) => '<c ${m[1]}${m[2]}/>',
          );
      final fixed = utf8.encode(text);
      out.addFile(ArchiveFile(f.name, fixed.length, fixed));
    } else {
      out.addFile(f);
    }
  }
  return ZipEncoder().encode(out)!;
}
