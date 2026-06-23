import 'dart:async';
import 'dart:io';

import 'package:share_plus/share_plus.dart';

class AcquisitionCsvLogger {
  static final RegExp _counterPattern = RegExp(r'^\d+$');
  static const List<_CsvSensorField> _sensorFields = [
    _CsvSensorField(
      prefix: 'CO2',
      label: 'CO2',
      unit: 'ppm',
    ),
    _CsvSensorField(
      prefix: 'TEM1',
      label: 'Internal Temperature',
      unit: '°C',
    ),
    _CsvSensorField(
      prefix: 'HUM1',
      label: 'Internal Humidity',
      unit: '%',
    ),
    _CsvSensorField(
      prefix: 'VOC',
      label: 'VOC',
    ),
    _CsvSensorField(
      prefix: 'NOX',
      label: 'NOX',
    ),
    _CsvSensorField(
      prefix: 'VOCi',
      label: 'VOC Index',
    ),
    _CsvSensorField(
      prefix: 'NOXi',
      label: 'NOX Index',
    ),
    _CsvSensorField(
      prefix: 'NH3',
      label: 'NH3',
      unit: 'ppm',
    ),
    _CsvSensorField(
      prefix: 'CO',
      label: 'CO',
      unit: 'ppm',
    ),
    _CsvSensorField(
      prefix: 'Batt',
      label: 'Battery Level',
      unit: '%',
    ),
    _CsvSensorField(
      prefix: 'NO2',
      label: 'NO2',
      unit: 'ppb',
    ),
    _CsvSensorField(
      prefix: 'PM1.0',
      label: 'PM1.0',
      unit: 'ug/m3',
    ),
    _CsvSensorField(
      prefix: 'PM2.5',
      label: 'PM2.5',
      unit: 'ug/m3',
    ),
    _CsvSensorField(
      prefix: 'PM10',
      label: 'PM10',
      unit: 'ug/m3',
    ),
    _CsvSensorField(
      prefix: 'TEM2',
      label: 'External Temperature',
      unit: '°C',
    ),
    _CsvSensorField(
      prefix: 'HUM2',
      label: 'External Humidity',
      unit: '%',
    ),
    _CsvSensorField(
      prefix: 'PRE',
      label: 'Atmospheric Pressure',
      unit: 'Pa',
    ),
  ];

  static final Map<String, _CsvSensorField> _sensorFieldsByPrefix = {
    for (final field in _sensorFields) field.prefix: field,
  };

  File? _file;
  IOSink? _sink;
  String? _fileName;
  bool _isStarted = false;
  bool _isStopped = false;
  int? _currentClusterCounter;
  DateTime? _currentClusterReceivedAt;
  String? _currentClusterDeviceName;
  String? _currentClusterGpsCoordinates;
  final Map<String, String> _currentClusterValues = {};

  String? get fileName => _fileName;

  File? get file => _file;

  bool get isStarted => _isStarted;

  bool get isStopped => _isStopped;

  Future<void> start() async {
    if (_isStarted) {
      return;
    }

    final now = DateTime.now();
    _fileName = 'Acquisition_data_${_formatFileTimestamp(now)}.csv';
    final path = '${Directory.systemTemp.path}${Platform.pathSeparator}$_fileName';
    final file = File(path);

    await file.create(recursive: true);
    final sink = file.openWrite(mode: FileMode.writeOnly);
    sink.writeln('TIMESTAMP;DEVICE_NAME;DATA_RECEIVED;GPS_COORDINATES');
    await sink.flush();

    _file = file;
    _sink = sink;
    _isStarted = true;
    _isStopped = false;
    _clearCurrentCluster();
  }

  Future<void> appendBleMessage({
    required DateTime receivedAt,
    required String deviceName,
    required String gpsCoordinates,
    required String value,
  }) async {
    final sink = _sink;
    if (!_isStarted || _isStopped || sink == null) {
      return;
    }

    final trimmedValue = value.trim();
    if (_isCounterMessage(trimmedValue)) {
      final counter = int.parse(trimmedValue);
      if (counter >= 1) {
        _handleCounter(counter, receivedAt, deviceName, gpsCoordinates, sink);
        await sink.flush();
      }
      return;
    }

    _handleDataMessage(trimmedValue);
  }

  Future<void> stop() async {
    if (_isStopped) {
      return;
    }

    _isStopped = true;
    final sink = _sink;
    _sink = null;

    if (sink == null) {
      return;
    }

    _flushCurrentClusterIfNeeded(sink);
    await sink.flush();
    await sink.close();
  }

