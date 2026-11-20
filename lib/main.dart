import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:app_lares/ble_configuration_service.dart';
import 'package:app_lares/environmental_v2_ble_service.dart';
import 'package:app_lares/environmental_v2_configuration.dart';
import 'package:app_lares/environmental_v2_configuration_page.dart';
import 'package:app_lares/environmental_v2_message_parser.dart';
import 'package:app_lares/imu_time_alignment.dart';
import 'package:app_lares/polar_h10/polar_h10_configuration.dart';
import 'package:app_lares/polar_h10/polar_h10_configuration_page.dart';
import 'package:app_lares/polar_h10/polar_h10_event.dart';
import 'package:app_lares/polar_h10/polar_h10_models.dart';
import 'package:app_lares/polar_h10/polar_h10_platform_service.dart';
import 'package:app_lares/services/acquisition_recovery_store.dart';
import 'package:app_lares/services/acquisition_event_log.dart';
import 'package:app_lares/services/android_acquisition_foreground_service.dart';
import 'package:app_lares/services/gps_location_service.dart';
import 'package:app_lares/services/environmental_open_remote.dart';
import 'package:app_lares/services/mqtt_service.dart';
import 'package:app_lares/services/respiratory_device_name_store.dart';
import 'package:app_lares/services/unified_acquisition_csv_logger.dart';
import 'package:app_lares/stopwatch/stopwatch_bar.dart';
import 'package:app_lares/stopwatch/stopwatch_controller.dart';
import 'package:app_lares/wearable_agm_packet_parser.dart';
import 'package:app_lares/wearable_chart_sampler.dart';
import 'package:app_lares/wearable_configuration_service.dart';
import 'package:app_lares/wearable_mag_calibration.dart';
import 'package:app_lares/wearable_reception_monitor.dart';
import 'package:app_lares/wearable_sd_problems.dart';
import 'package:app_lares/wearable_sds_packet_parser.dart';
import 'package:app_lares/widgets/polar_h10_live_section.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart' show Position;
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

part 'acquisition_runtime.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterBluePlus.setOperationQueueMode(OperationQueueMode.perDevice);
  // Stopwatch of the bottom bar: state saved like on
  // time.sesnext.uk, so it survives the app being closed.
  await StopwatchController.instance.load();
  AcquisitionRecoverySnapshot? recoverySnapshot;
  try {
    recoverySnapshot = await AcquisitionRecoveryStore.load();
  } catch (error) {
    if (!Platform.isAndroid) rethrow;
    _ActiveAcquisitionRuntime.recoveryError = 'Could not read the saved acquisition: $error';
    recoverySnapshot = const AcquisitionRecoverySnapshot(
      isActive: true, acquisitionType: 'unknown', deviceNames: [],
      deviceTypes: [], configurationSummaries: [], startedAtIso8601: null,
      logicalRoute: 'recovery', status: 'recovery_error',
    );
  }
  if (Platform.isAndroid) {
    if (recoverySnapshot == null) await AndroidAcquisitionForegroundService.stop();
    AndroidAcquisitionForegroundService.setActivityAttachedHandler(
      _ActiveAcquisitionRuntime.handleResumed,
    );
    _ActiveAcquisitionRuntime._isForegroundVisible =
        await AndroidAcquisitionForegroundService.isActivityAttached();
    if (recoverySnapshot?.status != 'recovery_error') {
      await _ActiveAcquisitionRuntime.restore(recoverySnapshot);
    }
  }
  runApp(LaresApp(recoverySnapshot: recoverySnapshot));
}

class LaresApp extends StatefulWidget {
  const LaresApp({
    super.key,
    this.recoverySnapshot,
  });

  final AcquisitionRecoverySnapshot? recoverySnapshot;

  @override
  State<LaresApp> createState() => _LaresAppState();
}

class _LaresAppState extends State<LaresApp> with WidgetsBindingObserver {
  /// Bottom bar with the stopwatch button on every page.
  final StopwatchNavigation _stopwatchNavigation = StopwatchNavigation();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_ActiveAcquisitionRuntime.handleResumed());
        break;
      case AppLifecycleState.inactive:
        unawaited(_ActiveAcquisitionRuntime.handleInactive());
        break;
      case AppLifecycleState.paused:
        unawaited(_ActiveAcquisitionRuntime.handlePaused());
        break;
      case AppLifecycleState.detached:
        unawaited(_ActiveAcquisitionRuntime.handleDetached());
        break;
      case AppLifecycleState.hidden:
        unawaited(_ActiveAcquisitionRuntime.handlePaused());
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lares',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      navigatorKey: _stopwatchNavigation.navigatorKey,
      navigatorObservers: [_stopwatchNavigation.observer],
      builder: (context, child) => StopwatchShell(
        navigation: _stopwatchNavigation,
        child: child ?? const SizedBox.shrink(),
      ),
      home: widget.recoverySnapshot == null
          ? (_ActiveAcquisitionRuntime.activePage ?? const AccessCodePage())
          : (_ActiveAcquisitionRuntime.activePage ??
              AcquisitionRecoveryPage(snapshot: widget.recoverySnapshot!)),
    );
  }
}

class _ActiveAcquisitionRuntime {
  static bool _isActive = false;
  static bool _isForegroundVisible = true;
  static _MultiDeviceSessionManager? _multiDeviceManager;
  static Object? activeOwner;
  static Widget Function()? _pageBuilder;
  static Future<void> Function()? _resume;
  static Timer? _heartbeat;
  static Future<void>? _restoration;
  static String? recoveryError;

  static Widget? get activePage => _pageBuilder?.call();

  static void registerSingleOwner(
    Object owner,
    Widget Function() pageBuilder,
    Future<void> Function() resume,
  ) {
    if (activeOwner != null && !identical(activeOwner, owner)) {
      throw StateError('An acquisition already owns this runtime.');
    }
    activeOwner = owner;
    _pageBuilder = pageBuilder;
    _resume = resume;
  }

  static Future<void> restore(AcquisitionRecoverySnapshot? snapshot) async {
    if (!Platform.isAndroid || snapshot == null || _isActive) return;
    if (_restoration != null) return _restoration;
    final operation = _restoreSavedAcquisition(snapshot);
    _restoration = operation;
    try {
      await operation;
    } catch (error) {
      recoveryError = error.toString();
      if (activeOwner == null) {
        try { await AndroidAcquisitionForegroundService.stop(); } catch (_) {}
      }
    } finally {
      _restoration = null;
    }
  }

  static bool get isForegroundVisible => _isForegroundVisible;

  static void registerMultiDeviceManager(_MultiDeviceSessionManager manager) {
    _multiDeviceManager = manager;
  }

  static Future<void> markActive() async {
    _isActive = true;
    if (Platform.isAndroid) {
      _heartbeat ??= Timer.periodic(const Duration(seconds: 5), (_) {
        unawaited(AcquisitionRecoveryStore.heartbeat().catchError((_) {}));
      });
    }
  }

