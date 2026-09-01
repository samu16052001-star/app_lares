enum EnvironmentalV2Option {
  pm1(
    label: 'PM1',
    characteristicUuid: '12341806-1234-5678-1234-56789abcdef0',
  ),
  pm25(
    label: 'PM2.5',
    characteristicUuid: '12341804-1234-5678-1234-56789abcdef0',
  ),
  pm10(
    label: 'PM10',
    characteristicUuid: '12341805-1234-5678-1234-56789abcdef0',
  ),
  vocIndex(
    label: 'VOC Index',
    characteristicUuid: '12341812-1234-5678-1234-56789abcdef0',
  ),
  noxIndex(
    label: 'NOX Index',
    characteristicUuid: '12341813-1234-5678-1234-56789abcdef0',
  ),
  temperature(
    label: 'Temperature',
    characteristicUuid: '1234180e-1234-5678-1234-56789abcdef0',
  ),
  humidity(
    label: 'Humidity',
    characteristicUuid: '1234180f-1234-5678-1234-56789abcdef0',
  ),
  co2(
    label: 'CO2',
    characteristicUuid: '12341820-1234-5678-1234-56789abcdef0',
  ),
  gps(
    label: 'GPS',
    characteristicUuid: '12341815-1234-5678-1234-56789abcdef0',
  ),
  accelerometer(
    label: 'Accelerometer',
    characteristicUuid: '12341819-1234-5678-1234-56789abcdef0',
  );

  const EnvironmentalV2Option({
    required this.label,
    required this.characteristicUuid,
  });

  final String label;
  final String characteristicUuid;
}

EnvironmentalV2Option? environmentalV2OptionForMessageType(String type) {
  return switch (type) {
    'PM1' => EnvironmentalV2Option.pm1,
    'PM2.5' => EnvironmentalV2Option.pm25,
    'PM10' => EnvironmentalV2Option.pm10,
    'VOCi' => EnvironmentalV2Option.vocIndex,
    'NOXi' => EnvironmentalV2Option.noxIndex,
    'Temp' => EnvironmentalV2Option.temperature,
    'Hum' => EnvironmentalV2Option.humidity,
    'CO2' => EnvironmentalV2Option.co2,
    'Date' || 'Time' || 'Lat' || 'Long' => EnvironmentalV2Option.gps,
    'Accx' || 'Accy' || 'Accz' || 'Act' =>
      EnvironmentalV2Option.accelerometer,
    _ => null,
  };
}

class EnvironmentalV2Configuration {
  EnvironmentalV2Configuration({
    Map<EnvironmentalV2Option, bool> enabledOptions = const {},
  }) : enabledOptions = Map<EnvironmentalV2Option, bool>.unmodifiable(
         <EnvironmentalV2Option, bool>{
           for (final option in EnvironmentalV2Option.values)
             option: enabledOptions[option] ?? false,
         },
       );

  factory EnvironmentalV2Configuration.allOff() {
    return EnvironmentalV2Configuration();
  }

  final Map<EnvironmentalV2Option, bool> enabledOptions;

  bool isEnabled(EnvironmentalV2Option option) {
    return enabledOptions[option] ?? false;
  }

  bool isOptionEnabled(EnvironmentalV2Option option) {
    return isEnabled(option);
  }

  bool isMessageTypeEnabled(String type) {
    final option = environmentalV2OptionForMessageType(type);
    return option != null && isEnabled(option);
  }

  bool get allMeasurementsEnabled {
    return EnvironmentalV2Option.values.every(isEnabled);
  }

  List<EnvironmentalV2Option> get enabledOptionList {
    return EnvironmentalV2Option.values.where(isEnabled).toList(
      growable: false,
    );
  }

  List<String> get enabledOptionLabels {
    return enabledOptionList.map((option) => option.label).toList(
      growable: false,
    );
  }

  String get summary {
    final labels = enabledOptionLabels;
    return 'enabled=${labels.isEmpty ? 'none' : labels.join(', ')}';
  }

  EnvironmentalV2Configuration copyWithOption(
    EnvironmentalV2Option option,
    bool enabled,
  ) {
    return EnvironmentalV2Configuration(
      enabledOptions: <EnvironmentalV2Option, bool>{
        ...enabledOptions,
        option: enabled,
      },
    );
  }
}
