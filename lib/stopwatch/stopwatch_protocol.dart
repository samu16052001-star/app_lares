import 'dart:convert';
import 'dart:math' as math;

// Protocol, labels, planned durations and CSV of the stopwatch. Same rules as
// time.sesnext.uk and as the thesis label files (scripts/labels_common.py):
// same activity names, same 4 classes, same posture, intensity and
// environment. Pure Dart (no Flutter), so it can be tested on its own.

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

  /// hh:mm:ss.mmm.
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

  /// Local phone time as in the label files: 2026-11-25T10:31:26.814.
  static String iso(int t) {
    final d = DateTime.fromMillisecondsSinceEpoch(t);
    return '${d.year}-${p2(d.month)}-${p2(d.day)}T${clock(t)}';
  }

  /// dd/mm/yyyy.
  static String day(int t) {
    final d = DateTime.fromMillisecondsSinceEpoch(t);
    return '${p2(d.day)}/${p2(d.month)}/${d.year}';
  }

  /// m:ss rounded up (time left of a step).
  static String minSec(int ms) {
    final s = (ms / 1000).ceil();
    return '${s ~/ 60}:${p2(s % 60)}';
  }

  /// 3 -> "3", 5.5 -> "5.5" (speeds and powers in the labels).
  static String number(num v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toString();
}

// --- labels -------------------------------------------------------------------

/// Class, posture and intensity of a protocol label.
class LabelInfo {
  const LabelInfo(this.cls, {this.posture = '', this.intensityValue = '', this.intensityUnit = ''});

  /// static / walk / run / bike / excluded.
  final String cls;
  final String posture;
  final String intensityValue;
  final String intensityUnit;
}

const Map<String, String> _staticPostures = {
  'PRONE': 'prone',
  'SUPINE': 'supine',
  'SITTING STILL': 'sitting',
  'STANDING STILL': 'standing',
  'SITTING DYNAMIC': 'sitting',
  'STANDING DYNAMIC': 'standing',
  'REST': 'unknown',
  'PC WRITING': 'sitting',
  'PAPER WRITING': 'sitting',
};

/// The campaign files used two Italian names; every label is now in English.
const Map<String, String> _renamed = {'PRONO': 'PRONE', 'SUPINO': 'SUPINE'};

String englishLabel(String raw) {
  final label = raw.toUpperCase().trim();
  return _renamed[label] ?? label;
}

final RegExp _walking = RegExp(r'^WALKING (\d+(?:\.\d+)?) KM/H$');
final RegExp _running = RegExp(r'^RUNNING (\d+(?:\.\d+)?) KM/H$');
final RegExp _bike = RegExp(r'^BIKE (\d+) W$');

LabelInfo classifyLabel(String raw) {
  final label = englishLabel(raw);
  final posture = _staticPostures[label];
  if (posture != null) {
    return LabelInfo('static', posture: posture);
  }
  var m = _walking.firstMatch(label);
  if (m != null) {
    return LabelInfo('walk', intensityValue: m.group(1)!, intensityUnit: 'km/h');
  }
  if (label == 'OUTDOOR WALKING') {
    return const LabelInfo('walk');
  }
  m = _running.firstMatch(label);
  if (m != null) {
    return LabelInfo('run', intensityValue: m.group(1)!, intensityUnit: 'km/h');
  }
  if (label == 'OUTDOOR RUNNING' || label == 'RUNNING') {
    return const LabelInfo('run');
  }
  m = _bike.firstMatch(label);
  if (m != null) {
    return LabelInfo('bike', intensityValue: m.group(1)!, intensityUnit: 'W');
  }
  if (label == 'OUTDOOR BIKING' || label == 'BIKE') {
    return const LabelInfo('bike');
  }
  return const LabelInfo('excluded'); // BUFFER, SLOW DOWN TO 0 KM/H, UNKNOWN
}

// --- planned durations ------------------------------------------------------------

