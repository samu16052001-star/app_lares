import 'dart:async';
import 'dart:io';

import 'package:share_plus/share_plus.dart';

class AcquisitionCsvLogger {
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

    final now = DateTime.now().toUtc();
    _fileName = 'Acquisition_data_${_formatFileTimestamp(now)}.csv';
    final path = '${Directory.systemTemp.path}${Platform.pathSeparator}$_fileName';
    final file = File(path);

    await file.create(recursive: true);
    final sink = file.openWrite(mode: FileMode.writeOnly);
    sink.writeln('TIMESTAMP;DEVICE_NAME;DATA_RECEIVED');
    await sink.flush();

    _file = file;
    _sink = sink;
    _isStarted = true;
    _isStopped = false;
  }

  Future<void> appendBleMessage({
    required DateTime receivedAt,
    required String deviceName,
    required String value,
  }) async {
    final sink = _sink;
    if (!_isStarted || _isStopped || sink == null) {
      return;
    }

    final row = [
      _escapeCsvField(_formatUtcTimestamp(receivedAt)),
      _escapeCsvField(deviceName),
      _escapeCsvField(value),
    ].join(';');

    sink.writeln(row);
    await sink.flush();
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

  String _escapeCsvField(String value) {
    final needsEscaping = value.contains(';') ||
        value.contains('"') ||
        value.contains('\n') ||
        value.contains('\r') ||
        value.contains(',');

    if (!needsEscaping) {
      return value;
    }

    return '"${value.replaceAll('"', '""')}"';
  }

  String _formatUtcTimestamp(DateTime value) {
    return value.toUtc().toIso8601String();
  }

  String _formatFileTimestamp(DateTime value) {
    final utc = value.toUtc();
    final date = [
      utc.year.toString().padLeft(4, '0'),
      utc.month.toString().padLeft(2, '0'),
      utc.day.toString().padLeft(2, '0'),
    ].join('-');
    final time = [
      utc.hour.toString().padLeft(2, '0'),
      utc.minute.toString().padLeft(2, '0'),
      utc.second.toString().padLeft(2, '0'),
    ].join('-');

    return '${date}_$time';
  }
}

class AcquisitionCsvLoggerException implements Exception {
  const AcquisitionCsvLoggerException(this.message);

  final String message;

  @override
  String toString() => message;
}
