/// A problem the person can fix (missing field, not enough stock, ...).
/// [message] is Arabic and shown to them as-is; nothing has been saved.
class ValidationException implements Exception {
  ValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}
