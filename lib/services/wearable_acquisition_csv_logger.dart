import 'dart:io';

import 'package:app_lares/wearable_agm_packet_parser.dart';
import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';

import 'acquisition_csv_file.dart';

class WearableAcquisitionCsvLogger {
  File? _file;
  IOSink? _sink;
  AcquisitionCsvFile? _output;
  Future<void>? _startFuture;
  Future<void>? _stopFuture;
  Future<void> _writeQueue = Future<void>.value();
  String? _fileName;
  bool _isStarted = false;
  bool _isStopped = false;

  String? get fileName => _fileName;

  File? get file => _file;

  bool get isStarted => _isStarted;

  bool get isStopped => _isStopped;

  Future<void> start({
    String? existingFilePath,
    String? existingFileName,
    DateTime? startedAt,
    String? sessionId,
  }) {
    final pending = _startFuture;
    if (pending != null) return pending;
    final operation = _start(
      existingFilePath: existingFilePath,
      existingFileName: existingFileName,
      startedAt: startedAt,
      sessionId: sessionId,
    );
    _startFuture = operation;
    return operation.catchError((Object error, StackTrace stackTrace) {
      _startFuture = null;
      Error.throwWithStackTrace(error, stackTrace);
    });
  }

  Future<void> _start({
    String? existingFilePath,
    String? existingFileName,
    DateTime? startedAt,
    String? sessionId,
  }) async {
    if (_isStarted) {
      return;
    }

    final now = Platform.isAndroid ? startedAt ?? DateTime.now() : DateTime.now();
    _fileName = Platform.isAndroid && existingFilePath != null
        ? existingFileName ?? File(existingFilePath).uri.pathSegments.last
        : 'Acquisition_data_${_formatFileTimestamp(now)}.csv';
    final output = await AcquisitionCsvFile.open(
      fileName: _fileName!,
      existingFilePath: Platform.isAndroid ? existingFilePath : null,
      sessionId: sessionId,
    );

    _output = output;
    _file = output.file;
    _sink = output.sink;
    _isStarted = true;
    _isStopped = false;
    _stopFuture = null;
  }

  Future<void> appendAgmBatch({
    required DateTime receivedAt,
    required String deviceName,
    required String gpsCoordinates,
    required List<WearableAgmSample> samples,
  }) {
    if (Platform.isAndroid) {
      if (_stopFuture != null) {
        return Future<void>.value();
      }
      return _enqueue(() => _appendAgmBatch(
            receivedAt: receivedAt,
            deviceName: deviceName,
            gpsCoordinates: gpsCoordinates,
            samples: samples,
          ));
    }
    return _appendAgmBatch(
      receivedAt: receivedAt,
      deviceName: deviceName,
      gpsCoordinates: gpsCoordinates,
      samples: samples,
    );
  }

  Future<void> _appendAgmBatch({
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
      await _output!.flush();
    } catch (error) {
      debugPrint('Wearable CSV append error: $error');
    }
  }

  Future<void> stop() {
    return _stopFuture ??=
        Platform.isAndroid ? _enqueue(_stop) : _stop();
  }

  Future<void> _stop() async {
    if (_isStopped) {
      return;
    }

    _isStopped = true;
    final sink = _sink;
    _sink = null;

    if (sink == null) {
      return;
    }

    await _output!.close();
    _output = null;
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _writeQueue.catchError((_) {}).then((_) => action());
    _writeQueue = next.catchError((_) {});
    return next;
  }

  Future<void> exportToDownloadsOrShare() async {
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
    return 't=${sample.timestampMs} ms, acc=(${sample.accX.toStringAsFixed(3)}, '
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
