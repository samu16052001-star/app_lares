import 'dart:collection';

// Time alignment of the IMU samples on the phone clock.
//
// Every IMU timestamps its samples with the clock of its sensor (nominal
// 9.6 ms per sample at 104 Hz). That clock runs a little faster or slower
// than nominal, differently for every IMU and with the gyroscope on or off,
// so after some minutes the IMUs drift apart by seconds if their own clock
// is trusted.
//
// Every notification gives a pair (x, y): x = sensor time of its last
// sample, y = phone time when it arrived; y = a + b*x + delay, delay >= 0.
// Every [ImuClockAligner.slotMs] the line y = a + b*x is recomputed on the
// notifications of the last [ImuClockAligner.windowMs]: the line under all
// the points that touches the fastest ones (lower convex hull, edge under
// the mean x; Moon, Skelly, Towsley 1999). Late notifications lie above it
// and do not count. Then:
// - phone time of any sample = a + b*x;
// - real sampling frequency = nominal frequency / b.
//
// Guard: a new line is accepted only if its frequency is within
// +-[ImuClockAligner.guard] of the nominal one; otherwise the previous
// slope is kept (start of the acquisition, slow links).
//
// Losses: a hole in the sensor time between two notifications that arrived
// less than [ImuClockAligner.disconnectMs] apart (no disconnection) means
// the IMU is losing samples inside itself: its queue is full and every
// notification is late. Those notifications, from
// [ImuClockAligner.lossLookbackMs] before the hole (queue filling up) to
// [ImuClockAligner.lossHoldMs] after the last one, are kept out of the
// line; while the window contains them the slope is refitted only if the
// good notifications span more time than those of the current slope,
// otherwise only the offset. If no good line exists yet (slow and lossy
// from the start) they are used anyway.
//
// Phone clock: the wall clock (DateTime.now), the same used for the
// TIMESTAMP column and for the other devices. A monotonic Stopwatch would
// stop while Android suspends the CPU between two notifications.

/// What the app knows about the time alignment of one IMU.
enum ImuTimeAlignmentState {
  /// No data since the last START.
  waiting,

  /// Line fitted on less than [ImuClockAligner.alignedSpanMs] of data:
  /// the frequency can still be off by some 0.1 %.
  aligning,

  /// Line fitted on enough data.
  aligned,

  /// The IMU is losing samples (its notifications are late): the last good
  /// line is kept.
  uncertain,
}

/// State and real sampling frequency of one IMU (shown in the acquisition
/// page and written in the event log when the state changes).
class ImuTimeAlignment {
  const ImuTimeAlignment({required this.state, this.frequencyHz});

  static const ImuTimeAlignment waiting =
      ImuTimeAlignment(state: ImuTimeAlignmentState.waiting);

  final ImuTimeAlignmentState state;

  /// Real sampling frequency measured on the phone clock (null = no data).
  final double? frequencyHz;

  String get _frequencyText {
    final frequency = frequencyHz;
    return frequency == null ? '' : ' - ${frequency.toStringAsFixed(2)} Hz';
  }

  /// Text of the acquisition page.
  String get description {
    return switch (state) {
      ImuTimeAlignmentState.waiting => 'Time alignment: waiting for data',
      ImuTimeAlignmentState.aligning =>
        'Time alignment: aligning$_frequencyText',
      ImuTimeAlignmentState.aligned => 'Time alignment: aligned$_frequencyText',
      ImuTimeAlignmentState.uncertain =>
        'Time alignment: uncertain, the IMU is losing samples$_frequencyText',
    };
  }

  /// Details of the event log.
  String get eventDetails {
    final frequency = frequencyHz;
    final name = switch (state) {
      ImuTimeAlignmentState.waiting => 'waiting for data',
      ImuTimeAlignmentState.aligning => 'aligning',
      ImuTimeAlignmentState.aligned => 'aligned',
      ImuTimeAlignmentState.uncertain => 'uncertain (IMU losing samples)',
    };
    return frequency == null
        ? name
        : '$name, sampling frequency ${frequency.toStringAsFixed(3)} Hz';
  }
}

class _Notification {
  _Notification(this.y, this.x, this.late);

  /// Arrival on the phone, ms from the first notification.
  final double y;

