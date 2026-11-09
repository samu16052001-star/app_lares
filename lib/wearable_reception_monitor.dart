import 'dart:collection';

import 'package:app_lares/wearable_agm_packet_parser.dart';

/// Share of IMU samples that reached the app in the last [window] of phone
/// time, for the "samples received" indicator.
/// Missing samples are found from the sensor time written in every packet.
class WearableReceptionMonitor {
  WearableReceptionMonitor({
    this.window = const Duration(seconds: 10),
  });

  final Duration window;

  final ListQueue<_ReceptionEvent> _events = ListQueue<_ReceptionEvent>();
  DateTime? _lastPacketAt;
  int? _expectedNextTicks;
  int? _lastAgmTimestampMs;
  int _totalReceived = 0;
  int _totalMissing = 0;

  /// Samples received since the monitor was created or reset.
  int get totalReceived => _totalReceived;

  /// Samples missing since the monitor was created or reset.
  int get totalMissing => _totalMissing;

  void reset() {
    _events.clear();
    _lastPacketAt = null;
    _expectedNextTicks = null;
    _lastAgmTimestampMs = null;
    _totalReceived = 0;
    _totalMissing = 0;
  }

  /// IMD or AG2 packet: [firstTicks] and [stepTicks] in 25 us sensor ticks.
  /// [newAcquisition] = first packet after START (no gap check).
  void addTickPacket({
    required DateTime receivedAt,
    required int firstTicks,
    required int stepTicks,
    required int sampleCount,
    required bool newAcquisition,
  }) {
    var missing = 0;
    final expected = _expectedNextTicks;
    if (!newAcquisition && expected != null && stepTicks > 0) {
      final delta = (firstTicks - expected) & 0xFFFFFFFF;
      // A "negative" difference (packet older than expected) is not a gap.
      if (delta < 0x80000000) {
        missing = delta ~/ stepTicks;
      }
    }
    _expectedNextTicks = (firstTicks + sampleCount * stepTicks) & 0xFFFFFFFF;
    _add(receivedAt, sampleCount, missing);
  }

  /// AGM batch: one timestamp (ms) per sample, nominal step [stepMs].
  void addAgmSamples({
    required DateTime receivedAt,
    required List<int> timestampsMs,
    required double stepMs,
  }) {
    var missing = 0;
    var previous = _lastAgmTimestampMs;
    for (final timestamp in timestampsMs) {
      if (previous != null && stepMs > 0) {
        final delta = timestamp - previous;
        if (delta > 1.5 * stepMs) {
          missing += (delta / stepMs).round() - 1;
        }
      }
      previous = timestamp;
    }
    _lastAgmTimestampMs = previous;
    _add(receivedAt, timestampsMs.length, missing);
  }

  /// Percentage (0-100) of samples received in the last [window], or null
  /// when no packet arrived in the window.
  double? receivedPercent(DateTime now) {
    _prune(now);
    var received = 0;
    var missing = 0;
    for (final event in _events) {
      received += event.received;
      missing += event.missing;
    }
    final total = received + missing;
    if (total == 0) {
      return null;
    }
    return 100.0 * received / total;
  }

  /// Time since the last packet, null before the first one.
  Duration? timeSinceLastPacket(DateTime now) {
    final last = _lastPacketAt;
    return last == null ? null : now.difference(last);
  }

  void _add(DateTime receivedAt, int received, int missing) {
    _events.addLast(
      _ReceptionEvent(at: receivedAt, received: received, missing: missing),
    );
    _lastPacketAt = receivedAt;
    _totalReceived += received;
    _totalMissing += missing;
    _prune(receivedAt);
  }

  void _prune(DateTime now) {
    final cutoff = now.subtract(window);
    while (_events.isNotEmpty && _events.first.at.isBefore(cutoff)) {
      _events.removeFirst();
    }
  }
}

class _ReceptionEvent {
  const _ReceptionEvent({
    required this.at,
    required this.received,
    required this.missing,
  });

  final DateTime at;
  final int received;
  final int missing;
}

/// Data watchdog of an IMU that is streaming.
///
/// The phone declares a link lost only after 5 s of radio silence. To notice sooner
/// that an IMU stopped (switched off, flat battery, out of range) the app
/// looks at the data: an IMU that is streaming sends a notification every
/// 0.12-0.37 s at 104 Hz (12, 19 or 38 samples per notification with 3, 2
/// or 1 sensors), and in the tests of 28/10 the longest pause between two
/// notifications in the app was 0.39 s. The alert threshold is
/// [minimumThreshold], or 3 times the normal pause when notifications are
/// rarer (one sensor at a low ODR). The app only warns: the link is left
/// alone, so if the signal comes back the data resume at once.
class WearableNoDataWatchdog {
  const WearableNoDataWatchdog._();

  static const Duration minimumThreshold = Duration(seconds: 2);

  /// Samples per IMD notification with MTU 247 (payload 244, header 13).
  static int samplesPerNotification(int sensorCount) {
    if (sensorCount <= 0) {
      return 0;
    }
    final samples = (244 - 13) ~/ (6 * sensorCount);
    return samples > 38 ? 38 : samples;
  }

  /// Silence that triggers the alert for [sensorMask] at [odr] Hz.
  static Duration thresholdFor({required int? sensorMask, required int odr}) {
    final mask = sensorMask;
    if (mask == null || odr <= 0) {
      return minimumThreshold;
    }
    final samples = samplesPerNotification(WearableSensorMask.countSensors(mask));
    if (samples == 0) {
      return minimumThreshold;
    }
    final normalPauseMs = 1000.0 * samples / odr;
    final adaptive = Duration(milliseconds: (3 * normalPauseMs).round());
    return adaptive > minimumThreshold ? adaptive : minimumThreshold;
  }

  /// Time without data, counted from the later of [lastDataAt] and
  /// [armedAt] (START or reconnection), when it reaches [threshold]; null
  /// otherwise.
  static Duration? silenceBeyond({
    required DateTime now,
    required DateTime? lastDataAt,
    required DateTime? armedAt,
    required Duration threshold,
  }) {
    DateTime? reference = lastDataAt;
    if (armedAt != null && (reference == null || armedAt.isAfter(reference))) {
      reference = armedAt;
    }
    if (reference == null) {
      return null;
    }
    final silence = now.difference(reference);
    return silence >= threshold ? silence : null;
  }
}
