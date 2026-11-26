import 'dart:async';
import 'dart:math' as math;

import 'package:app_lares/stopwatch/stopwatch_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

export 'package:app_lares/stopwatch/stopwatch_protocol.dart';

// Protocol stopwatch with start/pause, splits, protocol steps and reset.
// Port of time.sesnext.uk: same state, same rules, same CSV of the labels.

/// Where the state is saved (SharedPreferences in the app, memory in tests).
abstract class StopwatchStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class SharedPreferencesStopwatchStorage implements StopwatchStorage {
  const SharedPreferencesStopwatchStorage();

  @override
  Future<String?> read(String key) async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(key);
  }

  @override
  Future<void> write(String key, String value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(key, value);
  }
}

/// Result of [StopwatchController.split].
enum StopwatchSplitResult { added, notStarted, duplicate }

/// Settings and protocol before a change, for "Undo".
class StopwatchPlanSnapshot {
  const StopwatchPlanSnapshot(this.settings, this.plan, this.ptr);

  final StopwatchSettings settings;
  final List<ProtocolStep> plan;
  final int ptr;
}

class StopwatchController extends ChangeNotifier {
  StopwatchController({
    int Function()? clock,
    StopwatchStorage? storage,
  })  : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _storage = storage ?? const SharedPreferencesStopwatchStorage();

  /// The app-wide stopwatch (bottom bar and stopwatch page).
  static final StopwatchController instance = StopwatchController();

  /// Same key and fields as the site's localStorage.
  static const String key = 'cronometro.v2';

  /// State of the first version (times only, no protocol).
  static const String oldKey = 'cronometro.v1';

  final int Function() _clock;
  final StopwatchStorage _storage;

  StopwatchState _state = StopwatchState.fresh();

  StopwatchState get state => _state;
  bool get running => _state.running;
  bool get started => _state.started;
  List<StopwatchSplit> get splits => _state.splits;
  List<ProtocolStep> get plan => _state.plan;
  int get ptr => _state.ptr;
  StopwatchSettings get settings => _state.settings;

  /// Current protocol step, null at the end of the protocol.
  ProtocolStep? get currentStep => _state.ptr < _state.plan.length ? _state.plan[_state.ptr] : null;

  String get currentLabel => currentStep?.label ?? 'UNKNOWN';

  int now() => _clock();

