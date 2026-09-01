import 'environmental_v2_configuration.dart';

abstract final class EnvironmentalV2MessageTypes {
  static const String pm1 = 'PM1';
  static const String pm25 = 'PM2.5';
  static const String pm10 = 'PM10';
  static const String vocIndex = 'VOCi';
  static const String noxIndex = 'NOXi';
  static const String temperature = 'Temp';
  static const String humidity = 'Hum';
  static const String co2 = 'CO2';
  static const String date = 'Date';
  static const String time = 'Time';
  static const String latitude = 'Lat';
  static const String longitude = 'Long';
  static const String accelerometerX = 'Accx';
  static const String accelerometerY = 'Accy';
  static const String accelerometerZ = 'Accz';
  static const String activity = 'Act';

  static const List<String> values = <String>[
    pm1,
    pm25,
    pm10,
    vocIndex,
    noxIndex,
    temperature,
    humidity,
    co2,
    date,
    time,
    latitude,
    longitude,
    accelerometerX,
    accelerometerY,
    accelerometerZ,
    activity,
  ];
}

class EnvironmentalV2ParsedMessage {
  const EnvironmentalV2ParsedMessage({
    required this.type,
    required this.value,
    required this.numericValue,
    required this.option,
  });

  final String type;
  final String value;
  final double? numericValue;
  final EnvironmentalV2Option option;
}

EnvironmentalV2ParsedMessage? parseEnvironmentalV2Message(String message) {
  final normalizedMessage = normalizeEnvironmentalV2NotificationText(message);
  if (normalizedMessage.isEmpty) {
    return null;
  }

  final separatorIndex = _firstSeparatorIndex(normalizedMessage);
  if (separatorIndex <= 0) {
    return null;
  }

  final header = normalizedMessage.substring(0, separatorIndex + 1);
  final definition = _definitionByHeader[header];
  if (definition == null) {
    return null;
  }

  final value = normalizedMessage.substring(separatorIndex + 1).trim();
  if (value.isEmpty) {
    return null;
  }

  final double? numericValue;
  switch (definition.valueKind) {
    case _EnvironmentalV2ValueKind.finiteNumber:
      final parsed = double.tryParse(value);
      if (parsed == null || !parsed.isFinite) {
        return null;
      }
      numericValue = parsed;
      break;
    case _EnvironmentalV2ValueKind.integer:
      if (!_integerPattern.hasMatch(value)) {
        return null;
      }
      final parsed = int.tryParse(value);
      if (parsed == null) {
        return null;
      }
      numericValue = parsed.toDouble();
      break;
    case _EnvironmentalV2ValueKind.text:
      numericValue = null;
      break;
  }

  return EnvironmentalV2ParsedMessage(
    type: definition.type,
    value: value,
    numericValue: numericValue,
    option: definition.option,
  );
}

