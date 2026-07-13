import 'dart:async';
import 'dart:io';

import 'package:app_lares/polar_h10/polar_h10_models.dart';
import 'package:app_lares/wearable_agm_packet_parser.dart';
import 'package:share_plus/share_plus.dart';

class UnifiedAcquisitionCsvLogger {
  static final RegExp _counterPattern = RegExp(r'^\d+$');
  static const List<_CsvSensorField> _sensorFields = [
    _CsvSensorField(prefix: 'CO2', label: 'CO2', unit: 'ppm'),
    _CsvSensorField(prefix: 'TEM1', label: 'Internal Temperature', unit: 'Â°C'),
    _CsvSensorField(prefix: 'HUM1', label: 'Internal Humidity', unit: '%'),
    _CsvSensorField(prefix: 'VOC', label: 'VOC'),
    _CsvSensorField(prefix: 'NOX', label: 'NOX'),
    _CsvSensorField(prefix: 'VOCi', label: 'VOC Index'),
    _CsvSensorField(prefix: 'NOXi', label: 'NOX Index'),
    _CsvSensorField(prefix: 'NH3', label: 'NH3', unit: 'ppm'),
    _CsvSensorField(prefix: 'CO', label: 'CO', unit: 'ppm'),
    _CsvSensorField(prefix: 'Batt', label: 'Battery Level', unit: '%'),
    _CsvSensorField(prefix: 'NO2', label: 'NO2', unit: 'ppb'),
    _CsvSensorField(prefix: 'PM1.0', label: 'PM1.0', unit: 'ug/m3'),
    _CsvSensorField(prefix: 'PM2.5', label: 'PM2.5', unit: 'ug/m3'),
    _CsvSensorField(prefix: 'PM10', label: 'PM10', unit: 'ug/m3'),
    _CsvSensorField(prefix: 'TEM2', label: 'External Temperature', unit: 'Â°C'),
    _CsvSensorField(prefix: 'HUM2', label: 'External Humidity', unit: '%'),
    _CsvSensorField(prefix: 'PRE', label: 'Atmospheric Pressure', unit: 'Pa'),
  ];

  static final Map<String, _CsvSensorField> _sensorFieldsByPrefix = {
    for (final field in _sensorFields) field.prefix: field,
  };

  File? _file;
  IOSink? _sink;
  String? _fileName;
  bool _isStarted = false;
  bool _isStopped = false;
  Future<void> _writeQueue = Future<void>.value();
  final Map<String, _EnvironmentalClusterState> _environmentalClusters = {};

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
    final path =
        '${Directory.systemTemp.path}${Platform.pathSeparator}$_fileName';
    final file = File(path);

    await file.create(recursive: true);
    final sink = file.openWrite(mode: FileMode.writeOnly);
    sink.writeln('TIMESTAMP;DEVICE_NAME;DATA_RECEIVED;GPS_COORDINATES');
    await sink.flush();

