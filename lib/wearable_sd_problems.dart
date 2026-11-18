import 'package:app_lares/wearable_sds_packet_parser.dart';

/// Local time as HH:MM:SS.
String sdClockText(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

String sdDurationText(Duration value) {
  final seconds = value.isNegative ? 0 : value.inSeconds;
  if (seconds < 60) {
    return '$seconds s';
  }
  if (seconds < 3600) {
    return '${seconds ~/ 60} min ${(seconds % 60).toString().padLeft(2, '0')} s';
  }
  final minutes = (seconds % 3600) ~/ 60;
  return '${seconds ~/ 3600} h ${minutes.toString().padLeft(2, '0')} min';
}

/// A period in which the SD card of an IMU did not save, as reported by the
/// SDS packets: from the first packet with a problem to the first one that
/// says "saving" again (or to the stop).
///
/// The states seen meanwhile are kept in order: a card that stops answering
/// is first "stuck" (the IMU is waiting for it) and then, when the IMU gives
/// up waiting, in "write errors". They are two phases of the same problem,
/// so they make one period.
class SdProblemPeriod {
  SdProblemPeriod({required WearableSdState state, required this.startedAt})
      : states = [state];

  /// When the SD stopped saving (reception of the first SDS with a problem
  /// minus the seconds it reports).
  final DateTime startedAt;

  /// States reported during the period, in order of first appearance.
  final List<WearableSdState> states;

  DateTime? endedAt;

  /// Still open when the acquisition was stopped.
  bool endedAtStop = false;

  bool get isOngoing => endedAt == null;

  void addState(WearableSdState state) {
    if (!states.contains(state)) {
      states.add(state);
    }
  }

  Duration durationAt(DateTime now) {
    final duration = (endedAt ?? now).difference(startedAt);
    return duration.isNegative ? Duration.zero : duration;
  }

  /// "stuck, then write errors".
  String get causes => states.map((state) => state.cause).join(', then ');

  /// IMU card, while the problem lasts:
  /// "SD not saving since 18:49:29 (2 min 05 s): write errors".
  String ongoingTextAt(DateTime now) {
    return 'SD not saving since ${sdClockText(startedAt)} '
        '(${sdDurationText(durationAt(now))}): ${states.last.cause}';
  }

  String detailsAt(DateTime now) {
    final from = sdClockText(startedAt);
    final ended = endedAt;
    final String period;
    if (ended == null) {
      period = 'since $from';
    } else if (endedAtStop) {
      period = '$from - stop';
    } else {
      period = '$from - ${sdClockText(ended)}';
    }
    return '$period (${sdDurationText(durationAt(now))}): $causes';
  }

  /// Notification: without the duration, so the text changes only when the
  /// state changes.
  String get notificationText {
    final from = sdClockText(startedAt);
    final ended = endedAt;
    if (ended == null) {
      return 'SD not saving since $from (${states.last.cause})';
    }
    if (endedAtStop) {
      return 'SD not saving from $from until the stop';
    }
    return 'SD not saving from $from to ${sdClockText(ended)}, '
        'now saving again';
  }
}

/// SD problems of one IMU during an acquisition, kept until its end (also
/// after the SD saves again).
class SdProblemHistory {
  final List<SdProblemPeriod> periods = [];

  bool get isEmpty => periods.isEmpty;

  bool get isNotEmpty => periods.isNotEmpty;

  /// The period still open, if the SD is not saving now.
  SdProblemPeriod? get ongoing {
    if (periods.isEmpty || !periods.last.isOngoing) {
      return null;
    }
    return periods.last;
  }

  /// Updates the history with the SD state of an SDS packet.
  void update(WearableSdHealth health, DateTime receivedAt) {
    final current = ongoing;
    if (health.isSaving) {
      current?.endedAt = receivedAt;
      return;
    }
    if (current != null) {
      current.addState(health.state);
      return;
    }
    periods.add(
      SdProblemPeriod(
        state: health.state,
        startedAt: receivedAt.subtract(Duration(seconds: health.seconds)),
      ),
    );
  }

  /// The acquisition was stopped: a period still open ends here.
  void closeAtStop(DateTime stoppedAt) {
    final current = ongoing;
    if (current != null) {
      current
        ..endedAt = stoppedAt
        ..endedAtStop = true;
    }
  }

  void clear() => periods.clear();

  /// Time without saving, all the periods together.
  Duration totalAt(DateTime now) {
    var total = Duration.zero;
    for (final period in periods) {
      total += period.durationAt(now);
    }
    return total;
  }

  /// "3 periods, 5 min 29 s".
  String summaryAt(DateTime now) {
    final count = periods.length;
    return '$count ${count == 1 ? 'period' : 'periods'}, '
        '${sdDurationText(totalAt(now))}';
  }
}