/// Planned duration of a step: fixed ([seconds]) or, for the steps that depend
/// on the route or on the subject, a [text] with a typical value (typical
/// values of the 22 campaign subjects).
class PlannedDuration {
  const PlannedDuration.minutes(int minutes)
      : seconds = minutes * 60,
        text = null,
        typicalSeconds = null;

  const PlannedDuration.about(String this.text, int this.typicalSeconds) : seconds = null;

  final int? seconds;
  final String? text;
  final int? typicalSeconds;

  /// "2 min", "1:30" or the text of the variable steps.
  String get label {
    final t = text;
    if (t != null) {
      return t;
    }
    final s = seconds ?? 0;
    return s % 60 != 0 ? '${s ~/ 60}:${StopwatchFormat.p2(s % 60)}' : '${s ~/ 60} min';
  }

  /// Seconds used for the total of the protocol.
  int get estimateSeconds => seconds ?? typicalSeconds ?? 0;

  Map<String, Object?> toJson() => seconds != null ? {'s': seconds} : {'t': text, 'm': typicalSeconds};

  static PlannedDuration? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final s = json['s'];
    if (s is num) {
      return PlannedDuration._seconds(s.toInt());
    }
    final t = json['t'];
    final m = json['m'];
    if (t is String) {
      return PlannedDuration.about(t, m is num ? m.toInt() : 0);
    }
    return null;
  }

  const PlannedDuration._seconds(int this.seconds)
      : text = null,
        typicalSeconds = null;
}

const Map<String, PlannedDuration> _outdoorDurations = {
  'OUTDOOR WALKING': PlannedDuration.about('~9–10 min', 570),
  'OUTDOOR RUNNING': PlannedDuration.about('~6–7 min', 390),
  'OUTDOOR BIKING': PlannedDuration.about('~7–9 min', 480),
};

/// Duration of an activity picked by hand. REST depends on where it is in the
/// protocol (2 or 3 min): none.
PlannedDuration? defaultDuration(String label) {
  if (_walking.hasMatch(label) ||
      _running.hasMatch(label) ||
      const ['PRONE', 'SUPINE', 'SITTING STILL', 'STANDING STILL'].contains(label)) {
    return const PlannedDuration.minutes(2);
  }
  if (_bike.hasMatch(label) || label == 'SITTING DYNAMIC' || label == 'STANDING DYNAMIC') {
    return const PlannedDuration.minutes(3);
  }
  if (label == 'PC WRITING' || label == 'PAPER WRITING') {
    return const PlannedDuration.minutes(5);
  }
  if (label == 'SLOW DOWN TO 0 KM/H') {
    return const PlannedDuration.about('~1–2 min', 90);
  }
  return _outdoorDurations[label];
}

// --- protocol ------------------------------------------------------------------------

/// One step of the session protocol. [kind] is '' (as planned), 'mod'
/// (changed by hand) or 'add' (added by hand).
class ProtocolStep {
  const ProtocolStep(this.label, {this.kind = '', this.duration, this.block});

  final String label;
  final String kind;
  final PlannedDuration? duration;

  /// posture / treadmill / ergometer / outdoor / writing.
  final String? block;

  bool get edited => kind.isNotEmpty;

  /// "changed" / "added" / "".
  String get tag => kind == 'mod' ? 'changed' : (kind == 'add' ? 'added' : '');

  Map<String, Object?> toJson() => {
        'l': label,
        'k': kind,
        'd': duration?.toJson(),
        'b': block,
      };

  static ProtocolStep? fromJson(Object? json) {
    if (json is! Map || json['l'] is! String) {
      return null;
    }
    final label = englishLabel(json['l'] as String);
    final kind = json['k'] is String ? json['k'] as String : '';
    // A step saved without a duration gets the default one of its label.
    final duration = json.containsKey('d') ? PlannedDuration.fromJson(json['d']) : defaultDuration(label);
    return ProtocolStep(
      label,
      kind: kind,
      duration: duration,
      block: json['b'] is String ? json['b'] as String : null,
    );
  }
}

