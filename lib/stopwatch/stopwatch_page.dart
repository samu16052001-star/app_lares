import 'dart:io';
import 'dart:math' as math;

import 'package:app_lares/stopwatch/stopwatch_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

/// Colors of time.sesnext.uk (light theme).
class _C {
  const _C._();

  static const bg = Color(0xFFF5F5F2);
  static const surface = Color(0xFFFFFFFF);
  static const text = Color(0xFF15171C);
  static const muted = Color(0xFF5F6570);
  static const line = Color(0xFFE2E2DC);
  static const go = Color(0xFF15803D);
  static const hold = Color(0xFFB45309);
  static const split = Color(0xFF1D4ED8);
  static const ghost = Color(0xFFE8E8E3);
  static const danger = Color(0xFFB91C1C);

  // classes of the activities
  static const cStatic = Color(0xFF6B7280);
  static const cWalk = Color(0xFF15803D);
  static const cRun = Color(0xFFC2410C);
  static const cBike = Color(0xFF1D4ED8);
  static const cExcluded = Color(0xFF9CA3AF);
}

Color _classColor(String cls) => switch (cls) {
      'static' => _C.cStatic,
      'walk' => _C.cWalk,
      'run' => _C.cRun,
      'bike' => _C.cBike,
      _ => _C.cExcluded,
    };

const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

const TextStyle _headStyle = TextStyle(
  fontSize: 11.5,
  letterSpacing: 0.6,
  color: _C.muted,
  fontWeight: FontWeight.w600,
);

/// Value returned by the activity picker for "Remove this step".
const String _removeChoice = '\u0000remove';

enum _View { setup, timer }

/// Stopwatch of the protocol, in two pages like time.sesnext.uk: the setup
/// (subject, block order, speeds and powers, protocol with the planned times)
/// and the stopwatch (current activity, splits, CSV of the labels).
class StopwatchPage extends StatefulWidget {
  const StopwatchPage({super.key, this.controller});

  static const String routeName = '/cronometro';

  /// Defaults to [StopwatchController.instance].
  final StopwatchController? controller;

  @override
  State<StopwatchPage> createState() => _StopwatchPageState();
}

class _StopwatchPageState extends State<StopwatchPage> {
  StopwatchController get _c => widget.controller ?? StopwatchController.instance;

  /// With a session in progress the page opens on the stopwatch, otherwise on
  /// the setup.
  late _View _view = _c.started ? _View.timer : _View.setup;

  /// Split number to highlight (just added).
  int? _flashN;
  bool _previewOpen = false;

  final _subjectCtl = TextEditingController();
  final _walkCtl = TextEditingController();
  final _runCtl = TextEditingController();
  final _powersCtl = TextEditingController();
  final _subjectFocus = FocusNode();
  final _walkFocus = FocusNode();
  final _runFocus = FocusNode();
  final _powersFocus = FocusNode();

  List<FocusNode> get _focusNodes => [_subjectFocus, _walkFocus, _runFocus, _powersFocus];

  /// False from the start of [dispose]: the fields must not be applied any more.
  bool _alive = true;

  @override
  void initState() {
    super.initState();
    _syncFields();
    _c.addListener(_syncFields);
    for (final node in _focusNodes) {
      node.addListener(() {
        // A field of the setup is applied when it loses the focus.
        if (_alive && !node.hasFocus) {
          _commitSetup();
        }
      });
    }
  }

