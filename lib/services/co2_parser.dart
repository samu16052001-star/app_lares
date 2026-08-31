double? parseCo2Value(String message) {
  final match = RegExp(r'^CO2:(\d+(?:\.\d+)?)$').firstMatch(message.trim());
  if (match == null) {
    return null;
  }

  return double.tryParse(match.group(1)!);
}