const Map<String, String> protocolBlockNames = {
  'posture': 'Postures',
  'treadmill': 'Treadmill',
  'ergometer': 'Cycle ergometer',
  'outdoor': 'Outdoor',
  'writing': 'Writing',
};

/// Settings of the setup page.
class StopwatchSettings {
  const StopwatchSettings({
    this.subject = '',
    this.order = 'indoor',
    this.walk = defaultWalk,
    this.run = defaultRun,
    this.powers = defaultPowers,
  });

  static const List<num> defaultWalk = [3, 4, 5, 6];
  static const List<num> defaultRun = [8, 9, 10];
  static const List<num> defaultPowers = [80, 100, 120, 80];

  /// Optional subject code, e.g. "S23" (goes in the subject column of the CSV).
  final String subject;

  /// "indoor" (indoor -> outdoor) or "outdoor" (outdoor -> indoor).
  final String order;

  /// Treadmill walking and running speeds (km/h) and cycle ergometer powers
  /// (W), in the order they are done. Empty: that part is skipped.
  final List<num> walk;
  final List<num> run;
  final List<num> powers;

  bool sameProtocol(StopwatchSettings other) =>
      order == other.order &&
      _sameList(walk, other.walk) &&
      _sameList(run, other.run) &&
      _sameList(powers, other.powers);

  StopwatchSettings copyWith({
    String? subject,
    String? order,
    List<num>? walk,
    List<num>? run,
    List<num>? powers,
  }) =>
      StopwatchSettings(
        subject: subject ?? this.subject,
        order: order ?? this.order,
        walk: walk ?? this.walk,
        run: run ?? this.run,
        powers: powers ?? this.powers,
      );
}

