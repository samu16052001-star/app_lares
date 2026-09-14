import 'dart:io';
import 'dart:ui' show Rect;

import 'package:app_lares/wearable_agm_packet_parser.dart';
import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';

class WearableAcquisitionCsvLogger {
  File? _file;
  IOSink? _sink;
  String? _fileName;
  bool _isStarted = false;
  bool _isStopped = false;

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
  }

  Future<void> appendAgmBatch({
    required DateTime receivedAt,
    required String deviceName,
    required String gpsCoordinates,
    required List<WearableAgmSample> samples,
  }) async {
    final sink = _sink;
    if (!_isStarted || _isStopped || sink == null || samples.isEmpty) {
      return;
    }

    try {
      sink.writeln(
        [
          _escapeCsvField(_formatLocalTimestamp(receivedAt)),
          _escapeCsvField(deviceName),
          _escapeCsvField(_formatDataReceived(samples)),
          _escapeCsvField(gpsCoordinates),
        ].join(';'),
      );
      await sink.flush();
    } catch (error) {
      debugPrint('Wearable CSV append error: $error');
    }
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

    await sink.flush();
    await sink.close();
  }

  Future<void> exportToDownloadsOrShare({Rect? sharePositionOrigin}) async {
    await stop();

    final file = _file;
    final fileName = _fileName;
    if (file == null || fileName == null || !await file.exists()) {
      throw const WearableAcquisitionCsvLoggerException(
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
        sharePositionOrigin: sharePositionOrigin,
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

  String _formatDataReceived(List<WearableAgmSample> samples) {
    return samples.map(_formatSample).join(' - ');
  }

  String _formatSample(WearableAgmSample sample) {
    // t = sensor hardware timestamp (ms from sensor power-on), per sample.
    return 't=${sample.timestampMs} ms, '
        'acc=(${sample.accX.toStringAsFixed(3)}, '
        '${sample.accY.toStringAsFixed(3)}, '
        '${sample.accZ.toStringAsFixed(3)}) g, '
        'gyr=(${sample.gyrX.toStringAsFixed(3)}, '
        '${sample.gyrY.toStringAsFixed(3)}, '
        '${sample.gyrZ.toStringAsFixed(3)}) dps';
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

class WearableAcquisitionCsvLoggerException implements Exception {
  const WearableAcquisitionCsvLoggerException(this.message);

  final String message;

  @override
  String toString() => message;
}