  static Future<void> markInactive() async {
    _isActive = false;
    _multiDeviceManager = null;
    activeOwner = null;
    _pageBuilder = null;
    _resume = null;
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  static void beginStopping() {
    _isActive = false;
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  static Future<void> handlePaused() async {
    _isForegroundVisible = false;
    if (!_isActive) {
      return;
    }

    await AcquisitionRecoveryStore.updateStatus(
      logicalRoute: 'background',
      status: 'running_in_background',
    );
    await _ensureAndroidForegroundService();
  }

  static Future<void> handleInactive() async {
    _isForegroundVisible = false;
    if (!_isActive) {
      return;
    }

    await AcquisitionRecoveryStore.updateStatus(
      logicalRoute: 'inactive',
      status: 'running',
    );
  }

  static Future<void> handleDetached() async {
    _isForegroundVisible = false;
    if (!_isActive) {
      return;
    }

    await AcquisitionRecoveryStore.updateStatus(
      logicalRoute: 'detached',
      status: Platform.isAndroid ? 'running_in_background' : 'interrupted',
    );
  }

  static Future<void> handleResumed() async {
    _isForegroundVisible = true;
    if (!_isActive) {
      return;
    }

    await AcquisitionRecoveryStore.updateStatus(
      logicalRoute: 'acquisition',
      status: 'running',
    );
    await _ensureAndroidForegroundService();
    await _multiDeviceManager?.refreshAfterResume();
    await _resume?.call();
  }

  static Future<void> _ensureAndroidForegroundService() async {
    if (!_isActive) return;
    try {
      await AndroidAcquisitionForegroundService.start();
    } catch (_) {
      // The acquisition itself remains active; the UI shows permission/service issues.
    }
  }
}

class _LegacyAcquisitionRecoveryPage extends StatelessWidget {
  const _LegacyAcquisitionRecoveryPage({
    required this.snapshot,
  });

  final AcquisitionRecoverySnapshot snapshot;

  Future<void> _dismissRecovery(BuildContext context) async {
    await AcquisitionRecoveryStore.clear();
    await AndroidAcquisitionForegroundService.stop();
    if (!context.mounted) {
      return;
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => const AccessCodePage(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final deviceText = snapshot.deviceNames.isEmpty
        ? 'No device details available'
        : snapshot.deviceNames.join(', ');
    final csvText = snapshot.csvFileName == null
        ? 'CSV details unavailable'
        : 'CSV: ${snapshot.csvFileName}';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Acquisition recovery'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 48,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  'Previous acquisition was interrupted',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(
                  'Reconnect to continue.\n\nDevices: $deviceText\n$csvText',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => unawaited(_dismissRecovery(context)),
                  child: const Text('Reconnect to continue'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AccessCodePage extends StatefulWidget {
  const AccessCodePage({super.key});

  @override
  State<AccessCodePage> createState() => _AccessCodePageState();
}

class _AccessCodePageState extends State<AccessCodePage> {
  final TextEditingController _codeController = TextEditingController();
  String? _errorMessage;

  static const Map<String, String> _sectionMessages = {
    'user': 'Welcome to the user section!',
    'researcher': 'Welcome to the researcher section!',
    'developer': 'Welcome to the developer section!',
  };

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  void _submitCode() {
    final code = _codeController.text.trim().toLowerCase();
    final message = _sectionMessages[code];

    if (message == null) {
      setState(() {
        _errorMessage = 'Invalid code. Please try again.';
      });
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SectionPage(
          sectionName: code,
          message: message,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lares'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Enter your access code',
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _codeController,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    errorText: _errorMessage,
                    labelText: 'Access code',
                  ),
                  onChanged: (_) {
                    if (_errorMessage != null) {
                      setState(() {
                        _errorMessage = null;
                      });
                    }
                  },
                  onSubmitted: (_) => _submitCode(),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _submitCode,
                  child: const Text('Continue'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SectionPage extends StatelessWidget {
  const SectionPage({
    super.key,
    required this.sectionName,
    required this.message,
  });

  final String sectionName;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(sectionName),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message,
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              if (sectionName == 'user') ...[
                const SizedBox(height: 24),
                IconButton(
                  color: Colors.black,
                  icon: const Icon(Icons.arrow_forward),
                  iconSize: 48,
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const ConfigurationChoicePage(),
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class ConfigurationChoicePage extends StatelessWidget {
  const ConfigurationChoicePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Configuration'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const AutomaticConfigurationPage(),
                      ),
                    );
                  },
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 48,
                      ),
                      child: Text(
                        'Automatic Configuration',
                        style: Theme.of(context).textTheme.headlineSmall,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                TextButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const BluetoothScanningPage(),
                      ),
                    );
                  },
                  child: const Text('Manual Configuration'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AutomaticConfigurationPage extends StatelessWidget {
  const AutomaticConfigurationPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        title: const Text('Automatic Configuration'),
      ),
      body: const SizedBox.expand(),
    );
  }
}

enum KnownDeviceType {
  environmentalMonitor,
  environmentalMonitorV2,
  respiratoryMonitor,
  polarH10,
  unsupported,
}

extension KnownDeviceTypeLabel on KnownDeviceType {
  String get label {
    return switch (this) {
      KnownDeviceType.environmentalMonitor => 'Environmental Monitor',
      KnownDeviceType.environmentalMonitorV2 => 'Environmental Monitor V2',
      KnownDeviceType.respiratoryMonitor => 'Respiratory Monitor / IMU',
      KnownDeviceType.polarH10 => 'Polar H10',
      KnownDeviceType.unsupported => 'Unsupported device',
    };
  }
}

class KnownDeviceClassifier {
  const KnownDeviceClassifier._();

  static const String environmentalV2NamePrefix = 'LARES_ENV_V2';

  static KnownDeviceType fromNames(Iterable<String> names) {
    final originalNames = names.toList(growable: false);
    if (environmentalV2NameFrom(originalNames) != null) {
      return KnownDeviceType.environmentalMonitorV2;
    }

    final normalizedNames = originalNames.map(_normalizeDeviceName);

    if (normalizedNames.any((name) => name.contains('env'))) {
      return KnownDeviceType.environmentalMonitor;
    }

    if (normalizedNames.any(
      (name) =>
          name.contains('respiratorymonitor') ||
          name.contains('resp') ||
          name.contains('imu'),
    )) {
      return KnownDeviceType.respiratoryMonitor;
    }

    if (normalizedNames.any(_looksLikePolarH10Name)) {
      return KnownDeviceType.polarH10;
    }

    return KnownDeviceType.unsupported;
  }

  static String? environmentalV2NameFrom(Iterable<String> names) {
    for (final name in names) {
      final candidate = name.trim();
      if (candidate.isNotEmpty &&
          candidate.startsWith(environmentalV2NamePrefix)) {
        return candidate;
      }
    }

    return null;
  }

  static bool matchesSupportedFilter(Iterable<String> names) {
    return names.map(_normalizeDeviceName).any((name) {
      return name.contains('lares') ||
          name.contains('env') ||
          name.contains('respiratorymonitor') ||
          name.contains('resp') ||
          name.contains('imu') ||
          _looksLikePolarH10Name(name);
    });
  }

  static bool matchesLaresFilter(Iterable<String> names) {
    return matchesSupportedFilter(names);
  }

  static String _normalizeDeviceName(String value) {
    return value.trim().toLowerCase();
  }

  static bool _looksLikePolarH10Name(String name) {
    return name.contains('polar') && name.contains('h10');
  }
}

class WearableDeviceConfiguration {
  const WearableDeviceConfiguration({
    required this.odr,
    required this.mag,
    required this.accG,
    required this.gyrDPS,
    required this.calibrationEnabled,
    this.accEnabled = true,
    this.gyrEnabled = true,
    this.magCalibrationEnabled = false,
  });

  final int odr;
  final int mag;
  final int accG;
  final int gyrDPS;
  final bool calibrationEnabled;

  /// Magnetometer calibration.
  final bool magCalibrationEnabled;

  final bool accEnabled;
  final bool gyrEnabled;

  /// accG sent in CONFIG: 0 = accelerometer off.
  int get commandAccG => accEnabled ? accG : 0;

  /// gyrDPS sent in CONFIG: 0 = gyroscope off.
  int get commandGyrDPS => gyrEnabled ? gyrDPS : 0;

  /// Sensors requested ([WearableSensorMask] bits).
  int get sensorMask => WearableSensorMask.fromConfiguration(
        mag: mag,
        accG: commandAccG,
        gyrDPS: commandGyrDPS,
      );
}

String _summarizeEnvironmentalConfiguration(BleConfiguration configuration) {
  final enabledOptions = configuration.enabledOptions.entries
      .where((entry) => entry.value)
      .map((entry) => entry.key)
      .join(', ');
  final enabledText = enabledOptions.isEmpty ? 'none' : enabledOptions;

  return 'samplingFrequencySeconds=${configuration.samplingFrequencySeconds}; '
      'enabled=$enabledText';
}

String _summarizeEnvironmentalV2Configuration(
  EnvironmentalV2Configuration configuration,
) {
  return configuration.summary;
}

String _summarizeWearableConfiguration(
  WearableDeviceConfiguration configuration,
) {
  return 'odr=${configuration.odr}; '
      'acc=${configuration.accEnabled ? 'on' : 'off'}; '
      'gyr=${configuration.gyrEnabled ? 'on' : 'off'}; '
      'mag=${configuration.mag}; '
      'accG=${configuration.accG}; '
      'gyrDPS=${configuration.gyrDPS}; '
      'calibrationEnabled=${configuration.calibrationEnabled}; '
      'magCalibrationEnabled=${configuration.magCalibrationEnabled}';
}

String _summarizePolarH10Configuration(
  PolarH10Configuration configuration,
) {
  final streams = [
    if (configuration.hrEnabled) 'HR',
    if (configuration.rawEcgEnabled) 'Raw ECG',
    if (configuration.accelerometerEnabled) 'Accelerometer',
  ].join(', ');
  return 'streams=$streams';
}

String _mergeStatusMessage(String? current, String message) {
  if (current == null || current.isEmpty || current == message) {
    return message;
  }
  if (current.split('\n').contains(message)) {
    return current;
  }

  return '$current\n$message';
}

Future<bool> _confirmStopAcquisition(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      final colorScheme = Theme.of(dialogContext).colorScheme;
      return PopScope<bool>(
        canPop: false,
        child: AlertDialog(
          title: const Text('Stop acquisition?'),
          content: const Text(
            'Are you sure you want to stop the acquisition? '
            'This action will end the current acquisition.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: colorScheme.error,
                foregroundColor: colorScheme.onError,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Stop acquisition'),
            ),
          ],
        ),
      );
    },
  );
  return confirmed == true;
}

enum _BleReconnectStatus {
  disconnected,
  reconnecting,
  failed,
  reconnected,
}

extension _BleReconnectStatusText on _BleReconnectStatus {
  String get label {
    return switch (this) {
      _BleReconnectStatus.disconnected => 'Disconnected',
      _BleReconnectStatus.reconnecting => 'Reconnecting...',
      _BleReconnectStatus.failed => 'Reconnection failed',
      _BleReconnectStatus.reconnected => 'Reconnected',
    };
  }
}

class _BleDisconnectionAlertItem {
  const _BleDisconnectionAlertItem({
    required this.id,
    required this.deviceName,
    required this.status,
    this.failureMessage,
  });

  final String id;
  final String deviceName;
  final _BleReconnectStatus status;
  final String? failureMessage;
}

/// Disconnection alert of the multi-device acquisition page: a panel inside
/// the page instead of a dialog over it, so the rest of the app stays usable
/// while a device is disconnected.
class _BleDisconnectionAlertPanel extends StatelessWidget {
  const _BleDisconnectionAlertPanel({
    required this.items,
    required this.onStopRetrying,
  });

  final List<_BleDisconnectionAlertItem> items;

  /// Closes the alert and stops the automatic reconnection of [items].
  final VoidCallback onStopRetrying;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colorScheme.error, width: 1.5),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      items.length == 1
                          ? 'BLE device disconnected'
                          : 'BLE devices disconnected',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  TextButton(
                    onPressed: onStopRetrying,
                    child: const Text('Stop retrying'),
                  ),
                ],
              ),
              Text(
                'The app keeps trying to reconnect by itself.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                // With many devices the rows scroll: the cards of the
                // devices below must stay visible.
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.25,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (var index = 0; index < items.length; index++) ...[
                        if (index > 0) const Divider(height: 20),
                        _BleDisconnectionAlertDeviceRow(item: items[index]),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BleDisconnectionAlertDeviceRow extends StatelessWidget {
  const _BleDisconnectionAlertDeviceRow({
    required this.item,
  });

  final _BleDisconnectionAlertItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final statusColor = switch (item.status) {
      _BleReconnectStatus.reconnecting => colorScheme.primary,
      _BleReconnectStatus.failed => colorScheme.error,
      _ => colorScheme.onSurfaceVariant,
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.bluetooth_disabled, color: colorScheme.error),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.deviceName,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                item.status.label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: statusColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (item.failureMessage != null) ...[
                const SizedBox(height: 4),
                Text(
                  item.failureMessage!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _BleReconnectHelper {
  const _BleReconnectHelper._();

  static const Duration connectTimeout = Duration(seconds: 12);
  static const Duration _scanTimeout = Duration(seconds: 5);

  static Future<BluetoothDevice> reconnect({
    required BluetoothDevice currentDevice,
    required String deviceId,
    required String deviceName,
    bool requireUnambiguousEnvironmentalV2NameFallback = false,
    bool allowNameFallback = true,
  }) async {
    late final Object savedDeviceError;

    try {
      return await _connectDevice(currentDevice);
    } catch (error) {
      savedDeviceError = error;
    }

    final scannedDevice = await _scanForMatchingDevice(
      deviceId: deviceId,
      deviceName: deviceName,
      requireUnambiguousEnvironmentalV2NameFallback:
          requireUnambiguousEnvironmentalV2NameFallback,
      allowNameFallback: allowNameFallback,
    );
    if (scannedDevice == null) {
      throw savedDeviceError;
    }

    return _connectDevice(scannedDevice);
  }

  static Future<BluetoothDevice> _connectDevice(BluetoothDevice device) async {
    final state = await device.connectionState.first.timeout(
      const Duration(seconds: 2),
      onTimeout: () => BluetoothConnectionState.disconnected,
    );
    if (state != BluetoothConnectionState.disconnected) {
      return device;
    }

    await device
        .connect(
          license: License.nonprofit,
          timeout: connectTimeout,
        )
        .timeout(connectTimeout);
    return device;
  }

  static Future<BluetoothDevice?> _scanForMatchingDevice({
    required String deviceId,
    required String deviceName,
    required bool requireUnambiguousEnvironmentalV2NameFallback,
    required bool allowNameFallback,
  }) async {
    final hasPermissions = await _requestBluetoothReconnectPermissions();
    if (!hasPermissions) {
      return null;
    }

    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}

    BluetoothDevice? nameFallbackDevice;
    final environmentalV2NameFallbackDevices = <String, BluetoothDevice>{};
    final idMatchCompleter = Completer<BluetoothDevice>();
    late final StreamSubscription<List<ScanResult>> scanSubscription;

    scanSubscription = FlutterBluePlus.onScanResults.listen((results) {
      for (final result in results) {
        final resultDevice = result.device;
        if (_deviceId(resultDevice) == deviceId) {
          if (!idMatchCompleter.isCompleted) {
            idMatchCompleter.complete(resultDevice);
          }
          return;
        }

        if (!allowNameFallback) continue;

        if (requireUnambiguousEnvironmentalV2NameFallback) {
          if (_scanResultMatchesEnvironmentalV2Name(result, deviceName)) {
            environmentalV2NameFallbackDevices[_deviceId(resultDevice)] =
                resultDevice;
          }
        } else if (nameFallbackDevice == null &&
            _scanResultMatchesName(result, deviceName)) {
          nameFallbackDevice = resultDevice;
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(timeout: _scanTimeout);
      try {
        return await idMatchCompleter.future.timeout(_scanTimeout);
      } on TimeoutException {
        if (requireUnambiguousEnvironmentalV2NameFallback) {
          return environmentalV2NameFallbackDevices.length == 1
              ? environmentalV2NameFallbackDevices.values.single
              : null;
        }
        return nameFallbackDevice;
      }
    } finally {
      await scanSubscription.cancel();
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
    }
  }

  static Future<bool> _requestBluetoothReconnectPermissions() async {
    if (!Platform.isAndroid) {
      return true;
    }

    // Background retry may use granted permissions but must never ask an
    // Activity-dependent plugin to present a dialog without an Activity.
    if (!await AndroidAcquisitionForegroundService.isActivityAttached()) {
      final scanStatus = await Permission.bluetoothScan.status;
      final connectStatus = await Permission.bluetoothConnect.status;
      return scanStatus.isGranted && connectStatus.isGranted;
    }

    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final scanStatus = statuses[Permission.bluetoothScan];
    final connectStatus = statuses[Permission.bluetoothConnect];

    return (scanStatus == null || scanStatus.isGranted) &&
        (connectStatus == null || connectStatus.isGranted);
  }

  static bool _scanResultMatchesName(ScanResult result, String deviceName) {
    final expected = _normalizeDeviceNameForReconnect(deviceName);
    if (expected.isEmpty) {
      return false;
    }

    return _scanResultNameCandidates(result).any((name) {
      return _normalizeDeviceNameForReconnect(name) == expected;
    });
  }

  static bool _scanResultMatchesEnvironmentalV2Name(
    ScanResult result,
    String deviceName,
  ) {
    return _scanResultNameCandidates(result).any((candidate) {
      return candidate == deviceName &&
          candidate.startsWith(
            KnownDeviceClassifier.environmentalV2NamePrefix,
          );
    });
  }

  static List<String> _scanResultNameCandidates(ScanResult result) {
    final names = <String>[];
    for (final name in [
      result.device.platformName,
      result.advertisementData.advName,
      result.device.advName,
    ]) {
      final trimmedName = name.trim();
      if (trimmedName.isNotEmpty && !names.contains(trimmedName)) {
        names.add(trimmedName);
      }
    }

    return names;
  }

  static String _deviceId(BluetoothDevice device) {
    return device.remoteId.toString();
  }
}

class _BleAutoReconnectCoordinator {
  _BleAutoReconnectCoordinator({
    required this.runAutomaticCycle,
    required this.hasPendingWork,
    required this.canContinue,
    this.onStateChanged,
  });

  // Short pause between attempts (was 10 s): an IMU switched off and on
  // during the acquisition is reconnected as soon as it advertises again.
  static const Duration retryDelay = Duration(seconds: 2);

  final Future<void> Function() runAutomaticCycle;
  final bool Function() hasPendingWork;
  final bool Function() canContinue;
  final VoidCallback? onStateChanged;

  Timer? _retryTimer;
  bool _active = false;
  bool _operationInProgress = false;
  Future<void>? _inFlight;
  int _generation = 0;

  bool get isActive => _active;

  Future<void> waitForIdle() async {
    await _inFlight;
  }

  void start() {
    if (_active || !_canRun) {
      return;
    }

    _active = true;
    _generation += 1;
    unawaited(_startOperation(_generation, runAutomaticCycle));
  }

  void cancel({bool notify = true}) {
    _active = false;
    _generation += 1;
    _retryTimer?.cancel();
    _retryTimer = null;
    if (notify) {
      _notify();
    }
  }

  bool get _canRun => canContinue() && hasPendingWork();

  Future<void> _startOperation(
    int generation,
    Future<void> Function() operation,
  ) {
    if (!_isCurrent(generation) || _operationInProgress || !_canRun) {
      return Future<void>.value();
    }

    _operationInProgress = true;
    _notify();
    return _inFlight = _completeOperation(generation, operation);
  }

  Future<void> _completeOperation(
    int generation,
    Future<void> Function() operation,
  ) async {
    try {
      await operation();
    } catch (_) {
      // Individual reconnection attempts own their visible failure state.
    } finally {
      _operationInProgress = false;
      _notify();
    }

    if (!_isCurrent(generation)) {
      // Cancelled and started again while this operation was still running
      // ("Stop retrying" and then "Retry"): the new run could not start
      // then, so it starts now.
      if (_active) {
        if (_canRun) {
          unawaited(_startOperation(_generation, runAutomaticCycle));
        } else {
          _finish(_generation);
        }
      }
      return;
    }

    if (!_canRun) {
      _finish(generation);
      return;
    }

    _scheduleRetry(generation);
  }

  void _scheduleRetry(int generation) {
    if (!_isCurrent(generation) || !_canRun) {
      return;
    }

    _retryTimer?.cancel();
    _retryTimer = Timer(retryDelay, () {
      _retryTimer = null;
      _notify();
      if (!_isCurrent(generation) || !_canRun) {
        return;
      }

      unawaited(_startOperation(generation, runAutomaticCycle));
    });
    _notify();
  }

  void _finish(int generation) {
    if (_generation != generation) {
      return;
    }

    _active = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _notify();
  }

  bool _isCurrent(int generation) {
    return _active && _generation == generation;
  }

  void _notify() {
    onStateChanged?.call();
  }
}

String _normalizeDeviceNameForReconnect(String value) {
  return value.trim().toLowerCase();
}

class _ConnectedDeviceSession {
  _ConnectedDeviceSession({
    this.device,
    required this.deviceId,
    required this.deviceName,
    required this.type,
    this.customName,
    this.polarAddress,
    this.polarRssi,
  });

  factory _ConnectedDeviceSession.fromRecoveryDevice(Map<String, dynamic> value) =>
      _decodeAcquisitionDevice(value);

  Map<String, dynamic> toRecoveryDevice() => _encodeAcquisitionDevice(this);

  static const Duration wearableVisibleChartWindow = Duration(seconds: 2);
  static const Duration polarVisibleEcgWindow = Duration(seconds: 5);
  static const int polarVisibleEcgSampleCount = 650;
  static const Duration polarVisibleAccelerometerWindow = Duration(seconds: 5);
  static const Duration polarUiRefreshInterval = Duration(milliseconds: 250);

  BluetoothDevice? device;
  final String deviceId;
  // Original BLE name: never replace this with a user-defined name.
  final String deviceName;
  final KnownDeviceType type;
  String? customName;

  String get displayName => type == KnownDeviceType.respiratoryMonitor
      ? customName ?? deviceName
      : deviceName;

  String? polarDeviceId;
  String? polarAddress;
  int? polarRssi;

  BleConfiguration? environmentalConfiguration;
  EnvironmentalV2Configuration? environmentalV2Configuration;
  WearableDeviceConfiguration? wearableConfiguration;
  PolarH10Configuration? polarConfiguration;
  BleConfigurationService? environmentalService;
  EnvironmentalV2BleService? environmentalV2Service;
  EnvironmentalV2OpenRemotePublisher? environmentalV2OpenRemotePublisher;
  WearableConfigurationBleService? wearableService;
  StreamSubscription<BluetoothConnectionState>? connectionSubscription;
  StreamSubscription<BleNotificationMessage>? environmentalMessagesSubscription;
  StreamSubscription<EnvironmentalV2NotificationMessage>?
      environmentalV2MessagesSubscription;
  StreamSubscription<WearableAgmReceivedBatch>? agmBatchesSubscription;
  StreamSubscription<WearableSdsReceivedStatus>? sdsStatusSubscription;
  StreamSubscription<PolarH10Event>? polarEventsSubscription;

  bool isConnected = true;
  bool isInitializing = false;
  bool isInitialized = false;

  /// 1 at the first initialization of this device; more when its link
  /// dropped during it and only this device is initialized again.
  int initializationAttempt = 1;
  // A process restart needs configuration replay; ordinary radio reconnects
  // continue using the existing notification-only reconnect path.
  bool needsProcessRecovery = false;
  bool interruptionPending = false;
  bool environmentalV2ConfigurationApplied = false;
  bool environmentalV2NotificationsRequested = false;
  bool environmentalV2NotificationsStarted = false;
  bool disconnectedDuringAcquisition = false;
  int disconnectionAlertVersion = 0;
  _BleReconnectStatus reconnectStatus = _BleReconnectStatus.disconnected;
  String? reconnectFailureMessage;
  String? errorMessage;

  final List<BleNotificationMessage> environmentalMessages = [];
  final Map<String, _LiveMeasurementValue> liveMeasurementValues = {};
  final Map<String, List<_MeasurementChartSample>> chartSamplesByPrefix = {};
  _LiveVisualizationMode visualizationMode = _LiveVisualizationMode.cards;

  final Map<_WearableMetric, _WearableMetricSeries> wearableMetricSeries = {
    for (final definition in _wearableMetricDefinitions)
      definition.metric: _WearableMetricSeries(),
  };
  // Live charts: samples drawn (about 26 per second) and right edge of the
  // chart = time of the last drawn sample.
  final WearableChartSampler wearableChartSampler = WearableChartSampler();
  DateTime? wearableChartWindowEnd;
  int? latestBatteryPercent;
  int? latestFlushFailureRate;
  WearableSdHealth? latestSdHealth;

  /// Last time-alignment state written in the event log.
  ImuTimeAlignmentState? loggedTimeAlignmentState;

  /// SD problems of this acquisition (from the SDS packets), kept also
  /// after the SD saves again: card, notification and completed page.
  final SdProblemHistory sdProblems = SdProblemHistory();

  /// When the app started listening to the Polar SDK for this acquisition:
  /// samples received before belong to an earlier acquisition.
  DateTime? polarListeningSince;
  PolarH10Status polarStatus = PolarH10Status.disconnected;
  PolarH10HrSample? latestPolarHrSample;
  int? latestPolarBatteryPercent;
  final List<PolarH10EcgSample> polarEcgSamples = [];
  final List<PolarH10AccelerometerSample> polarAccelerometerSamples = [];
  int? latestPolarAccelerometerSamplingRateHz;
  Timer? polarUiRefreshTimer;
  DateTime? lastPolarUiRefreshAt;
  bool polarStreamsStarted = false;

  bool get isPolarManaged => type == KnownDeviceType.polarH10;

  BluetoothDevice get bleDevice {
    final bleDevice = device;
    if (bleDevice == null) {
      throw StateError('$deviceName is managed by the Polar SDK.');
    }

    return bleDevice;
  }

  PolarH10DeviceIdentity get polarIdentity {
    return PolarH10DeviceIdentity(
      deviceId: deviceId,
      displayName: deviceName,
      polarDeviceId: polarDeviceId,
      address: polarAddress ?? deviceId,
      rssi: polarRssi,
    );
  }

  bool get isConfigured {
    return switch (type) {
      KnownDeviceType.environmentalMonitor => environmentalConfiguration != null,
      KnownDeviceType.environmentalMonitorV2 =>
        environmentalV2Configuration != null,
      KnownDeviceType.respiratoryMonitor => wearableConfiguration != null,
      KnownDeviceType.polarH10 => polarConfiguration?.isValid ?? false,
      KnownDeviceType.unsupported => false,
    };
  }

  List<_MeasurementDefinition> get visibleMeasurements {
    switch (type) {
      case KnownDeviceType.environmentalMonitor:
        final v1Configuration = environmentalConfiguration;
        if (v1Configuration == null) {
          return const [];
        }
        return _measurementDefinitions
            .where(
              (definition) =>
                  v1Configuration.enabledOptions[definition.label] ?? false,
            )
            .toList(growable: false);
      case KnownDeviceType.environmentalMonitorV2:
        final v2Configuration = environmentalV2Configuration;
        if (v2Configuration == null) {
          return const [];
        }
        return _environmentalV2MeasurementDefinitions
            .where(
              (definition) =>
                  v2Configuration.isMessageTypeEnabled(definition.prefix),
            )
            .toList(growable: false);
      case KnownDeviceType.respiratoryMonitor:
      case KnownDeviceType.polarH10:
      case KnownDeviceType.unsupported:
        return const [];
    }
  }

  Map<String, _MeasurementDefinition> get visibleMeasurementsByPrefix {
    return {
      for (final definition in visibleMeasurements)
        definition.prefix: definition,
    };
  }

  Future<void> cancelLiveSubscriptions() async {
    environmentalV2OpenRemotePublisher?.reset();
    await environmentalMessagesSubscription?.cancel();
    environmentalMessagesSubscription = null;
    await environmentalV2MessagesSubscription?.cancel();
    environmentalV2MessagesSubscription = null;
    await agmBatchesSubscription?.cancel();
    agmBatchesSubscription = null;
    await sdsStatusSubscription?.cancel();
    sdsStatusSubscription = null;
    await polarEventsSubscription?.cancel();
    polarEventsSubscription = null;
    polarUiRefreshTimer?.cancel();
    polarUiRefreshTimer = null;
    latestPolarAccelerometerSamplingRateHz = null;
    polarAccelerometerSamples.clear();
  }

  Future<void> cancelConnectionSubscription() async {
    await connectionSubscription?.cancel();
    connectionSubscription = null;
  }
}

class _MultiDeviceSessionManager extends ChangeNotifier {
  _MultiDeviceSessionManager() {
    _bleAutoReconnectCoordinator = _BleAutoReconnectCoordinator(
      runAutomaticCycle: _runAutomaticBleReconnectCycle,
      hasPendingWork: _hasAutomaticBleReconnectTargets,
      canContinue: _canContinueAutomaticBleReconnect,
      onStateChanged: notifyListeners,
    );
    logEvent('SCAN_PAGE_OPENED');
  }

  static Future<void> restore(AcquisitionRecoverySnapshot snapshot) =>
      _restoreMultiDeviceAcquisition(snapshot);

  static const _openRemoteAttributeByEnvironmentalPrefix = <String, String>{
    'CO2': 'co2',
    'CO': 'co',
    'PM2.5': 'pm2_5',
    'PM10': 'pm10',
    'TEM1': 'internalTemperature',
    'HUM1': 'internalHumidity',
    'VOC': 'voc',
    'NOX': 'nox',
    'VOCi': 'vocIndex',
    'NOXi': 'noxIndex',
    'NH3': 'nh3',
    'NO2': 'no2',
    'PM1.0': 'pm1',
    'TEM2': 'externalTemperature',
    'HUM2': 'externalHumidity',
    'PRE': 'pressure',
  };

  final List<_ConnectedDeviceSession> _sessions = [];
  /// Connection and acquisition events of every device, written to
  /// Acquisition_events_*.csv next to the data file.
  final AcquisitionEventLog eventLog = AcquisitionEventLog();
  late final UnifiedAcquisitionCsvLogger csvLogger =
      UnifiedAcquisitionCsvLogger(eventLog: eventLog);

  /// Shown on the initialization page while a disconnected device is being
  /// connected again (see reconnectSessionLink).
  String? _initReconnectMessage;
  final GpsLocationService gpsLocationService = GpsLocationService();
  final OpenRemoteMqttService mqttService = OpenRemoteMqttService(
    includeConnectionDiagnostics: true,
    useUniqueClientId: true,
  );
  late final _BleAutoReconnectCoordinator _bleAutoReconnectCoordinator;
  final Set<String> _dismissedBleAutoReconnectAlertKeys = {};

  StreamSubscription<OpenRemoteMqttState>? _mqttStateSubscription;
  StreamSubscription<Position>? _openRemoteLocationSubscription;
  OpenRemoteMqttState mqttState = const OpenRemoteMqttState(
    status: OpenRemoteMqttStatus.disconnected,
  );
  bool _initializationStarted = false;
  bool _acquisitionStarted = false;
  bool _isStopping = false;
  bool _disposed = false;
  bool _openRemoteLocationConnectionPending = false;
  bool _openRemoteLocationAuthorized = false;
  bool _foregroundServiceStarted = false;
  DateTime? _startedAt;
  String _sessionId = const Uuid().v4();
  bool _openRemoteConnectRequested = false;
  Future<void>? _streamStartup;
  String? backgroundStatusMessage;

  List<_ConnectedDeviceSession> get sessions => List.unmodifiable(_sessions);

  /// What the person must do with the device being configured (IMU
  /// calibrations), shown on the initialization page; null otherwise.
  String? get initializationInstruction {
    final reconnectMessage = _initReconnectMessage;
    if (reconnectMessage != null) {
      return reconnectMessage;
    }
    for (final session in _sessions) {
      if (!session.isInitializing) {
        continue;
      }
      final instruction = session.wearableService?.calibrationInstruction;
      if (instruction != null) {
        // Initialization repeated after a lost link: said, so the person
        // knows why the calibration is asked again.
        final attempt = session.initializationAttempt > 1
            ? ' (attempt ${session.initializationAttempt}/$_deviceInitAttempts)'
            : '';
        return '${session.displayName}$attempt: $instruction';
      }
    }
    return null;
  }

  List<_ConnectedDeviceSession> get disconnectedSessionsDuringAcquisition {
    return _sessions
        .where(
          (session) =>
              session.disconnectedDuringAcquisition &&
              session.reconnectStatus != _BleReconnectStatus.reconnected,
        )
        .toList(growable: false);
  }

  int get connectedCount {
    return _sessions.where((session) => session.isConnected).length;
  }

  bool get hasConnectedDevices => connectedCount > 0;

  /// Every device of the list configured. Devices left disconnected (for
  /// example by a failed initialization) count too: the initialization
  /// connects them again.
  bool get allDevicesConfigured {
    return _sessions.isNotEmpty &&
        _sessions.every((session) => session.isConfigured);
  }

  bool get isStopping => _isStopping;

  bool get isAndroidBackgroundServiceActive => _foregroundServiceStarted;

  bool get canUseOpenRemote {
    if (_sessions.isEmpty) return false;
    final session = _sessions.first;
    return EnvironmentalOpenRemote.isEligible(
      sessionDeviceCount: _sessions.length,
      bleDeviceName: session.deviceName,
      isEnvironmentalV1: session.type == KnownDeviceType.environmentalMonitor,
      isEnvironmentalV2:
          session.type == KnownDeviceType.environmentalMonitorV2 &&
          KnownDeviceClassifier.environmentalV2NameFrom([session.deviceName]) !=
              null,
    );
  }

  String? get _openRemoteAssetId => canUseOpenRemote
      ? EnvironmentalOpenRemote.assetIdByDeviceName[_sessions.first.deviceName]
      : null;

  bool get _usesPhoneGpsForOpenRemote =>
      canUseOpenRemote &&
      _sessions.first.type == KnownDeviceType.environmentalMonitor;

  List<String> get _recoveryConfigurationSummaries {
    return [
      for (final session in _sessions)
        switch (session.type) {
          KnownDeviceType.environmentalMonitor =>
            session.environmentalConfiguration == null
                ? 'not configured'
                : _summarizeEnvironmentalConfiguration(
                    session.environmentalConfiguration!,
                  ),
          KnownDeviceType.environmentalMonitorV2 =>
            session.environmentalV2Configuration == null
                ? 'not configured'
                : _summarizeEnvironmentalV2Configuration(
                    session.environmentalV2Configuration!,
                  ),
          KnownDeviceType.respiratoryMonitor =>
            session.wearableConfiguration == null
                ? 'not configured'
                : _summarizeWearableConfiguration(
                    session.wearableConfiguration!,
                  ),
          KnownDeviceType.polarH10 =>
            session.polarConfiguration == null
                ? 'not configured'
                : _summarizePolarH10Configuration(
                    session.polarConfiguration!,
                  ),
          KnownDeviceType.unsupported => 'unsupported',
        },
    ];
  }

  /// The IMUs that had SD problems in this acquisition, for the completed
  /// page.
  List<_ImuSdProblems> get sdProblemsByImu {
    return [
      for (final session in _sessions)
        if (session.sdProblems.isNotEmpty)
          _ImuSdProblems(
            deviceName: session.displayName,
            history: session.sdProblems,
          ),
    ];
  }

  static const int _linkReconnectAttempts = 3;

  /// Connects again a device whose link is down, keeping its configuration:
  /// used by the initialization (device disconnected during it, or by a
  /// failed attempt, after which the app disconnects every device) and by
  /// the "Reconnect" button of the scan page. Up to [_linkReconnectAttempts]
  /// attempts, 1.5 s apart; the last error is thrown if none works. The
  /// Polar H10 is connected by the Polar SDK in its own initialization.
  Future<void> reconnectSessionLink(_ConnectedDeviceSession session) async {
    if (session.isPolarManaged) {
      session.isConnected = true;
      notifyListeners();
      return;
    }

    logEvent(
      'RECONNECT_STARTED',
      session: session,
      details: 'phase: $_eventPhase',
    );
    Object? lastError;
    for (var attempt = 1; attempt <= _linkReconnectAttempts; attempt += 1) {
      if (_initializationStarted) {
        _initReconnectMessage = 'Reconnecting ${session.displayName} '
            '($attempt/$_linkReconnectAttempts)...';
      }
      notifyListeners();
      try {
        final device = await _BleReconnectHelper.reconnect(
          currentDevice: session.bleDevice,
          deviceId: session.deviceId,
          deviceName: session.deviceName,
          requireUnambiguousEnvironmentalV2NameFallback:
              session.type == KnownDeviceType.environmentalMonitorV2,
        );
        if (!identical(device, session.device) ||
            session.connectionSubscription == null) {
          await session.cancelConnectionSubscription();
          session.device = device;
          _attachConnectionListener(session);
        }
        session.isConnected = true;
        logEvent(
          'RECONNECTED',
          session: session,
          details: 'attempt $attempt, MTU ${device.mtuNow}',
        );
        return;
      } catch (error) {
        lastError = error;
        logEvent(
          'RECONNECT_FAILED',
          session: session,
          details: 'attempt $attempt/$_linkReconnectAttempts: $error',
        );
        if (attempt < _linkReconnectAttempts) {
          await Future<void>.delayed(const Duration(milliseconds: 1500));
        }
      } finally {
        _initReconnectMessage = null;
        notifyListeners();
      }
    }
    throw StateError(
      '${session.displayName} is disconnected and could not be reconnected: '
      '$lastError',
    );
  }

  /// Adds a line to the event log (Acquisition_events_*.csv).
  void logEvent(
    String event, {
    _ConnectedDeviceSession? session,
    String? deviceName,
    KnownDeviceType? deviceType,
    String details = '',
  }) {
    eventLog.add(
      event,
      deviceName: session?.displayName ?? deviceName ?? '',
      deviceType: (session?.type ?? deviceType)?.label ?? '',
      details: details,
    );
  }

  String get _eventPhase {
    if (_isStopping) {
      return 'stopping';
    }
    if (_acquisitionStarted) {
      return 'acquisition';
    }
    if (_initializationStarted) {
      return 'initialization';
    }
    return 'before initialization';
  }

  /// Link state seen by flutter_blue_plus (not the Polar H10, which is
  /// connected by the Polar SDK: see POLAR_STATUS).
  void _logLinkState(
    _ConnectedDeviceSession session,
    BluetoothConnectionState state,
  ) {
    if (state == BluetoothConnectionState.disconnected) {
      final reason = session.bleDevice.disconnectReason;
      final code = reason?.code;
      final description = reason?.description;
      final reasonText = code == null
          ? ''
          : ', reason $code${description == null ? '' : ' $description'}';
      logEvent(
        'LINK_DISCONNECTED',
        session: session,
        details: 'phase: $_eventPhase$reasonText',
      );
      return;
    }

    logEvent(
      'LINK_${state.name.toUpperCase()}',
      session: session,
      details: 'phase: $_eventPhase, MTU ${session.bleDevice.mtuNow}',
    );
  }

  void addConnectedSession(_ConnectedDeviceSession session) {
    if (_sessions.any((existing) => existing.deviceId == session.deviceId)) {
      return;
    }

    _sessions.add(session);
    if (!canUseOpenRemote) {
      _invalidateOpenRemoteLocationAuthorization();
    }
    if (!session.isPolarManaged) {
      _attachConnectionListener(session);
    }
    notifyListeners();
  }

  Future<void> disconnectAndRemove(_ConnectedDeviceSession session) async {
    logEvent(
      'DEVICE_REMOVED',
      session: session,
      details: 'Disconnected by the user',
    );
    _invalidateOpenRemoteLocationAuthorization();
    await session.cancelConnectionSubscription();
    await session.cancelLiveSubscriptions();
    try {
      await session.environmentalService?.dispose();
    } catch (_) {}
    try {
      await session.environmentalV2Service?.dispose();
    } catch (_) {}
    try {
      await session.wearableService?.dispose();
    } catch (_) {}
    if (session.isPolarManaged) {
      try {
        await PolarH10PlatformService.forDevice(session.deviceId).stop();
      } catch (_) {}
    } else {
      try {
        await session.bleDevice.disconnect();
      } catch (_) {}
    }
    _sessions.removeWhere((candidate) => candidate.deviceId == session.deviceId);
    notifyListeners();
  }

  void configureEnvironmental(
    _ConnectedDeviceSession session,
    BleConfiguration configuration,
  ) {
    session.environmentalConfiguration = configuration;
    notifyListeners();
  }

  void configureEnvironmentalV2(
    _ConnectedDeviceSession session,
    EnvironmentalV2Configuration configuration,
  ) {
    session.environmentalV2OpenRemotePublisher?.reset();
    session.environmentalV2Configuration = configuration;
    notifyListeners();
  }

  void configureWearable(
    _ConnectedDeviceSession session,
    WearableDeviceConfiguration configuration,
  ) {
    session.wearableConfiguration = configuration;
    notifyListeners();
  }

  void configurePolarH10(
    _ConnectedDeviceSession session,
    PolarH10Configuration configuration,
  ) {
    session.polarConfiguration = configuration;
    notifyListeners();
  }

  Future<void> initializeAllSequentially() async {
    if (_initializationStarted) {
      return;
    }

    if (Platform.isAndroid) {
      _ActiveAcquisitionRuntime.registerSingleOwner(
        this,
        () => _MultiDeviceAcquisitionInitializationPage(manager: this),
        () async {},
      );
    }

    _initializationStarted = true;
    _ConnectedDeviceSession? currentSession;
    try {
      _invalidateOpenRemoteLocationAuthorization();
      logEvent(
        'INITIALIZATION_STARTED',
        details:
            [for (final session in _sessions) session.displayName].join(', '),
      );
      // A new attempt starts from scratch (a failed one can leave devices
      // initialized or marked as disconnected).
      for (final session in _sessions) {
        session
          ..isInitializing = false
          ..isInitialized = false
          ..disconnectedDuringAcquisition = false
          ..reconnectStatus = _BleReconnectStatus.disconnected
          ..reconnectFailureMessage = null
          ..errorMessage = null
          ..latestSdHealth = null;
        session.sdProblems.clear();
      }
      if (Platform.isAndroid) _startedAt = DateTime.now();
      await csvLogger.start(startedAt: _startedAt, sessionId: _sessionId);
      await gpsLocationService.start();
      _openRemoteLocationSubscription ??=
          gpsLocationService.livePositions.listen(
        _handleOpenRemoteLivePosition,
      );
      final gpsStatusMessage = gpsLocationService.statusMessage;
      if (gpsStatusMessage != null) {
        backgroundStatusMessage = _mergeStatusMessage(
          backgroundStatusMessage,
          gpsStatusMessage,
        );
      }

      if (canUseOpenRemote) {
        _mqttStateSubscription = mqttService.states.listen(
          _handleOpenRemoteMqttState,
        );
      }

      for (final session in List<_ConnectedDeviceSession>.from(_sessions)) {
        currentSession = session;
        if (!session.isConfigured) {
          throw StateError('${session.displayName} is not configured.');
        }
        await _initializeSession(session);
      }
      currentSession = null;

      _acquisitionStarted = true;
      _startedAt ??= DateTime.now();
      logEvent('ACQUISITION_STARTED', details: 'INIT_DONE sent to the IMUs');
      // INIT_DONE to every IMU: from now on an IMU whose link
      // loses data may disconnect by itself, and it is reconnected right
      // away. A disconnected IMU gets it after its reconnection.
      for (final session in _sessions) {
        final service = session.wearableService;
        if (service != null) {
          unawaited(service.notifyInitializationDone());
        }
      }
      await _activateAndroidBackgroundSupport();
      // Android: Polar and environmental V2 streams are started here, not by
      // the acquisition page, so they do not depend on the page being open.
      if (Platform.isAndroid) await _startRuntimeStreams();
      // IMUs that disconnected while the other devices were being configured
      // (_isRecordingWearableDuringInitialization) are reconnected now.
      if (disconnectedSessionsDuringAcquisition.isNotEmpty) {
        _bleAutoReconnectCoordinator.start();
      }
      notifyListeners();
    } catch (error) {
      logEvent(
        'INITIALIZATION_FAILED',
        session: currentSession,
        details: error.toString(),
      );
      await stopAll();
      _initializationStarted = false;
      rethrow;
    }
  }

  static const int _deviceInitAttempts = 3;

  /// Initializes one device. If its link drops during its own
  /// initialization, the device is connected again and only its
  /// initialization is repeated (up to [_deviceInitAttempts] attempts in
  /// all): before, the whole initialization failed and every device had to
  /// be configured and calibrated again. Not for the Polar H10, whose link
  /// is managed by the Polar SDK.
  Future<void> _initializeSession(_ConnectedDeviceSession session) async {
    for (var attempt = 1; ; attempt += 1) {
      // Disconnected during the initialization, or by a failed attempt
      // (the app then stops and disconnects every device): connected
      // again here instead of stopping the initialization.
      if (!session.isConnected) {
        await reconnectSessionLink(session);
      }

      session
        ..isInitializing = true
        ..initializationAttempt = attempt
        ..errorMessage = null;
      notifyListeners();
      logEvent(
        'DEVICE_INIT_STARTED',
        session: session,
        details: attempt == 1 ? '' : 'attempt $attempt/$_deviceInitAttempts',
      );

      try {
        await _runDeviceInitialization(session);
      } catch (error) {
        if (!session.isPolarManaged && session.isConnected) {
          // A command can fail a moment before the disconnection is
          // reported.
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        final linkLost = !session.isPolarManaged &&
            (!session.isConnected || session.bleDevice.isDisconnected);
        if (!linkLost || attempt >= _deviceInitAttempts || _isStopping) {
          rethrow;
        }

        logEvent(
          'DEVICE_INIT_RETRY',
          session: session,
          details: 'link lost during its initialization '
              '(attempt $attempt/$_deviceInitAttempts): $error',
        );
        await _discardSessionInitialization(session);
        session.isConnected = false;
        continue;
      }

      session
        ..isInitializing = false
        ..isInitialized = true;
      logEvent('DEVICE_INIT_DONE', session: session);
      notifyListeners();
      return;
    }
  }

  Future<void> _runDeviceInitialization(_ConnectedDeviceSession session) {
    switch (session.type) {
      case KnownDeviceType.environmentalMonitor:
        return _initializeEnvironmental(session);
      case KnownDeviceType.environmentalMonitorV2:
        return _initializeEnvironmentalV2(session);
      case KnownDeviceType.respiratoryMonitor:
        return _initializeWearable(session);
      case KnownDeviceType.polarH10:
        return _initializePolarH10(session);
      case KnownDeviceType.unsupported:
        throw StateError('${session.displayName} is unsupported.');
    }
  }

  /// Drops what an interrupted initialization left in a session (services
  /// and their subscriptions) before the device is initialized again.
  Future<void> _discardSessionInitialization(
    _ConnectedDeviceSession session,
  ) async {
    await session.cancelLiveSubscriptions();
    try {
      await session.environmentalService?.dispose();
    } catch (_) {}
    try {
      await session.environmentalV2Service?.dispose();
    } catch (_) {}
    try {
      await session.wearableService?.dispose();
    } catch (_) {}
    session
      ..environmentalService = null
      ..environmentalV2Service = null
      ..wearableService = null
      ..isInitializing = false
      ..latestSdHealth = null;
    session.sdProblems.clear();
    notifyListeners();
  }

  Future<void> connectOpenRemote() async {
    if (_disposed ||
        _isStopping ||
        !canUseOpenRemote ||
        mqttState.status == OpenRemoteMqttStatus.connecting ||
        mqttState.status == OpenRemoteMqttStatus.connected) {
      return;
    }

    final assetId = _openRemoteAssetId;
    if (assetId == null) {
      mqttState = OpenRemoteMqttState(
        status: OpenRemoteMqttStatus.failed,
        message: EnvironmentalOpenRemote.missingAssetMessage(
          _sessions.first.deviceName,
        ),
      );
      notifyListeners();
      return;
    }

    _openRemoteLocationConnectionPending =
        _usesPhoneGpsForOpenRemote && _acquisitionStarted;
    if (Platform.isAndroid) {
      _openRemoteConnectRequested = true;
      await AcquisitionRecoveryStore.mergeRuntimeState({
        'openRemoteConnectRequested': true,
        'openRemoteAssetId': assetId,
      });
    }
    await mqttService.connect(assetId: assetId);
    if (mqttService.isConnected) {
      _completePendingOpenRemoteLocationAuthorization();
    } else {
      _openRemoteLocationConnectionPending = false;
    }
  }

  void _handleOpenRemoteMqttState(OpenRemoteMqttState state) {
    if (mqttState.status != state.status) {
      for (final session in _sessions) {
        session.environmentalV2OpenRemotePublisher?.reset();
      }
    }
    mqttState = state;
    if (state.isConnected) {
      _completePendingOpenRemoteLocationAuthorization();
    } else if (state.status == OpenRemoteMqttStatus.failed ||
        state.status == OpenRemoteMqttStatus.disconnected) {
      _openRemoteLocationConnectionPending = false;
    }
    if (state.status == OpenRemoteMqttStatus.failed &&
        state.message != null &&
        _sessions.isNotEmpty) {
      _appendEnvironmentalLog(_sessions.first, 'OpenRemote: ${state.message}');
    }
    notifyListeners();
  }

  void _completePendingOpenRemoteLocationAuthorization() {
    if (!_openRemoteLocationConnectionPending) {
      return;
    }

    _openRemoteLocationConnectionPending = false;
    if (_disposed ||
        !_acquisitionStarted ||
        _isStopping ||
        !_usesPhoneGpsForOpenRemote ||
        !mqttService.isConnected) {
      return;
    }

    _openRemoteLocationAuthorized = true;
    if (Platform.isAndroid) {
      unawaited(AcquisitionRecoveryStore.mergeRuntimeState({
        'openRemoteLocationAuthorized': true,
      }));
    }
  }

  void _invalidateOpenRemoteLocationAuthorization() {
    _openRemoteLocationConnectionPending = false;
    _openRemoteLocationAuthorized = false;
  }

  Future<void> refreshAfterResume() async {
    if (!_acquisitionStarted || _isStopping) {
      return;
    }

    if (_sessions.any((session) => session.isPolarManaged)) {
      try {
        await PolarH10PlatformService.instance.foregroundEntered();
      } catch (_) {}
    }

    for (final session in _sessions) {
      if (session.isPolarManaged) {
        continue;
      }
      try {
        final state = await session.bleDevice.connectionState.first;
        final isConnected = state != BluetoothConnectionState.disconnected;
        if (isConnected && session.disconnectedDuringAcquisition) {
          continue;
        }
        final wasConnected = session.isConnected;
        session.isConnected = isConnected;
        if (!isConnected && wasConnected) {
          _markSessionDisconnectedDuringAcquisition(session);
        }
      } catch (_) {}
    }

    if (Platform.isAndroid) {
      try {
        await AndroidAcquisitionForegroundService.start();
        _foregroundServiceStarted = true;
        await gpsLocationService.resumeAfterAndroidActivityAttached();
      } catch (error) {
        backgroundStatusMessage = _mergeStatusMessage(
          backgroundStatusMessage, 'Android background acquisition: $error',
        );
      }
    }
    notifyListeners();
  }

  /// "Stop retrying" of the disconnection alert: these devices are no
  /// longer reconnected automatically, until [resumeAutomaticBleReconnect]
  /// or their next disconnection.
  void dismissAutomaticBleReconnectForSessions(
    Iterable<_ConnectedDeviceSession> sessions,
  ) {
    for (final session in sessions) {
      _dismissedBleAutoReconnectAlertKeys.add(_bleAutoReconnectAlertKey(session));
      logEvent('AUTO_RECONNECT_STOPPED', session: session);
    }
    _bleAutoReconnectCoordinator.cancel();
  }

  /// "Retry" of a device whose automatic reconnection was stopped.
  void resumeAutomaticBleReconnect(_ConnectedDeviceSession session) {
    _dismissedBleAutoReconnectAlertKeys.remove(
      _bleAutoReconnectAlertKey(session),
    );
    logEvent('AUTO_RECONNECT_RESUMED', session: session);
    _bleAutoReconnectCoordinator.start();
    notifyListeners();
  }

  void cancelAutomaticBleReconnect() {
    _bleAutoReconnectCoordinator.cancel();
  }

  Future<void> _runAutomaticBleReconnectCycle() async {
    final targets = _automaticBleReconnectTargets;
    for (final session in targets) {
      if (!_bleAutoReconnectCoordinator.isActive ||
          !_canContinueAutomaticBleReconnect()) {
        return;
      }
      if (!_canAttemptAutomaticBleReconnect(session)) {
        continue;
      }

      await _reconnectDisconnectedSessionOnce(session);
    }
  }

  Future<void> _reconnectDisconnectedSessionOnce(
    _ConnectedDeviceSession session,
  ) async {
    if (!_canAttemptBleReconnect(session)) {
      return;
    }

    session.environmentalV2OpenRemotePublisher?.reset();
    session
      ..reconnectStatus = _BleReconnectStatus.reconnecting
      ..reconnectFailureMessage = null;
    notifyListeners();
    logEvent('RECONNECT_STARTED', session: session);

    if (session.isPolarManaged) {
      try {
        await _reconnectPolarH10(session);
        if (!_canContinueAutomaticBleReconnect() ||
            !_sessions.contains(session)) {
          return;
        }
        session
          ..isConnected = true
          ..isInitialized = true
          ..needsProcessRecovery = false
          ..disconnectedDuringAcquisition = false
          ..reconnectStatus = _BleReconnectStatus.reconnected
          ..reconnectFailureMessage = null;
        logEvent('RECONNECTED', session: session);
        if (disconnectedSessionsDuringAcquisition.isEmpty) {
          unawaited(AndroidAcquisitionForegroundService.clearBleDisconnectionAlert());
        }
        notifyListeners();
      } catch (error) {
        if (!_canContinueAutomaticBleReconnect() ||
            !_sessions.contains(session)) {
          return;
        }
        logEvent(
          'RECONNECT_FAILED',
          session: session,
          details: error.toString(),
        );
        session
          ..isConnected = false
          ..disconnectedDuringAcquisition = true
          ..reconnectStatus = _BleReconnectStatus.failed
          ..reconnectFailureMessage =
              'Could not reconnect to ${session.displayName}. Make sure the strap is worn and another app is not connected.';
        notifyListeners();
      }
      return;
    }

    try {
      final reconnectedDevice = await _BleReconnectHelper.reconnect(
        currentDevice: session.bleDevice,
        deviceId: session.deviceId,
        deviceName: session.deviceName,
        allowNameFallback: !Platform.isAndroid || !_sessions.any((other) =>
            other.deviceId != session.deviceId &&
            _normalizeDeviceNameForReconnect(other.deviceName) ==
                _normalizeDeviceNameForReconnect(session.deviceName)),
        requireUnambiguousEnvironmentalV2NameFallback:
            session.type == KnownDeviceType.environmentalMonitorV2,
      );
      if (!_canContinueAutomaticBleReconnect() ||
          !_sessions.contains(session)) {
        return;
      }

      final deviceReferenceChanged = !identical(reconnectedDevice, session.device);
      if (deviceReferenceChanged) {
        await session.cancelConnectionSubscription();
        session.device = reconnectedDevice;
        _attachConnectionListener(session);
      } else {
        session.device = reconnectedDevice;
      }

      if (session.needsProcessRecovery) {
        await _initializeRecoveredDevice(session);
      } else {
        switch (session.type) {
          case KnownDeviceType.environmentalMonitor:
            final service = session.environmentalService;
            if (service == null) {
              throw StateError('Environmental BLE service is not available.');
            }
            await service.resumeNotificationsAfterReconnect(
              reconnectedDevice: reconnectedDevice,
            );
            break;
          case KnownDeviceType.environmentalMonitorV2:
            final service = session.environmentalV2Service;
            if (service == null) {
              throw StateError(
                'Environmental Monitor V2 BLE service is not available.',
              );
            }
            if (session.environmentalV2NotificationsRequested) {
              await service.resumeNotificationsAfterReconnect(
                reconnectedDevice: reconnectedDevice,
              );
              session.environmentalV2NotificationsStarted = true;
            }
            break;
          case KnownDeviceType.respiratoryMonitor:
            final service = session.wearableService;
            if (service == null) {
              throw StateError('Wearable BLE service is not available.');
            }
            await service.resumeNotificationsAfterReconnect(
              reconnectedDevice: reconnectedDevice,
            );
            break;
          case KnownDeviceType.polarH10:
            throw StateError('${session.displayName} is managed by the Polar SDK.');
          case KnownDeviceType.unsupported:
            throw StateError('${session.displayName} is unsupported.');
        }
      }
      if (!_canContinueAutomaticBleReconnect() ||
          !_sessions.contains(session)) {
        return;
      }

      session
        ..isConnected = true
        ..disconnectedDuringAcquisition = false
        ..reconnectStatus = _BleReconnectStatus.reconnected
        ..reconnectFailureMessage = null;
      logEvent(
        'RECONNECTED',
        session: session,
        details: 'MTU ${reconnectedDevice.mtuNow}',
      );
      if (disconnectedSessionsDuringAcquisition.isEmpty) {
        unawaited(AndroidAcquisitionForegroundService.clearBleDisconnectionAlert());
      }
      notifyListeners();
    } catch (error) {
      logEvent(
        'RECONNECT_FAILED',
        session: session,
        details: error.toString(),
      );
      if (session.type == KnownDeviceType.environmentalMonitorV2) {
        session.environmentalV2NotificationsStarted = false;
      }
      try {
        await session.bleDevice.disconnect();
      } catch (_) {}
      if (!_canContinueAutomaticBleReconnect() ||
          !_sessions.contains(session)) {
        return;
      }
      session
        ..isConnected = false
        ..disconnectedDuringAcquisition = true
        ..reconnectStatus = _BleReconnectStatus.failed
        ..reconnectFailureMessage =
            'Could not reconnect to ${session.displayName}. Move closer and try again.';
      notifyListeners();
    }
  }

  bool _hasAutomaticBleReconnectTargets() {
    return _automaticBleReconnectTargets.isNotEmpty;
  }

  List<_ConnectedDeviceSession> get _automaticBleReconnectTargets {
    return disconnectedSessionsDuringAcquisition.where((session) {
      return !_dismissedBleAutoReconnectAlertKeys.contains(
        _bleAutoReconnectAlertKey(session),
      );
    }).toList(growable: false);
  }

  bool _canContinueAutomaticBleReconnect() {
    return _acquisitionStarted && !_isStopping && !_disposed;
  }

  bool _canAttemptAutomaticBleReconnect(_ConnectedDeviceSession session) {
    return _canAttemptBleReconnect(session) &&
        !_dismissedBleAutoReconnectAlertKeys.contains(
          _bleAutoReconnectAlertKey(session),
        );
  }

  bool _canAttemptBleReconnect(_ConnectedDeviceSession session) {
    if (!_canContinueAutomaticBleReconnect() ||
        !_sessions.contains(session) ||
        !session.disconnectedDuringAcquisition ||
        session.reconnectStatus == _BleReconnectStatus.reconnecting ||
        session.reconnectStatus == _BleReconnectStatus.reconnected) {
      return false;
    }

    final wearableService = session.wearableService;
    if (wearableService != null &&
        (wearableService.isStopping || wearableService.isStopped)) {
      return false;
    }

    return true;
  }

  String _bleAutoReconnectAlertKey(_ConnectedDeviceSession session) {
    return '${session.deviceId}:${session.disconnectionAlertVersion}';
  }

  void setVisualizationMode(
    _ConnectedDeviceSession session,
    _LiveVisualizationMode mode,
  ) {
    session.visualizationMode = mode;
    notifyListeners();
  }

  Future<void> stopAll() async {
    if (_isStopping) {
      return;
    }

    _bleAutoReconnectCoordinator.cancel();
    logEvent('STOP_REQUESTED', details: 'phase: $_eventPhase');
    _isStopping = true;
    final stoppedAt = DateTime.now();
    for (final session in _sessions) {
      session.sdProblems.closeAtStop(stoppedAt);
    }
    // Saved session marked as stopping first: if Android kills the app during
    // the stop, the acquisition is not recovered at the next launch.
    if (Platform.isAndroid) {
      try {
        await AcquisitionRecoveryStore.markStopping();
      } catch (_) {}
    }
    _ActiveAcquisitionRuntime.beginStopping();
    _invalidateOpenRemoteLocationAuthorization();
    notifyListeners();

    await _openRemoteLocationSubscription?.cancel();
    _openRemoteLocationSubscription = null;
    // Let in-flight configuration/reconnect work observe _isStopping before
    // releasing resources, so it cannot create a stream after Stop completes.
    if (Platform.isAndroid) {
      await _bleAutoReconnectCoordinator.waitForIdle();
      await _streamStartup;
    }

    final sessionsToStop = List<_ConnectedDeviceSession>.from(_sessions);

    // 1. STOP to all the IMUs at the same time, while their data subscriptions
    //    are still active. stopAcquisition() keeps listening until the IMU
    //    sends its END packet (or a short timeout), so the last samples reach
    //    the CSV. Before, the app stopped listening to every device first and
    //    then stopped the IMUs one by one: the last 10/20/32 samples of
    //    IMU1/IMU2/IMU3 (S13) were only on the SD.
    await Future.wait(
      sessionsToStop
          .where(
            (session) => session.type == KnownDeviceType.respiratoryMonitor,
          )
          .map(_stopWearableSession),
    );

    // 2. Only now stop listening to every device.
    for (final session in sessionsToStop) {
      await session.cancelLiveSubscriptions();
    }

    for (final session in sessionsToStop) {
      switch (session.type) {
        case KnownDeviceType.environmentalMonitor:
          try {
            await session.environmentalService?.dispose();
          } catch (_) {}
          try {
            await session.bleDevice.disconnect();
          } catch (_) {}
          break;
        case KnownDeviceType.environmentalMonitorV2:
          try {
            await session.environmentalV2Service?.dispose();
          } catch (_) {}
          try {
            await session.bleDevice.disconnect();
          } catch (_) {}
          break;
        case KnownDeviceType.respiratoryMonitor:
          // Already stopped in step 1 (no-op if it is stopped).
          await _stopWearableSession(session);
          break;
        case KnownDeviceType.polarH10:
          try {
            await PolarH10PlatformService.forDevice(session.deviceId).stop();
          } catch (_) {}
          break;
        case KnownDeviceType.unsupported:
          try {
            await session.bleDevice.disconnect();
          } catch (_) {}
          break;
      }
      session.isConnected = false;
    }

    await _mqttStateSubscription?.cancel();
    _mqttStateSubscription = null;
    try {
      await mqttService.dispose();
    } catch (_) {}
    await gpsLocationService.stop();
    logEvent('STOPPED');
    await csvLogger.stop();
    await AndroidAcquisitionForegroundService.clearBleDisconnectionAlert();
    try {
      await AcquisitionRecoveryStore.clear();
    } catch (_) {}
    await _ActiveAcquisitionRuntime.markInactive();
    await AndroidAcquisitionForegroundService.stop();
    _foregroundServiceStarted = false;
    _acquisitionStarted = false;
    // A new initialization (Retry) starts the Polar and environmental V2
    // streams again.
    _streamStartup = null;
    _isStopping = false;
    notifyListeners();
  }

  /// Sends STOP to one IMU and waits for its last samples (see stopAll).
  /// Never throws, so one IMU cannot block the others.
  Future<void> _stopWearableSession(_ConnectedDeviceSession session) async {
    final service = session.wearableService;
    if (service == null || service.isStopped) {
      return;
    }

    try {
      await service.stopAcquisition();
      logEvent('IMU_STOPPED', session: session);
    } catch (error) {
      logEvent('IMU_STOP_FAILED', session: session, details: error.toString());
      try {
        await service.dispose();
      } catch (_) {}
    }
  }

  Future<void> disposeSessions() async {
    if (_disposed) {
      return;
    }

    if (_acquisitionStarted) {
      if (!Platform.isAndroid) _bleAutoReconnectCoordinator.cancel();
      return;
    }

    _disposed = true;
    _invalidateOpenRemoteLocationAuthorization();
    _bleAutoReconnectCoordinator.cancel();
    await _openRemoteLocationSubscription?.cancel();
    _openRemoteLocationSubscription = null;
    for (final session in List<_ConnectedDeviceSession>.from(_sessions)) {
      await session.cancelConnectionSubscription();
      await session.cancelLiveSubscriptions();
      try {
        await session.environmentalService?.dispose();
      } catch (_) {}
      try {
        await session.environmentalV2Service?.dispose();
      } catch (_) {}
      try {
        await session.wearableService?.dispose();
      } catch (_) {}
      if (session.isPolarManaged) {
        try {
          await PolarH10PlatformService.forDevice(session.deviceId).stop();
        } catch (_) {}
      } else {
        try {
          await session.bleDevice.disconnect();
        } catch (_) {}
      }
    }
    await _mqttStateSubscription?.cancel();
    try {
      await mqttService.dispose();
    } catch (_) {}
    await csvLogger.stop();
    await gpsLocationService.dispose();
  }

  Future<void> _activateAndroidBackgroundSupport() async {
    if (!_acquisitionStarted || !Platform.isAndroid) {
      return;
    }

    _ActiveAcquisitionRuntime.registerSingleOwner(
      this, () => _MultiDeviceAcquisitionPage(manager: this), () async {},
    );
    _ActiveAcquisitionRuntime.registerMultiDeviceManager(this);
    await _persistSession();
    await _requestAndroidNotificationPermission();
    try {
      await AndroidAcquisitionForegroundService.start();
      _foregroundServiceStarted = true;
    } catch (error) {
      backgroundStatusMessage = _mergeStatusMessage(
        backgroundStatusMessage,
        'Android background acquisition may be unreliable: $error',
      );
    }

    await _ActiveAcquisitionRuntime.markActive();
  }

  Future<void> _persistSession() async {
    await AcquisitionRecoveryStore.saveActive(
      sessionId: _sessionId,
      workflow: 'multi-device',
      devices: [for (final session in _sessions) session.toRecoveryDevice()],
      runtimeState: {
        'gpsRequested': true,
        'openRemoteConnectRequested': _openRemoteConnectRequested,
        'openRemoteAssetId': _openRemoteAssetId,
        'openRemoteLocationAuthorized': _openRemoteLocationAuthorized,
      },
      acquisitionType: _sessions.length == 1
          ? _sessions.first.type.name
          : 'multi-device',
      deviceNames: [for (final session in _sessions) session.displayName],
      deviceTypes: [for (final session in _sessions) session.type.name],
      configurationSummaries: _recoveryConfigurationSummaries,
      startedAt: _startedAt ?? DateTime.now(),
      logicalRoute: 'acquisition',
      status: 'running',
      csvFileName: csvLogger.fileName,
      csvFilePath: csvLogger.file?.path,
    );
  }

  Future<void> _requestAndroidNotificationPermission() async {
    if (!Platform.isAndroid) {
      return;
    }

    if (!await AndroidAcquisitionForegroundService.isActivityAttached()) return;

    final status = await Permission.notification.request();
    if (!status.isGranted) {
      backgroundStatusMessage = _mergeStatusMessage(
        backgroundStatusMessage,
        'Android background acquisition may be unreliable without the persistent notification.',
      );
    }
  }

  void _attachConnectionListener(_ConnectedDeviceSession session) {
    if (session.isPolarManaged) {
      return;
    }

    // The first value is the current state (already logged as CONNECTED or
    // RECONNECTED): only the changes go to the event log.
    BluetoothConnectionState? lastLinkState;
    session.connectionSubscription = session.bleDevice.connectionState.listen(
      (state) {
        final previousLinkState = lastLinkState;
        lastLinkState = state;
        if (previousLinkState != null && previousLinkState != state) {
          _logLinkState(session, state);
        }
        final isConnected = state != BluetoothConnectionState.disconnected;
        if (isConnected &&
            _acquisitionStarted &&
            session.disconnectedDuringAcquisition) {
          return;
        }
        if (session.isConnected == isConnected) {
          return;
        }

        session.isConnected = isConnected;
        session.environmentalV2OpenRemotePublisher?.reset();
        if (!isConnected) {
          if (session.type == KnownDeviceType.environmentalMonitorV2) {
            session.environmentalV2NotificationsStarted = false;
          }
          if (_isStopping) {
            notifyListeners();
            return;
          }

          if (_acquisitionStarted ||
              _isRecordingWearableDuringInitialization(session)) {
            _markSessionDisconnectedDuringAcquisition(session);
          } else if (session.type ==
                  KnownDeviceType.environmentalMonitorV2 &&
              session.environmentalV2ConfigurationApplied &&
              _initializationStarted) {
            // Keep a configured V2 session until the live page can use the
            // normal acquisition reconnect flow. Notifications are not
            // started here.
          } else if (_initializationStarted) {
            // Kept in the list (before, it was removed and the
            // initialization stopped): a device not initialized yet is
            // connected again at its turn, one already initialized right
            // after the initialization, with the IMUs.
            if (session.isInitialized) {
              _markSessionDisconnectedDuringAcquisition(session);
            }
          } else {
            unawaited(session.cancelConnectionSubscription());
            _sessions.removeWhere(
              (candidate) => candidate.deviceId == session.deviceId,
            );
            _invalidateOpenRemoteLocationAuthorization();
          }
        }
        notifyListeners();
      },
    );
  }

  /// An IMU already configured and started while the app is still
  /// configuring the other devices. If it disconnects, it is kept and
  /// reconnected as soon as the acquisition starts (before, it was removed
  /// from the acquisition).
  bool _isRecordingWearableDuringInitialization(
    _ConnectedDeviceSession session,
  ) {
    return _initializationStarted &&
        session.type == KnownDeviceType.respiratoryMonitor &&
        session.isInitialized;
  }

  void _markSessionDisconnectedDuringAcquisition(
    _ConnectedDeviceSession session,
  ) {
    if (_isStopping) {
      return;
    }

    session.environmentalV2OpenRemotePublisher?.reset();
    if (Platform.isAndroid && !session.interruptionPending) {
      session.interruptionPending = true;
      backgroundStatusMessage = _mergeStatusMessage(
        backgroundStatusMessage,
        'A Bluetooth interruption may have caused missing samples. Details are saved with the CSV.',
      );
      unawaited(AcquisitionRecoveryStore.recordInterruption(
        deviceId: session.deviceId,
        startedAt: DateTime.now(),
        reason: 'ble_disconnected',
      ));
    }

    session
      ..disconnectedDuringAcquisition = true
      ..disconnectionAlertVersion += 1
      ..reconnectStatus = _BleReconnectStatus.disconnected
      ..reconnectFailureMessage = null;
    if (session.type == KnownDeviceType.environmentalMonitorV2) {
      session.environmentalV2NotificationsStarted = false;
    }

    unawaited(
      AndroidAcquisitionForegroundService.showBleDisconnectionAlert(
        session.displayName,
      ),
    );
    _bleAutoReconnectCoordinator.start();
  }

  Future<void> _initializeEnvironmental(_ConnectedDeviceSession session) async {
    final configuration = session.environmentalConfiguration!;
    final service = BleConfigurationService(session.bleDevice);
    session.environmentalService = service;
    session.environmentalMessagesSubscription = service.messages.listen(
      (message) {
        _handleEnvironmentalMessage(session, message);
      },
    );

    await service.initialize(configuration);
  }

  Future<void> _initializeEnvironmentalV2(
    _ConnectedDeviceSession session,
  ) async {
    final configuration = session.environmentalV2Configuration!;
    final service = EnvironmentalV2BleService(session.bleDevice);
    session
      ..environmentalV2Service = service
      ..environmentalV2ConfigurationApplied = false
      ..environmentalV2NotificationsRequested = false
      ..environmentalV2NotificationsStarted = false;
    session.environmentalV2MessagesSubscription = service.messages.listen(
      (message) {
        _handleEnvironmentalV2Message(session, message);
      },
    );

    await service.initialize(configuration);
    session.environmentalV2ConfigurationApplied = true;
  }

  Future<void> _initializeWearable(_ConnectedDeviceSession session) async {
    final configuration = session.wearableConfiguration!;
    final service = _createWearableService(session);

    await service.initialize();
    if (!service.isReadyToContinue) {
      throw StateError('${session.displayName} BLE setup is not complete.');
    }

    await service.startConfigurationSequence(
      odr: configuration.odr,
      mag: configuration.mag,
      accG: configuration.commandAccG,
      gyrDPS: configuration.commandGyrDPS,
      calibrationEnabled: configuration.calibrationEnabled,
      magCalibrationEnabled: configuration.magCalibrationEnabled,
      // INIT_BUSY before START: the IMU does not disconnect by
      // itself while the other devices are being configured.
      holdSafetyNetUntilInitDone: true,
    );

    final state = await _waitForWearableStart(session, service);
    if (state == null) {
      throw StateError(
        '${session.displayName} lost its BLE link during its initialization.',
      );
    }
    if (state != WearableBleSequenceState.streaming) {
      throw StateError('${session.displayName} did not enter streaming mode.');
    }
  }

  /// Acquisition recovered after Android restarted the app process (see
  /// acquisition_runtime.dart): a new service for an IMU that is probably
  /// still recording. No CONFIG and no calibration if it is recording (same
  /// SD file); if it was switched off and on, the same CONFIG and a new
  /// START without calibration, like after any reconnection.
  Future<void> _recoverWearable(_ConnectedDeviceSession session) async {
    final configuration = session.wearableConfiguration!;
    final service = _createWearableService(session);
    logEvent('IMU_PROCESS_RECOVERY', session: session);
    await service.recoverAfterProcessRestart(
      odr: configuration.odr,
      mag: configuration.mag,
      accG: configuration.commandAccG,
      gyrDPS: configuration.commandGyrDPS,
    );
  }

  /// IMU service of [session], with its data and SD status subscriptions.
  WearableConfigurationBleService _createWearableService(
    _ConnectedDeviceSession session,
  ) {
    final service = WearableConfigurationBleService(
      session.bleDevice,
      onStateChanged: notifyListeners,
      // Magnetometer missing or found after a retry, restart after a
      // firmware fatal error.
      onImuEvent: (event, details) {
        logEvent(event, session: session, details: details);
      },
    );
    session.wearableService = service;
    session.agmBatchesSubscription = service.agmBatchesStream.listen(
      (event) {
        _handleWearableAgmBatch(session, event);
      },
    );
    session.sdsStatusSubscription = service.sdsStatusStream.listen(
      (event) {
        session.latestBatteryPercent = event.batteryPercent;
        session.latestFlushFailureRate = event.flushFailureRate;
        final sdHealth = event.sdHealth;
        if (sdHealth != null &&
            sdHealth.state != session.latestSdHealth?.state) {
          logEvent(
            'IMU_SD_STATE',
            session: session,
            details: sdHealth.description,
          );
        }
        session.latestSdHealth = sdHealth;
        if (sdHealth != null) {
          session.sdProblems.update(sdHealth, event.receivedAt);
        }
        notifyListeners();
      },
    );
    return service;
  }

  /// Waits for the end of the IMU start sequence (configuration,
  /// calibrations, START) and returns its last state, or null if the link
  /// drops meanwhile: the wait then ends at once instead of at the timeout
  /// of the reply the app is waiting for (up to 32 s).
  Future<WearableBleSequenceState?> _waitForWearableStart(
    _ConnectedDeviceSession session,
    WearableConfigurationBleService service,
  ) async {
    if (service.sequenceState == WearableBleSequenceState.streaming) {
      return WearableBleSequenceState.streaming;
    }

    final result = Completer<WearableBleSequenceState?>();
    void finish(WearableBleSequenceState? state) {
      if (!result.isCompleted) {
        result.complete(state);
      }
    }

    final stateSubscription = service.sequenceStateStream.listen(
      (state) {
        if (state == WearableBleSequenceState.streaming ||
            state == WearableBleSequenceState.timeout ||
            state == WearableBleSequenceState.error ||
            state == WearableBleSequenceState.stopped) {
          finish(state);
        }
      },
      onDone: () => finish(WearableBleSequenceState.stopped),
    );
    final linkSubscription = session.bleDevice.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        finish(null);
      }
    });
    try {
      return await result.future;
    } finally {
      await stateSubscription.cancel();
      await linkSubscription.cancel();
    }
  }

  Future<void> _initializePolarH10(_ConnectedDeviceSession session) async {
    final configuration = session.polarConfiguration;
    if (configuration == null || !configuration.isValid) {
      throw StateError('${session.displayName} Polar H10 configuration is invalid.');
    }

    session
      ..polarStatus = PolarH10Status.preparing
      ..polarStreamsStarted = false;
    await session.polarEventsSubscription?.cancel();
    session.polarListeningSince = DateTime.now();
    session.polarEventsSubscription =
        PolarH10PlatformService.forDevice(session.deviceId).events.listen(
      (event) {
        _handlePolarH10Event(session, event);
      },
    );

    await PolarH10PlatformService.forDevice(session.deviceId).prepare(
      identity: session.polarIdentity,
      configuration: configuration,
    );
  }

  Future<void> _startRuntimeStreams() {
    return _streamStartup ??= () async {
      await startPolarStreamsForAcquisition();
      await startEnvironmentalV2NotificationsForAcquisition();
    }();
  }

  Future<void> startPolarStreamsForAcquisition() async {
    if (!_acquisitionStarted || _isStopping) {
      return;
    }

    for (final session in _sessions.where((session) => session.isPolarManaged)) {
      if (Platform.isAndroid && (_isStopping || _disposed)) return;
      if (session.polarStreamsStarted || !session.isInitialized) {
        continue;
      }

      final configuration = session.polarConfiguration;
      if (configuration == null || !configuration.isValid) {
        session.errorMessage = '${session.displayName} Polar H10 configuration is invalid.';
        continue;
      }

      try {
        logEvent('POLAR_STREAMS_REQUESTED', session: session);
        await PolarH10PlatformService.forDevice(session.deviceId).startStreams(
          identity: session.polarIdentity,
          configuration: configuration,
        );
        session
          ..polarStreamsStarted = true
          ..polarStatus = _polarStreamingStatus(configuration)
          ..isConnected = true;
        logEvent('POLAR_STREAMS_STARTED', session: session);
      } catch (error) {
        logEvent(
          'POLAR_STREAMS_FAILED',
          session: session,
          details: error.toString(),
        );
        session
          ..polarStatus = PolarH10Status.error
          ..errorMessage = error.toString()
          ..isConnected = false
          ..polarStreamsStarted = false;
        _markSessionDisconnectedDuringAcquisition(session);
        session.reconnectFailureMessage = error.toString();
      }
      notifyListeners();
    }
  }

  Future<void> startEnvironmentalV2NotificationsForAcquisition() async {
    if (!_acquisitionStarted || _isStopping) {
      return;
    }

    final sessions = _sessions.where(
      (session) =>
          session.type == KnownDeviceType.environmentalMonitorV2 &&
          session.isInitialized,
    );
    await Future.wait<void>([
      for (final session in sessions)
        _startEnvironmentalV2NotificationsForSession(session),
    ]);
  }

  Future<void> _startEnvironmentalV2NotificationsForSession(
    _ConnectedDeviceSession session,
  ) async {
    session.environmentalV2NotificationsRequested = true;
    if (session.environmentalV2NotificationsStarted || _isStopping) {
      return;
    }

    if (!session.isConnected) {
      if (!session.disconnectedDuringAcquisition) {
        _markSessionDisconnectedDuringAcquisition(session);
      }
      notifyListeners();
      return;
    }

    final service = session.environmentalV2Service;
    if (service == null) {
      return;
    }

    try {
      await service.startNotificationsForAcquisition(
        reconnectedDevice: session.bleDevice,
      );
      session
        ..environmentalV2NotificationsStarted = true
        ..isConnected = true
        ..errorMessage = null;
    } catch (error) {
      if (_isStopping || _disposed) {
        return;
      }
      try {
        await service.stopNotifications();
      } catch (_) {}
      if (_isStopping || _disposed) {
        return;
      }
      session
        ..environmentalV2NotificationsStarted = false
        ..isConnected = false
        ..errorMessage = error.toString()
        ..reconnectFailureMessage = error.toString();
      try {
        await session.bleDevice.disconnect();
      } catch (_) {}
      if (!session.disconnectedDuringAcquisition) {
        _markSessionDisconnectedDuringAcquisition(session);
        session.reconnectFailureMessage = error.toString();
      }
    }
    notifyListeners();
  }

  Future<void> _reconnectPolarH10(_ConnectedDeviceSession session) async {
    final configuration = session.polarConfiguration;
    if (configuration == null || !configuration.isValid) {
      throw StateError('${session.displayName} Polar H10 configuration is invalid.');
    }

    await session.polarEventsSubscription?.cancel();
    session.polarEventsSubscription =
        PolarH10PlatformService.forDevice(session.deviceId).events.listen(
      (event) {
        _handlePolarH10Event(session, event);
      },
    );
    await PolarH10PlatformService.forDevice(session.deviceId).reconnectAndStart(
      identity: session.polarIdentity,
      configuration: configuration,
    );
    session
      ..polarStreamsStarted = true
      ..polarStatus = _polarStreamingStatus(configuration);
  }

  PolarH10Status _polarStreamingStatus(PolarH10Configuration configuration) {
    final enabledCount = [
      configuration.hrEnabled,
      configuration.rawEcgEnabled,
      configuration.accelerometerEnabled,
    ].where((enabled) => enabled).length;
    if (enabledCount > 1) {
      return PolarH10Status.streaming;
    }
    if (configuration.hrEnabled) {
      return PolarH10Status.streamingHr;
    }
    if (configuration.rawEcgEnabled) {
      return PolarH10Status.streamingEcg;
    }
    return PolarH10Status.streamingAccelerometer;
  }

  void _handlePolarH10Event(
    _ConnectedDeviceSession session,
    PolarH10Event event,
  ) {
    switch (event) {
      case final PolarH10ConnectionStateEvent connectionEvent:
        _handlePolarH10ConnectionState(session, connectionEvent);
        break;
      case final PolarH10HrSampleEvent hrEvent:
        if (_isOldPolarData(session, hrEvent.sample.receivedAt, 'HR', 1)) {
          break;
        }
        _handlePolarH10HrSample(session, hrEvent.sample);
        break;
      case final PolarH10EcgSamplesEvent ecgEvent:
        if (ecgEvent.samples.isNotEmpty &&
            _isOldPolarData(
              session,
              ecgEvent.samples.first.receivedAt,
              'ECG',
              ecgEvent.samples.length,
            )) {
          break;
        }
        _handlePolarH10EcgSamples(session, ecgEvent.samples);
        break;
      case final PolarH10AccelerometerSamplesEvent accelerometerEvent:
        if (accelerometerEvent.samples.isNotEmpty &&
            _isOldPolarData(
              session,
              accelerometerEvent.samples.first.receivedAt,
              'ACC',
              accelerometerEvent.samples.length,
            )) {
          break;
        }
        _handlePolarH10AccelerometerSamples(
          session,
          accelerometerEvent.samples,
          samplingRateHz: accelerometerEvent.samplingRateHz,
        );
        break;
      case final PolarH10BatteryLevelEvent batteryEvent:
        session.latestPolarBatteryPercent = batteryEvent.level;
        notifyListeners();
        break;
      case final PolarH10ErrorEvent errorEvent:
        _handlePolarH10Error(session, errorEvent);
        break;
    }
  }

  /// Polar samples received before this acquisition started listening (a
  /// packet of the previous acquisition left in the channel between the
  /// Android side and the app, delivered to the new listener): they are not
  /// written to the CSV.
  bool _isOldPolarData(
    _ConnectedDeviceSession session,
    DateTime receivedAt,
    String kind,
    int sampleCount,
  ) {
    final listeningSince = session.polarListeningSince;
    if (listeningSince == null || !receivedAt.isBefore(listeningSince)) {
      return false;
    }

    logEvent(
      'POLAR_OLD_DATA_DROPPED',
      session: session,
      details: '$kind, $sampleCount samples received at '
          '${AcquisitionEventLog.formatTimestamp(receivedAt)}',
    );
    return true;
  }

  void _handlePolarH10ConnectionState(
    _ConnectedDeviceSession session,
    PolarH10ConnectionStateEvent event,
  ) {
    final message = event.message;
    if (event.status != session.polarStatus || message != null) {
      logEvent(
        'POLAR_STATUS',
        session: session,
        details: message == null
            ? event.status.label
            : '${event.status.label}: $message',
      );
    }
    session.polarStatus = event.status;
    if (event.deviceId != null && event.deviceId!.isNotEmpty) {
      session.polarDeviceId = event.deviceId;
    }
    if (event.address != null && event.address!.isNotEmpty) {
      session.polarAddress = event.address;
    }

    switch (event.status) {
      case PolarH10Status.connected:
      case PolarH10Status.preparing:
      case PolarH10Status.streamingHr:
      case PolarH10Status.streamingEcg:
      case PolarH10Status.streamingAccelerometer:
      case PolarH10Status.streaming:
      case PolarH10Status.reconnecting:
        session.isConnected = true;
        break;
      case PolarH10Status.disconnected:
        final wasConnected = session.isConnected;
        session
          ..isConnected = false
          ..polarStreamsStarted = false
          ..latestPolarAccelerometerSamplingRateHz = null;
        session.polarAccelerometerSamples.clear();
        if (_acquisitionStarted && wasConnected && !_isStopping) {
          _markSessionDisconnectedDuringAcquisition(session);
        }
        break;
      case PolarH10Status.error:
        session.errorMessage = event.message;
        break;
    }

    notifyListeners();
  }

  void _handlePolarH10HrSample(
    _ConnectedDeviceSession session,
    PolarH10HrSample sample,
  ) {
    _recordRecoveredSample(session);
    session
      ..latestPolarHrSample = sample
      ..isConnected = true;
    unawaited(
      csvLogger.appendPolarHrSample(
        receivedAt: sample.receivedAt,
        deviceName: session.displayName,
        gpsCoordinates: gpsLocationService.currentCoordinates,
        hrBpm: sample.hrBpm,
      ),
    );
    notifyListeners();
  }

  void _handlePolarH10EcgSamples(
    _ConnectedDeviceSession session,
    List<PolarH10EcgSample> samples,
  ) {
    if (samples.isEmpty) {
      return;
    }
    _recordRecoveredSample(session);

    session
      ..isConnected = true
      ..polarEcgSamples.addAll(samples);
    _prunePolarEcgSamples(session);

    unawaited(
      csvLogger.appendPolarEcgSamples(
        deviceName: session.displayName,
        gpsCoordinatesBySample: [
          for (var index = 0; index < samples.length; index += 1)
            gpsLocationService.currentCoordinates,
        ],
        samples: samples,
      ),
    );
    _schedulePolarUiRefresh(session);
  }

  void _prunePolarEcgSamples(_ConnectedDeviceSession session) {
    final samples = session.polarEcgSamples;
    if (samples.isEmpty) {
      return;
    }

    final latestDisplayTimestamp = samples
        .map((sample) => sample.displayTimestamp)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    final cutoff = latestDisplayTimestamp.subtract(
      _ConnectedDeviceSession.polarVisibleEcgWindow,
    );
    samples.removeWhere((sample) => sample.displayTimestamp.isBefore(cutoff));

    if (samples.length > _ConnectedDeviceSession.polarVisibleEcgSampleCount) {
      samples.removeRange(
        0,
        samples.length - _ConnectedDeviceSession.polarVisibleEcgSampleCount,
      );
    }
  }

  void _handlePolarH10AccelerometerSamples(
    _ConnectedDeviceSession session,
    List<PolarH10AccelerometerSample> samples, {
    required int samplingRateHz,
  }) {
    if (samples.isEmpty) {
      return;
    }
    _recordRecoveredSample(session);

    session
      ..isConnected = true
      ..latestPolarAccelerometerSamplingRateHz = samplingRateHz
      ..polarAccelerometerSamples.addAll(samples);
    _prunePolarAccelerometerSamples(session);

    unawaited(
      csvLogger.appendPolarAccelerometerSamples(
        deviceName: session.displayName,
        gpsCoordinatesBySample: [
          for (var index = 0; index < samples.length; index += 1)
            gpsLocationService.currentCoordinates,
        ],
        samples: samples,
      ),
    );
    _schedulePolarUiRefresh(session);
  }

  void _prunePolarAccelerometerSamples(_ConnectedDeviceSession session) {
    final samples = session.polarAccelerometerSamples;
    if (samples.isEmpty) {
      return;
    }

    final latestDisplayTimestamp = samples
        .map((sample) => sample.displayTimestamp)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    final cutoff = latestDisplayTimestamp.subtract(
      _ConnectedDeviceSession.polarVisibleAccelerometerWindow,
    );
    samples.removeWhere((sample) => sample.displayTimestamp.isBefore(cutoff));

    final samplingRateHz = session.latestPolarAccelerometerSamplingRateHz ?? 25;
    final maxSamples = math.max(
      samplingRateHz * _ConnectedDeviceSession.polarVisibleAccelerometerWindow.inSeconds * 2,
      samplingRateHz + 1,
    ).toInt();
    if (samples.length > maxSamples) {
      samples.removeRange(0, samples.length - maxSamples);
    }
  }

  void _handlePolarH10Error(
    _ConnectedDeviceSession session,
    PolarH10ErrorEvent event,
  ) {
    logEvent(
      'POLAR_ERROR',
      session: session,
      details: '${event.code}: ${event.message}',
    );
    session
      ..polarStatus = PolarH10Status.error
      ..errorMessage = event.message
      ..polarStreamsStarted = false
      ..latestPolarAccelerometerSamplingRateHz = null
      ..isConnected = false;
    session.polarAccelerometerSamples.clear();
    if (_acquisitionStarted && !_isStopping && !session.disconnectedDuringAcquisition) {
      _markSessionDisconnectedDuringAcquisition(session);
      session.reconnectFailureMessage = event.message;
    }
    notifyListeners();
  }

  void _schedulePolarUiRefresh(_ConnectedDeviceSession session) {
    final now = DateTime.now();
    final lastRefreshAt = session.lastPolarUiRefreshAt;
    if (lastRefreshAt == null ||
        now.difference(lastRefreshAt) >=
            _ConnectedDeviceSession.polarUiRefreshInterval) {
      session.lastPolarUiRefreshAt = now;
      notifyListeners();
      return;
    }

    session.polarUiRefreshTimer ??= Timer(
      _ConnectedDeviceSession.polarUiRefreshInterval - now.difference(lastRefreshAt),
      () {
        session.polarUiRefreshTimer = null;
        session.lastPolarUiRefreshAt = DateTime.now();
        notifyListeners();
      },
    );
  }

  void _handleOpenRemoteLivePosition(Position position) {
    if (_disposed ||
        !_acquisitionStarted ||
        _isStopping ||
        !_openRemoteLocationAuthorized ||
        !_usesPhoneGpsForOpenRemote ||
        !_sessions.first.isConnected ||
        !mqttService.isConnected) {
      return;
    }

    final longitude = position.longitude;
    final latitude = position.latitude;
    if (!longitude.isFinite ||
        !latitude.isFinite ||
        longitude < -180 ||
        longitude > 180 ||
        latitude < -90 ||
        latitude > 90) {
      return;
    }

    unawaited(
      _publishOpenRemoteLocation(
        longitude: longitude,
        latitude: latitude,
      ),
    );
  }

  Future<void> _publishOpenRemoteLocation({
    required double longitude,
    required double latitude,
  }) async {
    await mqttService.publishJsonAttributeValue(
      attribute: 'location',
      value: <String, Object>{
        'type': 'Point',
        'coordinates': <double>[longitude, latitude],
      },
    );
  }

  void _handleEnvironmentalMessage(
    _ConnectedDeviceSession session,
    BleNotificationMessage message,
  ) {
    _recordRecoveredSample(session);
    session.environmentalMessages.add(message);
    _updateEnvironmentalLiveMeasurement(session, message);
    unawaited(
      csvLogger.appendEnvironmentalMessage(
        receivedAt: message.receivedAt,
        deviceId: session.deviceId,
        deviceName: session.displayName,
        gpsCoordinates: gpsLocationService.currentCoordinates,
        value: message.value,
      ),
    );
    if (canUseOpenRemote) {
      unawaited(
        _publishOpenRemoteMeasurementIfConnected(session, message.value),
      );
    }
    notifyListeners();
  }

  void _handleEnvironmentalV2Message(
    _ConnectedDeviceSession session,
    EnvironmentalV2NotificationMessage message,
  ) {
    _recordRecoveredSample(session);
    final configuration = session.environmentalV2Configuration;
    if (configuration == null ||
        !configuration.isMessageTypeEnabled(message.type)) {
      return;
    }

    if (!_disposed &&
        _acquisitionStarted &&
        !_isStopping &&
        canUseOpenRemote &&
        _openRemoteAssetId != null &&
        identical(_sessions.first, session)) {
      final publisher = session.environmentalV2OpenRemotePublisher ??=
          EnvironmentalV2OpenRemotePublisher(mqttService);
      unawaited(
        publisher.publish(message: message, configuration: configuration),
      );
    }

    final definition = session.visibleMeasurementsByPrefix[message.type];
    if (definition == null) {
      return;
    }

    final previous = session.liveMeasurementValues[definition.prefix];
    session.liveMeasurementValues[definition.prefix] = _LiveMeasurementValue(
      formattedValue: message.value,
      updatedAt: message.receivedAt,
      updateCount: (previous?.updateCount ?? 0) + 1,
    );

    final numericValue = message.numericValue;
    if (definition.chartEnabled && numericValue != null) {
      final samples = session.chartSamplesByPrefix.putIfAbsent(
        definition.prefix,
        () => <_MeasurementChartSample>[],
      );
      samples.add(
        _MeasurementChartSample(
          receivedAt: message.receivedAt,
          value: numericValue,
        ),
      );
      if (samples.length > 100) {
        samples.removeRange(0, samples.length - 100);
      }
    }

    unawaited(
      csvLogger.appendEnvironmentalV2Message(
        receivedAt: message.receivedAt,
        deviceId: session.deviceId,
        deviceName: session.deviceName,
        gpsCoordinates: gpsLocationService.currentCoordinates,
        messageType: message.type,
        value: message.value,
      ),
    );
    notifyListeners();
  }

  void _updateEnvironmentalLiveMeasurement(
    _ConnectedDeviceSession session,
    BleNotificationMessage message,
  ) {
    final separatorIndex = message.value.indexOf(':');
    if (separatorIndex <= 0) {
      return;
    }

    final prefix = message.value.substring(0, separatorIndex);
    final definition = session.visibleMeasurementsByPrefix[prefix];
    if (definition == null) {
      return;
    }

    final rawValue = message.value.substring(separatorIndex + 1);
    final parsedValue = double.tryParse(rawValue);
    if (parsedValue == null) {
      return;
    }

    final previous = session.liveMeasurementValues[definition.prefix];
    session.liveMeasurementValues[definition.prefix] = _LiveMeasurementValue(
      formattedValue: parsedValue.toStringAsFixed(1),
      updatedAt: message.receivedAt,
      updateCount: (previous?.updateCount ?? 0) + 1,
    );

    final samples = session.chartSamplesByPrefix.putIfAbsent(
      definition.prefix,
      () => [],
    );
    samples.add(
      _MeasurementChartSample(
        receivedAt: message.receivedAt,
        value: parsedValue,
      ),
    );
    if (samples.length > 100) {
      samples.removeRange(0, samples.length - 100);
    }
  }

  Future<void> _publishOpenRemoteMeasurementIfConnected(
    _ConnectedDeviceSession session,
    String bleValue,
  ) async {
    if (!mqttService.isConnected) {
      return;
    }

    final separatorIndex = bleValue.indexOf(':');
    if (separatorIndex <= 0) {
      return;
    }

    final prefix = bleValue.substring(0, separatorIndex).trim();
    final attribute = _openRemoteAttributeByEnvironmentalPrefix[prefix];
    if (attribute == null) {
      return;
    }

    final rawValue = bleValue.substring(separatorIndex + 1).trim();
    final value = double.tryParse(rawValue);
    if (value == null || !value.isFinite) {
      return;
    }

    final sent = await mqttService.publishAttributeValue(
      attribute: attribute,
      value: value,
    );
    if (sent) {
      _appendEnvironmentalLog(
        session,
        'MQTT sent - $prefix: ${_formatMqttNumber(value)}',
      );
    }
  }

  void _appendEnvironmentalLog(
    _ConnectedDeviceSession session,
    String value,
  ) {
    session.environmentalMessages.add(
      BleNotificationMessage(
        receivedAt: DateTime.now(),
        value: value,
      ),
    );
  }

  String _formatMqttNumber(double value) {
    if (value == value.truncateToDouble()) {
      return value.toInt().toString();
    }

    return value.toString();
  }

  void _handleWearableAgmBatch(
    _ConnectedDeviceSession session,
    WearableAgmReceivedBatch event,
  ) {
    _recordRecoveredSample(session);
    // Live charts: about 26 samples per second (1 every 4 at 104 Hz), each
    // at its aligned phone time (tp), not at the arrival of the notification.
    final chartPoints = session.wearableChartSampler.pick(
      odr: session.wearableConfiguration?.odr ?? 104,
      sensorTimesMs: [for (final sample in event.samples) sample.timestampMs],
      receivedAt: event.receivedAt,
      phoneTimes: event.phoneTimes,
    );
    if (chartPoints.isNotEmpty) {
      final windowEnd = chartPoints.last.time;
      session.wearableChartWindowEnd = windowEnd;
      final cutoff = windowEnd.subtract(
        _ConnectedDeviceSession.wearableVisibleChartWindow,
      );
      for (final definition in _wearableMetricDefinitions) {
        final series = session.wearableMetricSeries[definition.metric];
        if (series == null) {
          continue;
        }

        for (final point in chartPoints) {
          final sample = event.samples[point.index];
          if (!_wearableMetricInSample(definition.metric, sample)) {
            continue;
          }
          series.addSample(
            time: point.time,
            value: _valueForWearableMetric(definition.metric, sample),
          );
        }
        series.pruneBefore(cutoff);
      }
    }

    final gpsCoordinates = gpsLocationService.currentCoordinates;
    unawaited(
      csvLogger.appendWearableAgmBatch(
        receivedAt: event.receivedAt,
        deviceName: session.displayName,
        gpsCoordinates: gpsCoordinates,
        samples: event.samples,
        phoneTimes: event.phoneTimes,
      ),
    );

    // Time alignment: every change of state goes to the event log, with the
    // real sampling frequency.
    final alignment = session.wearableService?.timeAlignment;
    if (alignment != null &&
        alignment.state != session.loggedTimeAlignmentState) {
      session.loggedTimeAlignmentState = alignment.state;
      logEvent(
        'IMU_TIME_ALIGNMENT',
        session: session,
        details: alignment.eventDetails,
      );
    }
    notifyListeners();
  }

  double _valueForWearableMetric(
    _WearableMetric metric,
    WearableAgmSample sample,
  ) {
    return switch (metric) {
      _WearableMetric.accelerometerX => sample.accX,
      _WearableMetric.accelerometerY => sample.accY,
      _WearableMetric.accelerometerZ => sample.accZ,
      _WearableMetric.accelerometerMagnitude => math.sqrt(
          (sample.accX * sample.accX) +
              (sample.accY * sample.accY) +
              (sample.accZ * sample.accZ),
        ),
      _WearableMetric.gyroscopeX => sample.gyrX,
      _WearableMetric.gyroscopeY => sample.gyrY,
      _WearableMetric.gyroscopeZ => sample.gyrZ,
      _WearableMetric.magnetometerX => sample.magX,
      _WearableMetric.magnetometerY => sample.magY,
      _WearableMetric.magnetometerZ => sample.magZ,
    };
  }
}

class BluetoothScanningPage extends StatefulWidget {
  const BluetoothScanningPage({super.key});

  @override
  State<BluetoothScanningPage> createState() => _BluetoothScanningPageState();
}

class _BluetoothScanningPageState extends State<BluetoothScanningPage> {
  final Map<String, ScanResult> _scanResults = {};
  final Map<String, String> _savedRespiratoryNames = {};
  final Map<String, TextEditingController> _respiratoryNameControllers = {};
  late final Future<void> _namesLoaded;
  bool _isSavingNames = false;
  final Map<String, int> _discoveryOrder = {};
  final Set<String> _connectingDeviceIds = {};
  final _MultiDeviceSessionManager _sessionManager =
      _MultiDeviceSessionManager();
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<bool>? _isScanningSubscription;

  int _nextDiscoveryIndex = 0;
  bool _isScanning = false;
  bool _showOnlySupportedDevices = false;
  bool _sortBySignalStrength = false;
  String? _statusMessage;

  static const Duration _minGapBetweenConnections = Duration(seconds: 3);
  DateTime? _lastConnectionAt;
  bool _connectionInProgress = false;
  Timer? _connectionCooldownTimer;

  @override
  void initState() {
    super.initState();
    _sessionManager.addListener(_handleSessionManagerChanged);
    _listenToScanState();
    _namesLoaded = _loadRespiratoryNames();
  }

  @override
  void dispose() {
    _connectionCooldownTimer?.cancel();
    _sessionManager.removeListener(_handleSessionManagerChanged);
    _scanSubscription?.cancel();
    _isScanningSubscription?.cancel();
    FlutterBluePlus.stopScan();
    unawaited(_sessionManager.disposeSessions());
    for (final controller in _respiratoryNameControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadRespiratoryNames() async {
    try {
      final names = await RespiratoryDeviceNameStore.loadAll();
      if (!mounted) {
        return;
      }
      setState(() {
        _savedRespiratoryNames.addAll(names);
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _statusMessage = 'Could not load saved device names: $error';
        });
      }
    }
  }

  bool get _hasValidRespiratoryNames {
    // A pending IMU connection must receive its editable name before continuing.
    for (final id in _connectingDeviceIds) {
      final result = _scanResults[id];
      if (result != null &&
          _deviceType(result) == KnownDeviceType.respiratoryMonitor) {
        return false;
      }
    }
    return _sessionManager.sessions.every(
      (session) => session.type != KnownDeviceType.respiratoryMonitor ||
          (_respiratoryNameControllers[session.deviceId]
                  ?.text.trim().isNotEmpty ??
              false),
    );
  }

  void _handleSessionManagerChanged() {
    if (!mounted) {
      return;
    }

    setState(() {});
  }

  void _listenToScanState() {
    _isScanningSubscription = FlutterBluePlus.isScanning.listen((isScanning) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isScanning = isScanning;
      });
    });
  }

  Future<void> _startScan({bool clearResults = true}) async {
    setState(() {
      if (clearResults) {
        _scanResults.clear();
        _discoveryOrder.clear();
        _nextDiscoveryIndex = 0;
      }
      _statusMessage = null;
    });

    final hasPermissions = await _requestBluetoothPermissions();
    if (!hasPermissions) {
      setState(() {
        _statusMessage = 'Bluetooth permission is required to scan devices.';
      });
      return;
    }

    final isSupported = await FlutterBluePlus.isSupported;
    if (!isSupported) {
      setState(() {
        _statusMessage = 'Bluetooth is not supported on this device.';
      });
      return;
    }

    try {
      await FlutterBluePlus.adapterState
          .where((state) => state == BluetoothAdapterState.on)
          .first
          .timeout(const Duration(seconds: 8));
    } on TimeoutException {
      setState(() {
        _statusMessage = 'Turn on Bluetooth and try again.';
      });
      return;
    }

    await _scanSubscription?.cancel();
    _scanSubscription = FlutterBluePlus.onScanResults.listen(
      (results) {
        if (!mounted) {
          return;
        }

        setState(() {
          for (final result in results) {
            final id = _deviceId(result.device);
            _discoveryOrder.putIfAbsent(id, () => _nextDiscoveryIndex++);
            _scanResults[id] = result;
          }
        });
      },
      onError: (Object error) {
        if (!mounted) {
          return;
        }

        setState(() {
          _statusMessage = 'Scan failed: $error';
        });
      },
    );

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
      await FlutterBluePlus.isScanning.where((isScanning) => !isScanning).first;

      if (mounted && _scanResults.isEmpty) {
        setState(() {
          _statusMessage = 'No Bluetooth LE devices found nearby.';
        });
      }
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _statusMessage = 'Scan failed: $error';
      });
    }
  }

  Future<bool> _requestBluetoothPermissions() async {
    if (Platform.isIOS) {
      // Su iOS flutter_blue_plus gestisce i permessi BLE autonomamente
      return true;
    }

    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final scanStatus = statuses[Permission.bluetoothScan];
    final connectStatus = statuses[Permission.bluetoothConnect];

    return (scanStatus == null || scanStatus.isGranted) &&
        (connectStatus == null || connectStatus.isGranted);
  }

  Future<void> _toggleConnection(ScanResult result) async {
    final device = result.device;
    final id = _deviceId(device);
    final session = _sessionForDeviceId(id);

    if (session != null) {
      if (!session.isConnected && !session.isPolarManaged) {
        await _reconnectSession(session);
        return;
      }
      await _disconnectFromSession(session);
      return;
    }

    await _connectToDevice(result);
  }

  bool _sessionIsConnected(String id) {
    final session = _sessionForDeviceId(id);
    return session != null &&
        (session.isConnected || session.isPolarManaged);
  }

  bool _sessionNeedsReconnect(String id) {
    final session = _sessionForDeviceId(id);
    return session != null &&
        !session.isConnected &&
        !session.isPolarManaged;
  }

  /// A device still in the list but not connected (for example after a
  /// failed initialization, which disconnects every device): connected
  /// again keeping its configuration.
  Future<void> _reconnectSession(_ConnectedDeviceSession session) async {
    final id = session.deviceId;
    final displayName = session.displayName;
    if (!await _waitForConnectionSlot(displayName)) {
      return;
    }

    setState(() {
      _connectingDeviceIds.add(id);
      _statusMessage = 'Reconnecting $displayName...';
    });
    try {
      await _stopScanBeforeConnecting();
      await _sessionManager.reconnectSessionLink(session);
      _lastConnectionAt = DateTime.now();
      _startConnectionCooldownTimer();
      if (mounted) {
        setState(() {
          _statusMessage = 'Connected to $displayName.';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _statusMessage = 'Could not reconnect $displayName: $error';
        });
      }
    } finally {
      _connectionInProgress = false;
      if (mounted) {
        setState(() {
          _connectingDeviceIds.remove(id);
        });
        if (!_isScanning) {
          unawaited(_startScan(clearResults: false));
        }
      }
    }
  }

  Future<void> _connectToDevice(ScanResult result) async {
    await _namesLoaded;
    if (!mounted || _isSavingNames) {
      return;
    }
    final device = result.device;
    final id = _deviceId(device);
    final originalName = _originalDeviceName(result);
    final displayName = _displayDeviceName(result);
    final deviceType = _deviceType(result);

    if (deviceType == KnownDeviceType.unsupported) {
      return;
    }

    _sessionManager.logEvent(
      'CONNECT_REQUESTED',
      deviceName: displayName,
      deviceType: deviceType,
      details: 'id $id, RSSI ${result.rssi} dBm',
    );
    setState(() {
      _connectingDeviceIds.add(id);
      _statusMessage = null;
    });

    var connectionSlotTaken = false;
    try {
      if (deviceType == KnownDeviceType.polarH10) {
        if (!Platform.isAndroid && _sessionManager.sessions.any(
          (session) => session.type == KnownDeviceType.polarH10,
        )) {
          setState(() {
            _statusMessage = 'Only one Polar H10 can be selected at a time.';
          });
          return;
        }
        if (!mounted) {
          return;
        }

        _sessionManager.addConnectedSession(
          _ConnectedDeviceSession(
            deviceId: id,
            deviceName: originalName,
            type: deviceType,
            polarAddress: id,
            polarRssi: result.rssi,
          )..isConnected = true,
        );
        _sessionManager.logEvent(
          'POLAR_SELECTED',
          deviceName: displayName,
          deviceType: deviceType,
          details: 'Connected later by the Polar SDK, during the initialization',
        );
        setState(() {
          _statusMessage = 'Connected to $displayName.';
        });
        if (!_isScanning) {
          unawaited(_startScan(clearResults: false));
        }
        return;
      }

      final slotRequestedAt = DateTime.now();
      if (!await _waitForConnectionSlot(displayName)) {
        return;
      }
      connectionSlotTaken = true;
      final waitedMs =
          DateTime.now().difference(slotRequestedAt).inMilliseconds;
      _sessionManager.logEvent(
        'CONNECTING',
        deviceName: displayName,
        deviceType: deviceType,
        details: waitedMs >= 200
            ? 'after waiting $waitedMs ms for the previous connection'
            : '',
      );
      await _connectWithRetries(device, displayName, deviceType);
      _lastConnectionAt = DateTime.now();
      _sessionManager.logEvent(
        'CONNECTED',
        deviceName: displayName,
        deviceType: deviceType,
        details: 'MTU ${device.mtuNow}',
      );
      _startConnectionCooldownTimer();

      if (!mounted) {
        return;
      }

      if (deviceType == KnownDeviceType.respiratoryMonitor) {
        final controller = _respiratoryNameControllers.putIfAbsent(
          id,
          () => TextEditingController(),
        );
        controller.text = displayName;
      }
      _sessionManager.addConnectedSession(
        _ConnectedDeviceSession(
          device: device,
          deviceId: id,
          deviceName: originalName,
          type: deviceType,
          customName: deviceType == KnownDeviceType.respiratoryMonitor
              ? _savedRespiratoryNames[id]
              : null,
        ),
      );
      setState(() {
        _statusMessage = 'Connected to $displayName.';
      });
      if (!_isScanning) {
        unawaited(_startScan(clearResults: false));
      }
    } catch (error) {
      _sessionManager.logEvent(
        'CONNECT_FAILED',
        deviceName: displayName,
        deviceType: deviceType,
        details: error.toString(),
      );
      if (!mounted) {
        return;
      }

      setState(() {
        _statusMessage = 'Could not connect to $displayName: $error';
      });
      if (!_isScanning) {
        unawaited(_startScan(clearResults: false));
      }
    } finally {
      if (connectionSlotTaken) {
        _connectionInProgress = false;
      }
      if (mounted) {
        setState(() {
          _connectingDeviceIds.remove(id);
        });
      }
    }
  }

  /// Android often refuses a connection at once (error 133), above all
  /// while the page is scanning: the scan is stopped first and the
  /// connection is tried up to [_connectAttempts] times.
  static const int _connectAttempts = 3;
  static const Duration _connectRetryDelay = Duration(milliseconds: 1500);

  Future<void> _connectWithRetries(
    BluetoothDevice device,
    String displayName,
    KnownDeviceType deviceType,
  ) async {
    await _stopScanBeforeConnecting();
    for (var attempt = 1; ; attempt += 1) {
      try {
        await device.connect(
          license: License.nonprofit,
          timeout: const Duration(seconds: 12),
        );
        return;
      } on FlutterBluePlusException catch (error) {
        final canceled = error.platform == ErrorPlatform.fbp &&
            error.code == FbpErrorCode.connectionCanceled.index;
        if (canceled || attempt >= _connectAttempts || !mounted) {
          rethrow;
        }
        _sessionManager.logEvent(
          'CONNECT_RETRY',
          deviceName: displayName,
          deviceType: deviceType,
          details: 'attempt ${attempt + 1}/$_connectAttempts after: $error',
        );
        setState(() {
          _statusMessage = 'Could not connect to $displayName, retrying '
              '(${attempt + 1}/$_connectAttempts)...';
        });
        await Future<void>.delayed(_connectRetryDelay);
        if (!mounted) {
          rethrow;
        }
      }
    }
  }

  /// Stops the scan of the page before a connection; it starts again after
  /// the connection (see _connectToDevice).
  Future<void> _stopScanBeforeConnecting() async {
    if (!FlutterBluePlus.isScanningNow) {
      return;
    }
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    // Short pause: some phones refuse a connection started right after the
    // scan.
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  Duration get _connectionCooldownRemaining {
    final lastConnectionAt = _lastConnectionAt;
    if (lastConnectionAt == null) {
      return Duration.zero;
    }

    final remaining = _minGapBetweenConnections -
        DateTime.now().difference(lastConnectionAt);
    return remaining > Duration.zero ? remaining : Duration.zero;
  }

  /// True while a device is connecting (or disconnecting) or the last
  /// connection is less than [_minGapBetweenConnections] old: the Connect
  /// buttons are disabled.
  bool get _isConnectBlocked {
    return _connectingDeviceIds.isNotEmpty ||
        _connectionInProgress ||
        _connectionCooldownRemaining > Duration.zero;
  }

  String? get _connectionWaitMessage {
    if (_connectingDeviceIds.isNotEmpty || _connectionInProgress) {
      return 'Please wait until the connection is complete.';
    }

    final remaining = _connectionCooldownRemaining;
    if (remaining <= Duration.zero) {
      return null;
    }

    final seconds = (remaining.inMilliseconds / 1000).ceil();
    return 'Please wait $seconds s before connecting another device.';
  }

  /// Refreshes the countdown every 0.5 s until the Connect buttons are
  /// enabled again.
  void _startConnectionCooldownTimer() {
    _connectionCooldownTimer?.cancel();
    _connectionCooldownTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        if (_connectionCooldownRemaining <= Duration.zero) {
          timer.cancel();
        }
        setState(() {});
      },
    );
  }

  /// Waits until no other device is connecting and at least
  /// [_minGapBetweenConnections] has passed since the last connection, then
  /// takes the connection slot. False if the page was closed meanwhile.
  Future<bool> _waitForConnectionSlot(String displayName) async {
    var announced = false;
    while (true) {
      if (!mounted) {
        return false;
      }

      final lastConnectionAt = _lastConnectionAt;
      final remaining = lastConnectionAt == null
          ? Duration.zero
          : _minGapBetweenConnections -
              DateTime.now().difference(lastConnectionAt);
      if (!_connectionInProgress && remaining <= Duration.zero) {
        _connectionInProgress = true;
        return true;
      }

      if (!announced) {
        announced = true;
        setState(() {
          _statusMessage =
              'Waiting a few seconds before connecting $displayName...';
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  bool _isSupportedFilterDevice(ScanResult result) {
    return KnownDeviceClassifier.matchesSupportedFilter(
      _deviceNameCandidates(result),
    );
  }

  List<String> _deviceNameCandidates(ScanResult result) {
    final names = <String>[];
    for (final name in [
      result.device.platformName,
      result.advertisementData.advName,
      result.device.advName,
    ]) {
      final trimmedName = name.trim();
      if (trimmedName.isNotEmpty && !names.contains(trimmedName)) {
        names.add(trimmedName);
      }
    }

    return names;
  }

  String _displayDeviceName(ScanResult result) {
    if (_deviceType(result) == KnownDeviceType.respiratoryMonitor) {
      final savedName = _savedRespiratoryNames[_deviceId(result.device)];
      if (savedName != null) {
        return savedName;
      }
    }
    return _originalDeviceName(result);
  }

  String _originalDeviceName(ScanResult result) {
    final names = _deviceNameCandidates(result);
    final environmentalV2Name =
        KnownDeviceClassifier.environmentalV2NameFrom(names);
    if (environmentalV2Name != null) {
      return environmentalV2Name;
    }
    return names.isEmpty ? 'Unknown device' : names.first;
  }

  KnownDeviceType _deviceType(ScanResult result) {
    return KnownDeviceClassifier.fromNames(_deviceNameCandidates(result));
  }

  _ConnectedDeviceSession? _sessionForDeviceId(String deviceId) {
    for (final session in _sessionManager.sessions) {
      if (session.deviceId == deviceId) {
        return session;
      }
    }

    return null;
  }

  Future<void> _continueToDeviceConfiguration() async {
    if (!_sessionManager.hasConnectedDevices ||
        _connectingDeviceIds.isNotEmpty ||
        !_hasValidRespiratoryNames ||
        _isSavingNames) {
      return;
    }

    setState(() {
      _isSavingNames = true;
    });
    try {
      final respiratorySessions = _sessionManager.sessions
          .where((session) =>
              session.type == KnownDeviceType.respiratoryMonitor)
          .toList(growable: false);
      final names = <String, String>{
        for (final session in respiratorySessions)
          session.deviceId:
              _respiratoryNameControllers[session.deviceId]!.text.trim(),
      };
      for (final entry in names.entries) {
        await RespiratoryDeviceNameStore.save(entry.key, entry.value);
      }
      if (!mounted) {
        return;
      }
      for (final session in respiratorySessions) {
        final name = names[session.deviceId]!;
        session.customName = name;
        _respiratoryNameControllers[session.deviceId]!.text = name;
      }
      _savedRespiratoryNames.addAll(names);

      await _stopScanBeforeNavigation();
      if (!mounted || !_sessionManager.hasConnectedDevices) {
        return;
      }

      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => _MultiDeviceConfigurationPage(
              manager: _sessionManager,
            ),
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _statusMessage = 'Could not save device names: $error';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSavingNames = false;
        });
      }
    }
  }

  Future<void> _stopScanBeforeNavigation() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {
      // Best effort: navigation should not be blocked by a stale scan state.
    }
  }

  Future<void> _disconnectFromSession(_ConnectedDeviceSession session) async {
    final id = session.deviceId;
    final displayName = session.displayName;

    setState(() {
      _connectingDeviceIds.add(id);
      _statusMessage = null;
    });

    try {
      await _sessionManager.disconnectAndRemove(session);
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _statusMessage = 'Could not disconnect $displayName: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _connectingDeviceIds.remove(id);
        });
      }
    }
  }

  String _deviceId(BluetoothDevice device) {
    return device.remoteId.toString();
  }

  List<ScanResult> _displayDevices() {
    var devices = _scanResults.values.toList();

    if (_showOnlySupportedDevices) {
      devices = devices.where(_isSupportedFilterDevice).toList();
    }

    if (_sortBySignalStrength) {
      devices.sort((a, b) {
        final signalComparison = b.rssi.compareTo(a.rssi);
        if (signalComparison != 0) {
          return signalComparison;
        }

        final aOrder = _discoveryOrder[_deviceId(a.device)] ?? 0;
        final bOrder = _discoveryOrder[_deviceId(b.device)] ?? 0;
        return aOrder.compareTo(bOrder);
      });
      return devices;
    }

    devices.sort(
      (a, b) => _displayDeviceName(a).compareTo(_displayDeviceName(b)),
    );
    return devices;
  }

  void _toggleSupportedFilter() {
    setState(() {
      _showOnlySupportedDevices = !_showOnlySupportedDevices;
    });
  }

  void _toggleSignalSort() {
    setState(() {
      _sortBySignalStrength = !_sortBySignalStrength;
    });
  }

  Color _statusMessageColor(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final message = _statusMessage;
    if (message != null && message.startsWith('Connected to ')) {
      return Colors.green.shade700;
    }

    return colorScheme.error;
  }

  Widget _buildScanOptionButtons(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        _buildScanOptionButton(
          context,
          label: 'Supported Devices',
          selected: _showOnlySupportedDevices,
          onPressed: _toggleSupportedFilter,
        ),
        _buildScanOptionButton(
          context,
          label: 'Strongest Signal',
          selected: _sortBySignalStrength,
          onPressed: _toggleSignalSort,
        ),
      ],
    );
  }

  Widget _buildScanOptionButton(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback onPressed,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor:
            selected ? colorScheme.primary : colorScheme.surfaceContainerHighest,
        foregroundColor:
            selected ? colorScheme.onPrimary : colorScheme.onSurfaceVariant,
      ),
      onPressed: onPressed,
      child: Text(label),
    );
  }

  @override
  Widget build(BuildContext context) {
    final devices = _displayDevices()
        .where((result) => _sessionForDeviceId(_deviceId(result.device)) == null)
        .toList(growable: false);
    final connectedSessions = _sessionManager.sessions;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scanning Bluetooth Devices...'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text('Connected: ${_sessionManager.connectedCount}'),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              icon: Icon(_isScanning ? Icons.bluetooth_searching : Icons.search),
              label: Text(_isScanning ? 'Scanning...' : 'Scan Bluetooth Devices'),
              onPressed: _isScanning ? null : () => unawaited(_startScan()),
            ),
            const SizedBox(height: 12),
            _buildScanOptionButtons(context),
            if (_statusMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _statusMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(color: _statusMessageColor(context)),
              ),
            ],
            if (_connectionWaitMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                _connectionWaitMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Expanded(
              child: devices.isEmpty && connectedSessions.isEmpty
                  ? const Center(
                      child: Text(
                        'Press the scan button to find nearby Bluetooth LE devices.',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView(
                      children: [
                        if (connectedSessions.isNotEmpty) ...[
                          Text(
                            'Connected devices',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          for (final session in connectedSessions)
                            ListTile(
                              key: ValueKey(session.deviceId),
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.bluetooth_connected),
                              title: session.type ==
                                      KnownDeviceType.respiratoryMonitor
                                  ? TextField(
                                      controller: _respiratoryNameControllers[
                                          session.deviceId],
                                      enabled: !_isSavingNames,
                                      decoration: InputDecoration(
                                        labelText: 'Device name',
                                        errorText: _respiratoryNameControllers[
                                                    session.deviceId]!
                                                .text.trim().isEmpty
                                            ? 'Enter a device name'
                                            : null,
                                      ),
                                      onChanged: (_) => setState(() {}),
                                    )
                                  : Text(session.displayName),
                              subtitle: Text(session.type.label),
                              trailing: FilledButton(
                                onPressed: _isSavingNames ||
                                    _connectingDeviceIds.contains(
                                  session.deviceId,
                                )
                                    ? null
                                    : () => _disconnectFromSession(session),
                                child: Text(
                                  _connectingDeviceIds.contains(
                                    session.deviceId,
                                  )
                                      ? 'Wait'
                                      : 'Disconnect',
                                ),
                              ),
                            ),
                          const Divider(height: 24),
                        ],
                        if (devices.isNotEmpty) ...[
                          Text(
                            'Nearby devices',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                        ],
                        for (final result in devices) ...[
                          _BluetoothScanResultTile(
                            result: result,
                            displayName: _displayDeviceName(result),
                            deviceId: _deviceId(result.device),
                            deviceType: _deviceType(result),
                            isConnected: _sessionIsConnected(
                              _deviceId(result.device),
                            ),
                            needsReconnect: _sessionNeedsReconnect(
                              _deviceId(result.device),
                            ),
                            isBusy: _isSavingNames || _connectingDeviceIds.contains(
                              _deviceId(result.device),
                            ),
                            isBlocked: _isConnectBlocked,
                            onPressed: () => unawaited(_toggleConnection(result)),
                          ),
                          const Divider(height: 1),
                        ],
                      ],
                    ),
            ),
            SafeArea(
              top: false,
              minimum: const EdgeInsets.fromLTRB(0, 8, 0, 0),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  // Off while any device is still connecting (not only the
                  // IMUs, which also wait for their name field): a device
                  // whose connection fails after Continue would be left out
                  // with the error shown on this page only.
                  onPressed: _sessionManager.hasConnectedDevices &&
                          _connectingDeviceIds.isEmpty &&
                          _hasValidRespiratoryNames &&
                          !_isSavingNames
                      ? _continueToDeviceConfiguration
                      : null,
                  child: const Text('Continue'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BluetoothScanResultTile extends StatelessWidget {
  const _BluetoothScanResultTile({
    required this.result,
    required this.displayName,
    required this.deviceId,
    required this.deviceType,
    required this.isConnected,
    required this.needsReconnect,
    required this.isBusy,
    required this.isBlocked,
    required this.onPressed,
  });

  final ScanResult result;
  final String displayName;
  final String deviceId;
  final KnownDeviceType deviceType;
  final bool isConnected;

  /// Still in the list but not connected (for example after a failed
  /// initialization): "Reconnect".
  final bool needsReconnect;
  final bool isBusy;
  // Another device is connecting or has just connected: Connect is disabled
  // (see _BluetoothScanningPageState._isConnectBlocked).
  final bool isBlocked;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final isUnsupported = deviceType == KnownDeviceType.unsupported;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(isUnsupported ? 'Unsupported device' : displayName),
      subtitle: Text(
        isUnsupported
            ? '$displayName\n$deviceId - RSSI ${result.rssi} dBm'
            : '${deviceType.label}\n$deviceId - RSSI ${result.rssi} dBm',
      ),
      isThreeLine: true,
      trailing: FilledButton(
        onPressed: isUnsupported || isBusy || (isBlocked && !isConnected)
            ? null
            : onPressed,
        child: Text(
          isBusy
              ? 'Wait'
              : needsReconnect
                  ? 'Reconnect'
                  : isConnected
                      ? 'Disconnect'
                      : 'Connect',
        ),
      ),
    );
  }
}

class _MultiDeviceConfigurationPage extends StatefulWidget {
  const _MultiDeviceConfigurationPage({
    required this.manager,
  });

  final _MultiDeviceSessionManager manager;

  @override
  State<_MultiDeviceConfigurationPage> createState() =>
      _MultiDeviceConfigurationPageState();
}

class _MultiDeviceConfigurationPageState
    extends State<_MultiDeviceConfigurationPage> {
  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_handleManagerChanged);
    _ActiveAcquisitionRuntime.registerMultiDeviceManager(widget.manager);
  }

  @override
  void dispose() {
    widget.manager.removeListener(_handleManagerChanged);
    super.dispose();
  }

  void _handleManagerChanged() {
    if (!mounted) {
      return;
    }

    setState(() {});
  }

  Future<void> _openSessionConfiguration(
    _ConnectedDeviceSession session,
  ) async {
    switch (session.type) {
      case KnownDeviceType.environmentalMonitor:
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => DeviceConfigurationPage(
              initialConfiguration: session.environmentalConfiguration,
              onConfigurationConfirmed: (configuration) {
                widget.manager.configureEnvironmental(session, configuration);
              },
            ),
          ),
        );
        return;
      case KnownDeviceType.environmentalMonitorV2:
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => EnvironmentalV2ConfigurationPage(
              initialConfiguration: session.environmentalV2Configuration,
              onConfigurationConfirmed: (configuration) {
                widget.manager.configureEnvironmentalV2(
                  session,
                  configuration,
                );
              },
            ),
          ),
        );
        return;
      case KnownDeviceType.respiratoryMonitor:
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => WearableDeviceConfigurationPage(
              initialConfiguration: session.wearableConfiguration,
              onConfigurationConfirmed: (configuration) {
                widget.manager.configureWearable(session, configuration);
              },
            ),
          ),
        );
        return;
      case KnownDeviceType.polarH10:
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PolarH10ConfigurationPage(
              deviceName: session.displayName,
              initialConfiguration: session.polarConfiguration,
              onConfigurationConfirmed: (configuration) {
                widget.manager.configurePolarH10(session, configuration);
              },
            ),
          ),
        );
        return;
      case KnownDeviceType.unsupported:
        return;
    }
  }

  void _openAcquisitionInitialization() {
    if (!widget.manager.allDevicesConfigured) {
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _MultiDeviceAcquisitionInitializationPage(
          manager: widget.manager,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sessions = widget.manager.sessions;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Device Configuration'),
      ),
      body: Column(
        children: [
          Expanded(
            child: sessions.isEmpty
                ? const Center(
                    child: Text('No connected devices.'),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: sessions.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final session = sessions[index];
                      return Card(
                        child: ListTile(
                          title: Text(session.displayName),
                          subtitle: Text(
                            session.isConnected || session.isPolarManaged
                                ? session.type.label
                                : '${session.type.label} - Disconnected, '
                                    'reconnected at the start',
                          ),
                          leading: Icon(
                            session.isConnected || session.isPolarManaged
                                ? Icons.bluetooth_connected
                                : Icons.bluetooth_disabled,
                          ),
                          trailing: session.isConfigured
                              ? Icon(
                                  Icons.check_circle,
                                  color: Colors.green.shade700,
                                )
                              : const Icon(Icons.chevron_right),
                          onTap: session.isConnected
                              ? () => _openSessionConfiguration(session)
                              : null,
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                onPressed: widget.manager.allDevicesConfigured
                    ? _openAcquisitionInitialization
                    : null,
                child: const Text('Continue'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MultiDeviceAcquisitionInitializationPage extends StatefulWidget {
  const _MultiDeviceAcquisitionInitializationPage({
    required this.manager,
  });

  final _MultiDeviceSessionManager manager;

  @override
  State<_MultiDeviceAcquisitionInitializationPage> createState() =>
      _MultiDeviceAcquisitionInitializationPageState();
}

class _MultiDeviceAcquisitionInitializationPageState
    extends State<_MultiDeviceAcquisitionInitializationPage> {
  bool _isInitializing = true;
  String? _errorMessage;
  // Calibration instructions with a countdown.
  Timer? _instructionRefreshTimer;

  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_handleManagerChanged);
    _instructionRefreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _isInitializing) {
        setState(() {});
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startInitialization();
    });
  }

  @override
  void dispose() {
    widget.manager.removeListener(_handleManagerChanged);
    _instructionRefreshTimer?.cancel();
    super.dispose();
  }

  void _handleManagerChanged() {
    if (mounted && _isInitializing) {
      setState(() {});
    }
  }

  Future<void> _startInitialization() async {
    setState(() {
      _isInitializing = true;
      _errorMessage = null;
    });

    try {
      await widget.manager.initializeAllSequentially();
      if (!mounted) {
        return;
      }

      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => _MultiDeviceAcquisitionPage(
            manager: widget.manager,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isInitializing = false;
        _errorMessage = error.toString();
      });
    }
  }

  Widget _buildInitializationProgress(BuildContext context) {
    final instruction = widget.manager.initializationInstruction;
    if (instruction == null) {
      return const CircularProgressIndicator();
    }

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 24),
          Text(
            instruction,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isInitializing,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Acquisition Initialization'),
        ),
        body: Center(
          child: _isInitializing
              ? _buildInitializationProgress(context)
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _errorMessage ?? 'Could not initialize acquisition.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Retry starts the initialization again and reconnects '
                        'the disconnected devices.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: () => unawaited(_startInitialization()),
                        child: const Text('Retry'),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Back'),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

class _MultiDeviceAcquisitionPage extends StatefulWidget {
  const _MultiDeviceAcquisitionPage({
    required this.manager,
  });

  final _MultiDeviceSessionManager manager;

  @override
  State<_MultiDeviceAcquisitionPage> createState() =>
      _MultiDeviceAcquisitionPageState();
}

class _MultiDeviceAcquisitionPageState
    extends State<_MultiDeviceAcquisitionPage> with WidgetsBindingObserver {
  bool _stopConfirmationOpen = false;
  // Disconnections whose alert was closed with "Stop retrying".
  final Set<String> _dismissedBleAlertKeys = {};
  Timer? _bleAlertBeepTimer;
  // Keeps the IMU "samples received" indicators current even when no data
  // arrive.
  Timer? _receptionRefreshTimer;
  final _ImuNoDataAlert _noDataAlert = _ImuNoDataAlert();
  final _ImuSdAlert _sdAlert = _ImuSdAlert();
  // Device cards left open by the user. The list builds only
  // the visible cards: a card that scrolled off the screen was destroyed and
  // came back closed (shorter), so the list jumped. Now a card that comes
  // back is rebuilt open if it was open.
  final Set<String> _expandedDeviceIds = {};

  @override
  void initState() {
    super.initState();
    if (widget.manager.sessions.length == 1) {
      _expandedDeviceIds.add(widget.manager.sessions.first.deviceId);
    }
    WidgetsBinding.instance.addObserver(this);
    _receptionRefreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
        _checkImuNoData();
      }
    });
    widget.manager.addListener(_handleManagerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncBleDisconnectionAlert();
      // On Android the manager starts these streams itself at the end of the
      // initialization (they must not depend on this page).
      if (!Platform.isAndroid) {
        unawaited(widget.manager.startPolarStreamsForAcquisition());
        unawaited(
          widget.manager.startEnvironmentalV2NotificationsForAcquisition(),
        );
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.manager.removeListener(_handleManagerChanged);
    // On Android the acquisition belongs to the manager, not to this page:
    // closing the page does not stop the automatic reconnection.
    if (!Platform.isAndroid) widget.manager.cancelAutomaticBleReconnect();
    _receptionRefreshTimer?.cancel();
    _noDataAlert.clear();
    _sdAlert.clear();
    _stopBleAlertAlarm();
    super.dispose();
  }

  /// Data watchdog: IMUs still connected but silent.
  void _checkImuNoData() {
    if (widget.manager.isStopping) {
      _noDataAlert.clear();
      _sdAlert.clear();
      return;
    }

    // SD problems of the IMUs: the notification stays until the stop.
    _sdAlert.update(
      widget.manager.sessions.where(
        (session) => session.type == KnownDeviceType.respiratoryMonitor,
      ),
    );

    final now = DateTime.now();
    final disconnected =
        widget.manager.disconnectedSessionsDuringAcquisition.toSet();
    _noDataAlert.update(
      silentDevices: [
        for (final session in widget.manager.sessions)
          if (session.type == KnownDeviceType.respiratoryMonitor &&
              !disconnected.contains(session) &&
              session.wearableService?.noDataFor(now) != null)
            session.displayName,
      ],
      now: now,
      canRepeatVibration: _ActiveAcquisitionRuntime.isForegroundVisible &&
          _bleAlertBeepTimer == null,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _syncBleDisconnectionAlert();
      });
      return;
    }

    _stopBleAlertAlarm();
  }

  void _handleManagerChanged() {
    if (!mounted) {
      return;
    }

    setState(() {});
    _syncBleDisconnectionAlert();
  }

  /// The disconnection alert is a panel of this page, not a dialog over it:
  /// the app stays usable while a device is disconnected.
  bool get _isBleAlertVisible {
    return Platform.isAndroid &&
        !widget.manager.isStopping &&
        _visibleBleAlertSessions.isNotEmpty;
  }

  /// Vibration of the disconnection alert: every 5 s while the panel is on
  /// the screen.
  void _syncBleDisconnectionAlert() {
    if (!mounted || !Platform.isAndroid) {
      return;
    }

    if (!_isBleAlertVisible || !_ActiveAcquisitionRuntime.isForegroundVisible) {
      _stopBleAlertAlarm();
      return;
    }

    if (_bleAlertBeepTimer == null) {
      _startBleAlertAlarm();
    }
  }

  Widget _buildBleDisconnectionAlert() {
    if (!_isBleAlertVisible) {
      return const SizedBox.shrink();
    }

    return _BleDisconnectionAlertPanel(
      items: _visibleBleAlertSessions
          .map(_bleAlertItemForSession)
          .toList(growable: false),
      onStopRetrying: _stopRetryingBleReconnect,
    );
  }

  _BleDisconnectionAlertItem _bleAlertItemForSession(
    _ConnectedDeviceSession session,
  ) {
    return _BleDisconnectionAlertItem(
      id: session.deviceId,
      deviceName: session.displayName,
      status: session.reconnectStatus,
      failureMessage: session.reconnectFailureMessage,
    );
  }

  /// "Stop retrying": closes the alert of the devices shown in it (panel
  /// and vibration) and stops reconnecting them automatically. "Retry" in
  /// the card of the device starts again.
  void _stopRetryingBleReconnect() {
    final visibleSessions = _visibleBleAlertSessions;
    setState(() {
      for (final session in visibleSessions) {
        _dismissedBleAlertKeys.add(_bleAlertKey(session));
      }
    });
    widget.manager.dismissAutomaticBleReconnectForSessions(visibleSessions);
    _syncBleDisconnectionAlert();
  }

  void _resumeBleReconnect(_ConnectedDeviceSession session) {
    setState(() {
      _dismissedBleAlertKeys.remove(_bleAlertKey(session));
    });
    widget.manager.resumeAutomaticBleReconnect(session);
    _syncBleDisconnectionAlert();
  }

  void _startBleAlertAlarm() {
    _stopBleAlertAlarm();
    _playBleAlertCue();
    _bleAlertBeepTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _playBleAlertCue();
    });
  }

  void _stopBleAlertAlarm() {
    _bleAlertBeepTimer?.cancel();
    _bleAlertBeepTimer = null;
  }

  void _playBleAlertCue() {
    if (!Platform.isAndroid) {
      return;
    }

    // Vibration only, no sound.
    unawaited(AndroidAcquisitionForegroundService.vibrateBleDisconnectionAlert());
    unawaited(HapticFeedback.vibrate().catchError((_) {}));
  }

  String _bleAlertKey(_ConnectedDeviceSession session) {
    return '${session.deviceId}:${session.disconnectionAlertVersion}';
  }

  List<_ConnectedDeviceSession> get _visibleBleAlertSessions {
    return widget.manager.disconnectedSessionsDuringAcquisition.where((session) {
      return !_dismissedBleAlertKeys.contains(_bleAlertKey(session));
    }).toList(growable: false);
  }

  Future<void> _requestStopAcquisition() async {
    if (!mounted || _stopConfirmationOpen || widget.manager.isStopping) {
      return;
    }

    _stopConfirmationOpen = true;
    final bool confirmed;
    try {
      confirmed = await _confirmStopAcquisition(context);
    } finally {
      _stopConfirmationOpen = false;
    }
    if (!mounted || !confirmed) {
      return;
    }
    await _stopAcquisition();
  }

  Future<void> _stopAcquisition() async {
    if (widget.manager.isStopping) {
      return;
    }

    try {
      await widget.manager.stopAll();
      if (!mounted) {
        return;
      }

      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => _MultiDeviceAcquisitionCompletedPage(
            csvLogger: widget.manager.csvLogger,
            sdProblems: widget.manager.sdProblemsByImu,
          ),
        ),
      );
    } catch (_) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not stop acquisition')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Acquisition in progress...'),
          automaticallyImplyLeading: false,
        ),
        body: Column(
          children: [
            _buildConnectedCounter(context),
            _buildBackgroundStatus(context),
            _buildBleDisconnectionAlert(),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: widget.manager.sessions.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final session = widget.manager.sessions[index];
                  return _buildDeviceSection(
                    context,
                    session,
                    initiallyExpanded:
                        _expandedDeviceIds.contains(session.deviceId),
                  );
                },
              ),
            ),
            if (widget.manager.canUseOpenRemote)
              _buildOpenRemoteBanner(context),
            _buildStopAcquisitionButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildBackgroundStatus(BuildContext context) {
    if (!Platform.isAndroid) {
      return const SizedBox.shrink();
    }

    final colorScheme = Theme.of(context).colorScheme;
    final warning = widget.manager.backgroundStatusMessage;
    final text = warning ??
        (widget.manager.isAndroidBackgroundServiceActive
            ? 'Background acquisition active'
            : 'Background acquisition starting');
    final backgroundColor = warning == null
        ? Colors.green.shade50
        : colorScheme.errorContainer;
    final foregroundColor = warning == null
        ? Colors.green.shade900
        : colorScheme.onErrorContainer;
    final icon = warning == null
        ? Icons.notifications_active
        : Icons.warning_amber_rounded;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(icon, size: 18, color: foregroundColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(color: foregroundColor),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConnectedCounter(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Align(
        alignment: Alignment.centerRight,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colorScheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text('Connected: ${widget.manager.connectedCount}'),
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceSection(
    BuildContext context,
    _ConnectedDeviceSession session, {
    required bool initiallyExpanded,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final disconnected = !session.isConnected;

    return Card(
      // One key per device: the open/closed state follows the device even if
      // the list changes.
      key: ValueKey<String>('acquisition-device-${session.deviceId}'),
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        onExpansionChanged: (expanded) {
          if (expanded) {
            _expandedDeviceIds.add(session.deviceId);
          } else {
            _expandedDeviceIds.remove(session.deviceId);
          }
        },
        leading: Icon(
          disconnected ? Icons.bluetooth_disabled : Icons.bluetooth_connected,
          color: disconnected ? colorScheme.error : colorScheme.primary,
        ),
        title: Text(session.displayName),
        subtitle: _buildDeviceSubtitle(
          context,
          session,
          disconnected: disconnected,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          if (session.disconnectedDuringAcquisition)
            _buildDisconnectedBanner(context, session),
          switch (session.type) {
            KnownDeviceType.environmentalMonitor =>
              _buildEnvironmentalSection(context, session),
            KnownDeviceType.environmentalMonitorV2 =>
              _buildEnvironmentalSection(context, session),
            KnownDeviceType.respiratoryMonitor =>
              _buildWearableSection(context, session),
            KnownDeviceType.polarH10 =>
              _buildPolarH10Section(context, session),
            KnownDeviceType.unsupported => const SizedBox.shrink(),
          },
        ],
      ),
    );
  }

  /// Type and connection state. For an IMU with SD problems: "IMU - SD not
  /// saving" (red, while it lasts) or "IMU - SD problem earlier" (orange),
  /// visible also with the card closed.
  Widget _buildDeviceSubtitle(
    BuildContext context,
    _ConnectedDeviceSession session, {
    required bool disconnected,
  }) {
    final problems = session.sdProblems;
    final sdOngoing = problems.ongoing != null;
    final parts = [
      // Short type name, to leave room for the SD text.
      problems.isEmpty ? session.type.label : 'IMU',
      if (disconnected) 'Disconnected',
      if (problems.isNotEmpty) sdOngoing ? 'SD not saving' : 'SD problem earlier',
    ];

    return Text(
      parts.join(' - '),
      style: problems.isEmpty
          ? null
          : TextStyle(
              color: sdOngoing
                  ? Theme.of(context).colorScheme.error
                  : Colors.orange.shade800,
            ),
    );
  }

  Widget _buildDisconnectedBanner(
    BuildContext context,
    _ConnectedDeviceSession session,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    // Automatic reconnection stopped with "Stop retrying".
    final retryStopped = _dismissedBleAlertKeys.contains(_bleAlertKey(session));

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: colorScheme.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  retryStopped
                      ? 'Disconnected. Automatic reconnection stopped.'
                      : session.reconnectFailureMessage ??
                          session.reconnectStatus.label,
                  style: TextStyle(color: colorScheme.onErrorContainer),
                ),
              ),
              if (retryStopped)
                TextButton(
                  onPressed: widget.manager.isStopping
                      ? null
                      : () => _resumeBleReconnect(session),
                  child: const Text('Retry'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEnvironmentalSection(
    BuildContext context,
    _ConnectedDeviceSession session,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: SegmentedButton<_LiveVisualizationMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment<_LiveVisualizationMode>(
                value: _LiveVisualizationMode.cards,
                icon: _CardsModeIcon(),
                tooltip: 'Measurement cards',
              ),
              ButtonSegment<_LiveVisualizationMode>(
                value: _LiveVisualizationMode.charts,
                icon: _ChartModeIcon(),
                tooltip: 'Line charts',
              ),
            ],
            selected: {session.visualizationMode},
            onSelectionChanged: (selection) {
              widget.manager.setVisualizationMode(session, selection.first);
            },
          ),
        ),
        const SizedBox(height: 12),
        switch (session.visualizationMode) {
          _LiveVisualizationMode.cards =>
            _buildEnvironmentalCards(context, session),
          _LiveVisualizationMode.charts =>
            _buildEnvironmentalCharts(context, session),
        },
      ],
    );
  }

  Widget _buildEnvironmentalCards(
    BuildContext context,
    _ConnectedDeviceSession session,
  ) {
    final measurements = session.visibleMeasurements;
    if (measurements.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'No measurements selected.',
          textAlign: TextAlign.center,
        ),
      );
    }

    return _buildEnvironmentalCardGrid(
      session,
      measurements,
    );
  }

  Widget _buildEnvironmentalCardGrid(
    _ConnectedDeviceSession session,
    List<_MeasurementDefinition> measurements, {
    double childAspectRatio = 0.9,
    double? mainAxisExtent,
  }) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: measurements.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: childAspectRatio,
        mainAxisExtent: mainAxisExtent,
      ),
      itemBuilder: (context, index) {
        final definition = measurements[index];
        final value = session.liveMeasurementValues[definition.prefix];

        return _LiveMeasurementCard(
          definition: definition,
          value: value,
          updatedAtText: value == null
              ? 'No data received yet'
              : _formatDashboardTime(value.updatedAt),
        );
      },
    );
  }

  Widget _buildEnvironmentalCharts(
    BuildContext context,
    _ConnectedDeviceSession session,
  ) {
    final measurements = session.visibleMeasurements;
    if (measurements.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'No measurements selected.',
          textAlign: TextAlign.center,
        ),
      );
    }

    final chartMeasurements = measurements
        .where((definition) => definition.chartEnabled)
        .toList(growable: false);
    final currentValueMeasurements = measurements
        .where((definition) => !definition.chartEnabled)
        .toList(growable: false);

    return Column(
      children: [
        for (final definition in chartMeasurements) ...[
          _LiveMeasurementChartCard(
            definition: definition,
            samples: session.chartSamplesByPrefix[definition.prefix] ?? const [],
            currentValue: session.liveMeasurementValues[definition.prefix],
            formatTime: _formatDashboardTime,
          ),
          const SizedBox(height: 12),
        ],
        if (currentValueMeasurements.isNotEmpty)
          _buildEnvironmentalCardGrid(
            session,
            currentValueMeasurements,
            mainAxisExtent: _compactEnvironmentalCardExtent(context),
          ),
      ],
    );
  }

  double _compactEnvironmentalCardExtent(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    final titleScale = textScaler.scale(14) / 14;
    final valueScale = textScaler.scale(24) / 24;
    final updateScale = textScaler.scale(12) / 12;
    final effectiveScale = math.max(
      1.0,
      math.max(titleScale, math.max(valueScale, updateScale)),
    );
    return 144 * effectiveScale;
  }

  Widget _buildWearableSection(
    BuildContext context,
    _ConnectedDeviceSession session,
  ) {
    final sensorMask = session.wearableService?.configuredSensorMask ??
        session.wearableConfiguration?.sensorMask;
    return Column(
      children: [
        _WearableStatusBoxes(
          batteryPercent: session.latestBatteryPercent,
          flushFailureRate: session.latestFlushFailureRate,
          sdHealth: session.latestSdHealth,
          sdProblems: session.sdProblems,
          onSdProblemsTap: () => _showSdProblemsDialog(context, [
            _ImuSdProblems(
              deviceName: session.displayName,
              history: session.sdProblems,
            ),
          ]),
          receptionMonitor: session.wearableService?.receptionMonitor,
          timeAlignment: session.wearableService?.timeAlignment,
          calibrationInstruction:
              session.wearableService?.calibrationInstruction,
          magCalibrationWarning: session.wearableService?.magCalibrationWarning,
          magnetometerWarning: session.wearableService?.magnetometerWarning,
          noDataThreshold: session.wearableService?.noDataAlertThreshold,
        ),
        const SizedBox(height: 12),
        for (final definition in _wearableMetricDefinitionsFor(sensorMask)) ...[
          _WearableMetricChartCard(
            definition: definition,
            series: session.wearableMetricSeries[definition.metric]!,
            windowEnd: session.wearableChartWindowEnd,
            windowDuration: _ConnectedDeviceSession.wearableVisibleChartWindow,
            formatTime: _formatDashboardTime,
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _buildPolarH10Section(
    BuildContext context,
    _ConnectedDeviceSession session,
  ) {
    final configuration = session.polarConfiguration;
    if (configuration == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Polar H10 is not configured.',
          textAlign: TextAlign.center,
        ),
      );
    }

    return PolarH10LiveSection(
      configuration: configuration,
      status: session.polarStatus,
      latestHrSample: session.latestPolarHrSample,
      ecgSamples: session.polarEcgSamples,
      accelerometerSamples: session.polarAccelerometerSamples,
      accelerometerSamplingRateHz:
          session.latestPolarAccelerometerSamplingRateHz,
      batteryPercent: session.latestPolarBatteryPercent,
    );
  }

  Widget _buildOpenRemoteBanner(BuildContext context) {
    final status = widget.manager.mqttState.status;
    final canTap = status == OpenRemoteMqttStatus.disconnected ||
        status == OpenRemoteMqttStatus.failed;
    final colorScheme = Theme.of(context).colorScheme;

    final text = switch (status) {
      OpenRemoteMqttStatus.connecting => 'Connecting to OpenRemote...',
      OpenRemoteMqttStatus.connected => 'Connected to OpenRemote',
      OpenRemoteMqttStatus.failed => 'Connection failed - Tap to retry',
      OpenRemoteMqttStatus.disconnected => 'Connect to OpenRemote',
    };

    final backgroundColor = switch (status) {
      OpenRemoteMqttStatus.connected => Colors.green.shade50,
      OpenRemoteMqttStatus.failed => colorScheme.errorContainer,
      OpenRemoteMqttStatus.connecting => colorScheme.secondaryContainer,
      OpenRemoteMqttStatus.disconnected => colorScheme.surfaceContainerHighest,
    };

    final foregroundColor = switch (status) {
      OpenRemoteMqttStatus.connected => Colors.green.shade900,
      OpenRemoteMqttStatus.failed => colorScheme.onErrorContainer,
      OpenRemoteMqttStatus.connecting => colorScheme.onSecondaryContainer,
      OpenRemoteMqttStatus.disconnected => colorScheme.onSurfaceVariant,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Material(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: canTap ? () => unawaited(widget.manager.connectOpenRemote()) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Image.asset(
                  'assets/images/openremote_logo.png',
                  width: 36,
                  height: 36,
                  fit: BoxFit.contain,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        text,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              color: foregroundColor,
                            ),
                      ),
                      if (status == OpenRemoteMqttStatus.failed &&
                          widget.manager.mqttState.message != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          widget.manager.mqttState.message!,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: foregroundColor,
                              ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (status == OpenRemoteMqttStatus.connecting)
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: foregroundColor,
                    ),
                  )
                else if (status == OpenRemoteMqttStatus.connected)
                  Icon(Icons.check_circle, color: foregroundColor)
                else
                  Icon(Icons.chevron_right, color: foregroundColor),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStopAcquisitionButton() {
    return SafeArea(
      top: false,
      bottom: true,
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: SizedBox(
        width: double.infinity,
        height: 48,
        child: FilledButton(
          onPressed: widget.manager.isStopping ? null : _requestStopAcquisition,
          child: Text(
            widget.manager.isStopping ? 'Stopping...' : 'Stop acquisition',
          ),
        ),
      ),
    );
  }

  String _formatDashboardTime(DateTime value) {
    final local = value.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    final second = local.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }
}

class _ImuNoDataAlert {
  static const Duration _repeatEvery = Duration(seconds: 5);

  final Set<String> _silentDevices = {};
  DateTime? _lastCueAt;

  /// [silentDevices]: names of the IMUs without data beyond their threshold.
  void update({
    required Iterable<String> silentDevices,
    required DateTime now,
    required bool canRepeatVibration,
  }) {
    if (!Platform.isAndroid) {
      return;
    }

    final names = silentDevices.toSet();
    if (names.isEmpty) {
      clear();
      return;
    }

    final added = names.difference(_silentDevices);
    final changed = added.isNotEmpty || names.length != _silentDevices.length;
    _silentDevices
      ..clear()
      ..addAll(names);
    if (changed) {
      final sorted = names.toList()..sort();
      unawaited(
        AndroidAcquisitionForegroundService.showImuNoDataAlert(
          text: '${sorted.join(', ')}: no data. Check that the IMU is on '
              'and close to the phone.',
          alert: added.isNotEmpty,
        ),
      );
    }
    if (added.isNotEmpty) {
      // The notification itself vibrates.
      _lastCueAt = now;
      return;
    }

    final lastCueAt = _lastCueAt;
    if (canRepeatVibration &&
        (lastCueAt == null || now.difference(lastCueAt) >= _repeatEvery)) {
      _lastCueAt = now;
      unawaited(
        AndroidAcquisitionForegroundService.vibrateBleDisconnectionAlert(),
      );
    }
  }

  void clear() {
    if (_silentDevices.isEmpty) {
      return;
    }
    _silentDevices.clear();
    _lastCueAt = null;
    unawaited(AndroidAcquisitionForegroundService.clearImuNoDataAlert());
  }
}

/// The SD problems of one IMU with its name, for the completed page and the
/// details popup.
class _ImuSdProblems {
  const _ImuSdProblems({required this.deviceName, required this.history});

  final String deviceName;
  final SdProblemHistory history;
}

/// Popup with every period in which the SD of the given IMUs did not save.
void _showSdProblemsDialog(BuildContext context, List<_ImuSdProblems> imus) {
  final now = DateTime.now();
  unawaited(
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final textTheme = Theme.of(dialogContext).textTheme;
        return AlertDialog(
          scrollable: true,
          title: const Text('SD card problems'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final imu in imus) ...[
                Text(
                  '${imu.deviceName}: ${imu.history.summaryAt(now)}',
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                for (final period in imu.history.periods)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(period.detailsAt(now)),
                  ),
                const SizedBox(height: 12),
              ],
              const Text(
                'In these periods the SD files are incomplete: use the app '
                'data.',
              ),
              const SizedBox(height: 8),
              Text(
                'Stuck: a write did not finish within 2 s. Write errors: the '
                'writes failed.',
                style: textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    ),
  );
}

/// "SD card problem" notification: the last SD problem of every IMU that had
/// one, until the stop (also after the SD saves again). It vibrates when a
/// new problem starts.
class _ImuSdAlert {
  final Map<String, String> _texts = {};
  int _problemCount = 0;

  void update(Iterable<_ConnectedDeviceSession> imus) {
    if (!Platform.isAndroid) {
      return;
    }

    final texts = <String, String>{};
    var problemCount = 0;
    var ongoing = false;
    for (final session in imus) {
      final periods = session.sdProblems.periods;
      if (periods.isEmpty) {
        continue;
      }
      problemCount += periods.length;
      final last = periods.last;
      ongoing = ongoing || last.isOngoing;
      texts[session.displayName] = periods.length == 1
          ? last.notificationText
          : '${last.notificationText} (${periods.length} periods)';
    }
    if (texts.isEmpty) {
      clear();
      return;
    }

    final added = problemCount > _problemCount;
    final changed = added ||
        texts.length != _texts.length ||
        texts.entries.any((entry) => _texts[entry.key] != entry.value);
    _problemCount = problemCount;
    _texts
      ..clear()
      ..addAll(texts);
    if (!changed) {
      return;
    }

    final names = texts.keys.toList()..sort();
    final details = [
      for (final name in names) '$name: ${texts[name]}',
    ].join('; ');
    unawaited(
      AndroidAcquisitionForegroundService.showImuSdAlert(
        text: ongoing
            ? '$details. Until the SD saves again, the data are only in the app.'
            : '$details. The data of those periods are in the app.',
        alert: added,
      ),
    );
  }

  void clear() {
    if (_texts.isEmpty) {
      return;
    }
    _texts.clear();
    _problemCount = 0;
    unawaited(AndroidAcquisitionForegroundService.clearImuSdAlert());
  }
}

class _WearableStatusBoxes extends StatelessWidget {
  const _WearableStatusBoxes({
    required this.batteryPercent,
    required this.flushFailureRate,
    this.sdHealth,
    this.sdProblems,
    this.onSdProblemsTap,
    this.receptionMonitor,
    this.timeAlignment,
    this.calibrationInstruction,
    this.magCalibrationWarning,
    this.magnetometerWarning,
    this.noDataThreshold,
  });

  final int? batteryPercent;

  /// SD writes that failed in the last window, x100 (250 = 2.50%).
  final int? flushFailureRate;

  /// SD card state (IMUs with the 23-byte SDS packet); null with older
  /// firmware.
  final WearableSdHealth? sdHealth;

  /// SD problems of the acquisition (multi-device page): shown instead of
  /// [sdHealth], also after the SD saves again.
  final SdProblemHistory? sdProblems;

  /// Opens the list of the periods of [sdProblems].
  final VoidCallback? onSdProblemsTap;
  final WearableReceptionMonitor? receptionMonitor;

  /// Time alignment of the samples on the phone clock (null = not an IMU).
  final ImuTimeAlignment? timeAlignment;

  /// What to do with the IMU during a calibration.
  final String? calibrationInstruction;

  /// Failed magnetometer calibration (the IMU keeps its previous offset).
  final String? magCalibrationWarning;

  /// Magnetometer requested but not found by the IMU (data without it).
  final String? magnetometerWarning;

  /// Silence after which the indicator shows "No IMU data" (data watchdog).
  final Duration? noDataThreshold;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final batteryText =
        batteryPercent == null ? 'Battery: N/A' : 'Battery: $batteryPercent%';
    final rate = flushFailureRate;
    final flushFailureRateText = rate == null
        ? 'Flush failure rate: N/A'
        : 'Flush failure rate: ${(rate / 100).toStringAsFixed(2)}%';
    final sd = sdHealth;
    final problems = sdProblems;
    final sdOngoing = problems?.ongoing;
    final now = DateTime.now();

    final reception = _describeReception(
      receptionMonitor,
      DateTime.now(),
      noDataThreshold: noDataThreshold,
    );

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _WearableStatusBox(
                icon: Icons.battery_std,
                text: batteryText,
                iconColor: colorScheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _WearableStatusBox(
                icon: Icons.warning_amber_rounded,
                text: flushFailureRateText,
                iconColor: colorScheme.tertiary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _WearableStatusBox(
          icon: reception.icon,
          text: reception.text,
          iconColor: reception.color(colorScheme),
        ),
        if (timeAlignment != null) ...[
          const SizedBox(height: 12),
          _WearableStatusBox(
            icon: Icons.schedule,
            text: timeAlignment!.description,
            iconColor: _timeAlignmentColor(timeAlignment!.state, colorScheme),
          ),
        ],
        if (problems != null) ...[
          // The SD is not saving now.
          if (sdOngoing != null) ...[
            const SizedBox(height: 12),
            _WearableStatusBox(
              icon: Icons.sd_card_alert,
              text: '${sdOngoing.ongoingTextAt(now)}. '
                  'Data are saved only in the app.',
              iconColor: colorScheme.error,
            ),
          ],
          // Periods already over: one box for all of them, tap for the list.
          if (problems.periods.length > (sdOngoing == null ? 0 : 1)) ...[
            const SizedBox(height: 12),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onSdProblemsTap,
              child: _WearableStatusBox(
                icon: Icons.sd_card_alert,
                text: 'SD problems: ${problems.summaryAt(now)}. '
                    'Tap for details.',
                iconColor: Colors.orange.shade800,
              ),
            ),
          ],
        ] else if (sd != null && !sd.isSaving) ...[
          const SizedBox(height: 12),
          _WearableStatusBox(
            icon: Icons.sd_card_alert,
            text: '${sd.description}: data are saved only in the app',
            iconColor: colorScheme.error,
          ),
        ],
        if (calibrationInstruction != null) ...[
          const SizedBox(height: 12),
          _WearableStatusBox(
            icon: Icons.screen_rotation_alt,
            text: calibrationInstruction!,
            iconColor: colorScheme.primary,
          ),
        ],
        if (magnetometerWarning != null) ...[
          const SizedBox(height: 12),
          _WearableStatusBox(
            icon: Icons.explore_off,
            text: magnetometerWarning!,
            iconColor: colorScheme.error,
          ),
        ],
        if (magCalibrationWarning != null) ...[
          const SizedBox(height: 12),
          _WearableStatusBox(
            icon: Icons.explore_off,
            text: magCalibrationWarning!,
            iconColor: colorScheme.error,
          ),
        ],
      ],
    );
  }
}

class _WearableStatusBox extends StatelessWidget {
  const _WearableStatusBox({
    required this.icon,
    required this.text,
    required this.iconColor,
  });

  final IconData icon;
  final String text;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: iconColor),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MultiDeviceAcquisitionCompletedPage extends StatelessWidget {
  const _MultiDeviceAcquisitionCompletedPage({
    required this.csvLogger,
    this.sdProblems = const [],
  });

  final UnifiedAcquisitionCsvLogger csvLogger;

  /// IMUs whose SD did not save for some time during the acquisition.
  final List<_ImuSdProblems> sdProblems;

  Future<void> _downloadData(BuildContext context) async {
    try {
      await csvLogger.exportToDownloadsOrShare();
      if (!context.mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('CSV file saved successfully')),
      );
    } catch (_) {
      if (!context.mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save CSV file')),
      );
    }
  }

  /// SD problems of the acquisition, one line per IMU: for those periods the
  /// SD files are incomplete and the app data are the reference. A tap opens
  /// the list of the periods.
  Widget _buildSdSummary(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();

    return Material(
      color: theme.colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showSdProblemsDialog(context, sdProblems),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'SD card problems',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
              const SizedBox(height: 8),
              for (final imu in sdProblems)
                Text('${imu.deviceName}: ${imu.history.summaryAt(now)}'),
              const SizedBox(height: 8),
              const Text(
                'In these periods the SD files are incomplete: use the app '
                'data. Tap for the details.',
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _goHome(BuildContext context) {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(
        builder: (_) => const SectionPage(
          sectionName: 'user',
          message: 'Welcome to the user section!',
        ),
      ),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Acquisition completed'),
          automaticallyImplyLeading: false,
        ),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (sdProblems.isNotEmpty) ...[
                      _buildSdSummary(context),
                      const SizedBox(height: 24),
                    ],
                    FilledButton.icon(
                      icon: const Icon(Icons.download),
                      label: const Text('Download data'),
                      onPressed: () => unawaited(_downloadData(context)),
                    ),
                    const SizedBox(height: 24),
                    IconButton(
                      icon: const Icon(Icons.home),
                      iconSize: 40,
                      onPressed: () => _goHome(context),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// IMU settings of one device of the multi-device acquisition: it only
/// collects the configuration and hands it back, nothing is sent here.
class WearableDeviceConfigurationPage extends StatefulWidget {
  const WearableDeviceConfigurationPage({
    super.key,
    this.initialConfiguration,
    required this.onConfigurationConfirmed,
  });

  final WearableDeviceConfiguration? initialConfiguration;
  final ValueChanged<WearableDeviceConfiguration> onConfigurationConfirmed;

  @override
  State<WearableDeviceConfigurationPage> createState() =>
      _WearableDeviceConfigurationPageState();
}

class _WearableDeviceConfigurationPageState
    extends State<WearableDeviceConfigurationPage> {
  static const List<int> _odrValues = [12, 26, 52, 104, 208, 416];
  static const List<int> _accGValues = [2, 4, 8, 16];
  static const List<int> _gyrDPSValues = [125, 250, 500, 1000, 2000];
  static const int _maxMagnetometerOdr = 104;

  int odr = 104;
  int mag = 0;
  int accG = 8;
  int gyrDPS = 500;
  bool accEnabled = true;
  bool gyrEnabled = true;
  bool calibrationEnabled = false;
  bool magCalibrationEnabled = false;

  @override
  void initState() {
    super.initState();
    final initialConfiguration = widget.initialConfiguration;
    if (initialConfiguration != null) {
      odr = initialConfiguration.odr;
      mag = initialConfiguration.mag;
      accG = initialConfiguration.accG;
      gyrDPS = initialConfiguration.gyrDPS;
      accEnabled = initialConfiguration.accEnabled;
      gyrEnabled = initialConfiguration.gyrEnabled;
      calibrationEnabled = initialConfiguration.calibrationEnabled;
      magCalibrationEnabled = initialConfiguration.magCalibrationEnabled &&
          initialConfiguration.mag == 1;
    }
  }

  void _setMagnetometer(bool enabled) {
    setState(() {
      mag = enabled ? 1 : 0;
      if (!enabled) {
        magCalibrationEnabled = false;
      }
    });
  }

  void _setMagCalibration(bool enabled) {
    setState(() {
      magCalibrationEnabled = enabled;
    });
  }

  void _setAccelerometer(bool enabled) {
    setState(() {
      accEnabled = enabled;
    });
  }

  void _setGyroscope(bool enabled) {
    setState(() {
      gyrEnabled = enabled;
    });
  }

  void _setOdr(int value) {
    setState(() {
      odr = value;
      // The magnetometer goes through the LSM6DSO sensor hub: max 104 Hz.
      if (!_magnetometerAllowed) {
        mag = 0;
        magCalibrationEnabled = false;
      }
    });
  }

  bool get _magnetometerAllowed => odr <= _maxMagnetometerOdr;

  /// At least one sensor must be on.
  bool get _hasEnabledSensor => accEnabled || gyrEnabled || mag == 1;

  WearableDeviceConfiguration get _currentConfiguration {
    return WearableDeviceConfiguration(
      odr: odr,
      mag: mag,
      accG: accG,
      gyrDPS: gyrDPS,
      calibrationEnabled: calibrationEnabled,
      accEnabled: accEnabled,
      gyrEnabled: gyrEnabled,
      magCalibrationEnabled: magCalibrationEnabled && mag == 1,
    );
  }

  void _setCalibration(bool enabled) {
    setState(() {
      calibrationEnabled = enabled;
    });
  }

  void _confirmConfiguration() {
    if (!_hasEnabledSensor) {
      return;
    }
    widget.onConfigurationConfirmed(_currentConfiguration);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Device Configuration'),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildDropdownSetting(
                  label: 'Output Data Rate (Hz)',
                  value: odr,
                  values: _odrValues,
                  onChanged: _setOdr,
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Accelerometer'),
                  value: accEnabled,
                  onChanged: _setAccelerometer,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Gyroscope'),
                  value: gyrEnabled,
                  onChanged: _setGyroscope,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Magnetometer'),
                  subtitle: _magnetometerAllowed
                      ? null
                      : const Text(
                          'Available only up to $_maxMagnetometerOdr Hz',
                        ),
                  value: mag == 1,
                  onChanged: _magnetometerAllowed ? _setMagnetometer : null,
                ),
                if (!_hasEnabledSensor)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Turn on at least one sensor.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Calibration'),
                  subtitle: const Text(
                    'Accelerometer and gyroscope: keep the IMU still, flat '
                    'and face up.',
                  ),
                  value: calibrationEnabled,
                  onChanged: _setCalibration,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Magnetometer calibration'),
                  subtitle: Text(
                    mag == 1
                        ? 'Rotate the IMU slowly in all directions for '
                            '${WearableMagCalibrationResult.duration.inSeconds} '
                            's. The result stays saved in the IMU: needed '
                            'only once in a while.'
                        : 'Turn on the magnetometer first.',
                  ),
                  value: magCalibrationEnabled && mag == 1,
                  onChanged: mag == 1 ? _setMagCalibration : null,
                ),
                const SizedBox(height: 12),
                _buildDropdownSetting(
                  label: 'Accelerometer Full Scale Range (g)',
                  value: accG,
                  values: _accGValues,
                  enabled: accEnabled,
                  onChanged: (value) {
                    setState(() {
                      accG = value;
                    });
                  },
                ),
                const SizedBox(height: 12),
                _buildDropdownSetting(
                  label: 'Gyroscope Full Scale Range (dps)',
                  value: gyrDPS,
                  values: _gyrDPSValues,
                  enabled: gyrEnabled,
                  onChanged: (value) {
                    setState(() {
                      gyrDPS = value;
                    });
                  },
                ),
              ],
            ),
          ),
          SafeArea(
            minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                onPressed: _hasEnabledSensor ? _confirmConfiguration : null,
                child: const Text('Confirm Configuration'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDropdownSetting({
    required String label,
    required int value,
    required List<int> values,
    required ValueChanged<int> onChanged,
    bool enabled = true,
  }) {
    return DropdownButtonFormField<int>(
      initialValue: value,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      items: [
        for (final option in values)
          DropdownMenuItem<int>(
            value: option,
            child: Text(option.toString()),
          ),
      ],
      // null disables the field (sensor turned off).
      onChanged: enabled
          ? (selectedValue) {
              if (selectedValue == null) {
                return;
              }

              onChanged(selectedValue);
            }
          : null,
    );
  }
}

enum _WearableMetric {
  accelerometerX,
  accelerometerY,
  accelerometerZ,
  accelerometerMagnitude,
  gyroscopeX,
  gyroscopeY,
  gyroscopeZ,
  magnetometerX,
  magnetometerY,
  magnetometerZ,
}

/// Sensor ([WearableSensorMask] bit) a chart needs.
int _wearableMetricSensor(_WearableMetric metric) {
  return switch (metric) {
    _WearableMetric.accelerometerX ||
    _WearableMetric.accelerometerY ||
    _WearableMetric.accelerometerZ ||
    _WearableMetric.accelerometerMagnitude =>
      WearableSensorMask.accelerometer,
    _WearableMetric.gyroscopeX ||
    _WearableMetric.gyroscopeY ||
    _WearableMetric.gyroscopeZ =>
      WearableSensorMask.gyroscope,
    _WearableMetric.magnetometerX ||
    _WearableMetric.magnetometerY ||
    _WearableMetric.magnetometerZ =>
      WearableSensorMask.magnetometer,
  };
}

/// True if the sample carries the sensor of this chart (absent sensors are
/// sent as 0 and must not be plotted).
bool _wearableMetricInSample(_WearableMetric metric, WearableAgmSample sample) {
  return (sample.sensorMask & _wearableMetricSensor(metric)) != 0;
}

/// Charts to show for the sensors requested in the configuration (null =
/// unknown: accelerometer and gyroscope, as before).
List<_WearableMetricDefinition> _wearableMetricDefinitionsFor(int? sensorMask) {
  final mask = sensorMask ?? WearableSensorMask.accelerometerGyroscope;
  return [
    for (final definition in _wearableMetricDefinitions)
      if ((mask & _wearableMetricSensor(definition.metric)) != 0) definition,
  ];
}

enum _ReceptionLevel { good, warning, bad, unknown }

/// Text, icon and color of the "samples received" indicator.
class _ReceptionDescription {
  const _ReceptionDescription(this.text, this.level);

  final String text;
  final _ReceptionLevel level;

  IconData get icon {
    return switch (level) {
      _ReceptionLevel.good => Icons.check_circle,
      _ReceptionLevel.warning => Icons.error_outline,
      _ReceptionLevel.bad => Icons.cancel,
      _ReceptionLevel.unknown => Icons.help_outline,
    };
  }

  Color color(ColorScheme colorScheme) {
    return switch (level) {
      _ReceptionLevel.good => Colors.green.shade600,
      _ReceptionLevel.warning => Colors.orange.shade700,
      _ReceptionLevel.bad => colorScheme.error,
      _ReceptionLevel.unknown => colorScheme.outline,
    };
  }
}

/// Icon color of the time-alignment indicator.
Color _timeAlignmentColor(
  ImuTimeAlignmentState state,
  ColorScheme colorScheme,
) {
  return switch (state) {
    ImuTimeAlignmentState.waiting => colorScheme.outline,
    ImuTimeAlignmentState.aligning => colorScheme.primary,
    ImuTimeAlignmentState.aligned => Colors.green.shade600,
    ImuTimeAlignmentState.uncertain => Colors.orange.shade700,
  };
}

/// Green >= 99%, orange >= 95%, red below or when nothing arrived for
/// [noDataThreshold] (2 s at 104 Hz, data watchdog; 3 s if not given).
_ReceptionDescription _describeReception(
  WearableReceptionMonitor? monitor,
  DateTime now, {
  Duration? noDataThreshold,
}) {
  if (monitor == null) {
    return const _ReceptionDescription(
      'Samples received (10 s): N/A',
      _ReceptionLevel.unknown,
    );
  }

  final silence = monitor.timeSinceLastPacket(now);
  if (silence == null) {
    return const _ReceptionDescription(
      'Samples received (10 s): waiting for data',
      _ReceptionLevel.unknown,
    );
  }
  if (silence >= (noDataThreshold ?? const Duration(seconds: 3))) {
    return _ReceptionDescription(
      'No IMU data for ${silence.inSeconds} s',
      _ReceptionLevel.bad,
    );
  }

  final percent = monitor.receivedPercent(now);
  if (percent == null) {
    return const _ReceptionDescription(
      'Samples received (10 s): N/A',
      _ReceptionLevel.unknown,
    );
  }

  final level = percent >= 99.0
      ? _ReceptionLevel.good
      : percent >= 95.0
          ? _ReceptionLevel.warning
          : _ReceptionLevel.bad;
  return _ReceptionDescription(
    'Samples received (10 s): ${percent.toStringAsFixed(1)}%',
    level,
  );
}

const List<_WearableMetricDefinition> _wearableMetricDefinitions = [
  _WearableMetricDefinition(
    metric: _WearableMetric.accelerometerX,
    label: 'Accelerometer X',
    unit: 'g',
    decimals: 3,
    showZeroLine: true,
  ),
  _WearableMetricDefinition(
    metric: _WearableMetric.accelerometerY,
    label: 'Accelerometer Y',
    unit: 'g',
    decimals: 3,
    showZeroLine: true,
  ),
  _WearableMetricDefinition(
    metric: _WearableMetric.accelerometerZ,
    label: 'Accelerometer Z',
    unit: 'g',
    decimals: 3,
    showZeroLine: true,
  ),
  _WearableMetricDefinition(
    metric: _WearableMetric.accelerometerMagnitude,
    label: 'Accelerometer Magnitude',
    unit: 'g',
    decimals: 3,
  ),
  _WearableMetricDefinition(
    metric: _WearableMetric.gyroscopeX,
    label: 'Gyroscope X',
    unit: 'dps',
    decimals: 2,
  ),
  _WearableMetricDefinition(
    metric: _WearableMetric.gyroscopeY,
    label: 'Gyroscope Y',
    unit: 'dps',
    decimals: 2,
  ),
  _WearableMetricDefinition(
    metric: _WearableMetric.gyroscopeZ,
    label: 'Gyroscope Z',
    unit: 'dps',
    decimals: 2,
  ),
  _WearableMetricDefinition(
    metric: _WearableMetric.magnetometerX,
    label: 'Magnetometer X',
    unit: 'uT',
    decimals: 2,
    showZeroLine: true,
  ),
  _WearableMetricDefinition(
    metric: _WearableMetric.magnetometerY,
    label: 'Magnetometer Y',
    unit: 'uT',
    decimals: 2,
    showZeroLine: true,
  ),
  _WearableMetricDefinition(
    metric: _WearableMetric.magnetometerZ,
    label: 'Magnetometer Z',
    unit: 'uT',
    decimals: 2,
    showZeroLine: true,
  ),
];

class _WearableMetricDefinition {
  const _WearableMetricDefinition({
    required this.metric,
    required this.label,
    required this.unit,
    required this.decimals,
    this.showZeroLine = false,
  });

  final _WearableMetric metric;
  final String label;
  final String unit;
  final int decimals;
  final bool showZeroLine;

  String formatValue(double value) {
    return '${value.toStringAsFixed(decimals)} $unit';
  }
}

class _WearableMetricSeries {
  final List<_WearableChartSample> visibleSamples = [];

  int count = 0;
  double sum = 0;
  double? min;
  double? max;
  double? latest;

  double? get mean => count == 0 ? null : sum / count;

  /// [time] = aligned phone time of the sample (tp). When the alignment
  /// line is refitted the new times can start a few ms before the last
  /// drawn ones: those last points are removed, so the line never goes back.
  void addSample({
    required DateTime time,
    required double value,
  }) {
    while (visibleSamples.isNotEmpty &&
        !visibleSamples.last.time.isBefore(time)) {
      visibleSamples.removeLast();
    }
    visibleSamples.add(
      _WearableChartSample(
        time: time,
        value: value,
      ),
    );

    count++;
    sum += value;
    latest = value;
    min = min == null ? value : math.min(min!, value);
    max = max == null ? value : math.max(max!, value);
  }

  void pruneBefore(DateTime cutoff) {
    while (visibleSamples.isNotEmpty &&
        visibleSamples.first.time.isBefore(cutoff)) {
      visibleSamples.removeAt(0);
    }
  }
}

class _WearableChartSample {
  const _WearableChartSample({
    required this.time,
    required this.value,
  });

  /// Aligned phone time of the sample (tp).
  final DateTime time;
  final double value;
}

class _WearableMetricChartCard extends StatelessWidget {
  const _WearableMetricChartCard({
    required this.definition,
    required this.series,
    required this.windowEnd,
    required this.windowDuration,
    required this.formatTime,
  });

  final _WearableMetricDefinition definition;
  final _WearableMetricSeries series;
  final DateTime? windowEnd;
  final Duration windowDuration;
  final String Function(DateTime value) formatTime;

  static const int _yAxisLabelCount = 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    definition.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  definition.unit,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 180,
              child: series.visibleSamples.isEmpty || windowEnd == null
                  ? _buildEmptyChartPlaceholder(context)
                  : _buildChart(context),
            ),
            const SizedBox(height: 10),
            _buildStatistics(context),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyChartPlaceholder(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Center(
        child: Text(
          'No data received yet',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }

  Widget _buildChart(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final end = windowEnd!;
    final start = end.subtract(windowDuration);
    final windowSeconds = windowDuration.inMilliseconds / 1000;
    final spots = series.visibleSamples.map((sample) {
      final seconds = sample.time.difference(start).inMilliseconds / 1000;
      return FlSpot(seconds.clamp(0, windowSeconds).toDouble(), sample.value);
    }).toList(growable: false);

    var minY = series.visibleSamples.first.value;
    var maxY = series.visibleSamples.first.value;
    for (final sample in series.visibleSamples.skip(1)) {
      minY = math.min(minY, sample.value);
      maxY = math.max(maxY, sample.value);
    }

    if (definition.showZeroLine) {
      minY = math.min(minY, 0);
      maxY = math.max(maxY, 0);
    }

    final yRange = maxY - minY;
    final yPadding = yRange == 0
        ? (definition.unit == 'dps' ? 0.1 : 0.01)
        : yRange * 0.12;
    final chartMinY = minY - yPadding;
    final chartMaxY = maxY + yPadding;
    final yAxisValues = _buildYAxisValues(chartMinY, chartMaxY);
    final yAxisInterval = _yAxisInterval(chartMinY, chartMaxY);
    final yAxisLabelStyle = theme.textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
      fontSize: 11,
    );

    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6, right: 4),
          child: LineChart(
            LineChartData(
              minX: 0,
              maxX: windowSeconds,
              minY: chartMinY,
              maxY: chartMaxY,
              gridData: FlGridData(
                show: true,
                horizontalInterval: yAxisInterval,
                verticalInterval: 1,
                checkToShowHorizontalLine: (value) =>
                    _isYAxisValue(value, yAxisValues),
                getDrawingHorizontalLine: (_) => FlLine(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.7),
                  strokeWidth: 0.8,
                ),
                getDrawingVerticalLine: (_) => FlLine(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.35),
                  strokeWidth: 0.6,
                ),
              ),
              titlesData: FlTitlesData(
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 48,
                    interval: yAxisInterval,
                    getTitlesWidget: (value, meta) {
                      if (!_isYAxisValue(value, yAxisValues)) {
                        return const SizedBox.shrink();
                      }

                      return SideTitleWidget(
                        meta: meta,
                        space: 6,
                        child: Text(
                          value.toStringAsFixed(definition.decimals),
                          style: yAxisLabelStyle,
                        ),
                      );
                    },
                  ),
                ),
                topTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                rightTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 28,
                    interval: 1,
                    getTitlesWidget: (value, meta) {
                      final rounded = value.roundToDouble();
                      if ((value - rounded).abs() > 0.001 ||
                          rounded < 0 ||
                          rounded > windowSeconds) {
                        return const SizedBox.shrink();
                      }

                      final labelTime = start.add(
                        Duration(milliseconds: (rounded * 1000).round()),
                      );
                      return SideTitleWidget(
                        meta: meta,
                        space: 6,
                        child: Text(
                          formatTime(labelTime),
                          style: yAxisLabelStyle,
                        ),
                      );
                    },
                  ),
                ),
              ),
              extraLinesData: ExtraLinesData(
                horizontalLines: [
                  if (definition.showZeroLine)
                    HorizontalLine(
                      y: 0,
                      color:
                          colorScheme.onSurfaceVariant.withValues(alpha: 0.42),
                      strokeWidth: 1,
                      dashArray: const [6, 4],
                    ),
                ],
              ),
              borderData: FlBorderData(
                show: true,
                border: Border(
                  left: BorderSide(color: colorScheme.outlineVariant),
                  bottom: BorderSide(color: colorScheme.outlineVariant),
                  right: BorderSide(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.35),
                  ),
                  top: BorderSide(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.35),
                  ),
                ),
              ),
              lineTouchData: const LineTouchData(enabled: false),
              lineBarsData: [
                LineChartBarData(
                  spots: spots,
                  isCurved: false,
                  color: colorScheme.primary,
                  barWidth: 2.4,
                  dotData: FlDotData(show: spots.length == 1),
                  belowBarData: BarAreaData(
                    show: true,
                    color: colorScheme.primary.withValues(alpha: 0.08),
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          top: 10,
          right: 12,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colorScheme.surface.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colorScheme.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text(
                series.latest == null
                    ? 'N/A'
                    : definition.formatValue(series.latest!),
                maxLines: 1,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatistics(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final minText = series.min == null
        ? 'Min: N/A'
        : 'Min: ${definition.formatValue(series.min!)}';
    final maxText = series.max == null
        ? 'Max: N/A'
        : 'Max: ${definition.formatValue(series.max!)}';
    final meanText = series.mean == null
        ? 'Mean: N/A'
        : 'Mean: ${definition.formatValue(series.mean!)}';
    final style = theme.textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );

    return Wrap(
      spacing: 18,
      runSpacing: 4,
      children: [
        Text(minText, style: style),
        Text(maxText, style: style),
        Text(meanText, style: style),
      ],
    );
  }

  List<double> _buildYAxisValues(double minY, double maxY) {
    final interval = _yAxisInterval(minY, maxY);

    return List<double>.generate(
      _yAxisLabelCount,
      (index) => minY + interval * index,
      growable: false,
    );
  }

  double _yAxisInterval(double minY, double maxY) {
    final range = (maxY - minY).abs();
    if (!range.isFinite || range <= 0) {
      return 1;
    }

    return range / (_yAxisLabelCount - 1);
  }

  bool _isYAxisValue(double value, List<double> yAxisValues) {
    const tolerance = 0.000001;

    return yAxisValues.any((axisValue) {
      final scale = math.max(1.0, axisValue.abs());
      return (value - axisValue).abs() <= tolerance * scale;
    });
  }
}

/// Settings of one environmental monitor of the multi-device acquisition: it
/// only collects the configuration and hands it back, nothing is sent here.
class DeviceConfigurationPage extends StatefulWidget {
  const DeviceConfigurationPage({
    super.key,
    this.initialConfiguration,
    required this.onConfigurationConfirmed,
  });

  final BleConfiguration? initialConfiguration;
  final ValueChanged<BleConfiguration> onConfigurationConfirmed;

  @override
  State<DeviceConfigurationPage> createState() =>
      _DeviceConfigurationPageState();
}

class _DeviceConfigurationPageState extends State<DeviceConfigurationPage> {
  static final List<String> _measurementOptions = [
    for (final definition in _measurementDefinitions) definition.label,
  ];

  final Map<String, bool> _options = {
    'CO2': false,
    'CO': false,
    'NH3': false,
    'NO2': false,
    'VOC': false,
    'NOX': false,
    'VOC Index': false,
    'NOX Index': false,
    'PM1.0': false,
    'PM2.5': false,
    'PM10': false,
    'Internal Temperature': false,
    'External Temperature': false,
    'Internal Humidity': false,
    'External Humidity': false,
    'Atmospheric Pressure': false,
    'SD Card Storage': true,
    'Fan': false,
  };

  static const List<int> _samplingFrequencies = [
    15,
    30,
    45,
    60,
    75,
    90,
    105,
    120,
  ];

  int _samplingFrequencyIndex = 0;

  int get _selectedSamplingFrequency {
    return _samplingFrequencies[_samplingFrequencyIndex];
  }

  bool get _allMeasurementsEnabled {
    return _measurementOptions.every((option) => _options[option] ?? false);
  }

  @override
  void initState() {
    super.initState();
    final initialConfiguration = widget.initialConfiguration;
    if (initialConfiguration == null) {
      return;
    }

    _options
      ..clear()
      ..addAll(initialConfiguration.enabledOptions);
    _samplingFrequencyIndex = _samplingFrequencies.indexOf(
      initialConfiguration.samplingFrequencySeconds,
    );
    if (_samplingFrequencyIndex < 0) {
      _samplingFrequencyIndex = 0;
    }
  }

  void _setAllMeasurements(bool value) {
    setState(() {
      for (final option in _measurementOptions) {
        _options[option] = value;
      }
    });
  }

  void _setOption(String option, bool value) {
    setState(() {
      _options[option] = value;
    });
  }

  void _setSamplingFrequency(double value) {
    setState(() {
      _samplingFrequencyIndex = value.round();
    });
  }

  void _confirmConfiguration() {
    widget.onConfigurationConfirmed(
      BleConfiguration(
        enabledOptions: Map<String, bool>.from(_options),
        samplingFrequencySeconds: _selectedSamplingFrequency,
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Device Configuration'),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('All Measurements'),
                  value: _allMeasurementsEnabled,
                  onChanged: _setAllMeasurements,
                ),
                const SizedBox(height: 8),
                ..._buildSwitchGroup(_measurementOptions),
                const Divider(height: 32),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('SD Card Storage'),
                  value: true,
                  onChanged: null,
                ),
                const Divider(height: 32),
                ..._buildSwitchGroup(['Fan']),
                const Divider(height: 32),
                Text(
                  'Sampling Frequency',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                Text(
                  'Sampling Frequency: $_selectedSamplingFrequency s',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                Slider(
                  value: _samplingFrequencyIndex.toDouble(),
                  min: 0,
                  max: (_samplingFrequencies.length - 1).toDouble(),
                  divisions: _samplingFrequencies.length - 1,
                  label: '$_selectedSamplingFrequency s',
                  onChanged: _setSamplingFrequency,
                ),
              ],
            ),
          ),
          SafeArea(
            minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                onPressed: _confirmConfiguration,
                child: const Text('Confirm Configuration'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildSwitchGroup(List<String> options) {
    return options.map((option) {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(option),
        value: _options[option] ?? false,
        onChanged: (value) => _setOption(option, value),
      );
    }).toList();
  }
}

const List<_MeasurementDefinition> _measurementDefinitions = [
  _MeasurementDefinition(label: 'CO2', prefix: 'CO2', unit: 'ppm'),
  _MeasurementDefinition(label: 'CO', prefix: 'CO', unit: 'ppm'),
  _MeasurementDefinition(label: 'NH3', prefix: 'NH3', unit: 'ppm'),
  _MeasurementDefinition(label: 'NO2', prefix: 'NO2', unit: 'ppb'),
  _MeasurementDefinition(label: 'VOC', prefix: 'VOC', unit: 'raw'),
  _MeasurementDefinition(label: 'NOX', prefix: 'NOX', unit: 'raw'),
  _MeasurementDefinition(label: 'VOC Index', prefix: 'VOCi', unit: 'index'),
  _MeasurementDefinition(label: 'NOX Index', prefix: 'NOXi', unit: 'index'),
  _MeasurementDefinition(label: 'PM1.0', prefix: 'PM1.0', unit: 'µg/m³'),
  _MeasurementDefinition(label: 'PM2.5', prefix: 'PM2.5', unit: 'µg/m³'),
  _MeasurementDefinition(label: 'PM10', prefix: 'PM10', unit: 'µg/m³'),
  _MeasurementDefinition(
    label: 'Internal Temperature',
    prefix: 'TEM1',
    unit: '°C',
  ),
  _MeasurementDefinition(
    label: 'External Temperature',
    prefix: 'TEM2',
    unit: '°C',
  ),
  _MeasurementDefinition(
    label: 'Internal Humidity',
    prefix: 'HUM1',
    unit: '%RH',
  ),
  _MeasurementDefinition(
    label: 'External Humidity',
    prefix: 'HUM2',
    unit: '%RH',
  ),
  _MeasurementDefinition(
    label: 'Atmospheric Pressure',
    prefix: 'PRE',
    unit: 'Pa',
  ),
];

const List<_MeasurementDefinition> _environmentalV2MeasurementDefinitions = [
  _MeasurementDefinition(
    label: 'PM1',
    prefix: EnvironmentalV2MessageTypes.pm1,
    unit: '\u00B5g/m\u00B3',
  ),
  _MeasurementDefinition(
    label: 'PM2.5',
    prefix: EnvironmentalV2MessageTypes.pm25,
    unit: '\u00B5g/m\u00B3',
  ),
  _MeasurementDefinition(
    label: 'PM10',
    prefix: EnvironmentalV2MessageTypes.pm10,
    unit: '\u00B5g/m\u00B3',
  ),
  _MeasurementDefinition(
    label: 'VOC Index',
    prefix: EnvironmentalV2MessageTypes.vocIndex,
    unit: 'index',
  ),
  _MeasurementDefinition(
    label: 'NOX Index',
    prefix: EnvironmentalV2MessageTypes.noxIndex,
    unit: 'index',
  ),
  _MeasurementDefinition(
    label: 'Temperature',
    prefix: EnvironmentalV2MessageTypes.temperature,
    unit: '\u00B0C',
  ),
  _MeasurementDefinition(
    label: 'Humidity',
    prefix: EnvironmentalV2MessageTypes.humidity,
    unit: '%',
  ),
  _MeasurementDefinition(
    label: 'CO2',
    prefix: EnvironmentalV2MessageTypes.co2,
    unit: 'ppm',
  ),
  _MeasurementDefinition(
    label: 'Date',
    prefix: EnvironmentalV2MessageTypes.date,
    unit: '',
    chartEnabled: false,
  ),
  _MeasurementDefinition(
    label: 'Time',
    prefix: EnvironmentalV2MessageTypes.time,
    unit: '',
    chartEnabled: false,
  ),
  _MeasurementDefinition(
    label: 'Latitude',
    prefix: EnvironmentalV2MessageTypes.latitude,
    unit: '\u00B0',
    chartEnabled: false,
  ),
  _MeasurementDefinition(
    label: 'Longitude',
    prefix: EnvironmentalV2MessageTypes.longitude,
    unit: '\u00B0',
    chartEnabled: false,
  ),
  _MeasurementDefinition(
    label: 'Acc x',
    prefix: EnvironmentalV2MessageTypes.accelerometerX,
    unit: 'g',
  ),
  _MeasurementDefinition(
    label: 'Acc y',
    prefix: EnvironmentalV2MessageTypes.accelerometerY,
    unit: 'g',
  ),
  _MeasurementDefinition(
    label: 'Acc z',
    prefix: EnvironmentalV2MessageTypes.accelerometerZ,
    unit: 'g',
  ),
  _MeasurementDefinition(
    label: 'Activity',
    prefix: EnvironmentalV2MessageTypes.activity,
    unit: '',
    chartEnabled: false,
  ),
];

class _MeasurementDefinition {
  const _MeasurementDefinition({
    required this.label,
    required this.prefix,
    required this.unit,
    this.chartEnabled = true,
  });

  final String label;
  final String prefix;
  final String unit;
  final bool chartEnabled;
}

class _LiveMeasurementValue {
  const _LiveMeasurementValue({
    required this.formattedValue,
    required this.updatedAt,
    required this.updateCount,
  });

  final String formattedValue;
  final DateTime updatedAt;
  final int updateCount;
}

class _MeasurementChartSample {
  const _MeasurementChartSample({
    required this.receivedAt,
    required this.value,
  });

  final DateTime receivedAt;
  final double value;
}

enum _LiveVisualizationMode {
  cards,
  charts,
}

class _LiveMeasurementCard extends StatelessWidget {
  const _LiveMeasurementCard({
    required this.definition,
    required this.value,
    required this.updatedAtText,
  });

  final _MeasurementDefinition definition;
  final _LiveMeasurementValue? value;
  final String updatedAtText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final updateCount = value?.updateCount ?? 0;
    final valueText = value == null
        ? '—'
        : definition.unit.isEmpty
            ? value!.formattedValue
            : '${value!.formattedValue} ${definition.unit}';

    return TweenAnimationBuilder<double>(
      key: ValueKey('${definition.prefix}-$updateCount'),
      tween: Tween<double>(begin: updateCount == 0 ? 0 : 1, end: 0),
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
      builder: (context, highlight, child) {
        final backgroundColor = Color.lerp(
          colorScheme.surface,
          colorScheme.primaryContainer,
          highlight * 0.55,
        )!;
        final borderColor = Color.lerp(
          colorScheme.outlineVariant,
          colorScheme.primary,
          highlight,
        )!;

        return Transform.scale(
          scale: 1 + (highlight * 0.025),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: borderColor, width: 1.2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: 0.04 + highlight * 0.04,
                  ),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    definition.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  SizedBox(
                    width: double.infinity,
                    child: FittedBox(
                      alignment: Alignment.centerLeft,
                      fit: BoxFit.scaleDown,
                      child: Text(
                        valueText,
                        maxLines: 1,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: colorScheme.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'Last update: $updatedAtText',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
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

class _LiveMeasurementChartCard extends StatelessWidget {
  const _LiveMeasurementChartCard({
    required this.definition,
    required this.samples,
    required this.currentValue,
    required this.formatTime,
  });

  final _MeasurementDefinition definition;
  final List<_MeasurementChartSample> samples;
  final _LiveMeasurementValue? currentValue;
  final String Function(DateTime value) formatTime;

  static const int _maxVisibleSamples = 40;
  static const int _yAxisLabelCount = 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final visibleSamples = _visibleSamples;
    final currentValueText = currentValue == null
        ? '—'
        : definition.unit.isEmpty
            ? currentValue!.formattedValue
            : '${currentValue!.formattedValue} ${definition.unit}';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    definition.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  definition.unit,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 180,
              child: visibleSamples.isEmpty
                  ? _buildEmptyChartPlaceholder(context)
                  : _buildChart(context, currentValueText, visibleSamples),
            ),
            const SizedBox(height: 8),
            if (visibleSamples.isEmpty)
              Text(
                'No data received yet',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              )
            else
              Row(
                children: [
                  Text(
                    formatTime(visibleSamples.first.receivedAt),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    formatTime(visibleSamples.last.receivedAt),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  List<_MeasurementChartSample> get _visibleSamples {
    if (samples.length <= _maxVisibleSamples) {
      return samples;
    }

    return samples.sublist(samples.length - _maxVisibleSamples);
  }

  Widget _buildEmptyChartPlaceholder(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Center(
        child: Text(
          'No data received yet',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }

  Widget _buildChart(
    BuildContext context,
    String currentValueText,
    List<_MeasurementChartSample> visibleSamples,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final firstSampleTime = visibleSamples.first.receivedAt;
    final spots = visibleSamples.map((sample) {
      final seconds = sample.receivedAt
              .difference(firstSampleTime)
              .inMilliseconds /
          1000;
      return FlSpot(seconds, sample.value);
    }).toList(growable: false);

    var minY = visibleSamples.first.value;
    var maxY = visibleSamples.first.value;
    for (final sample in visibleSamples.skip(1)) {
      minY = math.min(minY, sample.value);
      maxY = math.max(maxY, sample.value);
    }

    final yRange = maxY - minY;
    final yPadding = yRange == 0
        ? math.max(1.0, maxY.abs() * 0.1)
        : yRange * 0.12;
    final maxX = math.max(1.0, spots.last.x);
    final chartMinY = minY - yPadding;
    final chartMaxY = maxY + yPadding;
    final yAxisValues = _buildYAxisValues(chartMinY, chartMaxY);
    final yAxisInterval = _yAxisInterval(chartMinY, chartMaxY);
    final yAxisLabelStyle = theme.textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
      fontSize: 11,
    );

    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6, right: 4),
          child: LineChart(
            LineChartData(
              minX: 0,
              maxX: maxX,
              minY: chartMinY,
              maxY: chartMaxY,
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: yAxisInterval,
                checkToShowHorizontalLine: (value) =>
                    _isYAxisValue(value, yAxisValues),
                getDrawingHorizontalLine: (_) => FlLine(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.7),
                  strokeWidth: 0.8,
                ),
              ),
              titlesData: FlTitlesData(
                leftTitles: AxisTitles(
                  axisNameSize: 24,
                  axisNameWidget: Text(
                    definition.unit,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 38,
                    interval: yAxisInterval,
                    getTitlesWidget: (value, meta) {
                      if (!_isYAxisValue(value, yAxisValues)) {
                        return const SizedBox.shrink();
                      }

                      return SideTitleWidget(
                        meta: meta,
                        space: 6,
                        child: Text(
                          value.toStringAsFixed(1),
                          style: yAxisLabelStyle,
                        ),
                      );
                    },
                  ),
                ),
                topTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                rightTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                bottomTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
              ),
              borderData: FlBorderData(
                show: true,
                border: Border(
                  left: BorderSide(color: colorScheme.outlineVariant),
                  bottom: BorderSide(color: colorScheme.outlineVariant),
                  right: BorderSide(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.35),
                  ),
                  top: BorderSide(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.35),
                  ),
                ),
              ),
              lineTouchData: const LineTouchData(enabled: false),
              lineBarsData: [
                LineChartBarData(
                  spots: spots,
                  isCurved: false,
                  color: colorScheme.primary,
                  barWidth: 2.4,
                  dotData: FlDotData(show: visibleSamples.length == 1),
                  belowBarData: BarAreaData(
                    show: true,
                    color: colorScheme.primary.withValues(alpha: 0.08),
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          top: 10,
          right: 12,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colorScheme.surface.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colorScheme.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    currentValueText,
                    maxLines: 1,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<double> _buildYAxisValues(double minY, double maxY) {
    final interval = _yAxisInterval(minY, maxY);

    return List<double>.generate(
      _yAxisLabelCount,
      (index) => minY + interval * index,
      growable: false,
    );
  }

  double _yAxisInterval(double minY, double maxY) {
    final range = (maxY - minY).abs();
    if (!range.isFinite || range <= 0) {
      return 1;
    }

    return range / (_yAxisLabelCount - 1);
  }

  bool _isYAxisValue(double value, List<double> yAxisValues) {
    const tolerance = 0.000001;

    return yAxisValues.any((axisValue) {
      final scale = math.max(1.0, axisValue.abs());
      return (value - axisValue).abs() <= tolerance * scale;
    });
  }
}

class _CardsModeIcon extends StatelessWidget {
  const _CardsModeIcon();

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 22,
      child: CustomPaint(
        painter: _CardsModeIconPainter(
          color: IconTheme.of(context).color ??
              Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}

class _CardsModeIconPainter extends CustomPainter {
  const _CardsModeIconPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    final gap = size.width * 0.16;
    final squareSize = (size.width - gap) / 2;
    final radius = Radius.circular(size.width * 0.12);

    for (final offset in [
      Offset.zero,
      Offset(squareSize + gap, 0),
      Offset(0, squareSize + gap),
      Offset(squareSize + gap, squareSize + gap),
    ]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          offset & Size(squareSize, squareSize),
          radius,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CardsModeIconPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _ChartModeIcon extends StatelessWidget {
  const _ChartModeIcon();

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 22,
      child: CustomPaint(
        painter: _ChartModeIconPainter(
          color: IconTheme.of(context).color ??
              Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}

class _ChartModeIconPainter extends CustomPainter {
  const _ChartModeIconPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final axisPaint = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    final linePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final left = size.width * 0.16;
    final bottom = size.height * 0.82;
    final right = size.width * 0.9;
    final top = size.height * 0.16;

    canvas.drawLine(Offset(left, top), Offset(left, bottom), axisPaint);
    canvas.drawLine(Offset(left, bottom), Offset(right, bottom), axisPaint);

    final path = Path()
      ..moveTo(left + size.width * 0.06, bottom - size.height * 0.16)
      ..lineTo(left + size.width * 0.22, bottom - size.height * 0.42)
      ..lineTo(left + size.width * 0.4, bottom - size.height * 0.28)
      ..lineTo(left + size.width * 0.58, bottom - size.height * 0.58)
      ..lineTo(right - size.width * 0.03, bottom - size.height * 0.5);
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _ChartModeIconPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
