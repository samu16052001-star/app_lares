import 'package:app_lares/main.dart';
import 'package:app_lares/stopwatch/stopwatch_controller.dart';
import 'package:app_lares/stopwatch/stopwatch_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStorage implements StopwatchStorage {
  final Map<String, String> values = {};
  int writes = 0;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
    writes++;
  }
}

/// Local wall-clock instant (the texts use the local time, like the site).
int at(int h, int m, int s, int ms) => DateTime(2026, 11, 25, h, m, s, ms).millisecondsSinceEpoch;

void main() {
  group('StopwatchFormat (same formats as time.sesnext.uk)', () {
    test('fmt: mm:ss.cc, millis and hours', () {
      expect(StopwatchFormat.fmt(0), '00:00.00');
      expect(StopwatchFormat.fmt(9876), '00:09.87');
      expect(StopwatchFormat.fmt(2158, millis: true), '00:02.158');
      expect(StopwatchFormat.fmt(3600000 + 61005, millis: true), '1:01:01.005');
      expect(StopwatchFormat.fmt(-5), '00:00.00');
    });

    test('clock, iso, day, time left and numbers', () {
      expect(StopwatchFormat.clock(at(22, 54, 48, 233)), '22:54:48.233');
      expect(StopwatchFormat.iso(at(9, 5, 1, 7)), '2026-11-25T09:05:01.007');
      expect(StopwatchFormat.day(at(9, 0, 0, 0)), '25/11/2026');
      expect(StopwatchFormat.minSec(83001), '1:24');
      expect(StopwatchFormat.minSec(120000), '2:00');
      expect(StopwatchFormat.number(3), '3');
      expect(StopwatchFormat.number(5.5), '5.5');
    });

    test('short time of the bar', () {
      expect(stopwatchShortTime(192345), '03:12');
      expect(stopwatchShortTime(3600000 + 5000), '1:00:05');
    });
  });

  group('Protocol (same as the site and labels_common.py)', () {
    test('labels: classes, postures, intensities, English names', () {
      expect(classifyLabel('PRONE').cls, 'static');
      expect(classifyLabel('prono').posture, 'prone');
      expect(englishLabel(' supino '), 'SUPINE');
      final walk = classifyLabel('WALKING 6 KM/H');
      expect([walk.cls, walk.intensityValue, walk.intensityUnit], ['walk', '6', 'km/h']);
      expect(classifyLabel('RUNNING 8.5 KM/H').cls, 'run');
      final bike = classifyLabel('BIKE 120 W');
      expect([bike.cls, bike.intensityValue, bike.intensityUnit], ['bike', '120', 'W']);
      expect(classifyLabel('OUTDOOR BIKING').cls, 'bike');
      expect(classifyLabel('BUFFER').cls, 'excluded');
      expect(classifyLabel('SLOW DOWN TO 0 KM/H').cls, 'excluded');
    });

    test('default protocol: 53 steps, indoor first, planned times', () {
      final plan = buildProtocol(const StopwatchSettings());
      expect(plan.length, 53);
      expect([for (final p in plan.take(4)) p.label], ['BUFFER', 'PRONE', 'BUFFER', 'SUPINE']);
      expect(plan[1].duration?.label, '2 min');
      expect(plan[9].label, 'SITTING DYNAMIC');
      expect(plan[9].duration?.label, '3 min');
      expect(plan[0].duration, isNull);
      expect(plan[26].label, 'SLOW DOWN TO 0 KM/H');
      expect(plan[26].duration?.label, '~1–2 min');
      expect([plan[27].label, plan[27].duration?.label], ['REST', '3 min']);
      expect([plan[40].label, plan[40].duration?.label], ['OUTDOOR WALKING', '~9–10 min']);
      expect([plan[52].label, plan[52].duration?.label], ['REST', '2 min']);
      expect(plan[1].block, 'posture');
    });

    test('order and intensities change the protocol', () {
      const s = StopwatchSettings(order: 'outdoor', walk: [3, 4, 5, 6, 7], run: [], powers: [50, 100]);
      final labels = [for (final p in buildProtocol(s)) p.label];
      expect(labels.take(3).toList(), ['BUFFER', 'REST', 'OUTDOOR WALKING']);
      expect(labels.contains('WALKING 7 KM/H'), isTrue);
      expect(labels.any((l) => l.startsWith('RUNNING ')), isFalse);
      expect(labels.contains('BIKE 50 W'), isTrue);
      expect(labels.last, 'REST');
      final catalog = {for (final (_, l) in labelCatalog(s)) ...l};
      expect(catalog.contains('WALKING 7 KM/H'), isTrue);
      expect(catalog.contains('BIKE 50 W'), isTrue);
      expect(catalog.contains('RUNNING 8 KM/H'), isTrue);
    });

    test('numbers typed in the setup', () {
      expect(parseNumberList('3 4, 5/6', 30), [3, 4, 5, 6]);
      expect(parseNumberList('5.5 0 99', 30), [5.5]);
      expect(parseNumberList('', 30), <num>[]);
    });
  });

  group('StopwatchController', () {
    late int now;
    late _MemoryStorage storage;
    late StopwatchController c;

    setUp(() {
      now = at(10, 0, 0, 0);
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
      now += 60000; // paused: the time does not move
      expect(c.elapsed(), 5000);
      c.toggle(); // resume
      now += 1500;
      expect(c.elapsed(), 6500);
      expect(c.state.pauses.length, 1);
    });

    test('split closes the current activity and moves on; undo', () {
      expect(c.split(), StopwatchSplitResult.notStarted);
      c.toggle();
      now += 2158;
      expect(c.split(), StopwatchSplitResult.added);
      expect(c.splits.single.label, 'BUFFER');
      expect(c.currentLabel, 'PRONE');
      now += 1000;
      c.toggle(); // pause
      now += 4000; // paused: the split takes the time of the pause
      expect(c.split(), StopwatchSplitResult.added);
      expect(c.splits.last.total, 3158);
      expect(c.split(), StopwatchSplitResult.duplicate);
      c.undoSplit();
      expect(c.splits.length, 1);
      expect(c.currentLabel, 'PRONE');
    });

    test('change, add and remove steps stay in the protocol; undo', () {
      c.jump(3); // SUPINE
      final changed = c.changeStep('SITTING STILL');
      expect(changed, isNotNull);
      c.move(-2);
      c.move(2);
      expect(c.currentLabel, 'SITTING STILL');
      expect(c.currentStep?.tag, 'changed');
      final added = c.addStep('REST');
      expect(c.currentLabel, 'REST');
      expect(c.currentStep?.tag, 'added');
      expect(c.plan[4].label, 'SITTING STILL');
      expect(c.plan.length, 54);
      c.restorePlan(added);
      expect(c.plan.length, 53);
      c.restorePlan(changed!);
      expect(c.currentLabel, 'SUPINE');
      c.removeStep();
      expect(c.plan.length, 52);
      expect(c.currentLabel, 'BUFFER');
    });

    test('settings rebuild the protocol; undo only when steps were changed', () {
      expect(c.applySettings(c.settings.copyWith(subject: 'S23')), isNull);
      expect(c.settings.subject, 'S23');
      expect(c.applySettings(c.settings.copyWith(powers: [50, 100])), isNull);
      expect(c.plan.where((p) => p.label.startsWith('BIKE ')).length, 2);
      c.jump(1);
      c.changeStep('SUPINE');
      final before = c.applySettings(c.settings.copyWith(order: 'outdoor'));
      expect(before, isNotNull);
      expect(c.plan[2].label, 'OUTDOOR WALKING');
      c.restorePlan(before!);
      expect(c.settings.order, 'indoor');
      expect(c.plan[1].label, 'SUPINE');
    });

    test('reset keeps the settings; undo', () {
      c.applySettings(c.settings.copyWith(subject: 'S23', order: 'outdoor'));
      c.toggle();
      now += 1234;
      c.split();
      final before = c.reset();
      expect(before, isNotNull);
      expect(c.started, isFalse);
      expect(c.splits, isEmpty);
      expect(c.ptr, 0);
      expect(c.settings.subject, 'S23');
      expect(c.plan[2].label, 'OUTDOOR WALKING');
      c.restore(before!);
      expect(c.splits.length, 1);
    });

    test('CSV of the labels: same text as time.sesnext.uk', () {
      c.applySettings(c.settings.copyWith(subject: 'S23'));
      c.toggle(); // start 10:00:00.000
      now += 5000;
      c.split(); // BUFFER
      now += 120000;
      c.toggle(); // pause 10:02:05.000
      now += 10000;
      c.toggle(); // resume 10:02:15.000
      now += 1000;
      c.split(); // PRONE
      expect(
        c.csv(),
        'subject,session,start,end,duration_s,raw_label,class4,posture,intensity_value,'
        'intensity_unit,environment,source,note\r\n'
        'S23,supervised,2026-11-25T10:00:00.000,2026-11-25T10:00:05.000,5.000,BUFFER,excluded,,,,'
        'indoor,lares_app,split 1\r\n'
        'S23,supervised,2026-11-25T10:00:05.000,2026-11-25T10:02:05.000,120.000,PRONE,static,prone,,,'
        'indoor,lares_app,split 2\r\n'
        'S23,supervised,2026-11-25T10:02:05.000,2026-11-25T10:02:15.000,10.000,UNKNOWN,excluded,,,,'
        'indoor,lares_app,stopwatch paused\r\n'
        'S23,supervised,2026-11-25T10:02:15.000,2026-11-25T10:02:16.000,1.000,PRONE,static,prone,,,'
        'indoor,lares_app,split 2\r\n',
      );
      expect(c.fileName(), 'cronometro-20261125-1000.csv');
      expect(c.subjectLine(), 'Stopwatch times - S23 - 25/11/2026 10:00');
      expect(c.summary(), 'Protocol labels of S23 (25/11/2026): 2 splits.');
      c.setSplitLabel(1, 'SUPINE');
      expect(c.csv().split('\r\n')[2], contains('SUPINE,static,supine,,,indoor,lares_app,split 2; label chosen by hand'));
    });

    test('outdoor rows get the outdoor environment', () {
      expect(
        labelEnvironments(['REST', 'BUFFER', 'OUTDOOR WALKING', 'REST', 'OUTDOOR RUNNING', 'PC WRITING']),
        ['outdoor', 'indoor', 'outdoor', 'outdoor', 'outdoor', 'indoor'],
      );
    });

    test('state is saved and loaded', () async {
      c.applySettings(c.settings.copyWith(walk: [3, 4]));
      c.toggle();
      now += 1000;
      c.split();
      c.jump(5);
      c.changeStep('REST');
      await Future<void>.delayed(Duration.zero);
      final other = StopwatchController(clock: () => now, storage: storage);
      await other.load();
      expect(other.running, isTrue);
      expect(other.splits.single.total, 1000);
      expect(other.splits.single.label, 'BUFFER');
      expect(other.ptr, 5);
      expect(other.currentLabel, 'REST');
      expect(other.currentStep?.tag, 'changed');
      expect(other.settings.walk, [3, 4]);
      expect(other.plan.length, c.plan.length);
      now += 500;
      expect(other.elapsed(), 1500);
    });

    test('a session of the first version keeps its times', () async {
      storage.values[StopwatchController.oldKey] = '{"running":false,"acc":8343,"seg":null,'
          '"pausedAt":1793319294418,"start":1793319286075,"splits":'
          '[{"n":1,"total":2158,"lap":2158,"wall":1793319288233}]}';
      await c.load();
      expect(c.started, isTrue);
      expect(c.elapsed(), 8343);
      expect(c.splits.single.label, 'UNKNOWN');
      expect(c.plan.length, 53);
    });

    test('broken saved state is ignored', () async {
      storage.values[StopwatchController.key] = 'not json';
      await c.load();
      expect(c.started, isFalse);
    });
  });

  group('StopwatchPage', () {
    testWidgets('setup page first, then the stopwatch; start, split, reset', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      var now = at(10, 0, 0, 0);
      final c = StopwatchController(clock: () => now, storage: _MemoryStorage());
      await tester.pumpWidget(MaterialApp(home: StopwatchPage(controller: c)));

      expect(find.text('Stopwatch · protocol'), findsOneWidget);
      expect(find.text('Block order'), findsOneWidget);
      final next = find.text('Continue to the stopwatch');
      await tester.scrollUntilVisible(next, 400, scrollable: find.byType(Scrollable).first);
      await tester.tap(next);
      await tester.pump();
      expect(find.text('Ready'), findsOneWidget);
      expect(find.text('00:00.00'), findsOneWidget);
      expect(find.text('Transition, no planned time'), findsOneWidget);

      await tester.tap(find.text('Start'));
      await tester.pump();
      expect(c.running, isTrue);
      expect(find.text('Running'), findsOneWidget);

      now += 2158;
      await tester.tap(find.text('Split'));
      await tester.pump();
      expect(c.splits.single.label, 'BUFFER');
      expect(find.text('00:02.158'), findsOneWidget);
      expect(find.text('Planned 2 min · 2:00 left'), findsOneWidget);

      now += 1000;
      await tester.tap(find.text('Pause'));
      await tester.pump();
      expect(find.text('Paused'), findsOneWidget);

      // Reset: confirmation, setup page, then "Undo" brings the session back.
      await tester.tap(find.text('Reset'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Reset the stopwatch?'), findsOneWidget);
      await tester.tap(find.descendant(of: find.byType(Dialog), matching: find.text('Reset')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(c.started, isFalse);
      expect(find.text('Stopwatch · protocol'), findsOneWidget);
      expect(find.text('Session cleared'), findsOneWidget);
      await tester.tap(find.descendant(of: find.byType(SnackBar), matching: find.text('Undo')));
      await tester.pump();
      expect(c.splits.length, 1);
      expect(find.text('Paused'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('with a session in progress the page opens on the stopwatch', (tester) async {
      final c = StopwatchController(clock: () => at(10, 0, 0, 0), storage: _MemoryStorage());
      c.toggle();
      c.toggle(); // paused, so that no ticker is left running
      await tester.pumpWidget(MaterialApp(home: StopwatchPage(controller: c)));
      expect(find.text('Paused'), findsOneWidget);
      expect(find.text('‹ Setup'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('the bottom bar opens and closes the stopwatch page', (tester) async {
    await tester.pumpWidget(const LaresApp());
    expect(find.byIcon(Icons.timer_outlined), findsOneWidget);
    expect(find.text('Enter your access code'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.timer_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Stopwatch · protocol'), findsOneWidget);
    expect(find.text('Block order'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.timer_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Stopwatch · protocol'), findsNothing);
    expect(find.text('Enter your access code'), findsOneWidget);
  });
}
