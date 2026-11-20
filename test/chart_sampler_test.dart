import 'package:app_lares/wearable_chart_sampler.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sensor times (ms) of [count] consecutive samples at 104 Hz from [first].
List<int> sensorTimes(int first, int count) =>
    [for (var i = 0; i < count; i++) first + (i * 9.6).round()];

void main() {
  test('one sample every 4 at 104 Hz, all of them at 26 Hz or less', () {
    final sampler = WearableChartSampler();
    expect(sampler.stepFor(104), 4);
    expect(sampler.stepFor(208), 8);
    expect(sampler.stepFor(52), 2);
    expect(sampler.stepFor(26), 1);
    expect(sampler.stepFor(12), 1);
  });

  test('1 every 4 counted across notifications of 19 samples', () {
    final sampler = WearableChartSampler();
    final arrival = DateTime(2026, 11, 20, 17, 0);
    final drawn = <int>[];
    for (var notification = 0; notification < 4; notification++) {
      final points = sampler.pick(
        odr: 104,
        sensorTimesMs: sensorTimes(notification * 19 * 10, 19),
        receivedAt: arrival,
      );
      // Position of each drawn sample in the whole stream.
      for (final point in points) {
        drawn.add(notification * 19 + point.index);
      }
    }
    // 76 samples: 0, 4, 8, ..., 72 (19 points, evenly spaced).
    expect(drawn, [for (var i = 0; i < 76; i += 4) i]);
  });

  test('every point at the aligned phone time of its sample (tp)', () {
    final sampler = WearableChartSampler();
    final arrival = DateTime(2026, 11, 20, 17, 0, 0, 500);
    final phoneTimes = [
      for (var i = 0; i < 19; i++)
        DateTime(2026, 11, 20, 17, 0, 0, 200).add(
          Duration(microseconds: i * 9600),
        ),
    ];
    final points = sampler.pick(
      odr: 104,
      sensorTimesMs: sensorTimes(1000, 19),
      receivedAt: arrival,
      phoneTimes: phoneTimes,
    );
    expect([for (final point in points) point.index], [0, 4, 8, 12, 16]);
    for (final point in points) {
      expect(point.time, phoneTimes[point.index]);
    }
  });

  test('without phone times: rebuilt from the sensor times, last one at the '
      'arrival', () {
    final sampler = WearableChartSampler(targetHz: 104);
    final arrival = DateTime(2026, 11, 20, 17, 0, 1);
    final points = sampler.pick(
      odr: 104,
      sensorTimesMs: [1000, 1010, 1019],
      receivedAt: arrival,
    );
    expect([for (final point in points) point.time], [
      arrival.subtract(const Duration(milliseconds: 19)),
      arrival.subtract(const Duration(milliseconds: 9)),
      arrival,
    ]);
  });
}
