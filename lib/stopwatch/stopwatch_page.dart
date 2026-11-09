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
  static const best = Color(0xFF15803D);
  static const worst = Color(0xFFB91C1C);
  static const danger = Color(0xFFB91C1C);
}

const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

/// Stopwatch page: works like time.sesnext.uk.
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

  /// Split number to highlight (just added).
  int? _flashN;
  bool _previewOpen = false;

  // --- actions ---------------------------------------------------------------

  void _hideToast() => ScaffoldMessenger.of(context).hideCurrentSnackBar();

  void _toast(String message, {String? action, VoidCallback? onAction}) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: Duration(milliseconds: action != null ? 6000 : 2500),
        action: action == null
            ? null
            : SnackBarAction(label: action, onPressed: onAction ?? () {}),
      ),
    );
  }

  void _toggle() {
    _hideToast();
    _c.toggle();
  }

  void _split() {
    final result = _c.split();
    switch (result) {
      case StopwatchSplitResult.notStarted:
        return;
      case StopwatchSplitResult.duplicate:
        _toast('This time is already recorded');
        return;
      case StopwatchSplitResult.added:
        _hideToast();
        setState(() => _flashN = _c.splits.length);
        return;
    }
  }

  /// Reset always goes through the confirmation; meanwhile the stopwatch
  /// keeps running.
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
    });
    _toast('Session reset', action: 'Undo', onAction: () {
      _c.restore(before);
    });
  }

  Future<File> _writeTemp(String name, String text) async {
    final file = File('${Directory.systemTemp.path}${Platform.pathSeparator}$name');
    await file.writeAsString(text, flush: true);
    return file;
  }

  /// "Send .txt file": the .txt goes attached through the share panel
  /// (choose the mail app there), with subject and summary as on the site.
  Future<void> _sendTxt() async {
    if (!_c.started) {
      return;
    }
    final name = _c.fileName('txt');
    final text = _c.report().replaceAll('\n', '\r\n');
    try {
      final file = await _writeTemp(name, text);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/plain', name: name)],
          subject: _c.subject(),
          text: _c.summary(),
        ),
      );
    } catch (_) {
      if (mounted) {
        _toast('Could not send the file');
      }
    }
  }

  Future<void> _copy() async {
    if (!_c.started) {
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: _c.report()));
      if (mounted) {
        _toast('Times copied');
      }
    } catch (_) {
      if (mounted) {
        _toast('Copy failed');
      }
    }
  }

  /// "CSV": saved in Download (as the site downloads it); if that is not
  /// possible, through the share panel.
  Future<void> _saveCsv() async {
    if (!_c.started) {
      return;
    }
    final name = _c.fileName('csv');
    try {
      final file = await _writeTemp(name, _c.csv());
      if (Platform.isAndroid) {
        final downloads = Directory('/storage/emulated/0/Download');
        try {
          if (await downloads.exists()) {
            await file.copy('${downloads.path}${Platform.pathSeparator}$name');
            if (mounted) {
              _toast('CSV saved in Download: $name');
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

  // --- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final started = _c.started;
        final running = _c.running;
        return Scaffold(
          backgroundColor: _C.bg,
          appBar: AppBar(
            backgroundColor: _C.bg,
            surfaceTintColor: Colors.transparent,
            foregroundColor: _C.text,
            title: const Text(
              'Stopwatch',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(child: _StatusPill(started: started, running: running)),
              ),
            ],
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
                children: [
                  _ClockSection(controller: _c),
                  _Controls(
                    started: started,
                    running: running,
                    onToggle: _toggle,
                    onSplit: _split,
                    onReset: _askReset,
                  ),
                  _Card(
                    title: 'Splits',
                    child: _c.splits.isEmpty
                        ? const Text(
                            'No splits yet. Press Split, even while the stopwatch '
                            'is paused, to record the time.',
                            style: TextStyle(color: _C.muted, fontSize: 15.2),
                          )
                        : _SplitTable(controller: _c, flashN: _flashN),
                  ),
                  _Card(
                    title: 'Send the times',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: _ActionButton(
                                label: 'Send .txt file',
                                background: _C.split,
                                foreground: Colors.white,
                                small: true,
                                enabled: started,
                                onTap: _sendTxt,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _ActionButton(
                                label: 'Copy',
                                background: _C.ghost,
                                foreground: _C.text,
                                small: true,
                                enabled: started,
                                onTap: _copy,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _ActionButton(
                                label: 'CSV',
                                background: _C.ghost,
                                foreground: _C.text,
                                small: true,
                                enabled: started,
                                onTap: _saveCsv,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          '"Send .txt file" attaches the times as a text file: '
                          'pick your mail app in the panel that opens.',
                          style: TextStyle(color: _C.muted, fontSize: 13.6),
                        ),
                        const SizedBox(height: 12),
                        _Preview(
                          open: _previewOpen,
                          onToggle: () => setState(() => _previewOpen = !_previewOpen),
                          text: !_previewOpen
                              ? ''
                              : started
                                  ? _c.report()
                                  : 'Start the stopwatch to see the text of the mail.',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.started, required this.running});

  final bool started;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final String label;
    final Color fg;
    final Color bg;
    if (running) {
      label = 'Running';
      fg = _C.go;
      bg = _C.go.withValues(alpha: 0.15);
    } else if (started) {
      label = 'Paused';
      fg = _C.hold;
      bg = _C.hold.withValues(alpha: 0.15);
    } else {
      label = 'Ready';
      fg = _C.muted;
      bg = _C.ghost;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text(
        label,
        style: TextStyle(color: fg, fontSize: 12.8, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Big time + "Giro · Split". Repaints every frame only while running; paused
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

  /// Ticker only while running, breathing only while paused. The page
  /// rebuilds this widget on every change of the controller.
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
        padding: const EdgeInsets.only(top: 36, bottom: 28),
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
            const SizedBox(height: 14),
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

/// Splits, newest first; fastest lap green, slowest red (from 3 splits).
class _SplitTable extends StatelessWidget {
  const _SplitTable({required this.controller, required this.flashN});

  final StopwatchController controller;
  final int? flashN;

  static const _cellPad = EdgeInsets.symmetric(horizontal: 4, vertical: 9);

  Widget _cell(String text, TextStyle style, {bool first = false}) {
    return Padding(
      padding: _cellPad,
      child: Align(
        alignment: first ? Alignment.centerLeft : Alignment.centerRight,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(text, maxLines: 1, style: style),
        ),
      ),
    );
  }

  Widget _row(List<Widget> cells, {Color? background, bool border = true}) {
    return Container(
      decoration: BoxDecoration(
        color: background,
        border: border ? const Border(bottom: BorderSide(color: _C.line)) : null,
      ),
      child: Row(
        children: [
          SizedBox(width: 40, child: cells[0]),
          Expanded(flex: 10, child: cells[1]),
          Expanded(flex: 10, child: cells[2]),
          Expanded(flex: 10, child: cells[3]),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const head = TextStyle(
      fontSize: 11.5,
      letterSpacing: 0.6,
      color: _C.muted,
      fontWeight: FontWeight.w600,
    );
    const base = TextStyle(fontSize: 16, color: _C.text, fontFeatures: _tabular);
    final splits = controller.splits;
    final (best, worst) = controller.bestWorst();
    final rows = <Widget>[
      _row([
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Text('#', style: head),
        ),
        for (final h in const ['LAP', 'TOTAL', 'TIME'])
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Align(alignment: Alignment.centerRight, child: Text(h, style: head)),
          ),
      ]),
    ];
    for (var i = splits.length - 1; i >= 0; i--) {
      final s = splits[i];
      final lapStyle = i == best
          ? base.copyWith(color: _C.best, fontWeight: FontWeight.w600)
          : i == worst
              ? base.copyWith(color: _C.worst, fontWeight: FontWeight.w600)
              : base;
      final cells = [
        _cell('${s.n}', base.copyWith(color: _C.muted), first: true),
        _cell(StopwatchFormat.fmt(s.lap, millis: true), lapStyle),
        _cell(StopwatchFormat.fmt(s.total, millis: true), base),
        _cell(StopwatchFormat.clock(s.wall), base.copyWith(color: _C.muted)),
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

/// "Text preview" (details/summary of the site).
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
                'Text preview',
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
                  fontSize: 13,
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
