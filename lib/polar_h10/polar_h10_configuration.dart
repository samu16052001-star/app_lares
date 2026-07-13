class PolarH10Configuration {
  const PolarH10Configuration({
    this.hrEnabled = true,
    this.rawEcgEnabled = true,
  });

  final bool hrEnabled;
  final bool rawEcgEnabled;

  bool get isValid => hrEnabled || rawEcgEnabled;

  PolarH10Configuration copyWith({
    bool? hrEnabled,
    bool? rawEcgEnabled,
  }) {
    return PolarH10Configuration(
      hrEnabled: hrEnabled ?? this.hrEnabled,
      rawEcgEnabled: rawEcgEnabled ?? this.rawEcgEnabled,
    );
  }
}
