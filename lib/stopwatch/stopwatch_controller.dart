import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stopwatch with start/pause, splits and reset.
/// Port of stopwatch time.sesnext.uk: same state and same rules.
class StopwatchSplit {
  const StopwatchSplit({
    required this.n,
    required this.total,
    required this.lap,
    required this.wall,
  });

  /// Split number, from 1.
  final int n;

  /// Stopwatch time at the split (ms).
  final int total;

  /// Time since the previous split (ms).
  final int lap;

  /// Wall-clock time of the split (ms since the epoch). With the stopwatch
  /// paused it is the moment of the pause, as on the site.
  final int wall;

  Map<String, Object?> toJson() => {
        'n': n,
        'total': total,
        'lap': lap,
        'wall': wall,
      };

  static StopwatchSplit? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final n = json['n'];
    final total = json['total'];
    final lap = json['lap'];
    final wall = json['wall'];
    if (n is! num || total is! num || lap is! num || wall is! num) {
      return null;
    }
    return StopwatchSplit(
      n: n.toInt(),
      total: total.toInt(),
      lap: lap.toInt(),
      wall: wall.toInt(),
    );
  }
}

/// Saved state, same fields as the site's localStorage ("cronometro.v1").
class StopwatchState {
  const StopwatchState({
    this.running = false,
    this.acc = 0,
    this.seg,
    this.pausedAt,
    this.start,
    this.splits = const [],
  });

  /// True while the stopwatch runs.
  final bool running;

  /// Time accumulated in the finished running segments (ms).
  final int acc;

  /// Wall-clock start of the current running segment (ms), null when paused.
  final int? seg;

  /// Wall-clock moment of the last pause (ms).
  final int? pausedAt;

  /// Wall-clock moment of the first start (ms), null before the first start.
  final int? start;

  final List<StopwatchSplit> splits;

  bool get started => start != null;

  String toJsonString() => jsonEncode({
        'running': running,
        'acc': acc,
        'seg': seg,
        'pausedAt': pausedAt,
        'start': start,
        'splits': [for (final s in splits) s.toJson()],
      });

