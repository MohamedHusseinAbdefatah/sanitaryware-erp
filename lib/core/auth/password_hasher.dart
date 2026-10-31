import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// PBKDF2-HMAC-SHA256 with a random per-user salt. The stored hash records
/// its iteration count (`pbkdf2-sha256$<iterations>$<hex>`) so the count can
/// be raised later without breaking existing passwords.
class PasswordHasher {
  const PasswordHasher({this.iterations = 100000});

  final int iterations;

  static const _scheme = 'pbkdf2-sha256';

  String newSalt() {
    final random = Random.secure();
    return _hex(List.generate(16, (_) => random.nextInt(256)));
  }

  /// Runs on a background isolate so the window does not freeze.
  Future<String> hash(String password, String salt) async {
    final n = iterations;
    final key = await Isolate.run(() => _pbkdf2(password, salt, n));
    return '$_scheme\$$n\$$key';
  }

  Future<bool> verify(String password, String salt, String stored) async {
    final parts = stored.split(r'$');
    if (parts.length != 3 || parts[0] != _scheme) return false;
    final n = int.tryParse(parts[1]);
    if (n == null || n < 1) return false;
    final key = await Isolate.run(() => _pbkdf2(password, salt, n));
    return _constantTimeEquals(key, parts[2]);
  }
}

String _pbkdf2(String password, String salt, int iterations) {
  final hmac = Hmac(sha256, utf8.encode(password));
  // One block is enough: SHA-256 output is the 32-byte key we keep.
  var u = hmac.convert([...utf8.encode(salt), 0, 0, 0, 1]).bytes;
  final result = List<int>.of(u);
  for (var i = 1; i < iterations; i++) {
    u = hmac.convert(u).bytes;
    for (var j = 0; j < result.length; j++) {
      result[j] ^= u[j];
    }
  }
  return _hex(result);
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

bool _constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}
