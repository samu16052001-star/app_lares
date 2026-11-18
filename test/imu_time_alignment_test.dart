import 'dart:math' as math;

import 'package:app_lares/imu_time_alignment.dart';
import 'package:app_lares/wearable_agm_packet_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// Simulated IMU: samples taken at [hz] on the phone clock, timestamped every
/// 9.6 ms on the sensor clock (rounded to the ms, like the app), sent in
/// notifications of [perNotification] samples that arrive late by
/// [delayMs] (one notification every five arrives with the minimum delay).
class _SimulatedImu {
  _SimulatedImu({
    required this.hz,
    this.sensorOffsetMs = 500000,
    DateTime? start,
  }) : start = start ?? DateTime(2026, 11, 13, 10);

  final double hz;
  final int perNotification = 12;
  final double sensorOffsetMs;
  final DateTime start;
  final math.Random random = math.Random(7);
  int nextSample = 0;

  /// Phone time (ms from [start]) when sample [k] is taken.
  double takenMs(int k) => k * 1000.0 / hz;

  int sensorMs(int k) => (sensorOffsetMs + k * 9.6).round();

  /// Normal delay: 20 ms minimum, often more.
  double normalDelayMs(int notification) =>
      notification % 5 == 0 ? 20.0 : 20.0 + random.nextDouble() * 150.0;

  /// Sends the notifications until [untilS] seconds; [delayMs] returns the
  /// delay of a notification (null = lost inside the IMU).
  void run(
    ImuClockAligner aligner,
    double untilS, {
    double? Function(int notification, double takenS)? delayMs,
  }) {
    while (takenMs(nextSample + perNotification - 1) < untilS * 1000.0) {
      final first = nextSample;
      final last = first + perNotification - 1;
      nextSample += perNotification;
      final notification = first ~/ perNotification;
      final delay = delayMs == null
          ? normalDelayMs(notification)
          : delayMs(notification, takenMs(last) / 1000.0);
      if (delay == null) {
        continue;
      }
      aligner.addNotification(
        arrival: start.add(
          Duration(microseconds: ((takenMs(last) + delay) * 1000).round()),
        ),
        firstSensorMs: sensorMs(first).toDouble(),
        lastSensorMs: sensorMs(last).toDouble(),
        stepMs: 9.6,
      );
    }
  }

  /// Error (ms) of the phone time the aligner gives to sample [k].
  double errorMs(ImuClockAligner aligner, int k) {
    final phone = aligner.phoneTimeOf(sensorMs(k).toDouble())!;
    return phone.difference(start).inMicroseconds / 1000.0 - takenMs(k);
  }
}