  static StopwatchState? fromJsonString(String? text) {
    if (text == null) {
      return null;
    }
    try {
      final json = jsonDecode(text);
      if (json is! Map || json['splits'] is! List) {
        return null;
      }
      int? optInt(Object? v) => v is num ? v.toInt() : null;
      final splits = <StopwatchSplit>[];
      for (final item in json['splits'] as List) {
        final split = StopwatchSplit.fromJson(item);
        if (split != null) {
          splits.add(split);
        }
      }
      return StopwatchState(
        running: json['running'] == true,
        acc: optInt(json['acc']) ?? 0,
        seg: optInt(json['seg']),
        pausedAt: optInt(json['pausedAt']),
        start: optInt(json['start']),
        splits: List.unmodifiable(splits),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Where the state is saved (SharedPreferences in the app, memory in tests).
abstract class StopwatchStorage {
  Future<String?> read();
  Future<void> write(String value);
}

class SharedPreferencesStopwatchStorage implements StopwatchStorage {
  const SharedPreferencesStopwatchStorage();

  static const String key = 'cronometro.v1';

  @override
  Future<String?> read() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(key);
  }

  @override
  Future<void> write(String value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(key, value);
  }
}

/// Result of [StopwatchController.split].
enum StopwatchSplitResult { added, notStarted, duplicate }

class StopwatchController extends ChangeNotifier {
  StopwatchController({
    int Function()? clock,
    StopwatchStorage? storage,
  })  : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _storage = storage ?? const SharedPreferencesStopwatchStorage();

  /// The app-wide stopwatch (bottom bar and stopwatch page).
  static final StopwatchController instance = StopwatchController();

  final int Function() _clock;
  final StopwatchStorage _storage;

  StopwatchState _state = const StopwatchState();

  StopwatchState get state => _state;
  bool get running => _state.running;
  bool get started => _state.started;
  List<StopwatchSplit> get splits => _state.splits;

  int now() => _clock();

  /// Loads the saved state (call once at app start). Never throws.
  Future<void> load() async {
    try {
      final saved = StopwatchState.fromJsonString(await _storage.read());
      if (saved != null) {
        _state = saved;
        notifyListeners();
      }
    } catch (_) {
      // No saved state (or storage unavailable, e.g. in widget tests).
    }
  }

  void _set(StopwatchState next) {
    _state = next;
    notifyListeners();
    final text = next.toJsonString();
    unawaited(() async {
      try {
        await _storage.write(text);
      } catch (_) {
        // Saving is best effort: the stopwatch keeps working in memory.
      }
    }());
  }

  /// Stopwatch time (ms) at wall-clock time [t] (default: now).
  int elapsed([int? t]) {
    final s = _state;
    final at = t ?? _clock();
    return s.acc + (s.running && s.seg != null ? at - s.seg! : 0);
  }

  int get lastTotal => _state.splits.isEmpty ? 0 : _state.splits.last.total;

  /// Start / pause / resume (site: toggle()).
  void toggle() {
    final t = _clock();
    final s = _state;
    if (s.running) {
      _set(StopwatchState(
        running: false,
        acc: s.acc + (s.seg == null ? 0 : t - s.seg!),
        seg: null,
        pausedAt: t,
        start: s.start,
        splits: s.splits,
      ));
    } else {
      _set(StopwatchState(
        running: true,
        acc: s.acc,
        seg: t,
        pausedAt: null,
        start: s.start ?? t,
        splits: s.splits,
      ));
    }
  }

  /// Records a split (site: split()). Paused: the stopped time, with the
  /// wall-clock time of the pause.
  StopwatchSplitResult split() {
    final t = _clock();
    final s = _state;
    if (!s.started) {
      return StopwatchSplitResult.notStarted;
    }
    final total = elapsed(t);
    final prev = lastTotal;
    if (total == prev) {
      return StopwatchSplitResult.duplicate;
    }
    final wall = s.running ? t : (s.pausedAt ?? t);
    _set(StopwatchState(
      running: s.running,
      acc: s.acc,
      seg: s.seg,
      pausedAt: s.pausedAt,
      start: s.start,
      splits: List.unmodifiable([
        ...s.splits,
        StopwatchSplit(
          n: s.splits.length + 1,
          total: total,
          lap: total - prev,
          wall: wall,
        ),
      ]),
    ));
    return StopwatchSplitResult.added;
  }

  /// Clears everything and returns the previous state, for "Undo".
  StopwatchState? reset() {
    if (!_state.started) {
      return null;
    }
    final before = _state;
    _set(const StopwatchState());
    return before;
  }

  /// "Undo" of [reset].
  void restore(StopwatchState before) => _set(before);

  /// Indexes of the fastest and slowest lap (green and red), only
  /// with at least 3 splits and different laps; -1 otherwise.
  (int best, int worst) bestWorst() {
    final laps = [for (final s in _state.splits) s.lap];
    if (laps.length < 3) {
      return (-1, -1);
    }
    final lo = laps.reduce(math.min);
    final hi = laps.reduce(math.max);
    if (lo == hi) {
      return (-1, -1);
    }
    return (laps.indexOf(lo), laps.indexOf(hi));
  }

  // --- text of the mail, .txt and CSV (layout of the site, in English) -----

  /// "1 split", "3 splits".
  static String splitsLabel(int n) => n == 1 ? '1 split' : '$n splits';

  String subject() {
    final start = _state.start ?? _clock();
    final d = DateTime.fromMillisecondsSinceEpoch(start);
    return 'Stopwatch times - ${StopwatchFormat.day(start)} '
        '${StopwatchFormat.p2(d.hour)}:${StopwatchFormat.p2(d.minute)}';
  }

  String summary() {
    final start = _state.start ?? _clock();
    return 'Times of ${StopwatchFormat.day(start)}: '
        '${splitsLabel(_state.splits.length)}, total time '
        '${StopwatchFormat.full(elapsed())}.';
  }

  /// Text of the .txt file, of "Copy" and of the preview ("\n" lines).
  String report() {
    final t = _clock();
    final s = _state;
    final start = s.start ?? t;
    final total = elapsed(t);
    final lines = <String>[
      'Stopwatch - session of ${StopwatchFormat.day(start)}',
      'Start: ${StopwatchFormat.clock(start)}',
      'Total time: ${StopwatchFormat.full(total)}'
          '${s.running ? ' (still running at ${StopwatchFormat.clock(t)})' : ''}',
      '',
    ];
    if (s.splits.isNotEmpty) {
      lines.add('SPLITS (${s.splits.length})');
      for (final sp in s.splits) {
        lines.add('${sp.n}. lap ${StopwatchFormat.full(sp.lap)} | total '
            '${StopwatchFormat.full(sp.total)} | time '
            '${StopwatchFormat.clock(sp.wall)}');
      }
    } else {
      lines.add('No splits recorded.');
    }
    lines
      ..add('')
      ..add('- LaRes app');
    return lines.join('\n');
  }

  /// CSV: n;lap_s;total_s;lap;total;time (";" and decimal comma as on the
  /// site, so Excel with Italian settings opens it in columns; CRLF).
  String csv() {
    String sec(int ms) => (ms / 1000).toStringAsFixed(3).replaceAll('.', ',');
    final lines = <String>['n;lap_s;total_s;lap;total;time'];
    for (final sp in _state.splits) {
      lines.add([
        sp.n,
        sec(sp.lap),
        sec(sp.total),
        StopwatchFormat.full(sp.lap),
        StopwatchFormat.full(sp.total),
        StopwatchFormat.clock(sp.wall),
      ].join(';'));
    }
    return '${lines.join('\r\n')}\r\n';
  }

  /// `stopwatch-YYYYMMDD-hhmm.<ext>`, from the first start.
  String fileName(String ext) {
    final d = DateTime.fromMillisecondsSinceEpoch(_state.start ?? _clock());
    return 'stopwatch-${d.year}${StopwatchFormat.p2(d.month)}'
        '${StopwatchFormat.p2(d.day)}-${StopwatchFormat.p2(d.hour)}'
        '${StopwatchFormat.p2(d.minute)}.$ext';
  }
}

/// Time formats of the site.
class StopwatchFormat {
  const StopwatchFormat._();

  static String p2(int n) => n.toString().padLeft(2, '0');
  static String p3(int n) => n.toString().padLeft(3, '0');

  /// [h:]mm:ss.cc (or .mmm with [millis]): display and table.
  static String fmt(num ms, {bool millis = false}) {
    final v = math.max(0, ms.floor());
    final h = v ~/ 3600000;
    final m = (v ~/ 60000) % 60;
    final s = (v ~/ 1000) % 60;
    final f = millis ? p3(v % 1000) : p2((v % 1000) ~/ 10);
    return '${h > 0 ? '$h:' : ''}${p2(m)}:${p2(s)}.$f';
  }

  /// hh:mm:ss.mmm (durations in the text and CSV).
  static String full(num ms) {
    final v = math.max(0, ms.floor());
    return '${p2(v ~/ 3600000)}:${p2((v ~/ 60000) % 60)}:'
        '${p2((v ~/ 1000) % 60)}.${p3(v % 1000)}';
  }

  /// Local wall-clock time hh:mm:ss.mmm.
  static String clock(int t) {
    final d = DateTime.fromMillisecondsSinceEpoch(t);
    return '${p2(d.hour)}:${p2(d.minute)}:${p2(d.second)}.${p3(d.millisecond)}';
  }

  /// dd/mm/yyyy (as on the site).
  static String day(int t) {
    final d = DateTime.fromMillisecondsSinceEpoch(t);
    return '${p2(d.day)}/${p2(d.month)}/${d.year}';
  }
}
