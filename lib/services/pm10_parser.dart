double? parsePm10Value(String message) {
  final match = RegExp(r'^PM10:(\d+(?:\.\d+)?)$').firstMatch(message.trim());
  if (match == null) {
    return null;
  }

  return double.tryParse(match.group(1)!);
}
