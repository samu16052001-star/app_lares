import 'package:app_lares/wearable_agm_packet_parser.dart';
import 'package:app_lares/wearable_reception_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('alert threshold: 2 s at 104 Hz, longer when notifications are rare', () {
    Duration threshold(int mask, int odr) =>
        WearableNoDataWatchdog.thresholdFor(sensorMask: mask, odr: odr);

    expect(threshold(WearableSensorMask.all, 104), const Duration(seconds: 2));
    expect(
      threshold(WearableSensorMask.accelerometerGyroscope, 104),
      const Duration(seconds: 2),
    );
    expect(
      threshold(WearableSensorMask.accelerometer, 104),
      const Duration(seconds: 2),
    );
    // One sensor at 26 Hz: 38 samples per notification, one every 1.46 s.
    expect(
      threshold(WearableSensorMask.accelerometer, 26),
      const Duration(milliseconds: 4385),
    );
    expect(
      WearableNoDataWatchdog.thresholdFor(sensorMask: null, odr: 104),
      WearableNoDataWatchdog.minimumThreshold,
    );
  });

  test('samples per IMD notification with MTU 247', () {
    expect(WearableNoDataWatchdog.samplesPerNotification(1), 38);
    expect(WearableNoDataWatchdog.samplesPerNotification(2), 19);
    expect(WearableNoDataWatchdog.samplesPerNotification(3), 12);
  });

  test('silence counted from the last data or from START / reconnection', () {
    final t0 = DateTime(2026, 10, 28, 16, 0, 0);
    const threshold = Duration(seconds: 2);
    Duration? silence(DateTime now, DateTime? lastData, DateTime? armed) =>
        WearableNoDataWatchdog.silenceBeyond(
          now: now,
          lastDataAt: lastData,
          armedAt: armed,
          threshold: threshold,
        );

    // Data 1.9 s ago: no alert; 2 s ago: alert.
    expect(silence(t0.add(const Duration(milliseconds: 1900)), t0, null), isNull);
    expect(
      silence(t0.add(const Duration(seconds: 2)), t0, null),
      const Duration(seconds: 2),
    );
    // Reconnected after the last data: counted from the reconnection.
    expect(
      silence(t0.add(const Duration(seconds: 3)), t0, t0.add(const Duration(seconds: 2))),
      isNull,
    );
    // START and still no data after 2 s: alert.
    expect(
      silence(t0.add(const Duration(milliseconds: 2500)), null, t0),
      const Duration(milliseconds: 2500),
    );
    // Neither data nor START: nothing to watch.
    expect(silence(t0, null, null), isNull);
  });
}