  /// Loads the saved state (call once at app start). Never throws.
  Future<void> load() async {
    try {
      final saved = StopwatchState.fromJsonString(await _storage.read(key));
      if (saved != null) {
        _state = saved;
        notifyListeners();
        return;
      }
      // Session left halfway with the first version: the times are kept,
      // with UNKNOWN labels.
      final old = StopwatchState.fromJsonString(await _storage.read(oldKey));
      if (old != null && old.started) {
        _state = StopwatchState.fresh().copyWith(
          running: old.running,
          acc: old.acc,
          seg: old.seg,
          pausedAt: old.pausedAt,
          start: old.start,
          splits: List.unmodifiable([for (final s in old.splits) s.withLabel('UNKNOWN')]),
        );
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
        await _storage.write(key, text);
      } catch (_) {
        // Saving is best effort: the stopwatch keeps working in memory.
      }
    }());
  }

  /// Stopwatch time (ms) at wall-clock time [t] (default: now).
  int elapsed([int? t]) {
    final s = _state;
    final at = t ?? _clock();
    final seg = s.seg;
    return s.acc + (s.running && seg != null ? at - seg : 0);
  }

  int get lastTotal => _state.splits.isEmpty ? 0 : _state.splits.last.total;

  /// Start / pause / resume (site: toggle()).
  void toggle() {
    final t = _clock();
    final s = _state;
    if (s.running) {
      final seg = s.seg;
      _set(s.copyWith(
        running: false,
        acc: s.acc + (seg == null ? 0 : t - seg),
        seg: null,
        pausedAt: t,
      ));
    } else {
      final pausedAt = s.pausedAt;
      _set(s.copyWith(
        running: true,
        seg: t,
        pausedAt: null,
        start: s.start ?? t,
        pauses: s.started && pausedAt != null
            ? List.unmodifiable([...s.pauses, StopwatchPause(pausedAt, t)])
            : s.pauses,
      ));
    }
  }

  /// Records a split (site: split()): it closes the current activity with its
  /// name and moves to the next step. Paused: the stopped time, with the
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
    final step = currentStep;
    _set(s.copyWith(
      splits: List.unmodifiable([
        ...s.splits,
        StopwatchSplit(
          n: s.splits.length + 1,
          total: total,
          lap: total - prev,
          wall: s.running ? t : (s.pausedAt ?? t),
          label: currentLabel,
          manual: step != null && step.edited,
          ptrBefore: s.ptr,
        ),
      ]),
      ptr: math.min(s.ptr + 1, s.plan.length),
    ));
    return StopwatchSplitResult.added;
  }

  /// "Undo" of the last split.
  void undoSplit() {
    final s = _state;
    if (s.splits.isEmpty) {
      return;
    }
    final last = s.splits.last;
    _set(s.copyWith(
      splits: List.unmodifiable(s.splits.sublist(0, s.splits.length - 1)),
      ptr: math.min(last.ptrBefore, s.plan.length),
    ));
  }

  /// Previous / next step of the protocol.
  void move(int delta) => jump(_state.ptr + delta);

  /// Goes to step [index] (plan.length = end of the protocol).
  void jump(int index) {
    final next = math.max(0, math.min(_state.plan.length, index));
    if (next != _state.ptr) {
      _set(_state.copyWith(ptr: next));
    }
  }

  // --- changes to the protocol: they stay in the list until the session is reset

  StopwatchPlanSnapshot _snapshot() => StopwatchPlanSnapshot(_state.settings, _state.plan, _state.ptr);

  /// Replaces the current step with [label]. Returns the state before, for "Undo".
  StopwatchPlanSnapshot? changeStep(String label) {
    final step = currentStep;
    if (step == null || step.label == label) {
      return null;
    }
    final before = _snapshot();
    final plan = [..._state.plan];
    plan[_state.ptr] = ProtocolStep(
      label,
      kind: step.kind == 'add' ? 'add' : 'mod',
      duration: defaultDuration(label),
      block: step.block,
    );
    _set(_state.copyWith(plan: List.unmodifiable(plan)));
    return before;
  }

  /// Adds [label] before the current step; it becomes the current activity.
  StopwatchPlanSnapshot addStep(String label) {
    final before = _snapshot();
    final i = _state.ptr;
    final near = i < _state.plan.length ? _state.plan[i] : (i > 0 ? _state.plan[i - 1] : null);
    final plan = [..._state.plan]
      ..insert(i, ProtocolStep(label, kind: 'add', duration: defaultDuration(label), block: near?.block));
    _set(_state.copyWith(plan: List.unmodifiable(plan)));
    return before;
  }

  /// Removes the current step from the protocol.
  StopwatchPlanSnapshot? removeStep() {
    if (currentStep == null) {
      return null;
    }
    final before = _snapshot();
    final plan = [..._state.plan]..removeAt(_state.ptr);
    _set(_state.copyWith(plan: List.unmodifiable(plan)));
    return before;
  }

  /// "Undo" of a change to the protocol or to the settings.
  void restorePlan(StopwatchPlanSnapshot before) => _set(_state.copyWith(
        settings: before.settings,
        plan: before.plan,
        ptr: math.min(before.ptr, before.plan.length),
      ));

  /// Changes the activity of a recorded split (index from 0).
  void setSplitLabel(int index, String label) {
    if (index < 0 || index >= _state.splits.length || _state.splits[index].label == label) {
      return;
    }
    final splits = [..._state.splits];
    splits[index] = splits[index].withLabel(label);
    _set(_state.copyWith(splits: List.unmodifiable(splits)));
  }

  /// Applies the setup page. Changing order, speeds or powers rebuilds the
  /// protocol: if steps had been changed by hand, returns the state before
  /// (for "Undo"), otherwise null.
  StopwatchPlanSnapshot? applySettings(StopwatchSettings next) {
    final s = _state;
    if (next.sameProtocol(s.settings)) {
      if (next.subject != s.settings.subject) {
        _set(s.copyWith(settings: next));
      }
      return null;
    }
    final edited = s.plan.any((p) => p.edited);
    final before = _snapshot();
    final plan = buildProtocol(next);
    _set(s.copyWith(settings: next, plan: plan, ptr: math.min(s.ptr, plan.length)));
    return edited ? before : null;
  }

  /// Clears the session (settings kept) and returns the previous state, for "Undo".
  StopwatchState? reset() {
    if (!_state.started) {
      return null;
    }
    final before = _state;
    _set(StopwatchState.fresh(before.settings));
    return before;
  }

  /// "Undo" of [reset].
  void restore(StopwatchState before) => _set(before);

  // --- file, mail and CSV (same as the site) ---------------------------------

  /// "1 split", "3 splits".
  static String splitsLabel(int n) => n == 1 ? '1 split' : '$n splits';

  /// Labels as CSV, same format as labels/Sxx_labels.csv.
  String csv() => labelCsv(_state);

  /// Same name as on the site: cronometro-YYYYMMDD-HHMM.csv (first start).
  String fileName() {
    final d = DateTime.fromMillisecondsSinceEpoch(_state.start ?? _clock());
    return 'cronometro-${d.year}${StopwatchFormat.p2(d.month)}'
        '${StopwatchFormat.p2(d.day)}-${StopwatchFormat.p2(d.hour)}'
        '${StopwatchFormat.p2(d.minute)}.csv';
  }

  String subjectLine() {
    final start = _state.start ?? _clock();
    final d = DateTime.fromMillisecondsSinceEpoch(start);
    final subject = _state.settings.subject;
    return 'Stopwatch times - ${subject.isEmpty ? '' : '$subject - '}'
        '${StopwatchFormat.day(start)} ${StopwatchFormat.p2(d.hour)}:${StopwatchFormat.p2(d.minute)}';
  }

  String summary() {
    final start = _state.start ?? _clock();
    final subject = _state.settings.subject;
    return 'Protocol labels${subject.isEmpty ? '' : ' of $subject'} '
        '(${StopwatchFormat.day(start)}): ${splitsLabel(_state.splits.length)}.';
  }
}
