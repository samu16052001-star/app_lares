import 'dart:math' as math;

/// One sample of a notification that goes to the live charts: its index in
/// the notification and the time where it is drawn.
class WearableChartPoint {
  const WearableChartPoint({required this.index, required this.time});

  final int index;
  final DateTime time;
}

/// Chooses which IMU samples are drawn in the live charts and where.
///
/// A notification carries many samples (up to 19 with acc+gyr in an IMD
/// packet, 5 in the old AGM packet). Drawing only the first one of each
/// notification gives 5.5 points per second with IMD: an angular line.
/// Drawing all of them (104 per second, for every chart of every IMU) is
/// too heavy for a slow phone. So the charts get about [targetHz] points per
/// second: one sample every [stepFor] samples (1 every 4 at 104 Hz), counted
/// across notifications, so the points stay evenly spaced even if 19 is not
/// a multiple of 4.
///
/// Every point is placed at the aligned phone time of its sample (tp, the
/// same time written in the CSV): the moment the sensor took the sample, on
/// the phone clock. The arrival time of the notification would put all its
/// points at the same instant.
class WearableChartSampler {
  WearableChartSampler({this.targetHz = 26});

  /// Points per second drawn in every chart.
  final double targetHz;

  /// Samples still to skip before the next drawn one.
  int _toSkip = 0;

  /// Samples between two drawn points at [odr] Hz: 4 at 104 Hz, 8 at
  /// 208 Hz, 1 (all samples) at 26 Hz or less.
  int stepFor(int odr) => math.max(1, (odr / targetHz).round());

  /// Samples of one notification to draw, with their time.
  ///
  /// [sensorTimesMs] = sensor time of every sample; [phoneTimes] = aligned
  /// phone time of every sample (tp). Without [phoneTimes] the times are
  /// rebuilt from the sensor times, with the last sample at [receivedAt].
  List<WearableChartPoint> pick({
    required int odr,
    required List<int> sensorTimesMs,
    required DateTime receivedAt,
    List<DateTime>? phoneTimes,
  }) {
    final step = stepFor(odr);
    final times =
        phoneTimes != null && phoneTimes.length == sensorTimesMs.length
            ? phoneTimes
            : null;
    final points = <WearableChartPoint>[];
    for (var index = 0; index < sensorTimesMs.length; index++) {
      if (_toSkip > 0) {
        _toSkip--;
        continue;
      }
      _toSkip = step - 1;
      final time = times != null
          ? times[index]
          : receivedAt.subtract(
              Duration(
                milliseconds: sensorTimesMs.last - sensorTimesMs[index],
              ),
            );
      points.add(WearableChartPoint(index: index, time: time));
    }
    return points;
  }
}
