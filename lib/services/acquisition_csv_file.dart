import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Shared file lifetime for acquisition loggers. Android files live outside the
/// cache and are leased to one writer in the retained acquisition isolate.
class AcquisitionCsvFile {
  AcquisitionCsvFile._(this.file, this.sink, this._lease);

  static const _channel = MethodChannel(
    'app_lares/acquisition_foreground_service',
  );
  static const _header = 'TIMESTAMP;DEVICE_NAME;DATA_RECEIVED;GPS_COORDINATES';
  static final Set<String> _openPaths = <String>{};

  final File file;
  final IOSink sink;
  final String? _lease;
  DateTime? _checkpointAt;

  static Future<AcquisitionCsvFile> open({
    required String fileName,
    String? existingFilePath,
    String? sessionId,
  }) async {
    // Keep the original temporary-file behavior on iOS and other platforms.
    if (!Platform.isAndroid) {
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}$fileName',
      );
      await file.create(recursive: true);
      final sink = file.openWrite(mode: FileMode.writeOnly);
      sink.writeln(_header);
      await sink.flush();
      return AcquisitionCsvFile._(file, sink, null);
    }

    final File file;
    if (existingFilePath != null) {
      file = File(existingFilePath);
      if (!await file.exists()) {
        throw FileSystemException(
          'The original acquisition CSV is no longer available.',
          existingFilePath,
        );
      }
    } else {
      final root = await _channel.invokeMethod<String>(
        'getAcquisitionStorageDirectory',
      );
      if (root == null || root.isEmpty) {
        throw const FileSystemException(
          'Persistent acquisition storage is unavailable.',
        );
      }
      // A session directory prevents two acquisitions started in the same
      // second from overwriting one another without changing exported names.
      final directoryName =
          (sessionId ?? DateTime.now().microsecondsSinceEpoch.toString())
              .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      file = File('$root${Platform.pathSeparator}$directoryName'
          '${Platform.pathSeparator}$fileName');
      await file.parent.create(recursive: true);
      if (await file.exists()) {
        throw FileSystemException(
          'This acquisition CSV already exists; recover it explicitly.',
          file.path,
        );
      }
      await file.create();
    }

    final lease = file.absolute.path;
    if (!_openPaths.add(lease)) {
      throw StateError('An acquisition already owns this CSV: $lease');
    }

    IOSink? sink;
    try {
      if (existingFilePath != null) {
        await _repairInterruptedRecord(file);
      }
      final needsHeader = await file.length() == 0;
      sink = file.openWrite(mode: FileMode.append);
      final output = AcquisitionCsvFile._(file, sink, lease);
      if (needsHeader) {
        sink.writeln(_header);
      }
      await output.flush();
      return output;
    } catch (_) {
      try {
        await sink?.close();
      } finally {
        _openPaths.remove(lease);
      }
      rethrow;
    }
  }

  Future<void> flush({bool forceCheckpoint = false}) async {
    await sink.flush();
    if (!Platform.isAndroid) {
      return;
    }
    final now = DateTime.now();
    final previous = _checkpointAt;
    if (!forceCheckpoint &&
        previous != null &&
        now.difference(previous) < const Duration(seconds: 1)) {
      return;
    }
    // This byte offset is only recorded after complete CSV rows have flushed.
    // Recovery scans the uncheckpointed suffix, not the complete acquisition.
    final checkpoint = File('${file.path}.checkpoint');
    final temporary = File('${checkpoint.path}.tmp');
    try {
      await temporary.writeAsString('${await file.length()}', flush: true);
      await temporary.rename(checkpoint.path);
      _checkpointAt = now;
    } on FileSystemException {
      // Logging remains usable if an advisory checkpoint cannot be updated.
      // Without one, recovery streams the CSV to find complete record boundaries.
    }
  }

  Future<void> close() async {
    try {
      await flush(forceCheckpoint: true);
    } finally {
      try {
        await sink.close();
      } finally {
        if (_lease != null) {
          _openPaths.remove(_lease);
        }
      }
    }
  }

  static Future<void> _repairInterruptedRecord(File file) async {
    final length = await file.length();
    if (length == 0) {
      return;
    }
    var committed = 0;
    try {
      final value = int.tryParse(
        await File('${file.path}.checkpoint').readAsString(),
      );
      if (value != null && value >= 0 && value <= length) {
        committed = value;
      }
    } on FileSystemException {
      // Older acquisition files do not have a checkpoint.
    }

    var lastCompleteRecord = committed;
    var position = committed;
    var insideQuotes = false;
    await for (final bytes in file.openRead(committed)) {
      for (final byte in bytes) {
        position += 1;
        if (byte == 0x22) {
          // Doubled quotes toggle twice; UTF-8 continuation bytes cannot be
          // mistaken for ASCII quotes or newlines.
          insideQuotes = !insideQuotes;
        } else if (byte == 0x0a && !insideQuotes) {
          lastCompleteRecord = position;
        }
      }
    }
    if (lastCompleteRecord == length) {
      return;
    }

    // Preserve an incomplete final record separately before truncating it so
    // resumed samples cannot become concatenated with a half-written row.
    final interruptedAt = DateTime.now();
    final fragment = File('${file.path}.interrupted-'
        '${interruptedAt.microsecondsSinceEpoch}');
    final fragmentSink = fragment.openWrite();
    try {
      await fragmentSink.addStream(file.openRead(lastCompleteRecord));
      await fragmentSink.flush();
    } finally {
      await fragmentSink.close();
    }
    await File('${fragment.path}.json').writeAsString(
      jsonEncode(<String, Object>{
        'type': 'interrupted_csv_record',
        'detectedAt': interruptedAt.toIso8601String(),
        'csvFilePath': file.path,
        'offset': lastCompleteRecord,
        'bytes': length - lastCompleteRecord,
      }),
      flush: true,
    );
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.truncate(lastCompleteRecord);
      await handle.flush();
    } finally {
      await handle.close();
    }
  }
}
