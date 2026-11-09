import 'package:app_lares/main.dart';
import 'package:app_lares/stopwatch/stopwatch_controller.dart';
import 'package:app_lares/stopwatch/stopwatch_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStorage implements StopwatchStorage {
  String? value;
  int writes = 0;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String v) async {
    value = v;
    writes++;
  }
}

/// Local wall-clock instant (the texts use the local time, like the site).
int at(int h, int m, int s, int ms) =>
    DateTime(2026, 10, 30, h, m, s, ms).millisecondsSinceEpoch;

void main() {
  group('StopwatchFormat (same formats as time.sesnext.uk)', () {
    test('fmt: mm:ss.cc, millis and hours', () {
      expect(StopwatchFormat.fmt(0), '00:00.00');
      expect(StopwatchFormat.fmt(9876), '00:09.87');
      expect(StopwatchFormat.fmt(2158, millis: true), '00:02.158');
      expect(StopwatchFormat.fmt(3600000 + 61005, millis: true), '1:01:01.005');
      expect(StopwatchFormat.fmt(-5), '00:00.00');
    });

    test('full: hh:mm:ss.mmm', () {
      expect(StopwatchFormat.full(8343), '00:00:08.343');
      expect(StopwatchFormat.full(3723004), '01:02:03.004');
    });

    test('clock and day use the local time', () {
      expect(StopwatchFormat.clock(at(22, 54, 48, 233)), '22:54:48.233');
      expect(StopwatchFormat.day(at(9, 0, 0, 0)), '30/10/2026');
    });

    test('short time of the bar', () {
      expect(stopwatchShortTime(192345), '03:12');
      expect(stopwatchShortTime(3600000 + 5000), '1:00:05');
    });
  });

  group('StopwatchController', () {
    late int now;
    late _MemoryStorage storage;
    late StopwatchController c;

    setUp(() {
      now = at(22, 54, 46, 75);
      storage = _MemoryStorage();
      c = StopwatchController(clock: () => now, storage: storage);
    });

    test('start, pause, resume: time from the wall clock', () {
      expect(c.started, isFalse);
      c.toggle(); // start
      expect(c.running, isTrue);
      now += 5000;
      expect(c.elapsed(), 5000);
      c.toggle(); // pause
      expect(c.running, isFalse);
      now += 60000; // paused: the time does not move
      expect(c.elapsed(), 5000);
      c.toggle(); // resume
      now += 1500;
      expect(c.elapsed(), 6500);
      expect(c.state.start, at(22, 54, 46, 75));
    });

    test('splits: lap, total, wall time; paused split uses the pause time', () {
      expect(c.split(), StopwatchSplitResult.notStarted);
      c.toggle();
      now += 2158;
      expect(c.split(), StopwatchSplitResult.added);
      now += 3449;
      c.split();
      now += 1000;
      c.toggle(); // pause at 6.607 s
      final pausedAt = now;
      now += 4000;
      expect(c.split(), StopwatchSplitResult.added);
      expect(c.split(), StopwatchSplitResult.duplicate);
      final s = c.splits;
      expect(s.length, 3);
      expect([s[0].n, s[0].lap, s[0].total], [1, 2158, 2158]);
      expect([s[1].n, s[1].lap, s[1].total], [2, 3449, 5607]);
      expect([s[2].n, s[2].lap, s[2].total], [3, 1000, 6607]);
      expect(s[2].wall, pausedAt);
      expect(c.bestWorst(), (2, 1));
    });

    test('best/worst only from 3 splits with different laps', () {
      c.toggle();
      now += 1000;
      c.split();
      now += 2000;
      c.split();
      expect(c.bestWorst(), (-1, -1));
      now += 1000;
      c.split();
      expect(c.bestWorst(), (0, 1));
    });

    test('reset and undo', () {
      c.toggle();
      now += 1234;
      c.split();
      final before = c.reset();
      expect(before, isNotNull);
      expect(c.started, isFalse);
      expect(c.splits, isEmpty);
      c.restore(before!);
      expect(c.splits.length, 1);
      expect(c.started, isTrue);
    });

    test('report, csv and file name (layout of the site, in English)', () {
      c.toggle();
      now += 2158;
      c.split();
      now += 3449;
      c.split();
      now += 2736;
      c.split();
      now += 1537;
      expect(
        c.report(),
        'Stopwatch - session of 30/10/2026\n'
        'Start: 22:54:46.075\n'
        'Total time: 00:00:09.880 (still running at 22:54:55.955)\n'
        '\n'
        'SPLITS (3)\n'
        '1. lap 00:00:02.158 | total 00:00:02.158 | time 22:54:48.233\n'
        '2. lap 00:00:03.449 | total 00:00:05.607 | time 22:54:51.682\n'
        '3. lap 00:00:02.736 | total 00:00:08.343 | time 22:54:54.418\n'
        '\n'
        '- LaRes app',
      );
      expect(
        c.csv(),
        'n;lap_s;total_s;lap;total;time\r\n'
        '1;2,158;2,158;00:00:02.158;00:00:02.158;22:54:48.233\r\n'
        '2;3,449;5,607;00:00:03.449;00:00:05.607;22:54:51.682\r\n'
        '3;2,736;8,343;00:00:02.736;00:00:08.343;22:54:54.418\r\n',
      );
      expect(c.fileName('txt'), 'stopwatch-20261030-2254.txt');
      expect(c.subject(), 'Stopwatch times - 30/10/2026 22:54');
      expect(c.summary(), 'Times of 30/10/2026: 3 splits, total time 00:00:09.880.');
      c.toggle();
      expect(c.report().split('\n')[2], 'Total time: 00:00:09.880');
    });

    test('report without splits', () {
      c.toggle();
      now += 500;
      c.toggle();
      expect(c.report().split('\n').sublist(2),
          ['Total time: 00:00:00.500', '', 'No splits recorded.', '', '- LaRes app']);
      expect(c.summary(), 'Times of 30/10/2026: 0 splits, total time 00:00:00.500.');
    });

    test('state is saved and loaded (same keys as the site)', () async {
      c.toggle();
      now += 1000;
      c.split();
      await Future<void>.delayed(Duration.zero);
      expect(storage.writes, 2);
      final other = StopwatchController(clock: () => now, storage: storage);
      await other.load();
      expect(other.running, isTrue);
      expect(other.splits.single.total, 1000);
      now += 500;
      expect(other.elapsed(), 1500);

      // JSON written by time.sesnext.uk (localStorage "cronometro.v1")
      storage.value = '{"running":false,"acc":8343,"seg":null,'
          '"pausedAt":1793319294418,"start":1793319286075,"splits":'
          '[{"n":1,"total":2158,"lap":2158,"wall":1793319288233}]}';
      final fromSite = StopwatchController(clock: () => now, storage: storage);
      await fromSite.load();
      expect(fromSite.started, isTrue);
      expect(fromSite.running, isFalse);
      expect(fromSite.elapsed(), 8343);
      expect(fromSite.splits.single.wall, 1793319288233);
    });

    test('broken saved state is ignored', () async {
      storage.value = 'not json';
      await c.load();
      expect(c.started, isFalse);
    });
  });

  group('StopwatchPage', () {
    testWidgets('start, split and pause act on the touch', (tester) async {
      var now = at(10, 0, 0, 0);
      final c = StopwatchController(clock: () => now, storage: _MemoryStorage());
      await tester.pumpWidget(MaterialApp(home: StopwatchPage(controller: c)));

      expect(find.text('Ready'), findsOneWidget);
      expect(find.text('00:00.00'), findsOneWidget);

      await tester.tap(find.text('Start'));
      await tester.pump();
      expect(c.running, isTrue);
      expect(find.text('Running'), findsOneWidget);
      expect(find.text('Pause'), findsOneWidget);

      now += 2158;
      await tester.tap(find.text('Split'));
      await tester.pump();
      expect(c.splits.length, 1);
      expect(find.text('00:02.158'), findsWidgets);
      expect(find.text('10:00:02.158'), findsOneWidget);

      now += 1000;
      await tester.tap(find.text('Pause'));
      await tester.pump();
      expect(c.running, isFalse);
      expect(find.text('Paused'), findsOneWidget);
      expect(find.text('Resume'), findsOneWidget);
      expect(find.text('00:03.15'), findsOneWidget);

      // Reset: confirmation, then "Undo" in the toast restores everything.
      await tester.tap(find.text('Reset'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Reset the stopwatch?'), findsOneWidget);
      // "Reset" is both the page button and the dialog button.
      await tester.tap(
        find.descendant(of: find.byType(Dialog), matching: find.text('Reset')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(c.started, isFalse);
      expect(find.text('Reset the stopwatch?'), findsNothing);
      expect(find.text('Session reset'), findsOneWidget);
      await tester.tap(
        find.descendant(of: find.byType(SnackBar), matching: find.text('Undo')),
      );
      await tester.pump();
      expect(c.splits.length, 1);
      expect(c.started, isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('the bottom bar opens and closes the stopwatch page', (tester) async {
    await tester.pumpWidget(const LaresApp());
    expect(find.byIcon(Icons.timer_outlined), findsOneWidget);
    expect(find.text('Enter your access code'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.timer_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Stopwatch'), findsOneWidget);
    expect(find.text('Send the times'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.timer_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Stopwatch'), findsNothing);
    expect(find.text('Enter your access code'), findsOneWidget);
  });
}
