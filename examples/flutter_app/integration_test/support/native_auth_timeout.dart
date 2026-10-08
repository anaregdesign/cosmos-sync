Duration nativeAuthTimeout(String value) {
  final seconds = int.tryParse(value);
  if (!RegExp(r'^[0-9]+$').hasMatch(value) ||
      seconds == null ||
      seconds < 60 ||
      seconds > 900) {
    throw ArgumentError('Native auth timeout must be 60-900 integer seconds.');
  }
  return Duration(seconds: seconds);
}