  /// Sensor time of the last sample, ms from the first notification.
  final double x;

  /// Sent while the IMU was losing samples: kept out of the line.
  bool late;
}

/// Line between the sensor clock of one IMU and the phone clock.
class ImuClockAligner {
  ImuClockAligner({
    this.slotMs = 5000,
    this.windowMs = 120000,
    this.guard = 0.05,
    this.lossHoldMs = 5000,
    this.lossLookbackMs = 10000,
    this.disconnectMs = 1000,
    this.alignedSpanMs = 30000,
  });

  /// The line is recomputed every [slotMs] ...
  final double slotMs;

  /// ... on the notifications of the last [windowMs].
  final double windowMs;

  /// Accepted frequencies: nominal +- guard (0.05 = 5 %).
  final double guard;

  /// Notifications kept out of the line after an in-link loss ...
  final double lossHoldMs;

  /// ... and before it (the queue of the IMU was filling up).
  final double lossLookbackMs;

  /// No notification for this long = disconnection, not a loss.
  final double disconnectMs;

  /// Line fitted on at least this much sensor time = aligned.
  final double alignedSpanMs;

  final ListQueue<_Notification> _window = ListQueue<_Notification>();
  int? _originUs;
  double _originSensorMs = 0;
  int _count = 0;
  double _a = 0;
  double _b = 1;
  double _slotEnd = 0;
  bool _haveGood = false;
  double _slopeSpan = 0;
  double _lossUntil = double.negativeInfinity;
  double _previousY = 0;
  double _previousX = 0;
  double _stepMs = 9.6;
  bool _lastLate = false;

  /// New START or IMU restart: the line starts again from scratch.
  void reset() {
    _window.clear();
    _originUs = null;
    _originSensorMs = 0;
    _count = 0;
    _a = 0;
    _b = 1;
    _slotEnd = 0;
    _haveGood = false;
    _slopeSpan = 0;
    _lossUntil = double.negativeInfinity;
    _previousY = 0;
    _previousX = 0;
    _lastLate = false;
  }

  /// One notification: [arrival] on the phone clock, sensor time (ms) of its
  /// first and last sample, nominal step between two samples (ms).
  void addNotification({
    required DateTime arrival,
    required double firstSensorMs,
    required double lastSensorMs,
    required double stepMs,
  }) {
    // Sensor time going back: the IMU restarted, new sensor clock.
    if (_count > 0 && lastSensorMs - _originSensorMs < _previousX) {
      reset();
    }
    if (stepMs > 0) {
      _stepMs = stepMs;
    }
    if (_count == 0) {
      _originUs = arrival.microsecondsSinceEpoch;
      _originSensorMs = lastSensorMs;
    }
    final y = (arrival.microsecondsSinceEpoch - _originUs!) / 1000.0;
    final x = lastSensorMs - _originSensorMs;
    final xFirst = firstSensorMs - _originSensorMs;

    // 1. Losses inside the IMU.
    var late = false;
    if (_count > 0) {
      final hole = xFirst - _previousX > 1.5 * _stepMs;
      if (hole && y - _previousY < disconnectMs) {
        _lossUntil = y + lossHoldMs;
        // The queue was filling up before the first loss: those
        // notifications were already late.
        for (var i = _window.length - 1; i >= 0; i--) {
          final previous = _window.elementAt(i);
          if (previous.y < y - lossLookbackMs || previous.late) {
            break;
          }
          previous.late = true;
        }
      }
      late = y <= _lossUntil;
    } else {
      _a = y - x;
      _b = 1;
      _slotEnd = y + slotMs;
    }

    // 2. Slots that ended before this notification: new line.
    while (y >= _slotEnd) {
      if (_count > 1) {
        _fitSlot();
      }
      _slotEnd += slotMs;
    }

    // 3. This notification joins the window.
    _window.addLast(_Notification(y, x, late));
    _count++;
    _previousY = y;
    _previousX = x;
    _lastLate = late;
  }

