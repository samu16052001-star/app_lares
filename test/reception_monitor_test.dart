import 'package:app_lares/wearable_reception_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime(2026, 10, 17, 14, 30);

  test('consecutive IMD/AG2 packets: 100% received', () {
    final monitor = WearableReceptionMonitor();
    var ticks = 1000;
    for (var i = 0; i < 10; i += 1) {
      monitor.addTickPacket(
        receivedAt: start.add(Duration(milliseconds: 182 * i)),
        firstTicks: ticks,
        stepTicks: 384,
        sampleCount: 19,
        newAcquisition: i == 0,
      );
      ticks += 19 * 384;
    }

    expect(monitor.receivedPercent(start.add(const Duration(seconds: 2))), 100);
    expect(monitor.totalMissing, 0);
  });

  test('a lost notification shows up as missing samples', () {
    final monitor = WearableReceptionMonitor();
    monitor.addTickPacket(
      receivedAt: start,
      firstTicks: 0,
      stepTicks: 384,
      sampleCount: 19,
      newAcquisition: true,
    );
    // One packet of 19 samples lost: next first sample is 38 steps later.
    monitor.addTickPacket(
      receivedAt: start.add(const Duration(milliseconds: 365)),
      firstTicks: 38 * 384,
      stepTicks: 384,
      sampleCount: 19,
      newAcquisition: false,
    );

    expect(monitor.totalMissing, 19);
    expect(
      monitor.receivedPercent(start.add(const Duration(milliseconds: 400))),
      closeTo(100 * 38 / 57, 0.01),
    );
  });

  test('the window forgets old losses', () {
    final monitor = WearableReceptionMonitor();
    monitor.addTickPacket(
      receivedAt: start,
      firstTicks: 0,
      stepTicks: 384,
      sampleCount: 10,
      newAcquisition: true,
    );
    monitor.addTickPacket(
      receivedAt: start.add(const Duration(seconds: 1)),
      firstTicks: 100 * 384,
      stepTicks: 384,
      sampleCount: 10,
      newAcquisition: false,
    );
    monitor.addTickPacket(
      receivedAt: start.add(const Duration(seconds: 12)),
      firstTicks: 110 * 384,
      stepTicks: 384,
      sampleCount: 10,
      newAcquisition: false,
    );

    expect(monitor.receivedPercent(start.add(const Duration(seconds: 12))), 100);
    expect(monitor.totalMissing, 90);
  });

  test('a new acquisition is not a gap', () {
    final monitor = WearableReceptionMonitor();
    monitor.addTickPacket(
      receivedAt: start,
      firstTicks: 0,
      stepTicks: 384,
      sampleCount: 19,
      newAcquisition: true,
    );
    monitor.addTickPacket(
      receivedAt: start.add(const Duration(seconds: 1)),
      firstTicks: 999999,
      stepTicks: 384,
      sampleCount: 19,
      newAcquisition: true,
    );

    expect(monitor.totalMissing, 0);
  });

  test('AGM timestamps: a 3-sample hole is counted', () {
    final monitor = WearableReceptionMonitor();
    monitor.addAgmSamples(
      receivedAt: start,
      timestampsMs: const [0, 10, 19, 29, 38],
      stepMs: 9.6,
    );
    monitor.addAgmSamples(
      receivedAt: start.add(const Duration(milliseconds: 50)),
      timestampsMs: const [77, 86, 96, 106, 115],
      stepMs: 9.6,
    );

    expect(monitor.totalReceived, 10);
    expect(monitor.totalMissing, 3);
  });

  test('silence and no data', () {
    final monitor = WearableReceptionMonitor();
    expect(monitor.receivedPercent(start), isNull);
    expect(monitor.timeSinceLastPacket(start), isNull);

    monitor.addTickPacket(
      receivedAt: start,
      firstTicks: 0,
      stepTicks: 384,
      sampleCount: 19,
      newAcquisition: true,
    );
    final later = start.add(const Duration(seconds: 15));
    expect(monitor.timeSinceLastPacket(later), const Duration(seconds: 15));
    expect(monitor.receivedPercent(later), isNull);
  });
}
