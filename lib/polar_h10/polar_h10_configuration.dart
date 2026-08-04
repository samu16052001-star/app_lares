class PolarH10Configuration {
  const PolarH10Configuration({
    this.hrEnabled = true,
    this.rawEcgEnabled = true,
    this.accelerometerEnabled = false,
  });

  final bool hrEnabled;
  final bool rawEcgEnabled;
  final bool accelerometerEnabled;

  bool get isValid => hrEnabled || rawEcgEnabled || accelerometerEnabled;

  PolarH10Configuration copyWith({
    bool? hrEnabled,
    bool? rawEcgEnabled,
    bool? accelerometerEnabled,
  }) {
    return PolarH10Configuration(
      hrEnabled: hrEnabled ?? this.hrEnabled,
      rawEcgEnabled: rawEcgEnabled ?? this.rawEcgEnabled,
      accelerometerEnabled:
          accelerometerEnabled ?? this.accelerometerEnabled,
    );
  }
}