  @override
  void dispose() {
    _alive = false;
    _c.removeListener(_syncFields);
    for (final ctl in [_subjectCtl, _walkCtl, _runCtl, _powersCtl]) {
      ctl.dispose();
    }
    for (final node in _focusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  // --- setup ---------------------------------------------------------------------

  static String _numbers(List<num> values) => values.map(StopwatchFormat.number).join(' ');

  /// Shows the saved settings in the fields that are not being edited.
  void _syncFields() {
    final s = _c.settings;
    void put(TextEditingController ctl, FocusNode focus, String text) {
      if (!focus.hasFocus && ctl.text != text) {
        ctl.text = text;
      }
    }

    put(_subjectCtl, _subjectFocus, s.subject);
    put(_walkCtl, _walkFocus, _numbers(s.walk));
    put(_runCtl, _runFocus, _numbers(s.run));
    put(_powersCtl, _powersFocus, _numbers(s.powers));
  }

  void _applySettings(StopwatchSettings next) {
    final before = _c.applySettings(next);
    _syncFields();
    if (before != null && mounted) {
      _toast(
        'Protocol rebuilt: your step changes were removed',
        action: 'Undo',
        onAction: () => _c.restorePlan(before),
      );
    }
  }

  /// Changing order, speeds or powers rebuilds the protocol; the subject code
  /// does not touch it.
  void _commitSetup() {
    _applySettings(_c.settings.copyWith(
      subject: _subjectCtl.text.trim().toUpperCase(),
      walk: parseNumberList(_walkCtl.text, 30),
      run: parseNumberList(_runCtl.text, 40),
      powers: parseNumberList(_powersCtl.text, 999),
    ));
  }

  void _setOrder(String order) => _applySettings(_c.settings.copyWith(order: order));

  void _continue() {
    FocusScope.of(context).unfocus();
    _commitSetup();
    setState(() => _view = _View.timer);
  }

  // --- actions ---------------------------------------------------------------------

  void _hideToast() => ScaffoldMessenger.of(context).hideCurrentSnackBar();

  void _toast(String message, {String? action, VoidCallback? onAction, int? ms}) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: Duration(milliseconds: ms ?? (action != null ? 6000 : 2500)),
        // With an action a SnackBar would stay until dismissed (Flutter 3.38+):
        // like the site, it goes away by itself.
        persist: false,
        action: action == null ? null : SnackBarAction(label: action, onPressed: onAction ?? () {}),
      ),
    );
  }

  void _toggle() {
    _hideToast();
    _c.toggle();
  }

  void _split() {
    final label = _c.currentLabel;
    final result = _c.split();
    switch (result) {
      case StopwatchSplitResult.notStarted:
        return;
      case StopwatchSplitResult.duplicate:
        _toast('This time is already recorded');
        return;
      case StopwatchSplitResult.added:
        setState(() => _flashN = _c.splits.length);
        _toast('${_c.splits.length}. $label', action: 'Undo', onAction: _c.undoSplit);
        return;
    }
  }

  /// Reset always goes through the confirmation; meanwhile the stopwatch
  /// keeps running. After a reset the next thing is a new session: setup page.
  Future<void> _askReset() async {
    if (!_c.started) {
      return;
    }
    final n = _c.splits.length;
    final text = n > 0
        ? 'The time and ${n == 1 ? 'the recorded split' : 'the $n recorded splits'} '
            'will be deleted.'
        : 'The recorded time will be deleted.';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => _ResetDialog(text: text),
    );
    if (!mounted || ok != true) {
      return;
    }
    final before = _c.reset();
    if (before == null) {
      return;
    }
    setState(() {
      _flashN = null;
      _view = _View.setup;
    });
    _toast('Session cleared', action: 'Undo', onAction: () {
      _c.restore(before);
      if (mounted) {
        setState(() => _view = _View.timer);
      }
    });
  }

  Future<String?> _pick({
    required String title,
    required String text,
    String? current,
    bool canRemove = false,
  }) =>
      showDialog<String>(
        context: context,
        builder: (context) => _PickerDialog(
          title: title,
          text: text,
          groups: labelCatalog(_c.settings),
          current: current,
          canRemove: canRemove,
        ),
      );

  /// "Change activity": the new activity stays in the protocol.
  Future<void> _changeStep() async {
    final step = _c.currentStep;
    if (step == null) {
      return;
    }
    final i = _c.ptr;
    final choice = await _pick(
      title: 'Change step ${i + 1}',
      text: 'It is now ${step.label}. The new activity stays in the protocol '
          'even if you go back or forward.',
      current: step.label,
      canRemove: true,
    );
    if (!mounted || choice == null) {
      return;
    }
    if (choice == _removeChoice) {
      final before = _c.removeStep();
      if (before != null) {
        _toast('Step ${i + 1} removed: ${step.label}', action: 'Undo', onAction: () => _c.restorePlan(before));
      }
      return;
    }
    final before = _c.changeStep(choice);
    if (before != null) {
      _toast('Step ${i + 1} changed: $choice', action: 'Undo', onAction: () => _c.restorePlan(before));
    }
  }

  /// "+ Add here": a new step before the current one; it becomes the current
  /// activity and, after its Split, the protocol continues as before.
  Future<void> _addStep() async {
    final step = _c.currentStep;
    final i = _c.ptr;
    final choice = await _pick(
      title: step != null ? 'Add an activity before step ${i + 1}' : 'Add an activity at the end',
      text: step != null
          ? 'It becomes the current activity; after its Split the protocol continues with ${step.label}.'
          : 'It becomes the current activity, at the end of the protocol.',
    );
    if (!mounted || choice == null || choice == _removeChoice) {
      return;
    }
    final before = _c.addStep(choice);
    _toast('Added as step ${i + 1}: $choice', action: 'Undo', onAction: () => _c.restorePlan(before));
  }

  /// Fixes the activity of a recorded split.
  Future<void> _changeSplit(int index) async {
    final split = _c.splits[index];
    final choice = await _pick(
      title: 'Activity of split ${split.n}',
      text: 'Changes only the label of this split.',
      current: split.label,
    );
    if (!mounted || choice == null || choice == _removeChoice) {
      return;
    }
    _c.setSplitLabel(index, choice);
  }

  Future<File> _writeTemp(String name, String text) async {
    final file = File('${Directory.systemTemp.path}${Platform.pathSeparator}$name');
    await file.writeAsString(text, flush: true);
    return file;
  }

  /// "Send .csv file": the CSV goes attached through the share panel (choose
  /// the mail app there), with subject and summary as on the site.
  Future<void> _send() async {
    if (_c.splits.isEmpty) {
      return;
    }
    final name = _c.fileName();
    try {
      final file = await _writeTemp(name, _c.csv());
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/csv', name: name)],
          subject: _c.subjectLine(),
          text: _c.summary(),
        ),
      );
    } catch (_) {
      if (mounted) {
        _toast('Could not send the file');
      }
    }
  }

  /// "Download": saved in Download (as the site downloads it); if that is not
  /// possible, through the share panel.
  Future<void> _download() async {
    if (_c.splits.isEmpty) {
      return;
    }
    final name = _c.fileName();
    try {
      final file = await _writeTemp(name, _c.csv());
      if (Platform.isAndroid) {
        final downloads = Directory('/storage/emulated/0/Download');
        try {
          if (await downloads.exists()) {
            await file.copy('${downloads.path}${Platform.pathSeparator}$name');
            if (mounted) {
              _toast('Saved in Download: $name');
            }
            return;
          }
        } catch (_) {
          // Fall back to the share panel.
        }
      }
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/csv', name: name)],
          subject: name,
        ),
      );
    } catch (_) {
      if (mounted) {
        _toast('CSV not saved');
      }
    }
  }

  Future<void> _copy() async {
    if (_c.splits.isEmpty) {
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: _c.csv()));
      if (mounted) {
        _toast('Rows copied');
      }
    } catch (_) {
      if (mounted) {
        _toast('Copy failed');
      }
    }
  }

  // --- build -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final setup = _view == _View.setup;
        return Scaffold(
          backgroundColor: _C.bg,
          appBar: AppBar(
            backgroundColor: _C.bg,
            surfaceTintColor: Colors.transparent,
            foregroundColor: _C.text,
            title: Text(
              setup ? 'Stopwatch · protocol' : 'Stopwatch',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(
                  child: setup
                      ? const _Pill(label: 'Setup', foreground: _C.muted, background: _C.ghost)
                      : _StatusPill(started: _c.started, running: _c.running),
                ),
              ),
            ],
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: setup ? _buildSetup() : _buildTimer(),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSetup() {
    final s = _c.settings;
    final started = _c.started;
    final n = _c.splits.length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
      children: [
        _Card(
          title: 'Session',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _FieldLabel('Subject code', optional: true),
              _Field(
                controller: _subjectCtl,
                focusNode: _subjectFocus,
                hint: 'e.g. S23',
                capitals: true,
                onSubmitted: _commitSetup,
              ),
              const SizedBox(height: 14),
              const _FieldLabel('Block order'),
              Row(
                children: [
                  Expanded(
                    child: _Segment(
                      label: 'Indoor → outdoor',
                      selected: s.order != 'outdoor',
                      onTap: () => _setOrder('indoor'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _Segment(
                      label: 'Outdoor → indoor',
                      selected: s.order == 'outdoor',
                      onTap: () => _setOrder('outdoor'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        _Card(
          title: 'Intensities',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _FieldLabel('Treadmill walking speeds (km/h)'),
              _Field(controller: _walkCtl, focusNode: _walkFocus, onSubmitted: _commitSetup),
              const SizedBox(height: 14),
              const _FieldLabel('Treadmill running speeds (km/h)'),
              _Field(controller: _runCtl, focusNode: _runFocus, onSubmitted: _commitSetup),
              const SizedBox(height: 14),
              const _FieldLabel('Cycle ergometer powers, in order (W)'),
              _Field(controller: _powersCtl, focusNode: _powersFocus, onSubmitted: _commitSetup),
              const SizedBox(height: 10),
              const Text(
                'Separate the values with spaces, in the order they are done. '
                'Leave a field empty to skip that part of the protocol.',
                style: TextStyle(color: _C.muted, fontSize: 13.6),
              ),
            ],
          ),
        ),
        _Card(title: 'Protocol', child: _ProtocolList(plan: _c.plan)),
        if (started)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              'A session is in progress (${StopwatchController.splitsLabel(n)}). Changing the order, '
              'speeds or powers rebuilds the protocol, and changes made to single steps are lost.',
              style: const TextStyle(color: _C.hold, fontSize: 14.4),
            ),
          ),
        const SizedBox(height: 16),
        _ActionButton(
          label: started ? 'Back to the stopwatch' : 'Continue to the stopwatch',
          background: _C.go,
          foreground: Colors.white,
          enabled: true,
          onTap: _continue,
        ),
      ],
    );
  }

  Widget _buildTimer() {
    final started = _c.started;
    final running = _c.running;
    final has = _c.splits.isNotEmpty;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() => _view = _View.setup),
            style: TextButton.styleFrom(foregroundColor: _C.split, padding: EdgeInsets.zero),
            child: const Text('‹ Setup', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
        ),
        _SetupSummary(settings: _c.settings),
        _ClockSection(controller: _c),
        _NowCard(
          controller: _c,
          onPrev: () => _c.move(-1),
          onNext: () => _c.move(1),
          onJump: _c.jump,
          onChange: _changeStep,
          onAdd: _addStep,
        ),
        const SizedBox(height: 16),
        _Controls(
          started: started,
          running: running,
          onToggle: _toggle,
          onSplit: _split,
          onReset: _askReset,
        ),
        _Card(
          title: 'Splits',
          child: has
              ? _SplitTable(controller: _c, flashN: _flashN, onLabelTap: _changeSplit)
              : const Text(
                  'No splits yet. Each Split closes the current activity with its name '
                  'and starts the next step of the protocol.',
                  style: TextStyle(color: _C.muted, fontSize: 15.2),
                ),
        ),
        _Card(
          title: 'Send the labels',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: _ActionButton(
                      label: 'Send .csv file',
                      background: _C.split,
                      foreground: Colors.white,
                      small: true,
                      enabled: has,
                      onTap: _send,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ActionButton(
                      label: 'Download',
                      background: _C.ghost,
                      foreground: _C.text,
                      small: true,
                      enabled: has,
                      onTap: _download,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ActionButton(
                      label: 'Copy',
                      background: _C.ghost,
                      foreground: _C.text,
                      small: true,
                      enabled: has,
                      onTap: _copy,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const Text(
                '"Send .csv file" attaches the labels: pick your mail app in the panel that opens. '
                'The file has the same format as labels/Sxx_labels.csv; close the last activity '
                'with Split before sending it.',
                style: TextStyle(color: _C.muted, fontSize: 13.6),
              ),
              const SizedBox(height: 12),
              _Preview(
                open: _previewOpen,
                onToggle: () => setState(() => _previewOpen = !_previewOpen),
                text: !_previewOpen ? '' : (has ? _c.csv() : 'Rows appear at each Split.'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// --- small pieces -------------------------------------------------------------------

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.foreground, required this.background});

  final String label;
  final Color foreground;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(999)),
      child: Text(
        label,
        style: TextStyle(color: foreground, fontSize: 12.8, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.started, required this.running});

  final bool started;
  final bool running;

  @override
  Widget build(BuildContext context) {
    if (running) {
      return _Pill(label: 'Running', foreground: _C.go, background: _C.go.withValues(alpha: 0.15));
    }
    if (started) {
      return _Pill(label: 'Paused', foreground: _C.hold, background: _C.hold.withValues(alpha: 0.15));
    }
    return const _Pill(label: 'Ready', foreground: _C.muted, background: _C.ghost);
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text, {this.optional = false});

  final String text;
  final bool optional;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text.rich(
        TextSpan(
          style: const TextStyle(color: _C.muted, fontSize: 12.8, fontWeight: FontWeight.w600),
          children: [
            TextSpan(text: text),
            if (optional) const TextSpan(text: ' (optional)', style: TextStyle(fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.focusNode,
    required this.onSubmitted,
    this.hint,
    this.capitals = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSubmitted;
  final String? hint;
  final bool capitals;

  @override
  Widget build(BuildContext context) {
    OutlineInputBorder border(Color color, double width) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: color, width: width),
        );
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autocorrect: false,
      enableSuggestions: false,
      textCapitalization: capitals ? TextCapitalization.characters : TextCapitalization.none,
      onSubmitted: (_) => onSubmitted(),
      style: const TextStyle(fontSize: 16, color: _C.text),
      decoration: InputDecoration(
        hintText: hint,
        isDense: true,
        filled: true,
        fillColor: _C.bg,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        border: border(_C.line, 1),
        enabledBorder: border(_C.line, 1),
        focusedBorder: border(_C.split, 2),
      ),
    );
  }
}

/// One of the two "Block order" buttons.
class _Segment extends StatelessWidget {
  const _Segment({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          constraints: const BoxConstraints(minHeight: 46),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? _C.split : _C.bg,
            border: Border.all(color: selected ? _C.split : _C.line),
            borderRadius: BorderRadius.circular(10),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              maxLines: 1,
              style: TextStyle(
                color: selected ? Colors.white : _C.text,
                fontSize: 15.2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small colored bar of the class of an activity.
class _ClassMark extends StatelessWidget {
  const _ClassMark({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 4,
      height: 18,
      decoration: BoxDecoration(
        color: _classColor(classifyLabel(label).cls),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

/// Protocol of the setup page, grouped by block, with the planned time of
/// every activity (the buffers are not listed).
class _ProtocolList extends StatelessWidget {
  const _ProtocolList({required this.plan});

  final List<ProtocolStep> plan;

  @override
  Widget build(BuildContext context) {
    final groups = <(String, List<Widget>)>[];
    String? block;
    var count = 0;
    var seconds = 0;
    for (var i = 0; i < plan.length; i++) {
      final step = plan[i];
      final name = step.block ?? '';
      if (groups.isEmpty || name != block) {
        block = name;
        groups.add((protocolBlockNames[name] ?? 'Other', <Widget>[]));
      }
      if (step.label == 'BUFFER') {
        continue;
      }
      final d = step.duration;
      count++;
      seconds += d?.estimateSeconds ?? 0;
      groups.last.$2.add(
        Container(
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: _C.line))),
          child: Row(
            children: [
              SizedBox(
                width: 30,
                child: Text(
                  '${i + 1}',
                  style: const TextStyle(color: _C.muted, fontSize: 12.8, fontFeatures: _tabular),
                ),
              ),
              _ClassMark(label: step.label),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    style: const TextStyle(color: _C.text, fontSize: 14.7, fontWeight: FontWeight.w600),
                    children: [
                      TextSpan(text: step.label),
                      if (step.edited)
                        TextSpan(
                          text: ' (${step.tag})',
                          style: const TextStyle(color: _C.muted, fontWeight: FontWeight.w500),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                d?.label ?? '',
                style: const TextStyle(color: _C.muted, fontSize: 14.4, fontFeatures: _tabular),
              ),
            ],
          ),
        ),
      );
    }
    final minutes = (seconds / 60).round();
    final total = minutes >= 60 ? '${minutes ~/ 60} h ${minutes % 60} min' : '$minutes min';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '$count activities, about $total plus the buffers between them.',
          style: const TextStyle(color: _C.muted, fontSize: 13.6),
        ),
        for (final (name, rows) in groups)
          if (rows.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(top: 14, bottom: 2),
              child: Text(name.toUpperCase(), style: _headStyle),
            ),
            ...rows,
          ],
      ],
    );
  }
}

/// "S23 · Indoor → outdoor · treadmill 3/4/5/6 + 8/9/10 km/h · bike 80/100/120/80 W".
class _SetupSummary extends StatelessWidget {
  const _SetupSummary({required this.settings});

  final StopwatchSettings settings;

  @override
  Widget build(BuildContext context) {
    String list(List<num> v) => v.map(StopwatchFormat.number).join('/');
    final parts = <String>[settings.order == 'outdoor' ? 'Outdoor → indoor' : 'Indoor → outdoor'];
    final tread = [list(settings.walk), list(settings.run)].where((x) => x.isNotEmpty).join(' + ');
    if (tread.isNotEmpty) {
      parts.add('treadmill $tread km/h');
    }
    if (settings.powers.isNotEmpty) {
      parts.add('bike ${list(settings.powers)} W');
    }
    return Text.rich(
      TextSpan(
        style: const TextStyle(color: _C.muted, fontSize: 14.4),
        children: [
          if (settings.subject.isNotEmpty)
            TextSpan(
              text: settings.subject,
              style: const TextStyle(color: _C.text, fontWeight: FontWeight.w700),
            )
          else
            const TextSpan(text: 'no subject code'),
          TextSpan(text: ' · ${parts.join(' · ')}'),
        ],
      ),
    );
  }
}

/// Rebuilds [builder] every frame while the stopwatch runs.
class _Live extends StatefulWidget {
  const _Live({required this.controller, required this.builder});

  final StopwatchController controller;
  final WidgetBuilder builder;

  @override
  State<_Live> createState() => _LiveState();
}

class _LiveState extends State<_Live> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) => setState(() {}));

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_sync);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _Live oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_sync);
      widget.controller.addListener(_sync);
      _sync();
    }
  }

  void _sync() {
    if (widget.controller.running) {
      if (!_ticker.isActive) {
        _ticker.start();
      }
    } else if (_ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sync);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// "Planned 2 min · 1:23 left" (orange "+0:07 over" when the time is up).
class _PlanLine extends StatelessWidget {
  const _PlanLine({required this.controller});

  final StopwatchController controller;

  @override
  Widget build(BuildContext context) {
    final step = controller.currentStep;
    if (step == null) {
      return const SizedBox.shrink();
    }
    const base = TextStyle(color: _C.text, fontSize: 15.2, fontFeatures: _tabular);
    final d = step.duration;
    if (d == null) {
      return Text(
        step.label == 'BUFFER' ? 'Transition, no planned time' : 'No planned time',
        style: base.copyWith(color: _C.muted),
      );
    }
    final spans = <InlineSpan>[
      const TextSpan(text: 'Planned '),
      TextSpan(text: d.label, style: const TextStyle(fontWeight: FontWeight.w600)),
    ];
    final seconds = d.seconds;
    if (seconds != null && controller.started) {
      final lap = controller.elapsed() - controller.lastTotal;
      final left = seconds * 1000 - lap;
      spans.add(
        left > 0
            ? TextSpan(text: ' · ${StopwatchFormat.minSec(left)} left', style: const TextStyle(color: _C.muted))
            : TextSpan(
                text: ' · +${StopwatchFormat.minSec(-left)} over',
                style: const TextStyle(color: _C.hold, fontWeight: FontWeight.w600),
              ),
      );
    }
    return Text.rich(TextSpan(style: base, children: spans));
  }
}

String _stepText(int i, ProtocolStep step) {
  final d = step.duration;
  return '${i + 1}. ${step.label}${d != null ? ' · ${d.label}' : ''}${step.edited ? ' (${step.tag})' : ''}';
}

/// Menu with every step of the protocol, to jump to any of them.
class _StepMenu extends StatelessWidget {
  const _StepMenu({required this.controller, required this.onJump});

  final StopwatchController controller;
  final ValueChanged<int> onJump;

  @override
  Widget build(BuildContext context) {
    final plan = controller.plan;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: _C.bg,
        border: Border.all(color: _C.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          isExpanded: true,
          value: controller.ptr,
          menuMaxHeight: 420,
          style: const TextStyle(color: _C.text, fontSize: 15.2),
          items: [
            for (var i = 0; i < plan.length; i++)
              DropdownMenuItem<int>(
                value: i,
                child: Text(_stepText(i, plan[i]), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            DropdownMenuItem<int>(value: plan.length, child: const Text('End of the protocol')),
          ],
          onChanged: (value) {
            if (value != null) {
              onJump(value);
            }
          },
        ),
      ),
    );
  }
}

/// "Current activity": name, class, planned time, next steps, step buttons
/// and the changes to the protocol.
class _NowCard extends StatelessWidget {
  const _NowCard({
    required this.controller,
    required this.onPrev,
    required this.onNext,
    required this.onJump,
    required this.onChange,
    required this.onAdd,
  });

  final StopwatchController controller;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final ValueChanged<int> onJump;
  final VoidCallback onChange;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final plan = c.plan;
    final step = c.currentStep;
    final info = classifyLabel(c.currentLabel);
    final color = _classColor(info.cls);
    final position = step == null
        ? 'END, ${plan.length} STEPS'
        : 'STEP ${c.ptr + 1} OF ${plan.length}${step.edited ? ' · ${step.tag.toUpperCase()}' : ''}';
    final next = plan.skip(c.ptr + 1).take(2).toList();
    final linkStyle = TextButton.styleFrom(
      foregroundColor: _C.split,
      padding: EdgeInsets.zero,
      textStyle: const TextStyle(fontSize: 15.2, fontWeight: FontWeight.w600),
    );
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(22, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('CURRENT ACTIVITY · $position', style: _headStyle),
          const SizedBox(height: 4),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            runSpacing: 4,
            children: [
              Text(
                step == null ? 'Protocol finished' : step.label,
                style: const TextStyle(fontSize: 24.8, fontWeight: FontWeight.w700, color: _C.text, height: 1.2),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(999)),
                child: Text(
                  info.cls,
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          _Live(controller: c, builder: (context) => _PlanLine(controller: c)),
          const SizedBox(height: 2),
          Text.rich(
            TextSpan(
              style: const TextStyle(color: _C.muted, fontSize: 14.4),
              children: [
                const TextSpan(text: 'Next: '),
                if (next.isEmpty) const TextSpan(text: 'end of the protocol'),
                for (var k = 0; k < next.length; k++) ...[
                  if (k > 0) const TextSpan(text: ' → '),
                  TextSpan(
                    text: next[k].label,
                    style: const TextStyle(color: _C.text, fontWeight: FontWeight.w600),
                  ),
                  if (next[k].duration != null) TextSpan(text: ' (${next[k].duration?.label})'),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _StepButton(
                icon: Icons.chevron_left_rounded,
                label: 'Previous step of the protocol',
                enabled: c.ptr > 0,
                onTap: onPrev,
              ),
              const SizedBox(width: 8),
              Expanded(child: _StepMenu(controller: c, onJump: onJump)),
              const SizedBox(width: 8),
              _StepButton(
                icon: Icons.chevron_right_rounded,
                label: 'Next step of the protocol',
                enabled: c.ptr < plan.length,
                onTap: onNext,
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(
                onPressed: step == null ? null : onChange,
                style: linkStyle,
                child: const Text('Change activity'),
              ),
              TextButton(onPressed: onAdd, style: linkStyle, child: const Text('+ Add here')),
            ],
          ),
        ],
      ),
    );
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: _C.surface,
        border: Border.all(color: _C.line),
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          content,
          Positioned(left: 0, top: 0, bottom: 0, width: 6, child: ColoredBox(color: color)),
        ],
      ),
    );
  }
}

/// Big time + "Lap · Splits". Repaints every frame only while running; paused
/// it "breathes" like the site.
class _ClockSection extends StatefulWidget {
  const _ClockSection({required this.controller});

  final StopwatchController controller;

  @override
  State<_ClockSection> createState() => _ClockSectionState();
}

class _ClockSectionState extends State<_ClockSection> with TickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) => setState(() {}));
  late final AnimationController _breathe = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  /// Reduced motion (system setting): no "breathing" in pause.
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_sync);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _sync();
  }

  @override
  void didUpdateWidget(covariant _ClockSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_sync);
      widget.controller.addListener(_sync);
      _sync();
    }
  }

  /// Ticker only while running, breathing only while paused.
  void _sync() {
    final c = widget.controller;
    if (c.running) {
      if (!_ticker.isActive) {
        _ticker.start();
      }
    } else if (_ticker.isActive) {
      _ticker.stop();
    }
    final paused = c.started && !c.running;
    if (paused && !_reduceMotion) {
      if (!_breathe.isAnimating) {
        _breathe.repeat();
      }
    } else if (_breathe.isAnimating || _breathe.value != 0) {
      _breathe.stop();
      _breathe.value = 0;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sync);
    _ticker.dispose();
    _breathe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final total = c.elapsed();
    final paused = c.started && !c.running;
    final reduce = _reduceMotion;
    final width = MediaQuery.sizeOf(context).width;
    final fontSize = (width * 0.17).clamp(54.4, 116.0).toDouble();
    final display = Text(
      StopwatchFormat.fmt(total),
      textAlign: TextAlign.center,
      maxLines: 1,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w600,
        height: 1,
        letterSpacing: -0.03 * fontSize,
        color: _C.text,
        fontFeatures: _tabular,
      ),
    );
    return Semantics(
      label: 'Time',
      child: Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 14),
        child: Column(
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: paused
                  ? (reduce
                      ? Opacity(opacity: 0.6, child: display)
                      : AnimatedBuilder(
                          animation: _breathe,
                          builder: (context, child) {
                            // opacity 1 -> 0.35 -> 1 (ease-in-out), as the site
                            final x = Curves.easeInOut.transform(
                              1 - (2 * _breathe.value - 1).abs(),
                            );
                            return Opacity(opacity: 1 - 0.65 * x, child: child);
                          },
                          child: display,
                        ))
                  : display,
            ),
            const SizedBox(height: 10),
            Text.rich(
              TextSpan(
                style: const TextStyle(
                  color: _C.muted,
                  fontSize: 16,
                  fontFeatures: _tabular,
                ),
                children: [
                  const TextSpan(text: 'Lap '),
                  TextSpan(
                    text: StopwatchFormat.fmt(total - c.lastTotal),
                    style: const TextStyle(color: _C.text, fontWeight: FontWeight.w600),
                  ),
                  const TextSpan(text: ' · Splits '),
                  TextSpan(
                    text: '${c.splits.length}',
                    style: const TextStyle(color: _C.text, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.started,
    required this.running,
    required this.onToggle,
    required this.onSplit,
    required this.onReset,
  });

  final bool started;
  final bool running;
  final VoidCallback onToggle;
  final VoidCallback onSplit;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    // Grid 2fr 2fr 1.3fr, gap 10, as the site.
    return Row(
      children: [
        Expanded(
          flex: 20,
          child: _ActionButton(
            label: running ? 'Pause' : (started ? 'Resume' : 'Start'),
            background: running ? _C.hold : _C.go,
            foreground: Colors.white,
            enabled: true,
            instant: true,
            onTap: onToggle,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 20,
          child: _ActionButton(
            label: 'Split',
            background: _C.split,
            foreground: Colors.white,
            enabled: started,
            instant: true,
            onTap: onSplit,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 13,
          child: _ActionButton(
            label: 'Reset',
            background: _C.ghost,
            foreground: _C.text,
            enabled: started,
            onTap: onReset,
          ),
        ),
      ],
    );
  }
}

/// Button of the site. With [instant] the action fires on pointer down (the
/// moment of the touch); otherwise on tap.
class _ActionButton extends StatefulWidget {
  const _ActionButton({
    required this.label,
    required this.background,
    required this.foreground,
    required this.enabled,
    required this.onTap,
    this.instant = false,
    this.small = false,
  });

  final String label;
  final Color background;
  final Color foreground;
  final bool enabled;
  final bool instant;
  final bool small;
  final VoidCallback onTap;

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _pressed = false;

  void _down(PointerDownEvent event) {
    if (!widget.enabled) {
      return;
    }
    setState(() => _pressed = true);
    if (widget.instant &&
        (event.kind != PointerDeviceKind.mouse || (event.buttons & kPrimaryButton) != 0)) {
      widget.onTap();
    }
  }

  void _up() {
    if (_pressed) {
      setState(() => _pressed = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final button = AnimatedScale(
      scale: _pressed ? 0.97 : 1,
      duration: const Duration(milliseconds: 60),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        constraints: BoxConstraints(minHeight: widget.small ? 46 : 68),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: widget.background,
          borderRadius: BorderRadius.circular(widget.small ? 12 : 14),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            widget.label,
            maxLines: 1,
            style: TextStyle(
              color: widget.foreground,
              fontSize: widget.small ? 15.2 : 17.6,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.label,
      onTap: widget.enabled ? widget.onTap : null,
      excludeSemantics: true,
      child: Opacity(
        opacity: widget.enabled ? 1 : 0.4,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _down,
          onPointerUp: (_) => _up(),
          onPointerCancel: (_) => _up(),
          child: widget.instant
              ? button
              : GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.enabled ? widget.onTap : null,
                  child: button,
                ),
        ),
      ),
    );
  }
}

/// Previous / next step: rounded square with a chevron, same height as the menu.
class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: _C.ghost,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(icon, size: 30, color: enabled ? _C.text : _C.muted.withValues(alpha: 0.45)),
          ),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 24),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _C.surface,
        border: Border.all(color: _C.line),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 15.2,
              fontWeight: FontWeight.w600,
              color: _C.text,
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

/// Activity of a split: tap to change it.
class _LabelButton extends StatelessWidget {
  const _LabelButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Activity $label, tap to change it',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: _C.surface,
            border: Border.all(color: _C.line),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              _ClassMark(label: label),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _C.text, fontSize: 14.4, fontWeight: FontWeight.w600),
                ),
              ),
              const Icon(Icons.arrow_drop_down, size: 20, color: _C.muted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Splits, newest first: number, activity (tap to change it), lap and time.
class _SplitTable extends StatelessWidget {
  const _SplitTable({required this.controller, required this.flashN, required this.onLabelTap});

  final StopwatchController controller;
  final int? flashN;
  final ValueChanged<int> onLabelTap;

  Widget _row(List<Widget> cells, {Color? background, bool border = true}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: background,
        border: border ? const Border(bottom: BorderSide(color: _C.line)) : null,
      ),
      child: Row(
        children: [
          SizedBox(width: 32, child: cells[0]),
          Expanded(child: cells[1]),
          const SizedBox(width: 8),
          SizedBox(width: 104, child: cells[2]),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const base = TextStyle(fontSize: 15.2, color: _C.text, fontFeatures: _tabular);
    final splits = controller.splits;
    final rows = <Widget>[
      _row([
        const Text('#', style: _headStyle),
        const Text('ACTIVITY', style: _headStyle),
        const Align(alignment: Alignment.centerRight, child: Text('LAP · TIME', style: _headStyle)),
      ]),
    ];
    for (var i = splits.length - 1; i >= 0; i--) {
      final s = splits[i];
      final index = i;
      final cells = [
        Text('${s.n}', style: base.copyWith(color: _C.muted)),
        _LabelButton(label: s.label, onTap: () => onLabelTap(index)),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(StopwatchFormat.fmt(s.lap, millis: true), style: base),
            ),
            Text(
              StopwatchFormat.clock(s.wall),
              style: const TextStyle(color: _C.muted, fontSize: 12.8, fontFeatures: _tabular),
            ),
          ],
        ),
      ];
      final last = i == 0;
      if (s.n == flashN) {
        rows.add(TweenAnimationBuilder<double>(
          key: ValueKey('flash-${s.n}'),
          tween: Tween(begin: 1, end: 0),
          duration: const Duration(seconds: 1),
          curve: Curves.easeOut,
          builder: (context, v, _) => _row(
            cells,
            background: _C.split.withValues(alpha: 0.2 * v),
            border: !last,
          ),
        ));
      } else {
        rows.add(_row(cells, border: !last));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }
}

/// "File preview" (details/summary of the site).
class _Preview extends StatelessWidget {
  const _Preview({required this.open, required this.onToggle, required this.text});

  final bool open;
  final VoidCallback onToggle;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onToggle,
          child: Row(
            children: [
              AnimatedRotation(
                turns: open ? 0.25 : 0,
                duration: const Duration(milliseconds: 150),
                child: const Icon(Icons.arrow_right, size: 20, color: _C.muted),
              ),
              const Text(
                'File preview',
                style: TextStyle(color: _C.muted, fontSize: 13.6),
              ),
            ],
          ),
        ),
        if (open)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(12),
            constraints: const BoxConstraints(maxHeight: 280),
            decoration: BoxDecoration(
              color: _C.bg,
              border: Border.all(color: _C.line),
              borderRadius: BorderRadius.circular(10),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.5,
                  color: _C.text,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Activities to pick, in groups (as the menus of the site).
class _PickerDialog extends StatelessWidget {
  const _PickerDialog({
    required this.title,
    required this.text,
    required this.groups,
    this.current,
    this.canRemove = false,
  });

  final String title;
  final String text;
  final List<(String, List<String>)> groups;
  final String? current;
  final bool canRemove;

  Widget _option(BuildContext context, String label) {
    final selected = label == current;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).pop(label),
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: _C.bg,
          border: Border.all(color: selected ? _C.split : _C.line, width: selected ? 2 : 1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            _ClassMark(label: label),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(color: _C.text, fontSize: 13.6, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _grid(BuildContext context, List<String> labels) {
    return Column(
      children: [
        for (var i = 0; i < labels.length; i += 2)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Expanded(child: _option(context, labels[i])),
                const SizedBox(width: 6),
                Expanded(
                  child: i + 1 < labels.length ? _option(context, labels[i + 1]) : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _C.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _C.line),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: const TextStyle(fontSize: 17.6, fontWeight: FontWeight.w600, color: _C.text),
              ),
              const SizedBox(height: 6),
              Text(text, style: const TextStyle(color: _C.muted, fontSize: 15)),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (name, labels) in groups) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 6),
                          child: Text(name.toUpperCase(), style: _headStyle),
                        ),
                        _grid(context, labels),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (canRemove) ...[
                    Expanded(
                      child: _ActionButton(
                        label: 'Remove this step',
                        background: _C.ghost,
                        foreground: _C.text,
                        small: true,
                        enabled: true,
                        onTap: () => Navigator.of(context).pop(_removeChoice),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: _ActionButton(
                      label: 'Close',
                      background: _C.ghost,
                      foreground: _C.text,
                      small: true,
                      enabled: true,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResetDialog extends StatelessWidget {
  const _ResetDialog({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _C.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _C.line),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Reset the stopwatch?',
                style: TextStyle(fontSize: 17.6, fontWeight: FontWeight.w600, color: _C.text),
              ),
              const SizedBox(height: 6),
              Text(text, style: const TextStyle(color: _C.muted, fontSize: 16)),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _ActionButton(
                      label: 'Cancel',
                      background: _C.ghost,
                      foreground: _C.text,
                      small: true,
                      enabled: true,
                      onTap: () => Navigator.of(context).pop(false),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ActionButton(
                      label: 'Reset',
                      background: _C.danger,
                      foreground: Colors.white,
                      small: true,
                      enabled: true,
                      onTap: () => Navigator.of(context).pop(true),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Short time for the bottom bar: [h:]mm:ss (as the site's tab title).
String stopwatchShortTime(int ms) {
  final s = StopwatchFormat.fmt(ms);
  return s.substring(0, math.max(0, s.length - 3));
}
