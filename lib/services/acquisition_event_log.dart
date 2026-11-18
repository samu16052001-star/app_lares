import 'dart:async';
import 'dart:io';

/// One line of the acquisition event log.
class AcquisitionEvent {
  const AcquisitionEvent({
    required this.time,
    required this.event,
    this.deviceName = '',
    this.deviceType = '',
    this.details = '',
  });

  final DateTime time;
  final String event;
  final String deviceName;
  final String deviceType;
  final String details;
}

/// Connection and acquisition events of every device (IMUs, environmental
/// monitors, Polar H10) with the phone time in milliseconds.
///
/// The events are kept in memory from the moment the scan page opens, so the
/// connections made before the acquisition are not lost. When the
/// acquisition CSV is created, [open] writes all the events so far to the
/// companion file `Acquisition_events_<same date and time>.csv`; the next
/// events are appended as they happen, until [close]. The data CSV does not
/// change.
class AcquisitionEventLog {
  AcquisitionEventLog({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  static const String header = 'TIMESTAMP;DEVICE_NAME;DEVICE_TYPE;EVENT;DETAILS';

  /// Upper bound of the events kept in memory (a session has a few hundred).
  static const int maxEvents = 5000;

  final DateTime Function() _clock;
  final List<AcquisitionEvent> _events = [];
  File? _file;
  IOSink? _sink;
  Future<void> _writeQueue = Future<void>.value();

  /// Every event since the log was created (oldest first).
  List<AcquisitionEvent> get events => List.unmodifiable(_events);

  /// The last file opened (kept after [close], for the export).
  File? get file => _file;

  bool get isOpen => _sink != null;

  static String fileNameFor(String dataFileName) {
    const dataPrefix = 'Acquisition_data_';
    if (dataFileName.startsWith(dataPrefix)) {
      return 'Acquisition_events_${dataFileName.substring(dataPrefix.length)}';
    }
    return 'Acquisition_events_$dataFileName';
  }

  void add(
    String event, {
    String deviceName = '',
    String deviceType = '',
    String details = '',
  }) {
    final entry = AcquisitionEvent(
      time: _clock(),
      event: event,
      deviceName: deviceName,
      deviceType: deviceType,
      details: details,
    );
    _events.add(entry);
    if (_events.length > maxEvents) {
      _events.removeAt(0);
    }

    final sink = _sink;
    if (sink != null) {
      unawaited(
        _enqueue(() async {
          sink.writeln(formatRow(entry));
          await sink.flush();
        }),
      );
    }
  }

  /// Creates [file] with the header and every event so far; the next events
  /// are appended to it. A file already open is closed first.
  Future<void> open(File file) async {
    if (_sink != null) {
      await close();
    }
    _file = null;

    await file.create(recursive: true);
    final sink = file.openWrite(mode: FileMode.writeOnly);
    sink.writeln(header);
    for (final entry in _events) {
      sink.writeln(formatRow(entry));
    }
    _file = file;
    _sink = sink;
    await _enqueue(() => sink.flush());
  }

  /// Writes what is still pending and closes the file. The events added
  /// afterwards stay in memory only (and go into the next file opened).
  Future<void> close() {
    final sink = _sink;
    if (sink == null) {
      return _writeQueue;
    }

    _sink = null;
    return _enqueue(() async {
      await sink.flush();
      await sink.close();
    });
  }

  static String formatRow(AcquisitionEvent entry) {
    return [
      formatTimestamp(entry.time),
      entry.deviceName,
      entry.deviceType,
      entry.event,
      entry.details,
    ].map(_escapeField).join(';');
  }

  static String formatTimestamp(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    final date =
        '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-${two(local.day)}';
    final time = '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
    final millisecond = local.millisecond.toString().padLeft(3, '0');
    return '${date}T$time,$millisecond';
  }

  static String _escapeField(String value) {
    final oneLine = value.replaceAll('\r', ' ').replaceAll('\n', ' ');
    if (!oneLine.contains(';') && !oneLine.contains('"')) {
      return oneLine;
    }
    return '"${oneLine.replaceAll('"', '""')}"';
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _writeQueue.catchError((_) {}).then((_) => action());
    _writeQueue = next.catchError((_) {});
    return next;
  }
}