String normalizeEnvironmentalV2NotificationText(String value) {
  var start = 0;
  var end = value.length;

  while (start < end && _isBoundaryPadding(value.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _isBoundaryPadding(value.codeUnitAt(end - 1))) {
    end--;
  }

  return value.substring(start, end);
}

int _firstSeparatorIndex(String message) {
  final colonIndex = message.indexOf(':');
  final equalsIndex = message.indexOf('=');

  if (colonIndex < 0) {
    return equalsIndex;
  }
  if (equalsIndex < 0) {
    return colonIndex;
  }
  return colonIndex < equalsIndex ? colonIndex : equalsIndex;
}

bool _isBoundaryPadding(int codeUnit) {
  return codeUnit == 0 || String.fromCharCode(codeUnit).trim().isEmpty;
}

enum _EnvironmentalV2ValueKind {
  finiteNumber,
  integer,
  text,
}

class _EnvironmentalV2MessageDefinition {
  const _EnvironmentalV2MessageDefinition({
    required this.type,
    required this.option,
    required this.valueKind,
  });

  final String type;
  final EnvironmentalV2Option option;
  final _EnvironmentalV2ValueKind valueKind;
}

final RegExp _integerPattern = RegExp(r'^[+-]?\d+$');

const Map<String, _EnvironmentalV2MessageDefinition> _definitionByHeader =
    <String, _EnvironmentalV2MessageDefinition>{
      'PM1:': _EnvironmentalV2MessageDefinition(
        type: EnvironmentalV2MessageTypes.pm1,
        option: EnvironmentalV2Option.pm1,
        valueKind: _EnvironmentalV2ValueKind.finiteNumber,
      ),
      'PM2.5:': _EnvironmentalV2MessageDefinition(
        type: EnvironmentalV2MessageTypes.pm25,
        option: EnvironmentalV2Option.pm25,
        valueKind: _EnvironmentalV2ValueKind.finiteNumber,
      ),
      'PM10:': _EnvironmentalV2MessageDefinition(
        type: EnvironmentalV2MessageTypes.pm10,
        option: EnvironmentalV2Option.pm10,
        valueKind: _EnvironmentalV2ValueKind.finiteNumber,
      ),
      'VOCi:': _EnvironmentalV2MessageDefinition(
        type: EnvironmentalV2MessageTypes.vocIndex,
        option: EnvironmentalV2Option.vocIndex,
        valueKind: _EnvironmentalV2ValueKind.integer,
      ),
      'NOXi:': _EnvironmentalV2MessageDefinition(
        type: EnvironmentalV2MessageTypes.noxIndex,
        option: EnvironmentalV2Option.noxIndex,
        valueKind: _EnvironmentalV2ValueKind.integer,
      ),
      'Temp:': _EnvironmentalV2MessageDefinition(
        type: EnvironmentalV2MessageTypes.temperature,
        option: EnvironmentalV2Option.temperature,
        valueKind: _EnvironmentalV2ValueKind.finiteNumber,
      ),
      'Hum:': _EnvironmentalV2MessageDefinition(
        type: EnvironmentalV2MessageTypes.humidity,
        option: EnvironmentalV2Option.humidity,
        valueKind: _EnvironmentalV2ValueKind.finiteNumber,
      ),
      'CO2:': _EnvironmentalV2MessageDefinition(
        type: EnvironmentalV2MessageTypes.co2,
        option: EnvironmentalV2Option.co2,
        valueKind: _EnvironmentalV2ValueKind.integer,
      ),
      'Date:': _EnvironmentalV2MessageDefinition(
        type: EnvironmentalV2MessageTypes.date,
        option: EnvironmentalV2Option.gps,
        valueKind: _EnvironmentalV2ValueKind.text,
      ),
      'Time:': _EnvironmentalV2MessageDefinition(
        type: EnvironmentalV2MessageTypes.time,
        option: EnvironmentalV2Option.gps,
        valueKind: _EnvironmentalV2ValueKind.text,
      ),
      'Lat:': _EnvironmentalV2MessageDefinition(
        type: EnvironmentalV2MessageTypes.latitude,
        option: EnvironmentalV2Option.gps,
        valueKind: _EnvironmentalV2ValueKind.finiteNumber,
      ),
      'Long:': _EnvironmentalV2MessageDefinition(
        type: EnvironmentalV2MessageTypes.longitude,
        option: EnvironmentalV2Option.gps,
        valueKind: _EnvironmentalV2ValueKind.finiteNumber,
      ),
      'Accx=': _EnvironmentalV2MessageDefinition(
        type: EnvironmentalV2MessageTypes.accelerometerX,
        option: EnvironmentalV2Option.accelerometer,
        valueKind: _EnvironmentalV2ValueKind.finiteNumber,
      ),
      'Accy=': _EnvironmentalV2MessageDefinition(
        type: EnvironmentalV2MessageTypes.accelerometerY,
        option: EnvironmentalV2Option.accelerometer,
        valueKind: _EnvironmentalV2ValueKind.finiteNumber,
      ),
      'Accz=': _EnvironmentalV2MessageDefinition(
        type: EnvironmentalV2MessageTypes.accelerometerZ,
        option: EnvironmentalV2Option.accelerometer,
        valueKind: _EnvironmentalV2ValueKind.finiteNumber,
      ),
      'Act:': _EnvironmentalV2MessageDefinition(
        type: EnvironmentalV2MessageTypes.activity,
        option: EnvironmentalV2Option.accelerometer,
        valueKind: _EnvironmentalV2ValueKind.integer,
      ),
    };