bool _sameList(List<num> a, List<num> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

/// Numbers in a text field: "3 4 5 6", "3, 4, 5", "40/60".
List<num> parseNumberList(String text, num max) {
  final out = <num>[];
  for (final m in RegExp(r'\d+(?:\.\d+)?').allMatches(text)) {
    final s = m.group(0)!;
    final num v = s.contains('.') ? double.parse(s) : int.parse(s);
    if (v > 0 && v <= max) {
      out.add(v);
    }
  }
  return out;
}

/// Protocol blocks, with a BUFFER wherever the protocol has a change.
List<ProtocolStep> buildProtocol(StopwatchSettings s) {
  List<ProtocolStep> block(String name, List<(String, PlannedDuration?)> steps) => [
        for (final (label, d) in steps) ProtocolStep(label, duration: d, block: name),
      ];
  const (String, PlannedDuration?) buffer = ('BUFFER', null);
  (String, PlannedDuration?) step(String label) => (label, defaultDuration(label));
  List<(String, PlannedDuration?)> withBuffers(List<String> labels) => [
        for (final label in labels) ...[buffer, step(label)],
      ];
  const rest2 = ('REST', PlannedDuration.minutes(2));
  const rest3 = ('REST', PlannedDuration.minutes(3));

  final tread = [
    for (final v in s.walk) 'WALKING ${StopwatchFormat.number(v)} KM/H',
    for (final v in s.run) 'RUNNING ${StopwatchFormat.number(v)} KM/H',
  ];
  final blocks = <String, List<ProtocolStep>>{
    'posture': block('posture', withBuffers(const [
      'PRONE', 'SUPINE', 'SITTING STILL', 'STANDING STILL', 'SITTING DYNAMIC', 'STANDING DYNAMIC', //
    ])),
    'treadmill': tread.isEmpty
        ? const []
        : block('treadmill', [...withBuffers(tread), step('SLOW DOWN TO 0 KM/H'), rest3]),
    'ergometer': s.powers.isEmpty
        ? const []
        : block('ergometer', [
            ...withBuffers([for (final p in s.powers) 'BIKE ${StopwatchFormat.number(p)} W']),
            buffer,
            rest3,
          ]),
    'outdoor': block('outdoor', [
      buffer, rest2, step('OUTDOOR WALKING'), rest2, step('OUTDOOR RUNNING'), rest3, //
      buffer, step('OUTDOOR BIKING'), buffer, rest2,
    ]),
    'writing': block('writing', [step('PC WRITING'), buffer, step('PAPER WRITING'), buffer, rest2]),
  };
  final order = s.order == 'outdoor'
      ? const ['outdoor', 'writing', 'posture', 'treadmill', 'ergometer']
      : const ['posture', 'treadmill', 'ergometer', 'outdoor', 'writing'];
  return List.unmodifiable([for (final name in order) ...blocks[name]!]);
}

/// Every label that can be picked by hand, in groups.
List<(String, List<String>)> labelCatalog(StopwatchSettings s) {
  List<num> merged(List<num> a, List<num> b) {
    final all = <num>[];
    for (final v in [...a, ...b]) {
      if (!all.contains(v)) {
        all.add(v);
      }
    }
    all.sort();
    return all;
  }

  return [
    ('Excluded', const ['BUFFER', 'SLOW DOWN TO 0 KM/H', 'UNKNOWN']),
    (
      'Static',
      const [
        'PRONE', 'SUPINE', 'SITTING STILL', 'STANDING STILL', 'SITTING DYNAMIC', //
        'STANDING DYNAMIC', 'REST', 'PC WRITING', 'PAPER WRITING',
      ]
    ),
    (
      'Walk',
      [
        for (final v in merged(s.walk, StopwatchSettings.defaultWalk)) 'WALKING ${StopwatchFormat.number(v)} KM/H',
        'OUTDOOR WALKING',
      ]
    ),
    (
      'Run',
      [
        for (final v in merged(s.run, StopwatchSettings.defaultRun)) 'RUNNING ${StopwatchFormat.number(v)} KM/H',
        'RUNNING',
        'OUTDOOR RUNNING',
      ]
    ),
    (
      'Bike',
      [
        for (final p in merged(s.powers, const [40, 60, 80, 100, 120])) 'BIKE ${StopwatchFormat.number(p)} W',
        'BIKE',
        'OUTDOOR BIKING',
      ]
    ),
  ];
}

// --- splits and state ------------------------------------------------------------------

class StopwatchSplit {
  const StopwatchSplit({
    required this.n,
    required this.total,
    required this.lap,
    required this.wall,
    this.label = 'UNKNOWN',
    this.manual = false,
    this.ptrBefore = 0,
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

  /// Activity closed by this split.
  final String label;

  /// True if the label was chosen by hand.
  final bool manual;

  /// Protocol step before the split (for "Undo").
  final int ptrBefore;

  StopwatchSplit withLabel(String newLabel) => StopwatchSplit(
        n: n,
        total: total,
        lap: lap,
        wall: wall,
        label: newLabel,
        manual: true,
        ptrBefore: ptrBefore,
      );

  Map<String, Object?> toJson() => {
        'n': n,
        'total': total,
        'lap': lap,
        'wall': wall,
        'label': label,
        'manual': manual,
        'ptrBefore': ptrBefore,
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
    final label = json['label'];
    final ptrBefore = json['ptrBefore'];
    return StopwatchSplit(
      n: n.toInt(),
      total: total.toInt(),
      lap: lap.toInt(),
      wall: wall.toInt(),
      label: label is String ? englishLabel(label) : 'UNKNOWN',
      manual: json['manual'] == true,
      ptrBefore: ptrBefore is num ? ptrBefore.toInt() : 0,
    );
  }
}

/// A pause of the stopwatch: from [from] to [to] (wall clock, ms).
class StopwatchPause {
  const StopwatchPause(this.from, this.to);

  final int from;
  final int to;
}

const Object _keep = Object();

/// Saved state, same fields as the site's localStorage ("cronometro.v2").
class StopwatchState {
  const StopwatchState({
    this.running = false,
    this.acc = 0,
    this.seg,
    this.pausedAt,
    this.start,
    this.splits = const [],
    this.pauses = const [],
    this.ptr = 0,
    this.settings = const StopwatchSettings(),
    this.plan = const [],
  });

  /// A new session with the protocol of [settings].
  factory StopwatchState.fresh([StopwatchSettings settings = const StopwatchSettings()]) =>
      StopwatchState(settings: settings, plan: buildProtocol(settings));

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
  final List<StopwatchPause> pauses;

  /// Current protocol step (== plan.length at the end of the protocol).
  final int ptr;

  final StopwatchSettings settings;
  final List<ProtocolStep> plan;

  bool get started => start != null;

  StopwatchState copyWith({
    bool? running,
    int? acc,
    Object? seg = _keep,
    Object? pausedAt = _keep,
    Object? start = _keep,
    List<StopwatchSplit>? splits,
    List<StopwatchPause>? pauses,
    int? ptr,
    StopwatchSettings? settings,
    List<ProtocolStep>? plan,
  }) =>
      StopwatchState(
        running: running ?? this.running,
        acc: acc ?? this.acc,
        seg: identical(seg, _keep) ? this.seg : seg as int?,
        pausedAt: identical(pausedAt, _keep) ? this.pausedAt : pausedAt as int?,
        start: identical(start, _keep) ? this.start : start as int?,
        splits: splits ?? this.splits,
        pauses: pauses ?? this.pauses,
        ptr: ptr ?? this.ptr,
        settings: settings ?? this.settings,
        plan: plan ?? this.plan,
      );

  String toJsonString() => jsonEncode({
        'running': running,
        'acc': acc,
        'seg': seg,
        'pausedAt': pausedAt,
        'start': start,
        'splits': [for (final s in splits) s.toJson()],
        'pauses': [
          for (final p in pauses) [p.from, p.to],
        ],
        'ptr': ptr,
        'subject': settings.subject,
        'order': settings.order,
        'walk': settings.walk,
        'run': settings.run,
        'powers': settings.powers,
        'plan': [for (final p in plan) p.toJson()],
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
      List<num>? optList(Object? v) =>
          v is List ? [for (final x in v) if (x is num) x] : null;
      final splits = <StopwatchSplit>[];
      for (final item in json['splits'] as List) {
        final split = StopwatchSplit.fromJson(item);
        if (split != null) {
          splits.add(split);
        }
      }
      final pauses = <StopwatchPause>[];
      final rawPauses = json['pauses'];
      if (rawPauses is List) {
        for (final p in rawPauses) {
          if (p is List && p.length == 2 && p[0] is num && p[1] is num) {
            pauses.add(StopwatchPause((p[0] as num).toInt(), (p[1] as num).toInt()));
          }
        }
      }
      final settings = StopwatchSettings(
        subject: json['subject'] is String ? json['subject'] as String : '',
        order: json['order'] == 'outdoor' ? 'outdoor' : 'indoor',
        walk: optList(json['walk']) ?? StopwatchSettings.defaultWalk,
        run: optList(json['run']) ?? StopwatchSettings.defaultRun,
        powers: optList(json['powers']) ?? StopwatchSettings.defaultPowers,
      );
      final plan = <ProtocolStep>[];
      final rawPlan = json['plan'];
      if (rawPlan is List) {
        for (final p in rawPlan) {
          final step = ProtocolStep.fromJson(p);
          if (step != null) {
            plan.add(step);
          }
        }
      }
      final steps = rawPlan is List ? plan : buildProtocol(settings);
      return StopwatchState(
        running: json['running'] == true,
        acc: optInt(json['acc']) ?? 0,
        seg: optInt(json['seg']),
        pausedAt: optInt(json['pausedAt']),
        start: optInt(json['start']),
        splits: List.unmodifiable(splits),
        pauses: List.unmodifiable(pauses),
        ptr: math.min(math.max(optInt(json['ptr']) ?? 0, 0), steps.length),
        settings: settings,
        plan: List.unmodifiable(steps),
      );
    } catch (_) {
      return null;
    }
  }
}

// --- labels as CSV, in the same format as labels/Sxx_labels.csv --------------------------

const List<String> labelCsvFields = [
  'subject', 'session', 'start', 'end', 'duration_s', 'raw_label', 'class4', 'posture', //
  'intensity_value', 'intensity_unit', 'environment', 'source', 'note',
];

class _Segment {
  const _Segment(this.from, this.to, this.label, this.note, {this.manual = false});

  final int from;
  final int to;
  final String label;
  final String note;
  final bool manual;
}

/// A segment goes from the previous split (or from the start) to its split. If
/// the stopwatch was paused in between, the pause becomes a separate UNKNOWN row.
List<_Segment> _segments(StopwatchState s) {
  final out = <_Segment>[];
  final start = s.start;
  if (start == null) {
    return out;
  }
  var a = start;
  for (final sp in s.splits) {
    final b = sp.wall;
    var cur = a;
    for (final p in s.pauses) {
      if (p.to <= cur || p.from >= b) {
        continue;
      }
      if (p.from > cur) {
        out.add(_Segment(cur, p.from, sp.label, 'split ${sp.n}', manual: sp.manual));
      }
      out.add(_Segment(math.max(p.from, cur), math.min(p.to, b), 'UNKNOWN', 'stopwatch paused'));
      cur = math.min(p.to, b);
    }
    if (b > cur) {
      out.add(_Segment(cur, b, sp.label, 'split ${sp.n}', manual: sp.manual));
    }
    a = b;
  }
  return out;
}

/// indoor/outdoor as in labels_common.environments(): OUTDOOR*, everything
/// between the first and the last outdoor activity, and the REST that comes
/// before an outdoor activity.
List<String> labelEnvironments(List<String> labels) {
  final outdoor = <int>[
    for (var i = 0; i < labels.length; i++)
      if (labels[i].startsWith('OUTDOOR')) i,
  ];
  return [
    for (var i = 0; i < labels.length; i++) _environment(labels, outdoor, i),
  ];
}

String _environment(List<String> labels, List<int> outdoor, int i) {
  final label = labels[i];
  if (label.startsWith('OUTDOOR') || (outdoor.isNotEmpty && outdoor.first < i && i < outdoor.last)) {
    return 'outdoor';
  }
  if (label == 'REST') {
    final next = labels.skip(i + 1).firstWhere((x) => x != 'BUFFER', orElse: () => '');
    if (next.startsWith('OUTDOOR')) {
      return 'outdoor';
    }
  }
  return 'indoor';
}

String _csvField(String v) =>
    RegExp(r'[",\n]').hasMatch(v) ? '"${v.replaceAll('"', '""')}"' : v;

/// The labels as CSV (comma separated, CRLF), same columns as Sxx_labels.csv.
String labelCsv(StopwatchState s, {String source = 'lares_app'}) {
  final segments = _segments(s);
  final env = labelEnvironments([for (final g in segments) g.label]);
  final lines = <String>[labelCsvFields.join(',')];
  for (var i = 0; i < segments.length; i++) {
    final g = segments[i];
    final info = classifyLabel(g.label);
    final note = '${g.note}${g.manual ? '; label chosen by hand' : ''}';
    lines.add([
      s.settings.subject,
      'supervised',
      StopwatchFormat.iso(g.from),
      StopwatchFormat.iso(g.to),
      ((g.to - g.from) / 1000).toStringAsFixed(3),
      g.label,
      info.cls,
      info.posture,
      info.intensityValue,
      info.intensityUnit,
      env[i],
      source,
      note,
    ].map(_csvField).join(','));
  }
  return '${lines.join('\r\n')}\r\n';
}