  void _fitSlot() {
    final cutoff = _slotEnd - windowMs;
    while (_window.isNotEmpty && _window.first.y < cutoff) {
      _window.removeFirst();
    }
    if (_window.isEmpty) {
      return;
    }

    final all = _window.toList(growable: false);
    final good = [
      for (final notification in all)
        if (!notification.late) notification,
    ];
    var used = all;
    var minSpan = slotMs * 0.9;
    if (good.length >= 2) {
      if (_haveGood && good.length < all.length) {
        // Losses in the window: new slope only if the good notifications
        // now span more than those of the current slope.
        minSpan = _slopeSpan + 1.0;
      }
      used = good;
    } else if (_haveGood) {
      return; // keep the last good line
    }

    var minX = double.infinity;
    var maxX = double.negativeInfinity;
    for (final notification in used) {
      if (notification.x < minX) {
        minX = notification.x;
      }
      if (notification.x > maxX) {
        maxX = notification.x;
      }
    }
    final span = maxX - minX;
    if (used.length >= 2 && span >= minSpan) {
      final (a, b) = _lowerHullLine(used);
      if ((1.0 / b - 1.0).abs() <= guard) {
        _a = a;
        _b = b;
        _slopeSpan = span;
        if (good.length >= 2) {
          _haveGood = true;
        }
      } else {
        _a = _lowestOffset(used, _b);
      }
    } else {
      _a = _lowestOffset(used, _b);
    }
  }

  /// Offset of the line with slope [b] that touches the fastest notification.
  static double _lowestOffset(List<_Notification> points, double b) {
    var lowest = double.infinity;
    for (final point in points) {
      final offset = point.y - b * point.x;
      if (offset < lowest) {
        lowest = offset;
      }
    }
    return lowest;
  }

  /// Line under all the points that minimises their total distance above it:
  /// the edge of the lower convex hull under the mean x.
  static (double, double) _lowerHullLine(List<_Notification> points) {
    final order = List<int>.generate(points.length, (index) => index)
      ..sort((i, j) {
        final byX = points[i].x.compareTo(points[j].x);
        return byX != 0 ? byX : i.compareTo(j);
      });
    final xs = [for (final index in order) points[index].x];
    final ys = [for (final index in order) points[index].y];

    final hull = <int>[];
    for (var i = 0; i < xs.length; i++) {
      while (hull.length >= 2) {
        final i1 = hull[hull.length - 2];
        final i2 = hull[hull.length - 1];
        final cross = (xs[i2] - xs[i1]) * (ys[i] - ys[i1]) -
            (ys[i2] - ys[i1]) * (xs[i] - xs[i1]);
        if (cross <= 0) {
          hull.removeLast();
        } else {
          break;
        }
      }
      hull.add(i);
    }
    if (hull.length < 2) {
      return (ys[0] - xs[0], 1.0);
    }

    var sum = 0.0;
    for (final x in xs) {
      sum += x;
    }
    final meanX = sum / xs.length;
    for (var k = 0; k < hull.length - 1; k++) {
      final i = hull[k];
      final j = hull[k + 1];
      if ((xs[i] <= meanX && meanX <= xs[j]) || k == hull.length - 2) {
        final b = (ys[j] - ys[i]) / (xs[j] - xs[i]);
        return (ys[i] - b * xs[i], b);
      }
    }
    return (ys[0] - xs[0], 1.0); // not reached
  }

  /// Phone time of a sample with sensor time [sensorMs] (null = no data).
  DateTime? phoneTimeOf(double sensorMs) {
    final originUs = _originUs;
    if (originUs == null) {
      return null;
    }
    final y = _a + _b * (sensorMs - _originSensorMs);
    return DateTime.fromMicrosecondsSinceEpoch(originUs + (y * 1000).round());
  }

  /// Phone ms per sensor ms (1 = the IMU clock runs at the nominal rate).
  double get slope => _b;

  /// Real sampling frequency (null = no data).
  double? get frequencyHz => _count == 0 ? null : 1000.0 / (_stepMs * _b);

  ImuTimeAlignment get alignment {
    if (_count == 0) {
      return ImuTimeAlignment.waiting;
    }
    final state = _lastLate
        ? ImuTimeAlignmentState.uncertain
        : _slopeSpan < alignedSpanMs
            ? ImuTimeAlignmentState.aligning
            : ImuTimeAlignmentState.aligned;
    return ImuTimeAlignment(state: state, frequencyHz: frequencyHz);
  }
}