    _file = file;
    _sink = sink;
    _isStarted = true;
    _isStopped = false;
    _environmentalClusters.clear();
  }

  Future<void> appendEnvironmentalMessage({
    required DateTime receivedAt,
    required String deviceName,
    required String gpsCoordinates,
    required String value,
  }) {
    return _enqueue(() async {
      final sink = _sink;
      if (!_isStarted || _isStopped || sink == null) {
        return;
      }

      final trimmedValue = value.trim();
      if (_isCounterMessage(trimmedValue)) {
        final counter = int.parse(trimmedValue);
        if (counter >= 1) {
          _handleCounter(
            counter,
            receivedAt,
            deviceName,
            gpsCoordinates,
            sink,
          );
          await sink.flush();
        }
        return;
      }

      _handleDataMessage(deviceName, trimmedValue);
    });
  }

  Future<void> appendWearableAgmSample({
    required DateTime receivedAt,
    required String deviceName,
    required String gpsCoordinates,
    required WearableAgmSample sample,
  }) {
    return _enqueue(() async {
      final sink = _sink;
      if (!_isStarted || _isStopped || sink == null) {
        return;
      }

      sink.writeln(
        [
          _escapeCsvField(_formatWearableTimestamp(receivedAt)),
          _escapeCsvField(deviceName),
          _escapeCsvField(_formatWearableDataReceived(sample)),
          _escapeCsvField(gpsCoordinates),
        ].join(';'),
      );
      await sink.flush();
    });
  }

  Future<void> appendPolarHrSample({
    required DateTime receivedAt,
    required String deviceName,
    required String gpsCoordinates,
    required int hrBpm,
  }) {
    return _enqueue(() async {
      final sink = _sink;
      if (!_isStarted || _isStopped || sink == null) {
        return;
      }

      sink.writeln(
        [
          _escapeCsvField(_formatWearableTimestamp(receivedAt)),
          _escapeCsvField(_polarDeviceName(deviceName)),
          _escapeCsvField('HR=$hrBpm'),
          _escapeCsvField(gpsCoordinates),
        ].join(';'),
      );
      await sink.flush();
    });
  }

  Future<void> appendPolarEcgSamples({
    required String deviceName,
    required List<String> gpsCoordinatesBySample,
    required List<PolarH10EcgSample> samples,
  }) {
    return _enqueue(() async {
      final sink = _sink;
      if (!_isStarted || _isStopped || sink == null || samples.isEmpty) {
        return;
      }

      for (var index = 0; index < samples.length; index += 1) {
        final sample = samples[index];
        final gpsCoordinates = index < gpsCoordinatesBySample.length
            ? gpsCoordinatesBySample[index]
            : 'NA';
        sink.writeln(
          [
            _escapeCsvField(_formatWearableTimestamp(sample.sampleTimestamp)),
            _escapeCsvField(_polarDeviceName(deviceName)),
            _escapeCsvField('ECG_raw=${sample.ecgMicrovolts}'),
            _escapeCsvField(gpsCoordinates),
          ].join(';'),
        );
      }
      await sink.flush();
    });
  }

  Future<void> stop() async {
    if (_isStopped) {
      return;
    }

    _isStopped = true;
    await _writeQueue.catchError((_) {});
    final sink = _sink;
    _sink = null;

    if (sink == null) {
      return;
    }

    for (final cluster in _environmentalClusters.values) {
      _flushEnvironmentalClusterIfNeeded(cluster, sink);
    }
    _environmentalClusters.clear();
    await sink.flush();
    await sink.close();
  }

  Future<void> exportToDownloadsOrShare() async {
    await stop();

    final file = _file;
    final fileName = _fileName;
    if (file == null || fileName == null || !await file.exists()) {
      throw const UnifiedAcquisitionCsvLoggerException(
        'CSV file is not available.',
      );
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

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _writeQueue.catchError((_) {}).then((_) => action());
    _writeQueue = next.catchError((_) {});
    return next;
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
    final cluster = _environmentalClusters.putIfAbsent(
      deviceName,
      _EnvironmentalClusterState.new,
    );
    _flushEnvironmentalClusterIfNeeded(cluster, sink);
    cluster
      ..counter = counter
      ..receivedAt = receivedAt
      ..deviceName = deviceName
      ..gpsCoordinates = gpsCoordinates
      ..values.clear();
  }

  void _handleDataMessage(String deviceName, String message) {
    final cluster = _environmentalClusters[deviceName];
    if (cluster == null || cluster.counter == null) {
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

    cluster.values[prefix] = message.substring(separatorIndex + 1).trim();
  }

  void _flushEnvironmentalClusterIfNeeded(
    _EnvironmentalClusterState cluster,
    IOSink sink,
  ) {
    if (cluster.counter == null ||
        cluster.receivedAt == null ||
        cluster.deviceName == null ||
        cluster.gpsCoordinates == null) {
      return;
    }

    sink.writeln(_buildEnvironmentalClusterRow(cluster));
    cluster.clear();
  }

  String _buildEnvironmentalClusterRow(_EnvironmentalClusterState cluster) {
    return [
      _escapeCsvField(_formatEnvironmentalTimestamp(cluster.receivedAt!)),
      _escapeCsvField(cluster.deviceName!),
      _escapeCsvField(_buildEnvironmentalDataReceivedString(cluster)),
      _escapeCsvField(cluster.gpsCoordinates!),
    ].join(';');
  }

  String _buildEnvironmentalDataReceivedString(
    _EnvironmentalClusterState cluster,
  ) {
    return _sensorFields.map((field) {
      final value = cluster.values[field.prefix] ?? 'NA';
      return field.formatValue(value);
    }).join(',');
  }

  String _formatWearableDataReceived(WearableAgmSample sample) {
    return 'acc=(${sample.accX.toStringAsFixed(3)}, '
        '${sample.accY.toStringAsFixed(3)}, '
        '${sample.accZ.toStringAsFixed(3)}) g, '
        'gyr=(${sample.gyrX.toStringAsFixed(3)}, '
        '${sample.gyrY.toStringAsFixed(3)}, '
        '${sample.gyrZ.toStringAsFixed(3)}) dps';
  }

  String _polarDeviceName(String deviceName) {
    final trimmedName = deviceName.trim();
    return trimmedName.isEmpty ? 'POLAR_H10' : trimmedName;
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

  String _formatEnvironmentalTimestamp(DateTime value) {
    return value.toLocal().toIso8601String();
  }

  String _formatWearableTimestamp(DateTime value) {
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
    ].join(':');
    final millisecond = local.millisecond.toString().padLeft(3, '0');

    return '${date}T$time,$millisecond';
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

class _EnvironmentalClusterState {
  int? counter;
  DateTime? receivedAt;
  String? deviceName;
  String? gpsCoordinates;
  final Map<String, String> values = {};

  void clear() {
    counter = null;
    receivedAt = null;
    deviceName = null;
    gpsCoordinates = null;
    values.clear();
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

class UnifiedAcquisitionCsvLoggerException implements Exception {
  const UnifiedAcquisitionCsvLoggerException(this.message);

  final String message;

  @override
  String toString() => message;
}
