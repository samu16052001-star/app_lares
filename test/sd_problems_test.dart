import 'package:app_lares/wearable_sd_problems.dart';
import 'package:app_lares/wearable_sds_packet_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  WearableSdHealth health(WearableSdState state, [int seconds = 0]) =>
      WearableSdHealth(state: state, seconds: seconds);

  test('duration and clock texts', () {
    expect(sdDurationText(const Duration(seconds: 45)), '45 s');
    expect(sdDurationText(const Duration(seconds: 159)), '2 min 39 s');
    expect(sdDurationText(const Duration(seconds: 125)), '2 min 05 s');
    expect(sdDurationText(const Duration(seconds: 3725)), '1 h 02 min');
    expect(sdDurationText(const Duration(seconds: -3)), '0 s');
    expect(sdClockText(DateTime(2026, 11, 10, 8, 5, 9)), '08:05:09');
  });

  test('stuck and then write errors are one period', () {
    final history = SdProblemHistory();
    history.update(
      health(WearableSdState.saving),
      DateTime(2026, 11, 10, 18, 49, 25),
    );
    expect(history.isEmpty, isTrue);
    expect(history.ongoing, isNull);

    // "SD stuck for 2 s" received at 18:49:31: not saving since 18:49:29.
    history.update(
      health(WearableSdState.writeStalled, 2),
      DateTime(2026, 11, 10, 18, 49, 31),
    );
    history.update(
      health(WearableSdState.writeStalled, 7),
      DateTime(2026, 11, 10, 18, 49, 36),
    );
    history.update(
      health(WearableSdState.writeError),
      DateTime(2026, 11, 10, 18, 49, 40),
    );
    history.update(
      health(WearableSdState.writeError, 5),
      DateTime(2026, 11, 10, 18, 49, 45),
    );

    expect(history.periods, hasLength(1));
    final period = history.ongoing!;
    expect(period.startedAt, DateTime(2026, 11, 10, 18, 49, 29));
    expect(period.states, [
      WearableSdState.writeStalled,
      WearableSdState.writeError,
    ]);
    final now = DateTime(2026, 11, 10, 18, 51, 34);
    expect(
      period.ongoingTextAt(now),
      'SD not saving since 18:49:29 (2 min 05 s): write errors',
    );
    expect(
      period.notificationText,
      'SD not saving since 18:49:29 (write errors)',
    );
    expect(
      period.detailsAt(now),
      'since 18:49:29 (2 min 05 s): stuck, then write errors',
    );

    // The IMU restarts and its SD saves again.
    history.update(
      health(WearableSdState.saving),
      DateTime(2026, 11, 10, 18, 52, 8),
    );
    expect(history.ongoing, isNull);
    expect(
      period.detailsAt(DateTime(2026, 11, 10, 19)),
      '18:49:29 - 18:52:08 (2 min 39 s): stuck, then write errors',
    );
    expect(
      period.notificationText,
      'SD not saving from 18:49:29 to 18:52:08, now saving again',
    );
    expect(
      history.summaryAt(DateTime(2026, 11, 10, 19)),
      '1 period, 2 min 39 s',
    );
  });

  test('several periods and a period open at the stop', () {
    final history = SdProblemHistory();
    history.update(
      health(WearableSdState.noFile, 10),
      DateTime(2026, 11, 10, 18, 0, 20),
    );
    history.update(
      health(WearableSdState.saving),
      DateTime(2026, 11, 10, 18, 0, 30),
    );
    history.update(
      health(WearableSdState.writeStalled, 2),
      DateTime(2026, 11, 10, 18, 5, 2),
    );
    expect(history.periods, hasLength(2));
    expect(history.ongoing, isNotNull);

    history.closeAtStop(DateTime(2026, 11, 10, 18, 5, 31));
    expect(history.ongoing, isNull);
    expect(history.periods.last.endedAtStop, isTrue);
    final later = DateTime(2026, 11, 10, 20);
    expect(
      history.periods.first.detailsAt(later),
      '18:00:10 - 18:00:30 (20 s): no file',
    );
    expect(
      history.periods.last.detailsAt(later),
      '18:05:00 - stop (31 s): stuck',
    );
    expect(
      history.periods.last.notificationText,
      'SD not saving from 18:05:00 until the stop',
    );
    expect(history.totalAt(later), const Duration(seconds: 51));
    expect(history.summaryAt(later), '2 periods, 51 s');

    // Nothing changes after the stop; a new acquisition starts empty.
    history.closeAtStop(DateTime(2026, 11, 10, 18, 6));
    expect(history.totalAt(later), const Duration(seconds: 51));
    history.clear();
    expect(history.isEmpty, isTrue);
  });
}
