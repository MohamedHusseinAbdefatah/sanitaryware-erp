// Draws the app icon (a white water drop on a teal rounded square, the
// app's colour) and writes windows/runner/resources/app_icon.ico with all
// the sizes Windows uses, plus a 512 px PNG preview in docs/.
//
//   flutter test tool/icon/make_icon_test.dart
//
// The .ico is used by the program, its window, the taskbar and the installer.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _teal = Color(0xFF0E7C86);
const _tealDark = Color(0xFF0A5C64);

/// The icon at [size] pixels. Small sizes drop the shine so the shape
/// stays crisp.
Future<Uint8List> _render(int size) async {
  final s = size.toDouble();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, s, s));

  // Background: rounded square with a soft vertical gradient.
  final inset = s * 0.04;
  final rect = RRect.fromRectAndRadius(
    Rect.fromLTWH(inset, inset, s - 2 * inset, s - 2 * inset),
    Radius.circular(s * 0.22),
  );
  canvas.drawRRect(
    rect,
    Paint()
      ..shader = ui.Gradient.linear(Offset(0, inset), Offset(0, s - inset), [_teal, _tealDark]),
  );

  // Water drop: a point at the top, a round bottom.
  final cx = s / 2;
  final top = s * 0.18;
  final r = s * 0.24; // radius of the round part
  final cy = s * 0.60; // centre of the round part
  final drop = Path()
    ..moveTo(cx, top)
    ..cubicTo(cx + r * 0.25, top + r * 0.75, cx + r, cy - r * 0.55, cx + r, cy)
    ..arcToPoint(Offset(cx - r, cy), radius: Radius.circular(r))
    ..cubicTo(cx - r, cy - r * 0.55, cx - r * 0.25, top + r * 0.75, cx, top)
    ..close();
  canvas.drawPath(drop, Paint()..color = Colors.white);

  if (size >= 48) {
    // A small shine on the drop.
    final shine = Path()
      ..addArc(
        Rect.fromCircle(center: Offset(cx, cy), radius: r * 0.62),
        3.5, // radians, lower-left
        1.0,
      );
    canvas.drawPath(
      shine,
      Paint()
        ..color = _teal.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.14
        ..strokeCap = StrokeCap.round,
    );
  }

  final image = await recorder.endRecording().toImage(size, size);
  // 256 px is stored as PNG; smaller sizes as a bitmap, which every Windows
  // API can read (some cannot read small PNG entries).
  if (size >= 256) {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    return png!.buffer.asUint8List();
  }
  final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!.buffer.asUint8List();
  return _bmpEntry(size, rgba);
}

/// One icon image in the classic format: BITMAPINFOHEADER, 32-bit BGRA
/// pixels bottom-up, then an all-zero AND mask (the alpha channel is used).
Uint8List _bmpEntry(int size, Uint8List rgba) {
  final maskRow = ((size + 31) ~/ 32) * 4;
  final out = ByteData(40 + size * size * 4 + maskRow * size)
    ..setUint32(0, 40, Endian.little) // header size
    ..setInt32(4, size, Endian.little) // width
    ..setInt32(8, size * 2, Endian.little) // height: pixels + mask
    ..setUint16(12, 1, Endian.little) // planes
    ..setUint16(14, 32, Endian.little) // bits per pixel
    ..setUint32(20, size * size * 4, Endian.little); // image size
  var o = 40;
  for (var y = size - 1; y >= 0; y--) {
    for (var x = 0; x < size; x++) {
      final i = (y * size + x) * 4;
      out
        ..setUint8(o++, rgba[i + 2]) // B
        ..setUint8(o++, rgba[i + 1]) // G
        ..setUint8(o++, rgba[i]) // R
        ..setUint8(o++, rgba[i + 3]); // A
    }
  }
  return out.buffer.asUint8List();
}

/// An .ico file from per-size images (bitmap entries, or PNG for 256).
Uint8List _ico(Map<int, Uint8List> pngs) {
  final sizes = pngs.keys.toList()..sort();
  final header = ByteData(6 + 16 * sizes.length)
    ..setUint16(0, 0, Endian.little)
    ..setUint16(2, 1, Endian.little) // icon
    ..setUint16(4, sizes.length, Endian.little);
  var offset = header.lengthInBytes;
  for (var i = 0; i < sizes.length; i++) {
    final size = sizes[i];
    final png = pngs[size]!;
    final e = 6 + 16 * i;
    header
      ..setUint8(e, size >= 256 ? 0 : size) // 0 means 256
      ..setUint8(e + 1, size >= 256 ? 0 : size)
      ..setUint8(e + 2, 0) // no palette
      ..setUint8(e + 3, 0)
      ..setUint16(e + 4, 1, Endian.little) // colour planes
      ..setUint16(e + 6, 32, Endian.little) // bits per pixel
      ..setUint32(e + 8, png.length, Endian.little)
      ..setUint32(e + 12, offset, Endian.little);
    offset += png.length;
  }
  final out = BytesBuilder()..add(header.buffer.asUint8List());
  for (final size in sizes) {
    out.add(pngs[size]!);
  }
  return out.toBytes();
}

void main() {
  testWidgets('write app_icon.ico', (tester) async {
    final pngs = <int, Uint8List>{};
    await tester.runAsync(() async {
      for (final size in [16, 20, 24, 32, 40, 48, 64, 128, 256]) {
        pngs[size] = await _render(size);
      }
      await File('windows/runner/resources/app_icon.ico').writeAsBytes(_ico(pngs));
      await File('docs/app_icon.png').writeAsBytes(await _render(512));
    });
    expect(File('windows/runner/resources/app_icon.ico').lengthSync(), greaterThan(1000));
  });
}