void main() {
  test('no data: waiting, no phone time', () {
    final aligner = ImuClockAligner();
    expect(aligner.alignment.state, ImuTimeAlignmentState.waiting);
    expect(aligner.frequencyHz, isNull);
    expect(aligner.phoneTimeOf(1000), isNull);
  });

  test('measures the real frequency and the phone time of the samples', () {
    final imu = _SimulatedImu(hz: 105.07);
    final aligner = ImuClockAligner();

    imu.run(aligner, 10);
    expect(aligner.alignment.state, ImuTimeAlignmentState.aligning);

    imu.run(aligner, 300);
    final alignment = aligner.alignment;
    expect(alignment.state, ImuTimeAlignmentState.aligned);
    expect(alignment.frequencyHz!, closeTo(105.07, 105.07 * 0.0001));
    // The line touches the fastest notifications: 20 ms after the sample.
    for (final k in [imu.nextSample - 1, imu.nextSample - 5000]) {
      expect(imu.errorMs(aligner, k), closeTo(20, 5));
    }
    expect(alignment.description, contains('aligned - 105.07 Hz'));
  });

  test('guard: a busy phone at the start cannot give an absurd frequency', () {
    final imu = _SimulatedImu(hz: 103.97);
    final aligner = ImuClockAligner();

    // First 12 s: the phone is busy and delivers the notifications late,
    // 3 s at the start, then catching up.
    imu.run(
      aligner,
      12,
      delayMs: (n, takenS) => 20.0 + 3000.0 * (1 - takenS / 12),
    );
    final early = aligner.frequencyHz!;
    expect((early / (1000 / 9.6) - 1).abs(), lessThanOrEqualTo(0.05));

    imu.run(aligner, 240);
    expect(aligner.frequencyHz!, closeTo(103.97, 103.97 * 0.0001));
    expect(aligner.alignment.state, ImuTimeAlignmentState.aligned);
  });

  test('keeps the good line while the IMU is losing samples', () {
    final imu = _SimulatedImu(hz: 105.23);
    final aligner = ImuClockAligner();
    imu.run(aligner, 300);

    // 3 minutes of slow link: 3 notifications out of 5 lost inside the IMU,
    // the others 4 s late (full queue). Checked every second.
    var worstMs = 0.0;
    var uncertain = 0;
    for (var second = 301; second <= 480; second++) {
      imu.run(
        aligner,
        second.toDouble(),
        delayMs: (n, takenS) => n % 5 < 3 ? null : 4000.0,
      );
      if (aligner.alignment.state == ImuTimeAlignmentState.uncertain) {
        uncertain++;
      }
      worstMs =
          math.max(worstMs, imu.errorMs(aligner, imu.nextSample - 1).abs());
    }
    expect(uncertain, greaterThan(170));
    expect(worstMs, lessThan(50));

    // Then the safety net disconnects (the queue is lost, 2 s without data)
    // and the link is normal again: same line, aligned again.
    while (imu.takenMs(imu.nextSample) < 486000) {
      imu.nextSample++;
    }
    imu.run(aligner, 500);
    expect(aligner.alignment.state, ImuTimeAlignmentState.aligned);
    expect(imu.errorMs(aligner, imu.nextSample - 1), closeTo(20, 5));
    expect(aligner.frequencyHz!, closeTo(105.23, 105.23 * 0.0001));
  });

  test('a restart of the IMU (sensor time back) starts a new line', () {
    final imu = _SimulatedImu(hz: 105.07);
    final aligner = ImuClockAligner();
    imu.run(aligner, 120);
    expect(aligner.alignment.state, ImuTimeAlignmentState.aligned);

    // New sensor clock from 0, gyroscope off: +2.5 %.
    final restarted = _SimulatedImu(
      hz: 107.7,
      sensorOffsetMs: 0,
      start: imu.start.add(const Duration(seconds: 130)),
    );
    restarted.run(aligner, 5);
    expect(aligner.alignment.state, ImuTimeAlignmentState.aligning);
    restarted.run(aligner, 240);
    expect(aligner.frequencyHz!, closeTo(107.7, 107.7 * 0.0001));
  });

  test('reset: waiting again', () {
    final imu = _SimulatedImu(hz: 104.5);
    final aligner = ImuClockAligner();
    imu.run(aligner, 30);
    aligner.reset();
    expect(aligner.alignment.state, ImuTimeAlignmentState.waiting);
    expect(aligner.phoneTimeOf(1000), isNull);
  });

  test('CSV text with the phone time of the sample', () {
    const sample = WearableAgmSample(
      timestampMs: 10,
      accX: 0.1,
      accY: 0.2,
      accZ: 0.3,
      gyrX: 0,
      gyrY: 0,
      gyrZ: 0,
      magX: 0,
      magY: 0,
      magZ: 0,
      sensorMask: WearableSensorMask.accelerometer,
    );

    expect(
      formatWearableSampleForCsv(
        sample,
        phoneTime: '2026-11-13T10:00:00,123',
      ),
      't=10 ms, tp=2026-11-13T10:00:00,123, acc=(0.100, 0.200, 0.300) g',
    );
  });
}
