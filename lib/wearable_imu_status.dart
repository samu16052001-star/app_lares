/// Reply of the IMU to the STATUS command:
/// `STATUS:<recording 0/1>,<recordings since power-on>,<uptime s>`.
///
/// The app asks it after a reconnection during an acquisition: recording = 1
/// means that only the link dropped; recording = 0 means that the IMU was
/// switched off and on, so it lost CONFIG and START.
class WearableImuStatus {
  const WearableImuStatus({
    required this.recording,
    required this.recordingsSincePowerOn,
    required this.uptimeSeconds,
  });

  static const String command = 'STATUS';
  static const String _prefix = 'STATUS:';

  final bool recording;
  final int recordingsSincePowerOn;
  final int uptimeSeconds;

  String get summary {
    return 'recording: ${recording ? 'yes' : 'no'}, '
        'recordings since power-on: $recordingsSincePowerOn, '
        'uptime: $uptimeSeconds s';
  }

  /// Null when [text] is not a valid STATUS reply.
  static WearableImuStatus? tryParse(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith(_prefix)) {
      return null;
    }

    final fields = trimmed.substring(_prefix.length).split(',');
    if (fields.length != 3) {
      return null;
    }

    final recording = int.tryParse(fields[0].trim());
    final recordings = int.tryParse(fields[1].trim());
    final uptime = int.tryParse(fields[2].trim());
    if (recording == null ||
        recordings == null ||
        uptime == null ||
        (recording != 0 && recording != 1) ||
        recordings < 0 ||
        uptime < 0) {
      return null;
    }

    return WearableImuStatus(
      recording: recording == 1,
      recordingsSincePowerOn: recordings,
      uptimeSeconds: uptime,
    );
  }
}
