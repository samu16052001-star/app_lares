import 'dart:async';

import 'package:app_lares/services/android_acquisition_foreground_service.dart';
import 'package:app_lares/stopwatch/stopwatch_controller.dart';
import 'package:app_lares/stopwatch/stopwatch_page.dart';
import 'package:flutter/material.dart';

/// Keeps track of whether the stopwatch page is the page on screen.
class StopwatchRouteObserver extends NavigatorObserver {
  final ValueNotifier<bool> isOnTop = ValueNotifier<bool>(false);

  static bool _isStopwatch(Route<dynamic>? route) =>
      route?.settings.name == StopwatchPage.routeName;

  void _top(Route<dynamic>? route) {
    // Dialogs and other popups over the stopwatch page do not count.
    if (route is PopupRoute) {
      return;
    }
    isOnTop.value = _isStopwatch(route);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _top(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _top(previousRoute);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isStopwatch(route)) {
      isOnTop.value = false;
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (_isStopwatch(oldRoute) || _isStopwatch(newRoute)) {
      isOnTop.value = _isStopwatch(newRoute);
    }
  }
}

/// Navigator key + observer of the app, used by the bottom bar to open the
/// stopwatch page from any page.
class StopwatchNavigation {
  StopwatchNavigation();

  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
  final StopwatchRouteObserver observer = StopwatchRouteObserver();

  /// Opens the stopwatch page; if it is already on screen, goes back.
  void toggle() {
    final navigator = navigatorKey.currentState;
    if (navigator == null) {
      return;
    }
    if (observer.isOnTop.value) {
      navigator.maybePop();
      return;
    }
    navigator.push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: StopwatchPage.routeName),
        builder: (_) => const StopwatchPage(),
      ),
    );
  }
}

/// Wraps every page of the app (MaterialApp.builder) with the bottom bar of
/// the stopwatch. The bar hides while the keyboard is open.
/// While the stopwatch runs the screen stays on, as on the site (wake lock).
class StopwatchShell extends StatefulWidget {
  const StopwatchShell({
    super.key,
    required this.navigation,
    required this.child,
    this.controller,
  });

  final StopwatchNavigation navigation;
  final Widget child;

  /// Defaults to [StopwatchController.instance].
  final StopwatchController? controller;

  @override
  State<StopwatchShell> createState() => _StopwatchShellState();
}

class _StopwatchShellState extends State<StopwatchShell> {
  StopwatchController get _c => widget.controller ?? StopwatchController.instance;
  bool? _screenOn;

  @override
  void initState() {
    super.initState();
    _c.addListener(_syncScreen);
    _syncScreen();
  }

  @override
  void dispose() {
    _c.removeListener(_syncScreen);
    super.dispose();
  }

  void _syncScreen() {
    final on = _c.running;
    if (on != _screenOn) {
      _screenOn = on;
      unawaited(AndroidAcquisitionForegroundService.setKeepScreenOn(on));
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Same position in the tree with or without the bar: the pages
        // (Navigator) are never rebuilt from scratch.
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeBottom: !keyboardOpen,
            child: widget.child,
          ),
        ),
        if (!keyboardOpen)
          _StopwatchBar(navigation: widget.navigation, controller: _c),
      ],
    );
  }
}

class _StopwatchBar extends StatelessWidget {
  const _StopwatchBar({required this.navigation, required this.controller});

  final StopwatchNavigation navigation;
  final StopwatchController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Center(
            child: ValueListenableBuilder<bool>(
              valueListenable: navigation.observer.isOnTop,
              builder: (context, onTop, _) => AnimatedBuilder(
                animation: controller,
                builder: (context, _) => _StopwatchBarButton(
                  onTop: onTop,
                  controller: controller,
                  onPressed: navigation.toggle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Stopwatch-shaped button; with the stopwatch started it also shows the
/// time ([h:]mm:ss) and a dot: green running, orange paused.
class _StopwatchBarButton extends StatefulWidget {
  const _StopwatchBarButton({
    required this.onTop,
    required this.controller,
    required this.onPressed,
  });

  final bool onTop;
  final StopwatchController controller;
  final VoidCallback onPressed;

  @override
  State<_StopwatchBarButton> createState() => _StopwatchBarButtonState();
}

class _StopwatchBarButtonState extends State<_StopwatchBarButton> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _StopwatchBarButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTimer();
  }

  /// A timer only while the stopwatch runs (none otherwise: nothing pending
  /// in widget tests).
  void _syncTimer() {
    if (widget.controller.running) {
      _timer ??= Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (mounted) {
          setState(() {});
        }
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = widget.controller;
    final started = c.started;
    final fg = widget.onTop ? scheme.onPrimary : scheme.onSurface;
    final bg = widget.onTop ? scheme.primary : scheme.surfaceContainerHighest;
    return Semantics(
      button: true,
      label: widget.onTop ? 'Close the stopwatch' : 'Open the stopwatch',
      excludeSemantics: true,
      child: Material(
        color: bg,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onPressed,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: started ? 18 : 22, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.timer_outlined, size: 26, color: fg),
                if (started) ...[
                  const SizedBox(width: 10),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: c.running ? const Color(0xFF15803D) : const Color(0xFFB45309),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    stopwatchShortTime(c.elapsed()),
                    style: TextStyle(
                      color: fg,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (c.splits.isNotEmpty) ...[
                    Text(
                      '  ·  ${StopwatchController.splitsLabel(c.splits.length)}',
                      style: TextStyle(color: fg, fontSize: 14),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