  Future<void> exportToDownloadsOrShare() async {
    await stop();

    final file = _file;
    final fileName = _fileName;
    if (file == null || fileName == null || !await file.exists()) {
      throw const AcquisitionCsvLoggerException('CSV file is not available.');
    }

    if (Platform.isAndroid && await _copyToAndroidDownloads(file, fileName)) {
      return;
    }

    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'text/csv', name: fileName)],
        subject: fileName,
      ),
    );
  }

  Future<bool> _copyToAndroidDownloads(File source, String fileName) async {
    final downloadsDirectory = Directory('/storage/emulated/0/Download');
    try {
      if (!await downloadsDirectory.exists()) {
        return false;
      }

      final destination = File(
        '${downloadsDirectory.path}${Platform.pathSeparator}$fileName',
      );
      await source.copy(destination.path);
      return true;
    } catch (_) {
      return false;
    }
  }

  bool _isCounterMessage(String value) {
    return _counterPattern.hasMatch(value);
  }

  void _handleCounter(
    int counter,
    DateTime receivedAt,
    String deviceName,
    String gpsCoordinates,
    IOSink sink,
  ) {
    _flushCurrentClusterIfNeeded(sink);
    _currentClusterCounter = counter;
    _currentClusterReceivedAt = receivedAt;
    _currentClusterDeviceName = deviceName;
    _currentClusterGpsCoordinates = gpsCoordinates;
    _currentClusterValues.clear();
  }

  void _handleDataMessage(String message) {
    if (_currentClusterCounter == null) {
      return;
    }

    final separatorIndex = message.indexOf(':');
    if (separatorIndex <= 0) {
      return;
    }

    final prefix = message.substring(0, separatorIndex);
    if (!_sensorFieldsByPrefix.containsKey(prefix)) {
      return;
    }

    _currentClusterValues[prefix] = message.substring(separatorIndex + 1).trim();
  }

  void _flushCurrentClusterIfNeeded(IOSink sink) {
    if (_currentClusterCounter == null ||
        _currentClusterReceivedAt == null ||
        _currentClusterDeviceName == null ||
        _currentClusterGpsCoordinates == null) {
      return;
    }

    sink.writeln(_buildClusterRow());
    _clearCurrentCluster();
  }

  String _buildClusterRow() {
    final receivedAt = _currentClusterReceivedAt!;
    final deviceName = _currentClusterDeviceName!;
    final gpsCoordinates = _currentClusterGpsCoordinates!;

    return [
      _escapeCsvField(_formatLocalTimestamp(receivedAt)),
      _escapeCsvField(deviceName),
      _escapeCsvField(_buildDataReceivedString()),
      _escapeCsvField(gpsCoordinates),
    ].join(';');
  }

  String _buildDataReceivedString() {
    return _sensorFields.map((field) {
      final value = _currentClusterValues[field.prefix] ?? 'NA';
      return field.formatValue(value);
    }).join(',');
  }

  void _clearCurrentCluster() {
    _currentClusterCounter = null;
    _currentClusterReceivedAt = null;
    _currentClusterDeviceName = null;
    _currentClusterGpsCoordinates = null;
    _currentClusterValues.clear();
  }

  String _escapeCsvField(String value) {
    final needsEscaping = value.contains(';') ||
        value.contains('"') ||
        value.contains('\n') ||
        value.contains('\r');

    if (!needsEscaping) {
      return value;
    }

    return '"${value.replaceAll('"', '""')}"';
  }

  String _formatLocalTimestamp(DateTime value) {
    return value.toLocal().toIso8601String();
  }

  String _formatFileTimestamp(DateTime value) {
    final local = value.toLocal();
    final date = [
      local.year.toString().padLeft(4, '0'),
      local.month.toString().padLeft(2, '0'),
      local.day.toString().padLeft(2, '0'),
    ].join('-');
    final time = [
      local.hour.toString().padLeft(2, '0'),
      local.minute.toString().padLeft(2, '0'),
      local.second.toString().padLeft(2, '0'),
    ].join('-');

    return '${date}_$time';
  }
}

class _CsvSensorField {
  const _CsvSensorField({
    required this.prefix,
    required this.label,
    this.unit,
  });

  final String prefix;
  final String label;
  final String? unit;

  String formatValue(String value) {
    final suffix = unit == null ? '' : ' $unit';
    return '$label:$value$suffix';
  }
}

class AcquisitionCsvLoggerException implements Exception {
  const AcquisitionCsvLoggerException(this.message);

  final String message;

  @override
  String toString() => message;
}
