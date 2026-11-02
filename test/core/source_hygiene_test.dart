import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the Windows C++ files contain only ASCII', () {
    // The C++ compiler reads these files in the local code page, so a raw
    // Arabic letter becomes garbage at run time (this once broke the
    // "program already open" check). Write Arabic as character codes.
    final offenders = <String>[];
    for (final f in Directory('windows/runner').listSync().whereType<File>()) {
      if (!RegExp(r'\.(cpp|h|rc)$').hasMatch(f.path)) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].runes.any((r) => r > 127)) offenders.add('${f.path}:${i + 1}');
      }
    }
    expect(offenders, isEmpty);
  });
}
