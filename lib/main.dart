import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:app_lares/ble_configuration_service.dart';
import 'package:app_lares/environmental_v2_ble_service.dart';
import 'package:app_lares/environmental_v2_configuration.dart';
import 'package:app_lares/environmental_v2_configuration_page.dart';
import 'package:app_lares/environmental_v2_message_parser.dart';
import 'package:app_lares/polar_h10/polar_h10_configuration.dart';
import 'package:app_lares/polar_h10/polar_h10_configuration_page.dart';
import 'package:app_lares/polar_h10/polar_h10_event.dart';
import 'package:app_lares/polar_h10/polar_h10_models.dart';
import 'package:app_lares/polar_h10/polar_h10_platform_service.dart';
import 'package:app_lares/services/acquisition_recovery_store.dart';
import 'package:app_lares/services/acquisition_csv_logger.dart';
import 'package:app_lares/services/android_acquisition_foreground_service.dart';
import 'package:app_lares/services/gps_location_service.dart';
import 'package:app_lares/services/environmental_open_remote.dart';
import 'package:app_lares/services/mqtt_service.dart';
import 'package:app_lares/services/pm10_parser.dart';
import 'package:app_lares/services/respiratory_device_name_store.dart';
import 'package:app_lares/services/unified_acquisition_csv_logger.dart';
import 'package:app_lares/services/wearable_acquisition_csv_logger.dart';
import 'package:app_lares/wearable_agm_packet_parser.dart';
import 'package:app_lares/wearable_configuration_service.dart';
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
  });

  final int odr;
  final int mag;
  final int accG;
  final int gyrDPS;
  final bool calibrationEnabled;
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
      'mag=${configuration.mag}; '
      'accG=${configuration.accG}; '
      'gyrDPS=${configuration.gyrDPS}; '
      'calibrationEnabled=${configuration.calibrationEnabled}';
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
    required this.onReconnect,
    this.reconnectEnabled = true,
    this.failureMessage,
  });

  final String id;
  final String deviceName;
  final _BleReconnectStatus status;
  final VoidCallback onReconnect;
  final bool reconnectEnabled;
  final String? failureMessage;

  bool get isReconnecting => status == _BleReconnectStatus.reconnecting;

  bool get canReconnect => reconnectEnabled && !isReconnecting;
}

class _BleDisconnectionAlertDialog extends StatelessWidget {
  const _BleDisconnectionAlertDialog({
    required this.items,
    required this.onClose,
  });

  final List<_BleDisconnectionAlertItem> items;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 18, 8, 0),
      title: Row(
        children: [
          Expanded(
            child: Text(
              'BLE device disconnected',
              style: theme.textTheme.titleLarge,
            ),
          ),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: onClose,
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'The app will automatically attempt to reconnect every 10 seconds. You can also move closer to the phone and tap Reconnect to retry immediately.',
            ),
            const SizedBox(height: 16),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 340),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: items.length,
                separatorBuilder: (_, _) => const Divider(height: 20),
                itemBuilder: (context, index) {
                  final item = items[index];
                  return _BleDisconnectionAlertDeviceRow(item: item);
                },
              ),
            ),
          ],
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
        const SizedBox(width: 12),
        FilledButton(
          onPressed: item.canReconnect ? item.onReconnect : null,
          child: const Text('Reconnect'),
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

  static const Duration retryDelay = Duration(seconds: 10);

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

  bool get isOperationInProgress => _operationInProgress;

  Future<void> waitForIdle() async { await _inFlight; }

  void start() {
    if (_active || !_canRun) {
      return;
    }

    _active = true;
    _generation += 1;
    unawaited(_startOperation(_generation, runAutomaticCycle));
  }

  Future<void> requestImmediate({
    Future<void> Function()? operation,
  }) {
    if (!_canRun) {
      return Future<void>.value();
    }

    if (!_active) {
      _active = true;
      _generation += 1;
    }

    _retryTimer?.cancel();
    _retryTimer = null;
    if (_operationInProgress) {
      _notify();
      return Future<void>.value();
    }

    return _startOperation(_generation, operation ?? runAutomaticCycle);
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
  DateTime? latestWearableSampleReceivedAt;
  int? latestBatteryPercent;
  int? latestFlushFailureRate;
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
  }

  static Future<void> restore(AcquisitionRecoverySnapshot snapshot) =>
      _restoreMultiDeviceAcquisition(snapshot);

  // Recovery helpers notify through the owner, where ChangeNotifier's
  // protected notification API belongs.
  void _notifySessionChanged() {
    notifyListeners();
  }

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
  final UnifiedAcquisitionCsvLogger csvLogger = UnifiedAcquisitionCsvLogger();
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
  Future<void>? _androidStopFuture;
  String? backgroundStatusMessage;

  List<_ConnectedDeviceSession> get sessions => List.unmodifiable(_sessions);

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

  bool get allConnectedDevicesConfigured {
    final connectedSessions = _sessions.where((session) => session.isConnected);
    return connectedSessions.isNotEmpty &&
        connectedSessions.every((session) => session.isConfigured);
  }

  bool get isStopping => _isStopping;

  bool get isBleReconnectOperationInProgress =>
      _bleAutoReconnectCoordinator.isOperationInProgress;

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
    try {
    _invalidateOpenRemoteLocationAuthorization();
    if (Platform.isAndroid) _startedAt = DateTime.now();
    await csvLogger.start(startedAt: _startedAt, sessionId: _sessionId);
    await gpsLocationService.start();
    _openRemoteLocationSubscription ??= gpsLocationService.livePositions.listen(
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
        if (!session.isConnected) {
          throw StateError('${session.displayName} is disconnected.');
        }
        if (!session.isConfigured) {
          throw StateError('${session.displayName} is not configured.');
        }

        session
          ..isInitializing = true
          ..errorMessage = null;
        notifyListeners();

        switch (session.type) {
          case KnownDeviceType.environmentalMonitor:
            await _initializeEnvironmental(session);
            break;
          case KnownDeviceType.environmentalMonitorV2:
            await _initializeEnvironmentalV2(session);
            break;
          case KnownDeviceType.respiratoryMonitor:
            await _initializeWearable(session);
            break;
          case KnownDeviceType.polarH10:
            await _initializePolarH10(session);
            break;
          case KnownDeviceType.unsupported:
            throw StateError('${session.displayName} is unsupported.');
        }

        session
          ..isInitializing = false
          ..isInitialized = true;
        notifyListeners();
      }

      _acquisitionStarted = true;
      _startedAt ??= DateTime.now();
      await _activateAndroidBackgroundSupport();
      if (Platform.isAndroid) await _startRuntimeStreams();
      notifyListeners();
    } catch (error) {
      await stopAll();
      _initializationStarted = false;
      rethrow;
    }
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

  Future<void> reconnectDisconnectedSession(
    _ConnectedDeviceSession session,
  ) async {
    if (!_canAttemptBleReconnect(session)) {
      return;
    }

    await _bleAutoReconnectCoordinator.requestImmediate(
      operation: () => _reconnectDisconnectedSessionOnce(session),
    );
  }

  void dismissAutomaticBleReconnectForSessions(
    Iterable<_ConnectedDeviceSession> sessions,
  ) {
    for (final session in sessions) {
      _dismissedBleAutoReconnectAlertKeys.add(_bleAutoReconnectAlertKey(session));
    }
    _bleAutoReconnectCoordinator.cancel();
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
        if (disconnectedSessionsDuringAcquisition.isEmpty) {
          unawaited(AndroidAcquisitionForegroundService.clearBleDisconnectionAlert());
        }
        notifyListeners();
      } catch (_) {
        if (!_canContinueAutomaticBleReconnect() ||
            !_sessions.contains(session)) {
          return;
        }
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
      if (disconnectedSessionsDuringAcquisition.isEmpty) {
        unawaited(AndroidAcquisitionForegroundService.clearBleDisconnectionAlert());
      }
      notifyListeners();
    } catch (_) {
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
    if (Platform.isAndroid) {
      final operation = _androidStopFuture ??= _stopAndroidResources();
      try {
        await operation;
      } catch (_) {
        _androidStopFuture = null;
        rethrow;
      }
      return;
    }
    if (_isStopping) {
      return;
    }

    _bleAutoReconnectCoordinator.cancel();
    _isStopping = true;
    if (Platform.isAndroid) await AcquisitionRecoveryStore.markStopping();
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
          final service = session.wearableService;
          if (service != null && !service.isStopped) {
            try {
              await service.stopAcquisition();
            } catch (_) {
              try {
                await service.dispose();
              } catch (_) {}
            }
          }
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
    await csvLogger.stop();
    await AndroidAcquisitionForegroundService.clearBleDisconnectionAlert();
    await AndroidAcquisitionForegroundService.stop();
    await AcquisitionRecoveryStore.clear();
    await _ActiveAcquisitionRuntime.markInactive();
    _foregroundServiceStarted = false;
    _acquisitionStarted = false;
    _isStopping = false;
    notifyListeners();
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

    session.connectionSubscription = session.bleDevice.connectionState.listen(
      (state) {
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

          if (_acquisitionStarted) {
            _markSessionDisconnectedDuringAcquisition(session);
          } else if (session.type ==
                  KnownDeviceType.environmentalMonitorV2 &&
              session.environmentalV2ConfigurationApplied &&
              _initializationStarted) {
            // Keep a configured V2 session until the live page can use the
            // normal acquisition reconnect flow. Notifications are not
            // started here.
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
    final service = WearableConfigurationBleService(
      session.bleDevice,
      onStateChanged: notifyListeners,
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
        notifyListeners();
      },
    );

    await service.initialize();
    if (!service.isReadyToContinue) {
      throw StateError('${session.displayName} BLE setup is not complete.');
    }

    await service.startConfigurationSequence(
      odr: configuration.odr,
      mag: configuration.mag,
      accG: configuration.accG,
      gyrDPS: configuration.gyrDPS,
      calibrationEnabled: configuration.calibrationEnabled,
    );

    final state = service.sequenceState == WearableBleSequenceState.streaming
        ? WearableBleSequenceState.streaming
        : await service.sequenceStateStream.firstWhere((state) {
            return state == WearableBleSequenceState.streaming ||
                state == WearableBleSequenceState.timeout ||
                state == WearableBleSequenceState.error ||
                state == WearableBleSequenceState.stopped;
          });
    if (state != WearableBleSequenceState.streaming) {
      throw StateError('${session.displayName} did not enter streaming mode.');
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
        await PolarH10PlatformService.forDevice(session.deviceId).startStreams(
          identity: session.polarIdentity,
          configuration: configuration,
        );
        session
          ..polarStreamsStarted = true
          ..polarStatus = _polarStreamingStatus(configuration)
          ..isConnected = true;
      } catch (error) {
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
        _handlePolarH10HrSample(session, hrEvent.sample);
        break;
      case final PolarH10EcgSamplesEvent ecgEvent:
        _handlePolarH10EcgSamples(session, ecgEvent.samples);
        break;
      case final PolarH10AccelerometerSamplesEvent accelerometerEvent:
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

  void _handlePolarH10ConnectionState(
    _ConnectedDeviceSession session,
    PolarH10ConnectionStateEvent event,
  ) {
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
    final sample = event.firstSample;
    session.latestWearableSampleReceivedAt = event.receivedAt;
    final cutoff = event.receivedAt.subtract(
      _ConnectedDeviceSession.wearableVisibleChartWindow,
    );
    for (final definition in _wearableMetricDefinitions) {
      final series = session.wearableMetricSeries[definition.metric];
      if (series == null) {
        continue;
      }

      series
        ..addSample(
          receivedAt: event.receivedAt,
          value: _valueForWearableMetric(definition.metric, sample),
        )
        ..pruneBefore(cutoff);
    }

    final gpsCoordinates = gpsLocationService.currentCoordinates;
    unawaited(
      csvLogger.appendWearableAgmBatch(
        receivedAt: event.receivedAt,
        deviceName: session.displayName,
        gpsCoordinates: gpsCoordinates,
        samples: event.samples,
      ),
    );
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

  @override
  void initState() {
    super.initState();
    _sessionManager.addListener(_handleSessionManagerChanged);
    _listenToScanState();
    _namesLoaded = _loadRespiratoryNames();
  }

  @override
  void dispose() {
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
      await _disconnectFromSession(session);
      return;
    }

    await _connectToDevice(result);
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

    setState(() {
      _connectingDeviceIds.add(id);
      _statusMessage = null;
    });

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
        setState(() {
          _statusMessage = 'Connected to $displayName.';
        });
        if (!_isScanning) {
          unawaited(_startScan(clearResults: false));
        }
        return;
      }

      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 12),
      );

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
      if (!mounted) {
        return;
      }

      setState(() {
        _statusMessage = 'Could not connect to $displayName: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _connectingDeviceIds.remove(id);
        });
      }
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
                            isConnected:
                                _sessionForDeviceId(_deviceId(result.device)) !=
                                    null,
                            isBusy: _isSavingNames || _connectingDeviceIds.contains(
                              _deviceId(result.device),
                            ),
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
                  onPressed: _sessionManager.hasConnectedDevices &&
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
    required this.isBusy,
    required this.onPressed,
  });

  final ScanResult result;
  final String displayName;
  final String deviceId;
  final KnownDeviceType deviceType;
  final bool isConnected;
  final bool isBusy;
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
        onPressed: isUnsupported || isBusy ? null : onPressed,
        child: Text(
          isBusy
              ? 'Wait'
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
              device: session.bleDevice,
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
              device: session.bleDevice,
              deviceName: session.deviceName,
              customName: session.customName,
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
    if (!widget.manager.allConnectedDevicesConfigured) {
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
                          subtitle: Text(session.type.label),
                          leading: const Icon(Icons.bluetooth_connected),
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
                onPressed: widget.manager.allConnectedDevicesConfigured
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startInitialization();
    });
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
              ? const CircularProgressIndicator()
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
                      const SizedBox(height: 16),
                      FilledButton(
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
  final Set<String> _dismissedBleAlertKeys = {};
  Timer? _bleAlertBeepTimer;
  BuildContext? _bleAlertDialogContext;
  bool _bleAlertDialogOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.manager.addListener(_handleManagerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncBleDisconnectionAlertDialog();
      if (!Platform.isAndroid) {
        unawaited(widget.manager.startPolarStreamsForAcquisition());
        unawaited(widget.manager.startEnvironmentalV2NotificationsForAcquisition());
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.manager.removeListener(_handleManagerChanged);
    if (!Platform.isAndroid) widget.manager.cancelAutomaticBleReconnect();
    _stopBleAlertAlarm();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _syncBleDisconnectionAlertDialog();
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
    _syncBleDisconnectionAlertDialog();
  }

  void _syncBleDisconnectionAlertDialog() {
    if (!mounted || !Platform.isAndroid) {
      return;
    }

    final disconnectedSessions =
        widget.manager.disconnectedSessionsDuringAcquisition;
    if (_bleAlertDialogOpen) {
      if (disconnectedSessions.isEmpty || _visibleBleAlertSessions.isEmpty) {
        _closeBleAlertDialog(dismissCurrentDevices: false);
      }
      return;
    }

    if (!_ActiveAcquisitionRuntime.isForegroundVisible) {
      return;
    }

    final visibleSessions = _visibleBleAlertSessions;
    if (visibleSessions.isEmpty) {
      return;
    }

    _showBleAlertDialog();
  }

  void _showBleAlertDialog() {
    if (_bleAlertDialogOpen || !mounted) {
      return;
    }

    _bleAlertDialogOpen = true;
    _startBleAlertAlarm();
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          _bleAlertDialogContext = dialogContext;
          return AnimatedBuilder(
            animation: widget.manager,
            builder: (context, _) {
              final items = _visibleBleAlertSessions
                  .map(_bleAlertItemForSession)
                  .toList(growable: false);
              return _BleDisconnectionAlertDialog(
                items: items,
                onClose: () {
                  _closeBleAlertDialog(dismissCurrentDevices: true);
                },
              );
            },
          );
        },
      ).whenComplete(() {
        _bleAlertDialogOpen = false;
        _bleAlertDialogContext = null;
        _stopBleAlertAlarm();
        if (mounted) {
          setState(() {});
        }
      }),
    );
  }

  _BleDisconnectionAlertItem _bleAlertItemForSession(
    _ConnectedDeviceSession session,
  ) {
    return _BleDisconnectionAlertItem(
      id: session.deviceId,
      deviceName: session.displayName,
      status: session.reconnectStatus,
      reconnectEnabled:
          !widget.manager.isBleReconnectOperationInProgress &&
              !widget.manager.isStopping,
      failureMessage: session.reconnectFailureMessage,
      onReconnect: () {
        unawaited(widget.manager.reconnectDisconnectedSession(session));
      },
    );
  }

  void _closeBleAlertDialog({required bool dismissCurrentDevices}) {
    if (dismissCurrentDevices) {
      final visibleSessions = _visibleBleAlertSessions;
      for (final session in visibleSessions) {
        _dismissedBleAlertKeys.add(_bleAlertKey(session));
      }
      widget.manager.dismissAutomaticBleReconnectForSessions(visibleSessions);
    }

    _stopBleAlertAlarm();
    final dialogContext = _bleAlertDialogContext;
    _bleAlertDialogContext = null;
    if (dialogContext != null) {
      Navigator.of(dialogContext).pop();
    }
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

    unawaited(AndroidAcquisitionForegroundService.playBleDisconnectionAlarmCue());
    unawaited(SystemSound.play(SystemSoundType.alert).catchError((_) {}));
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
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: widget.manager.sessions.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  return _buildDeviceSection(
                    context,
                    widget.manager.sessions[index],
                    initiallyExpanded: widget.manager.sessions.length == 1,
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
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        leading: Icon(
          disconnected ? Icons.bluetooth_disabled : Icons.bluetooth_connected,
          color: disconnected ? colorScheme.error : colorScheme.primary,
        ),
        title: Text(session.displayName),
        subtitle: Text(
          disconnected ? '${session.type.label} - Disconnected' : session.type.label,
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

  Widget _buildDisconnectedBanner(
    BuildContext context,
    _ConnectedDeviceSession session,
  ) {
    final colorScheme = Theme.of(context).colorScheme;

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
                  session.reconnectFailureMessage ?? session.reconnectStatus.label,
                  style: TextStyle(color: colorScheme.onErrorContainer),
                ),
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
    return Column(
      children: [
        _WearableStatusBoxes(
          batteryPercent: session.latestBatteryPercent,
          flushFailureRate: session.latestFlushFailureRate,
        ),
        const SizedBox(height: 12),
        for (final definition in _wearableMetricDefinitions) ...[
          _WearableMetricChartCard(
            definition: definition,
            series: session.wearableMetricSeries[definition.metric]!,
            windowEnd: session.latestWearableSampleReceivedAt,
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

class _WearableStatusBoxes extends StatelessWidget {
  const _WearableStatusBoxes({
    required this.batteryPercent,
    required this.flushFailureRate,
  });

  final int? batteryPercent;
  final int? flushFailureRate;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final batteryText =
        batteryPercent == null ? 'Battery: N/A' : 'Battery: $batteryPercent%';
    final flushFailureRateText = flushFailureRate == null
        ? 'Flush failure rate: N/A'
        : 'Flush failure rate: $flushFailureRate';

    return Row(
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
  });

  final UnifiedAcquisitionCsvLogger csvLogger;

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

/// Android acquisition ownership is independent of either configuration or
/// chart State. The retained engine and foreground service keep this owner alive.
class _WearableAcquisitionController extends ChangeNotifier {
  _WearableAcquisitionController({
    required this.service,
    required this.csvLogger,
    required this.gpsLocationService,
    required this.deviceName,
    required this.customName,
    required this.configuration,
    required this.sessionId,
    required this.startedAt,
  }) {
    coordinator = _BleAutoReconnectCoordinator(
      runAutomaticCycle: _reconnect,
      hasPendingWork: () => disconnected && !_dismissed,
      canContinue: () => !_stopped && !stopping,
      onStateChanged: notifyListeners,
    );
  }

  final WearableConfigurationBleService service;
  final WearableAcquisitionCsvLogger csvLogger;
  final GpsLocationService gpsLocationService;
  final String deviceName;
  final String? customName;
  final WearableDeviceConfiguration configuration;
  final String sessionId;
  final DateTime startedAt;
  late final _BleAutoReconnectCoordinator coordinator;
  StreamSubscription<WearableAgmReceivedBatch>? _samples;
  StreamSubscription<BluetoothConnectionState>? _connection;
  StreamSubscription<WearableBleSequenceState>? _sequence;
  bool disconnected = false;
  bool stopping = false;
  bool _stopped = false;
  bool _dismissed = false;
  bool _needsProcessRecovery = false;
  bool _interruptionPending = false;
  Future<void>? _stopFuture;
  int disconnectionVersion = 0;
  _BleReconnectStatus reconnectStatus = _BleReconnectStatus.disconnected;
  String? reconnectFailureMessage;
  String? backgroundStatusMessage;

  String get displayName => customName ?? deviceName;
  String get deviceId => service.device.remoteId.toString();

  WearableBleCommunicationLogPage buildPage() {
    return WearableBleCommunicationLogPage._withController(this);
  }

  static void _ignoreStoppedCallback() {}

  Future<void> start({AcquisitionRecoverySnapshot? recovery}) async {
    final currentOwner = _ActiveAcquisitionRuntime.activeOwner;
    if (currentOwner != null && !identical(currentOwner, this)) {
      throw StateError('An acquisition already owns this runtime.');
    }
    // Transfer the service callback as well as subscriptions; the configuration
    // widget must no longer be retained by the hardware service.
    service.onStateChanged = null;
    if (recovery == null && await AndroidAcquisitionForegroundService.isActivityAttached()) {
      final notificationStatus = await Permission.notification.request();
      if (!notificationStatus.isGranted) {
        backgroundStatusMessage =
            'Android background acquisition may be unreliable without the persistent notification.';
      }
    }
    await AndroidAcquisitionForegroundService.start();
    await csvLogger.start(
      existingFilePath: recovery?.csvFilePath,
      existingFileName: recovery?.csvFileName,
      startedAt: startedAt,
      sessionId: sessionId,
    );
    await gpsLocationService.start();
    final gpsWarning = gpsLocationService.statusMessage;
    if (gpsWarning != null) {
      backgroundStatusMessage = _mergeStatusMessage(backgroundStatusMessage, gpsWarning);
    }
    final session = _ConnectedDeviceSession(
      device: service.device,
      deviceId: deviceId,
      deviceName: deviceName,
      customName: customName,
      type: KnownDeviceType.respiratoryMonitor,
    )..wearableConfiguration = configuration;
    await AcquisitionRecoveryStore.saveActive(
      sessionId: sessionId,
      workflow: 'single-wearable',
      acquisitionType: KnownDeviceType.respiratoryMonitor.name,
      deviceNames: [displayName],
      deviceTypes: [KnownDeviceType.respiratoryMonitor.name],
      configurationSummaries: [_summarizeWearableConfiguration(configuration)],
      devices: [session.toRecoveryDevice()],
      startedAt: startedAt,
      logicalRoute: 'acquisition',
      status: recovery == null ? 'running' : 'recovering',
      csvFileName: csvLogger.fileName,
      csvFilePath: csvLogger.file?.path,
      runtimeState: recovery?.runtimeState ?? <String, dynamic>{'gpsEnabled': true},
    );
    _samples = service.agmBatchesStream.listen((event) {
      unawaited(csvLogger.appendAgmBatch(
        receivedAt: event.receivedAt,
        deviceName: displayName,
        gpsCoordinates: gpsLocationService.currentCoordinates,
        samples: event.samples,
      ));
      if (_interruptionPending) {
        _interruptionPending = false;
        _needsProcessRecovery = false;
        unawaited(AcquisitionRecoveryStore.closeInterruption(deviceId));
        unawaited(AcquisitionRecoveryStore.updateStatus(
          logicalRoute: 'acquisition',
          status: 'running',
        ));
      }
    });
    _sequence = service.sequenceStateStream.listen((state) {
      if (_needsProcessRecovery &&
          (state == WearableBleSequenceState.error ||
              state == WearableBleSequenceState.timeout)) {
        disconnected = false;
        _markDisconnected();
      }
    });
    _ActiveAcquisitionRuntime.registerSingleOwner(this, buildPage, resume);
    await _ActiveAcquisitionRuntime.markActive();
    _attachConnection();
    if (recovery != null) {
      _needsProcessRecovery = true;
      _interruptionPending = true;
      backgroundStatusMessage = _mergeStatusMessage(
        backgroundStatusMessage,
        'Acquisition was interrupted. Possible data gaps are recorded in the session event log.',
      );
      await AcquisitionRecoveryStore.recordInterruption(
        deviceId: deviceId,
        startedAt: DateTime.tryParse(recovery.lastHeartbeatIso8601 ?? '') ?? startedAt,
        reason: 'acquisition_process_restarted',
      );
      _markDisconnected();
    } else {
      await service.startConfigurationSequence(
        odr: configuration.odr,
        mag: configuration.mag,
        accG: configuration.accG,
        gyrDPS: configuration.gyrDPS,
        calibrationEnabled: configuration.calibrationEnabled,
      );
    }
  }

  static Future<void> restore(AcquisitionRecoverySnapshot snapshot) async {
    if (_ActiveAcquisitionRuntime.activeOwner case final _WearableAcquisitionController owner) {
      await owner.resume();
      return;
    }
    final session = _ConnectedDeviceSession.fromRecoveryDevice(snapshot.devices.single);
    final owner = _WearableAcquisitionController(
      service: WearableConfigurationBleService(session.device!),
      csvLogger: WearableAcquisitionCsvLogger(),
      gpsLocationService: GpsLocationService(),
      deviceName: session.deviceName,
      customName: session.customName,
      configuration: session.wearableConfiguration!,
      sessionId: snapshot.sessionId,
      startedAt: DateTime.parse(snapshot.startedAtIso8601!),
    );
    try {
      await owner.start(recovery: snapshot);
    } catch (_) {
      await owner.releaseAfterFailedStart();
      rethrow;
    }
  }

  void _attachConnection() {
    unawaited(_connection?.cancel());
    _connection = service.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected &&
          !stopping && !_stopped && !service.isStopping && !service.isStopped) {
        _markDisconnected();
      }
    });
  }

  void _markDisconnected() {
    if (stopping || _stopped || disconnected) return;
    disconnected = true;
    _dismissed = false;
    disconnectionVersion += 1;
    reconnectStatus = _BleReconnectStatus.disconnected;
    reconnectFailureMessage = null;
    if (!_interruptionPending) {
      _interruptionPending = true;
      backgroundStatusMessage = _mergeStatusMessage(
        backgroundStatusMessage,
        'Acquisition was interrupted by a Bluetooth disconnection. Possible data gaps are recorded in the session event log.',
      );
      unawaited(AcquisitionRecoveryStore.recordInterruption(
        deviceId: deviceId,
        startedAt: DateTime.now(),
        reason: 'ble_disconnected',
      ));
    }
    unawaited(AndroidAcquisitionForegroundService.showBleDisconnectionAlert(displayName));
    notifyListeners();
    coordinator.start();
  }

  Future<void> _reconnect() async {
    if (!disconnected || stopping || _stopped || _dismissed) return;
    reconnectStatus = _BleReconnectStatus.reconnecting;
    reconnectFailureMessage = null;
    notifyListeners();
    try {
      final device = await _BleReconnectHelper.reconnect(
        currentDevice: service.device,
        deviceId: deviceId,
        deviceName: deviceName,
      );
      if (stopping || _stopped) return;
      if (_needsProcessRecovery) {
        await service.recoverConfigurationSequence(
          reconnectedDevice: device,
          odr: configuration.odr,
          mag: configuration.mag,
          accG: configuration.accG,
          gyrDPS: configuration.gyrDPS,
          calibrationEnabled: configuration.calibrationEnabled,
        );
      } else {
        await service.resumeNotificationsAfterReconnect(reconnectedDevice: device);
      }
      if (stopping || _stopped) return;
      _attachConnection();
      disconnected = false;
      reconnectStatus = _BleReconnectStatus.reconnected;
      await AndroidAcquisitionForegroundService.clearBleDisconnectionAlert();
    } catch (_) {
      if (stopping || _stopped) return;
      try { await service.device.disconnect(); } catch (_) {}
      reconnectStatus = _BleReconnectStatus.failed;
      reconnectFailureMessage =
          'Could not reconnect to $displayName. Move closer and try again.';
    }
    notifyListeners();
  }

  Future<void> resume() async {
    if (_stopped || stopping) return;
    await gpsLocationService.resumeAfterAndroidActivityAttached();
    if (disconnected && !_dismissed) coordinator.start();
  }

  Future<void> reconnectNow() async {
    _dismissed = false;
    await coordinator.requestImmediate();
  }

  void dismissReconnect() {
    _dismissed = true;
    coordinator.cancel();
  }

  Future<void> _stopLogging() async {
    try {
      await _samples?.cancel();
      _samples = null;
      await gpsLocationService.stop();
    } finally {
      await csvLogger.stop();
    }
  }

  Future<void> stop() async {
    final pending = _stopFuture;
    if (pending != null) return pending;
    if (_stopped) return;
    final operation = _stopAcquisitionResources();
    _stopFuture = operation;
    try {
      await operation;
    } finally {
      if (!_stopped) _stopFuture = null;
    }
  }

  Future<void> _stopAcquisitionResources() async {
    await AcquisitionRecoveryStore.markStopping();
    _ActiveAcquisitionRuntime.beginStopping();
    stopping = true;
    coordinator.cancel();
    notifyListeners();
    try {
      await coordinator.waitForIdle();
      await _connection?.cancel();
      await _sequence?.cancel();
      try {
        await service.stopAcquisition();
      } catch (_) {
        // A disconnected device cannot acknowledge STOP; the confirmed local
        // session still ends and must never be resurrected on the next launch.
        try { await service.dispose(); } catch (_) {}
        try { await service.device.disconnect(); } catch (_) {}
      }
    } finally {
      try {
        await _stopLogging();
      } finally {
        _stopped = true;
        notifyListeners();
        try {
          await AcquisitionRecoveryStore.clear();
        } finally {
          await _ActiveAcquisitionRuntime.markInactive();
          await AndroidAcquisitionForegroundService.clearBleDisconnectionAlert();
          await AndroidAcquisitionForegroundService.stop();
        }
      }
    }
  }

  Future<void> releaseAfterFailedStart() async {
    _stopped = true;
    coordinator.cancel();
    try {
      await coordinator.waitForIdle();
      await _connection?.cancel();
      await _sequence?.cancel();
      try {
        await _stopLogging();
      } finally {
        await service.dispose();
      }
    } finally {
      if (identical(_ActiveAcquisitionRuntime.activeOwner, this)) {
        await _ActiveAcquisitionRuntime.markInactive();
      }
    }
  }
}

class WearableDeviceConfigurationPage extends StatefulWidget {
  const WearableDeviceConfigurationPage({
    super.key,
    required this.device,
    required this.deviceName,
    this.customName,
    this.initialConfiguration,
    this.onConfigurationConfirmed,
    this.onDisconnected,
  });

  final BluetoothDevice device;
  // Keep the BLE name separate for the legacy acquisition reconnect flow.
  final String deviceName;
  final String? customName;
  final WearableDeviceConfiguration? initialConfiguration;
  final ValueChanged<WearableDeviceConfiguration>? onConfigurationConfirmed;
  final VoidCallback? onDisconnected;

  @override
  State<WearableDeviceConfigurationPage> createState() =>
      _WearableDeviceConfigurationPageState();
}

class _WearableDeviceConfigurationPageState
    extends State<WearableDeviceConfigurationPage> {
  WearableConfigurationBleService? _service;
  WearableAcquisitionCsvLogger? _csvLogger;
  GpsLocationService? _gpsLocationService;
  _WearableAcquisitionController? _androidAcquisition;
  String? _customName;

  String get _displayName => _customName ?? widget.deviceName;

  static const List<int> _odrValues = [12, 26, 52, 104, 208, 416];
  static const List<int> _accGValues = [2, 4, 8, 16];
  static const List<int> _gyrDPSValues = [125, 250, 500, 1000, 2000];

  int odr = 104;
  int mag = 0;
  int accG = 8;
  int gyrDPS = 500;
  bool calibrationEnabled = false;
  bool _isSendingConfig = false;
  bool _configurationSequenceStarted = false;
  bool _wearableAcquisitionStopped = false;
  bool _isDisposing = false;
  bool _disconnectionNotified = false;
  String? _backgroundStatusMessage;
  StreamSubscription<WearableAgmReceivedBatch>? _agmBatchesSubscription;

  bool get _isConfigurationOnly {
    return widget.onConfigurationConfirmed != null;
  }

  @override
  void initState() {
    super.initState();
    _customName = widget.customName;
    final initialConfiguration = widget.initialConfiguration;
    if (initialConfiguration != null) {
      odr = initialConfiguration.odr;
      mag = initialConfiguration.mag;
      accG = initialConfiguration.accG;
      gyrDPS = initialConfiguration.gyrDPS;
      calibrationEnabled = initialConfiguration.calibrationEnabled;
    }

    if (_isConfigurationOnly) {
      return;
    }

    final service = WearableConfigurationBleService(
      widget.device,
      onStateChanged: () {
        if (!mounted || _isDisposing) {
          return;
        }

        setState(() {});
      },
    );
    _service = service;
    _csvLogger = WearableAcquisitionCsvLogger();
    _gpsLocationService = GpsLocationService();
    unawaited(service.initialize());
  }

  @override
  void dispose() {
    _androidAcquisition?.removeListener(_handleAndroidOwnerChanged);
    if (!_isConfigurationOnly) {
      _isDisposing = true;
      if (!_configurationSequenceStarted || _wearableAcquisitionStopped) {
        _notifyDisconnected();
        unawaited(_cleanupAndDisconnect());
      }
    }
    super.dispose();
  }

  void _notifyDisconnected() {
    if (_disconnectionNotified) {
      return;
    }

    _disconnectionNotified = true;
    widget.onDisconnected?.call();
  }

  Future<void> _cleanupAndDisconnect() async {
    await _stopWearableCsvLogging();
    await _service?.dispose();

    try {
      await widget.device.disconnect();
    } catch (_) {
      // The device may already be disconnected when the route is disposed.
    } finally {
      _notifyDisconnected();
    }
  }

  void _setMagnetometer(bool enabled) {
    setState(() {
      mag = enabled ? 1 : 0;
    });
  }

  void _setCalibration(bool enabled) {
    setState(() {
      calibrationEnabled = enabled;
    });
  }

  Future<void> _startConfigurationSequenceAndOpenLog() async {
    final service = _service;
    final csvLogger = _csvLogger;
    if (service == null ||
        csvLogger == null ||
        !service.isReadyToContinue ||
        _isSendingConfig ||
        _configurationSequenceStarted) {
      return;
    }

    setState(() {
      _isSendingConfig = true;
      _configurationSequenceStarted = true;
    });

    try {
      if (Platform.isAndroid) {
        _customName ??= await RespiratoryDeviceNameStore.load(
          widget.device.remoteId.toString(),
        );
        final controller = _WearableAcquisitionController(
          service: service,
          csvLogger: csvLogger,
          gpsLocationService: _gpsLocationService!,
          deviceName: widget.deviceName,
          customName: _customName,
          configuration: WearableDeviceConfiguration(
            odr: odr,
            mag: mag,
            accG: accG,
            gyrDPS: gyrDPS,
            calibrationEnabled: calibrationEnabled,
          ),
          sessionId: const Uuid().v4(),
          startedAt: DateTime.now(),
        );
        _androidAcquisition = controller;
        controller.addListener(_handleAndroidOwnerChanged);
        await controller.start();
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => controller.buildPage()),
        );
        return;
      }
      await _startWearableCsvLogging();
      await service.startConfigurationSequence(
        odr: odr,
        mag: mag,
        accG: accG,
        gyrDPS: gyrDPS,
        calibrationEnabled: calibrationEnabled,
      );
      await _activateAndroidBackgroundSupport();
      if (!mounted) {
        return;
      }

      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => WearableBleCommunicationLogPage(
            service: service,
            csvLogger: csvLogger,
            deviceName: widget.deviceName,
            customName: _customName,
            stopWearableCsvLogging: _stopWearableCsvLogging,
            onAcquisitionStopped: _handleWearableAcquisitionStopped,
            backgroundStatusMessage: _backgroundStatusMessage,
          ),
        ),
      );
    } catch (error) {
      final controller = _androidAcquisition;
      if (controller != null) {
        controller.removeListener(_handleAndroidOwnerChanged);
        await controller.releaseAfterFailedStart();
        final stored = await AcquisitionRecoveryStore.load();
        if (stored?.sessionId == controller.sessionId) {
          await AcquisitionRecoveryStore.clear();
        }
        _androidAcquisition = null;
      }
      await _stopWearableCsvLogging();
      if (_ActiveAcquisitionRuntime.activeOwner == null) {
        await AndroidAcquisitionForegroundService.clearBleDisconnectionAlert();
        await AndroidAcquisitionForegroundService.stop();
      }
      _configurationSequenceStarted = false;
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not start acquisition: $error')),
      );
      setState(() {});
    } finally {
      if (mounted) {
        setState(() {
          _isSendingConfig = false;
        });
      }
    }
  }

  Future<void> _activateAndroidBackgroundSupport() async {
    if (!Platform.isAndroid) {
      return;
    }

    final notificationStatus = await Permission.notification.request();
    if (!notificationStatus.isGranted) {
      _backgroundStatusMessage = _mergeStatusMessage(
        _backgroundStatusMessage,
        'Android background acquisition may be unreliable without the persistent notification.',
      );
    }

    try {
      await AndroidAcquisitionForegroundService.start();
    } catch (error) {
      _backgroundStatusMessage = _mergeStatusMessage(
        _backgroundStatusMessage,
        'Android background acquisition may be unreliable: $error',
      );
    }

    await _ActiveAcquisitionRuntime.markActive();
    await AcquisitionRecoveryStore.saveActive(
      acquisitionType: KnownDeviceType.respiratoryMonitor.name,
      deviceNames: [_displayName],
      deviceTypes: [KnownDeviceType.respiratoryMonitor.name],
      configurationSummaries: [
        _summarizeWearableConfiguration(
          WearableDeviceConfiguration(
            odr: odr,
            mag: mag,
            accG: accG,
            gyrDPS: gyrDPS,
            calibrationEnabled: calibrationEnabled,
          ),
        ),
      ],
      startedAt: DateTime.now(),
      logicalRoute: 'acquisition',
      status: 'running',
      csvFileName: _csvLogger?.fileName,
      csvFilePath: _csvLogger?.file?.path,
    );
  }

  void _confirmConfiguration() {
    widget.onConfigurationConfirmed?.call(
      WearableDeviceConfiguration(
        odr: odr,
        mag: mag,
        accG: accG,
        gyrDPS: gyrDPS,
        calibrationEnabled: calibrationEnabled,
      ),
    );
    Navigator.of(context).pop();
  }

  void _handleWearableAcquisitionStopped() {
    _wearableAcquisitionStopped = true;
    _notifyDisconnected();
  }

  void _handleAndroidOwnerChanged() {
    if (mounted && _androidAcquisition?._stopped == true) {
      _handleWearableAcquisitionStopped();
    }
  }

  Future<void> _startWearableCsvLogging() async {
    final csvLogger = _csvLogger;
    final gpsLocationService = _gpsLocationService;
    final service = _service;
    if (csvLogger == null || gpsLocationService == null || service == null) {
      return;
    }

    // The standalone wearable path must resolve the same persisted IMU name
    // before subscribing to AGM data, while retaining widget.deviceName for BLE.
    _customName ??= await RespiratoryDeviceNameStore.load(
      widget.device.remoteId.toString(),
    );
    await csvLogger.start();
    await gpsLocationService.start();
    final gpsStatusMessage = gpsLocationService.statusMessage;
    if (gpsStatusMessage != null) {
      _backgroundStatusMessage = _mergeStatusMessage(
        _backgroundStatusMessage,
        gpsStatusMessage,
      );
    }
    await _agmBatchesSubscription?.cancel();
    _agmBatchesSubscription = service.agmBatchesStream.listen((event) {
      final gpsCoordinates = gpsLocationService.currentCoordinates;
      unawaited(
        csvLogger.appendAgmBatch(
          receivedAt: event.receivedAt,
          deviceName: _displayName,
          gpsCoordinates: gpsCoordinates,
          samples: event.samples,
        ),
      );
    });
  }

  Future<void> _stopWearableCsvLogging() async {
    await _agmBatchesSubscription?.cancel();
    _agmBatchesSubscription = null;
    await _gpsLocationService?.stop();
    await _csvLogger?.stop();
  }

  @override
  Widget build(BuildContext context) {
    final service = _service;
    final canContinue = _isConfigurationOnly ||
        (service != null &&
            service.isReadyToContinue &&
            !_isSendingConfig &&
            !_configurationSequenceStarted);
    final buttonText = _isConfigurationOnly
        ? 'Confirm Configuration'
        : _isSendingConfig
            ? 'Sending...'
            : 'Continue';

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
                  onChanged: (value) {
                    setState(() {
                      odr = value;
                    });
                  },
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Magnetometer'),
                  value: mag == 1,
                  onChanged: _setMagnetometer,
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Calibration'),
                  value: calibrationEnabled,
                  onChanged: _setCalibration,
                ),
                const SizedBox(height: 12),
                _buildDropdownSetting(
                  label: 'Accelerometer Full Scale Range (g)',
                  value: accG,
                  values: _accGValues,
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
                onPressed: canContinue
                    ? _isConfigurationOnly
                        ? _confirmConfiguration
                        : _startConfigurationSequenceAndOpenLog
                    : null,
                child: Text(buttonText),
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
      onChanged: (selectedValue) {
        if (selectedValue == null) {
          return;
        }

        onChanged(selectedValue);
      },
    );
  }
}

class WearableBleCommunicationLogPage extends StatefulWidget {
  const WearableBleCommunicationLogPage({
    super.key,
    required this.service,
    required this.csvLogger,
    required this.deviceName,
    this.customName,
    required this.stopWearableCsvLogging,
    required this.onAcquisitionStopped,
    this.backgroundStatusMessage,
  }) : _controller = null;

  WearableBleCommunicationLogPage._withController(
    _WearableAcquisitionController controller,
  ) : service = controller.service,
      csvLogger = controller.csvLogger,
      deviceName = controller.deviceName,
      customName = controller.customName,
      stopWearableCsvLogging = controller._stopLogging,
      onAcquisitionStopped = _WearableAcquisitionController._ignoreStoppedCallback,
      backgroundStatusMessage = null,
      _controller = controller;

  final WearableConfigurationBleService service;
  final WearableAcquisitionCsvLogger csvLogger;
  // Original BLE name used by _BleReconnectHelper.
  final String deviceName;
  final String? customName;

  String get displayName => customName ?? deviceName;

  final Future<void> Function() stopWearableCsvLogging;
  final VoidCallback onAcquisitionStopped;
  final String? backgroundStatusMessage;
  final _WearableAcquisitionController? _controller;

  @override
  State<WearableBleCommunicationLogPage> createState() =>
      _WearableBleCommunicationLogPageState();
}

class _WearableBleCommunicationLogPageState
    extends State<WearableBleCommunicationLogPage> with WidgetsBindingObserver {
  bool _stopConfirmationOpen = false;
  static const Duration _visibleChartWindow = Duration(seconds: 2);
  static const Duration _uiRefreshInterval = Duration(milliseconds: 500);

  final Map<_WearableMetric, _WearableMetricSeries> _metricSeries = {
    for (final definition in _wearableMetricDefinitions)
      definition.metric: _WearableMetricSeries(),
  };

  StreamSubscription<WearableAgmReceivedBatch>? _agmBatchesSubscription;
  StreamSubscription<WearableSdsReceivedStatus>? _sdsStatusSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  final Set<String> _dismissedBleAlertKeys = {};
  final ValueNotifier<int> _bleAlertRevision = ValueNotifier<int>(0);
  Timer? _uiRefreshTimer;
  Timer? _bleAlertBeepTimer;
  BuildContext? _bleAlertDialogContext;
  DateTime? _lastUiRefreshAt;
  DateTime? _latestSampleReceivedAt;
  int? _latestBatteryPercent;
  int? _latestFlushFailureRate;
  bool _bleDisconnectedDuringAcquisition = false;
  bool _bleAlertDialogOpen = false;
  int _bleDisconnectionAlertVersion = 0;
  _BleReconnectStatus _bleReconnectStatus = _BleReconnectStatus.disconnected;
  String? _bleReconnectFailureMessage;
  late final _BleAutoReconnectCoordinator _legacyBleAutoReconnectCoordinator;
  _BleAutoReconnectCoordinator get _bleAutoReconnectCoordinator =>
      widget._controller?.coordinator ?? _legacyBleAutoReconnectCoordinator;
  bool _isStoppingAcquisition = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget._controller == null) {
      _legacyBleAutoReconnectCoordinator = _BleAutoReconnectCoordinator(
        runAutomaticCycle: _runWearableAutomaticBleReconnectCycle,
        hasPendingWork: _hasWearableAutomaticBleReconnectWork,
        canContinue: _canContinueWearableAutomaticBleReconnect,
        onStateChanged: _handleWearableAutoReconnectStateChanged,
      );
    }
    _agmBatchesSubscription = widget.service.agmBatchesStream.listen(
      _handleAgmBatch,
    );
    _sdsStatusSubscription = widget.service.sdsStatusStream.listen(
      _handleSdsStatus,
    );
    final controller = widget._controller;
    if (controller == null) {
      _attachWearableConnectionListener();
    } else {
      controller.addListener(_handleControllerChanged);
      _copyControllerState();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _syncWearableBleDisconnectionAlertDialog();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_agmBatchesSubscription?.cancel());
    unawaited(_sdsStatusSubscription?.cancel());
    unawaited(_connectionSubscription?.cancel());
    _uiRefreshTimer?.cancel();
    widget._controller?.removeListener(_handleControllerChanged);
    if (widget._controller == null) {
      _bleAutoReconnectCoordinator.cancel(notify: false);
    }
    _stopWearableBleAlertAlarm();
    _bleAlertRevision.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _syncWearableBleDisconnectionAlertDialog();
      });
      return;
    }

    _stopWearableBleAlertAlarm();
  }

  void _attachWearableConnectionListener() {
    unawaited(_connectionSubscription?.cancel());
    _connectionSubscription = widget.service.connectionState.listen((state) {
      if (_isStoppingAcquisition ||
          widget.service.isStopping ||
          widget.service.isStopped ||
          state != BluetoothConnectionState.disconnected) {
        return;
      }

      _markWearableBleDisconnected();
    });
  }

  void _copyControllerState() {
    final controller = widget._controller!;
    _bleDisconnectedDuringAcquisition = controller.disconnected;
    _bleDisconnectionAlertVersion = controller.disconnectionVersion;
    _bleReconnectStatus = controller.reconnectStatus;
    _bleReconnectFailureMessage = controller.reconnectFailureMessage;
    _isStoppingAcquisition = controller.stopping;
  }

  void _handleControllerChanged() {
    if (!mounted) return;
    setState(_copyControllerState);
    _notifyWearableBleAlertChanged();
    _syncWearableBleDisconnectionAlertDialog();
  }

  void _handleAgmBatch(WearableAgmReceivedBatch event) {
    final sample = event.firstSample;
    _latestSampleReceivedAt = event.receivedAt;

    final cutoff = event.receivedAt.subtract(_visibleChartWindow);
    for (final definition in _wearableMetricDefinitions) {
      final series = _metricSeries[definition.metric];
      if (series == null) {
        continue;
      }

      series
        ..addSample(
          receivedAt: event.receivedAt,
          value: _valueForMetric(definition.metric, sample),
        )
        ..pruneBefore(cutoff);
    }

    _requestThrottledUiRefresh();
  }

  void _handleSdsStatus(WearableSdsReceivedStatus event) {
    _latestBatteryPercent = event.batteryPercent;
    _latestFlushFailureRate = event.flushFailureRate;
    _requestThrottledUiRefresh();
  }

  void _markWearableBleDisconnected() {
    if (_isStoppingAcquisition || widget.service.isStopping) {
      return;
    }

    if (_bleDisconnectedDuringAcquisition &&
        _bleReconnectStatus != _BleReconnectStatus.reconnected) {
      return;
    }

    if (mounted) {
      setState(() {
        _bleDisconnectedDuringAcquisition = true;
        _bleDisconnectionAlertVersion += 1;
        _bleReconnectStatus = _BleReconnectStatus.disconnected;
        _bleReconnectFailureMessage = null;
      });
    } else {
      _bleDisconnectedDuringAcquisition = true;
      _bleDisconnectionAlertVersion += 1;
      _bleReconnectStatus = _BleReconnectStatus.disconnected;
      _bleReconnectFailureMessage = null;
    }
    _notifyWearableBleAlertChanged();

    unawaited(
      AndroidAcquisitionForegroundService.showBleDisconnectionAlert(
        widget.displayName,
      ),
    );
    _bleAutoReconnectCoordinator.start();

    if (!_ActiveAcquisitionRuntime.isForegroundVisible) {
      return;
    }

    _syncWearableBleDisconnectionAlertDialog();
  }

  Future<void> _reconnectWearableAfterDisconnection() async {
    final controller = widget._controller;
    if (controller != null) {
      await controller.reconnectNow();
      return;
    }
    if (!_canAttemptWearableBleReconnect()) {
      return;
    }

    await _bleAutoReconnectCoordinator.requestImmediate(
      operation: _runWearableBleReconnectAttempt,
    );
  }

  Future<void> _runWearableAutomaticBleReconnectCycle() async {
    if (!_canAttemptWearableBleReconnect()) {
      return;
    }

    await _runWearableBleReconnectAttempt();
  }

  Future<void> _runWearableBleReconnectAttempt() async {
    if (!_canAttemptWearableBleReconnect()) {
      return;
    }

    setState(() {
      _bleReconnectStatus = _BleReconnectStatus.reconnecting;
      _bleReconnectFailureMessage = null;
    });
    _notifyWearableBleAlertChanged();

    try {
      final currentDevice = widget.service.device;
      final reconnectedDevice = await _BleReconnectHelper.reconnect(
        currentDevice: currentDevice,
        deviceId: currentDevice.remoteId.toString(),
        deviceName: widget.deviceName,
      );
      if (!_canContinueWearableAutomaticBleReconnect()) {
        return;
      }
      await widget.service.resumeNotificationsAfterReconnect(
        reconnectedDevice: reconnectedDevice,
      );
      _attachWearableConnectionListener();

      if (!_canContinueWearableAutomaticBleReconnect()) {
        return;
      }

      setState(() {
        _bleDisconnectedDuringAcquisition = false;
        _bleReconnectStatus = _BleReconnectStatus.reconnected;
        _bleReconnectFailureMessage = null;
      });
      _notifyWearableBleAlertChanged();
      unawaited(AndroidAcquisitionForegroundService.clearBleDisconnectionAlert());
      _closeWearableBleAlertDialog(dismissCurrentDevice: false);
    } catch (_) {
      try {
        await widget.service.device.disconnect();
      } catch (_) {}

      if (!_canContinueWearableAutomaticBleReconnect()) {
        return;
      }

      setState(() {
        _bleDisconnectedDuringAcquisition = true;
        _bleReconnectStatus = _BleReconnectStatus.failed;
        _bleReconnectFailureMessage =
            'Could not reconnect to ${widget.displayName}. Move closer and try again.';
      });
      _notifyWearableBleAlertChanged();
    }
  }

  bool _hasWearableAutomaticBleReconnectWork() {
    return _bleDisconnectedDuringAcquisition &&
        !_dismissedBleAlertKeys.contains(_wearableBleAlertKey);
  }

  bool _canContinueWearableAutomaticBleReconnect() {
    return mounted &&
        !_isStoppingAcquisition &&
        !widget.service.isStopping &&
        !widget.service.isStopped;
  }

  bool _canAttemptWearableBleReconnect() {
    return _canContinueWearableAutomaticBleReconnect() &&
        _bleDisconnectedDuringAcquisition &&
        !_dismissedBleAlertKeys.contains(_wearableBleAlertKey) &&
        _bleReconnectStatus != _BleReconnectStatus.reconnecting &&
        _bleReconnectStatus != _BleReconnectStatus.reconnected;
  }

  void _handleWearableAutoReconnectStateChanged() {
    _notifyWearableBleAlertChanged();
    if (mounted) {
      setState(() {});
    }
  }

  void _syncWearableBleDisconnectionAlertDialog() {
    if (!mounted || !Platform.isAndroid) {
      return;
    }

    if (_bleAlertDialogOpen) {
      if (!_bleDisconnectedDuringAcquisition) {
        _closeWearableBleAlertDialog(dismissCurrentDevice: false);
      }
      return;
    }

    if (!_ActiveAcquisitionRuntime.isForegroundVisible ||
        !_bleDisconnectedDuringAcquisition ||
        _dismissedBleAlertKeys.contains(_wearableBleAlertKey)) {
      return;
    }

    _showWearableBleAlertDialog();
  }

  void _showWearableBleAlertDialog() {
    if (_bleAlertDialogOpen || !mounted) {
      return;
    }

    _bleAlertDialogOpen = true;
    _startWearableBleAlertAlarm();
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          _bleAlertDialogContext = dialogContext;
          return ValueListenableBuilder<int>(
            valueListenable: _bleAlertRevision,
            builder: (_, _, _) {
              return _BleDisconnectionAlertDialog(
                items: [_wearableBleAlertItem],
                onClose: () {
                  _closeWearableBleAlertDialog(dismissCurrentDevice: true);
                },
              );
            },
          );
        },
      ).whenComplete(() {
        _bleAlertDialogOpen = false;
        _bleAlertDialogContext = null;
        _stopWearableBleAlertAlarm();
        if (mounted) {
          setState(() {});
        }
      }),
    );
  }

  _BleDisconnectionAlertItem get _wearableBleAlertItem {
    return _BleDisconnectionAlertItem(
      id: widget.service.device.remoteId.toString(),
      deviceName: widget.displayName,
      status: _bleReconnectStatus,
      reconnectEnabled: !_bleAutoReconnectCoordinator.isOperationInProgress &&
          !_isStoppingAcquisition &&
          !widget.service.isStopping &&
          !widget.service.isStopped,
      failureMessage: _bleReconnectFailureMessage,
      onReconnect: () {
        unawaited(_reconnectWearableAfterDisconnection());
      },
    );
  }

  void _closeWearableBleAlertDialog({required bool dismissCurrentDevice}) {
    if (dismissCurrentDevice && _bleDisconnectedDuringAcquisition) {
      _dismissedBleAlertKeys.add(_wearableBleAlertKey);
      if (widget._controller case final controller?) {
        controller.dismissReconnect();
      } else {
        _bleAutoReconnectCoordinator.cancel();
      }
    }

    _stopWearableBleAlertAlarm();
    final dialogContext = _bleAlertDialogContext;
    _bleAlertDialogContext = null;
    if (dialogContext != null) {
      Navigator.of(dialogContext).pop();
    }
  }

  void _startWearableBleAlertAlarm() {
    _stopWearableBleAlertAlarm();
    _playWearableBleAlertCue();
    _bleAlertBeepTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _playWearableBleAlertCue();
    });
  }

  void _stopWearableBleAlertAlarm() {
    _bleAlertBeepTimer?.cancel();
    _bleAlertBeepTimer = null;
  }

  void _playWearableBleAlertCue() {
    if (!Platform.isAndroid) {
      return;
    }

    unawaited(AndroidAcquisitionForegroundService.playBleDisconnectionAlarmCue());
    unawaited(SystemSound.play(SystemSoundType.alert).catchError((_) {}));
    unawaited(HapticFeedback.vibrate().catchError((_) {}));
  }

  void _notifyWearableBleAlertChanged() {
    _bleAlertRevision.value += 1;
  }

  String get _wearableBleAlertKey {
    return '${widget.service.device.remoteId}:$_bleDisconnectionAlertVersion';
  }

  double _valueForMetric(
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
    };
  }

  void _requestThrottledUiRefresh() {
    if (!mounted) {
      return;
    }

    final now = DateTime.now();
    final lastRefresh = _lastUiRefreshAt;
    if (lastRefresh == null ||
        now.difference(lastRefresh) >= _uiRefreshInterval) {
      _lastUiRefreshAt = now;
      setState(() {});
      return;
    }

    if (_uiRefreshTimer != null) {
      return;
    }

    final remaining = _uiRefreshInterval - now.difference(lastRefresh);
    _uiRefreshTimer = Timer(remaining, () {
      _uiRefreshTimer = null;
      if (!mounted) {
        return;
      }

      _lastUiRefreshAt = DateTime.now();
      setState(() {});
    });
  }

  Future<void> _requestStopAcquisition() async {
    if (!mounted ||
        _stopConfirmationOpen ||
        _isStoppingAcquisition ||
        widget.service.isStopping) {
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
    if (_isStoppingAcquisition || widget.service.isStopping) {
      return;
    }

    final controller = widget._controller;
    if (controller != null) {
      var csvFinalizeFailed = false;
      try {
        await controller.stop();
      } catch (_) {
        csvFinalizeFailed = true;
      }
      if (!mounted) return;
      if (!controller._stopped) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not stop acquisition')),
        );
        return;
      }
      if (csvFinalizeFailed) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not finalize CSV file')),
        );
      }
      unawaited(Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => WearableAcquisitionCompletedPage(csvLogger: widget.csvLogger),
        ),
      ));
      return;
    }

    _bleAutoReconnectCoordinator.cancel();
    setState(() {
      _isStoppingAcquisition = true;
    });

    try {
      await widget.service.stopAcquisition();
      var csvFinalizeFailed = false;
      try {
        await widget.stopWearableCsvLogging();
        await AndroidAcquisitionForegroundService.clearBleDisconnectionAlert();
        await AndroidAcquisitionForegroundService.stop();
        await AcquisitionRecoveryStore.clear();
        await _ActiveAcquisitionRuntime.markInactive();
      } catch (_) {
        csvFinalizeFailed = true;
      }
      widget.onAcquisitionStopped();

      if (!mounted) {
        return;
      }

      if (csvFinalizeFailed) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not finalize CSV file')),
        );
      }
      unawaited(
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => WearableAcquisitionCompletedPage(
              csvLogger: widget.csvLogger,
            ),
          ),
        ),
      );
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isStoppingAcquisition = false;
      });
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
            if (_bleDisconnectedDuringAcquisition)
              _buildWearableBleDisconnectedBanner(),
            Expanded(
              child: _buildWearableDashboard(),
            ),
            _buildBackgroundStatus(),
            _buildStopAcquisitionButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildWearableBleDisconnectedBanner() {
    final colorScheme = Theme.of(context).colorScheme;
    final message = _bleReconnectFailureMessage ?? _bleReconnectStatus.label;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                color: colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: colorScheme.onErrorContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWearableDashboard() {
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _wearableMetricDefinitions.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        if (index == 0) {
          return _buildStatusBoxes(context);
        }

        final definition = _wearableMetricDefinitions[index - 1];
        return _WearableMetricChartCard(
          definition: definition,
          series: _metricSeries[definition.metric]!,
          windowEnd: _latestSampleReceivedAt,
          windowDuration: _visibleChartWindow,
          formatTime: _formatChartTime,
        );
      },
    );
  }

  Widget _buildStatusBoxes(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final batteryText = _latestBatteryPercent == null
        ? 'Battery: N/A'
        : 'Battery: $_latestBatteryPercent%';
    final flushFailureRateText = _latestFlushFailureRate == null
        ? 'Flush failure rate: N/A'
        : 'Flush failure rate: $_latestFlushFailureRate';

    return Row(
      children: [
        Expanded(
          child: _buildStatusBox(
            context: context,
            icon: Icons.battery_std,
            text: batteryText,
            iconColor: colorScheme.primary,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildStatusBox(
            context: context,
            icon: Icons.warning_amber_rounded,
            text: flushFailureRateText,
            iconColor: colorScheme.tertiary,
          ),
        ),
      ],
    );
  }

  Widget _buildStatusBox({
    required BuildContext context,
    required IconData icon,
    required String text,
    required Color iconColor,
  }) {
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
            Icon(
              icon,
              color: iconColor,
            ),
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

  Widget _buildBackgroundStatus() {
    if (!Platform.isAndroid) {
      return const SizedBox.shrink();
    }

    final warning = widget._controller?.backgroundStatusMessage ?? widget.backgroundStatusMessage;
    final colorScheme = Theme.of(context).colorScheme;
    final backgroundColor = warning == null
        ? Colors.green.shade50
        : colorScheme.errorContainer;
    final foregroundColor = warning == null
        ? Colors.green.shade900
        : colorScheme.onErrorContainer;

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
              Icon(
                warning == null
                    ? Icons.notifications_active
                    : Icons.warning_amber_rounded,
                size: 18,
                color: foregroundColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  warning ?? 'Background acquisition active',
                  style: TextStyle(color: foregroundColor),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStopAcquisitionButton() {
    final isStopping = _isStoppingAcquisition || widget.service.isStopping;

    return SafeArea(
      top: false,
      bottom: true,
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: SizedBox(
        width: double.infinity,
        height: 48,
        child: FilledButton(
          onPressed: isStopping ? null : _requestStopAcquisition,
          child: Text(isStopping ? 'Stopping...' : 'Stop acquisition'),
        ),
      ),
    );
  }

  String _formatChartTime(DateTime value) {
    final local = value.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    final second = local.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
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

  void addSample({
    required DateTime receivedAt,
    required double value,
  }) {
    visibleSamples.add(
      _WearableChartSample(
        receivedAt: receivedAt,
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
        visibleSamples.first.receivedAt.isBefore(cutoff)) {
      visibleSamples.removeAt(0);
    }
  }
}

class _WearableChartSample {
  const _WearableChartSample({
    required this.receivedAt,
    required this.value,
  });

  final DateTime receivedAt;
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
      final seconds = sample.receivedAt.difference(start).inMilliseconds / 1000;
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

class WearableAcquisitionCompletedPage extends StatelessWidget {
  const WearableAcquisitionCompletedPage({
    super.key,
    required this.csvLogger,
  });

  final WearableAcquisitionCsvLogger csvLogger;

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

class DeviceConfigurationPage extends StatefulWidget {
  const DeviceConfigurationPage({
    super.key,
    required this.device,
    this.initialConfiguration,
    this.onConfigurationConfirmed,
  });

  final BluetoothDevice device;
  final BleConfiguration? initialConfiguration;
  final ValueChanged<BleConfiguration>? onConfigurationConfirmed;

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
  bool _isContinuing = false;

  bool get _isConfigurationOnly {
    return widget.onConfigurationConfirmed != null;
  }

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

  void _openAcquisitionInitializationPage() {
    if (_isContinuing) {
      return;
    }

    final configuration = BleConfiguration(
      enabledOptions: Map<String, bool>.from(_options),
      samplingFrequencySeconds: _selectedSamplingFrequency,
    );

    if (_isConfigurationOnly) {
      widget.onConfigurationConfirmed?.call(configuration);
      Navigator.of(context).pop();
      return;
    }

    setState(() {
      _isContinuing = true;
    });

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AcquisitionInitializationPage(
          device: widget.device,
          configuration: configuration,
        ),
      ),
    ).whenComplete(() {
      if (!mounted) {
        return;
      }

      setState(() {
        _isContinuing = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final buttonText = _isConfigurationOnly
        ? 'Confirm Configuration'
        : _isContinuing
            ? 'Opening...'
            : 'Continue';

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
                onPressed:
                    _isContinuing ? null : _openAcquisitionInitializationPage,
                child: Text(buttonText),
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

class AcquisitionInitializationPage extends StatefulWidget {
  const AcquisitionInitializationPage({
    super.key,
    required this.device,
    required this.configuration,
    this.recoverySnapshot,
  }) : _runtime = null;

  AcquisitionInitializationPage._withRuntime(
    _EnvironmentalAcquisitionController runtime,
  ) : device = runtime.initialDevice,
      configuration = runtime.configuration,
      recoverySnapshot = runtime.recoverySnapshot,
      _runtime = runtime;

  final BluetoothDevice device;
  final BleConfiguration configuration;
  final AcquisitionRecoverySnapshot? recoverySnapshot;
  final _EnvironmentalAcquisitionController? _runtime;

  @override
  State<AcquisitionInitializationPage> createState() => _AcquisitionInitializationPageState();
}

// This State owns only the presentation. Android acquisition ownership belongs
// to the engine runtime, which remains alive when its Activity/view detaches.
class _AcquisitionInitializationPageState extends State<AcquisitionInitializationPage> {
  late final _EnvironmentalAcquisitionController _controller;

  @override
  void initState() {
    super.initState();
    final retained = Platform.isAndroid ? _ActiveAcquisitionRuntime.activeOwner : null;
    _controller = widget._runtime ??
        (retained is _EnvironmentalAcquisitionController ? retained :
          _EnvironmentalAcquisitionController(
            initialDevice: widget.device,
            configuration: widget.configuration,
            recoverySnapshot: widget.recoverySnapshot,
          ));
    _controller.attach(this);
    _controller.addListener(_refresh);
    if (Platform.isAndroid) {
      unawaited(_controller.start());
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_controller.start());
      });
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_refresh);
    _controller.detach(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _controller.build(context);
}

class _EnvironmentalAcquisitionController extends ChangeNotifier with WidgetsBindingObserver {
  _EnvironmentalAcquisitionController({
    required this.initialDevice,
    required this.configuration,
    this.recoverySnapshot,
  }) {
    _initialize();
    if (Platform.isAndroid) {
      _ActiveAcquisitionRuntime.registerSingleOwner(this, () => page, resume);
    }
  }

  final BluetoothDevice initialDevice;
  final BleConfiguration configuration;
  final AcquisitionRecoverySnapshot? recoverySnapshot;
  late final DateTime _startedAt = DateTime.tryParse(recoverySnapshot?.startedAtIso8601 ?? '') ?? DateTime.now();
  late final String _sessionId = recoverySnapshot?.sessionId.isNotEmpty == true
      ? recoverySnapshot!.sessionId : const Uuid().v4();
  _AcquisitionInitializationPageState? _view;
  bool _disposed = false;
  bool _androidResourcesStopped = false;
  bool _needsProcessRecovery = false;
  bool _interruptionPending = false;
  bool _androidSessionPrepared = false;
  Future<void>? _startFuture;
  bool get mounted => !_disposed;
  bool get _viewAttached => _view?.mounted ?? false;
  BuildContext get context => _view!.context;

  AcquisitionInitializationPage get page =>
      AcquisitionInitializationPage._withRuntime(this);

  static Future<_EnvironmentalAcquisitionController> restore(AcquisitionRecoverySnapshot snapshot) async {
    final session = _ConnectedDeviceSession.fromRecoveryDevice(snapshot.devices.single);
    final controller = _EnvironmentalAcquisitionController(
      initialDevice: session.bleDevice,
      configuration: session.environmentalConfiguration!,
      recoverySnapshot: snapshot,
    );
    await controller.start();
    return controller;
  }

  Future<void> start() => _startFuture ??= _startInitialization();

  Future<void> resume() async {
    if (_disposed || _acquisitionStopped) return;
    if (Platform.isAndroid) await _gpsLocationService.resumeAfterAndroidActivityAttached();
    if (_needsProcessRecovery) _bleAutoReconnectCoordinator.start();
    if (_viewAttached) _syncSingleBleDisconnectionAlertDialog();
  }

  void attach(_AcquisitionInitializationPageState view) {
    _view = view;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_viewAttached) _syncSingleBleDisconnectionAlertDialog();
    });
  }

  void detach(_AcquisitionInitializationPageState view) {
    if (!identical(_view, view)) return;
    _view = null;
    _bleAlertDialogContext = null;
    _bleAlertDialogOpen = false;
    _stopSingleBleAlertAlarm();
    if (!Platform.isAndroid || (!_initializationStarted && !_acquisitionStarted && !_csvLogger.isStarted) || _acquisitionStopped) {
      _disposeRuntime();
    }
  }

  void setState(VoidCallback update) {
    if (_disposed) return;
    update();
    notifyListeners();
  }

  bool _stopConfirmationOpen = false;
  late BluetoothDevice _activeDevice;
  late final String _deviceDisplayName;
  late final BleConfigurationService _service;
  late final OpenRemoteMqttService _mqttService;
  late final AcquisitionCsvLogger _csvLogger;
  late final GpsLocationService _gpsLocationService;
  late final List<_MeasurementDefinition> _visibleMeasurements;
  late final Map<String, _MeasurementDefinition> _visibleMeasurementsByPrefix;

  final List<BleNotificationMessage> _messages = [];
  final Map<String, _LiveMeasurementValue> _liveMeasurementValues = {};
  final Map<String, List<_MeasurementChartSample>> _chartSamplesByPrefix = {};
  StreamSubscription<BleNotificationMessage>? _messagesSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<OpenRemoteMqttState>? _mqttStateSubscription;

  bool _isInitializing = true;
  bool _initializationStarted = false;
  bool _acquisitionStarted = false;
  bool _acquisitionStopped = false;
  bool _isStoppingAcquisition = false;
  String? _errorMessage;
  bool _canRetry = false;
  bool _requiresReconnect = false;
  bool _foregroundServiceStarted = false;
  bool _bleDisconnectedDuringActiveAcquisition = false;
  int _bleDisconnectionAlertVersion = 0;
  _BleReconnectStatus _bleReconnectStatus = _BleReconnectStatus.disconnected;
  String? _bleReconnectFailureMessage;
  final Set<String> _dismissedBleAlertKeys = {};
  final ValueNotifier<int> _bleAlertRevision = ValueNotifier<int>(0);
  late final _BleAutoReconnectCoordinator _bleAutoReconnectCoordinator;
  Timer? _bleAlertBeepTimer;
  BuildContext? _bleAlertDialogContext;
  bool _bleAlertDialogOpen = false;
  String? _backgroundStatusMessage;
  _LiveVisualizationMode _visualizationMode = _LiveVisualizationMode.cards;
  OpenRemoteMqttState _mqttState = const OpenRemoteMqttState(
    status: OpenRemoteMqttStatus.disconnected,
  );

  void _initialize() {
    WidgetsBinding.instance.addObserver(this);
    _activeDevice = initialDevice;
    _deviceDisplayName = recoverySnapshot?.deviceNames.firstOrNull ?? _deviceName(_activeDevice);
    _service = BleConfigurationService(_activeDevice);
    _mqttService = OpenRemoteMqttService();
    _csvLogger = AcquisitionCsvLogger();
    _gpsLocationService = GpsLocationService();
    _bleAutoReconnectCoordinator = _BleAutoReconnectCoordinator(
      runAutomaticCycle: _runSingleAutomaticBleReconnectCycle,
      hasPendingWork: _hasSingleAutomaticBleReconnectWork,
      canContinue: _canContinueSingleAutomaticBleReconnect,
      onStateChanged: _handleSingleAutoReconnectStateChanged,
    );
    _visibleMeasurements = _measurementDefinitions
        .where(
          (definition) =>
              configuration.enabledOptions[definition.label] ?? false,
        )
        .toList(growable: false);
    _visibleMeasurementsByPrefix = {
      for (final definition in _visibleMeasurements)
        definition.prefix: definition,
    };
    _messagesSubscription = _service.messages.listen((message) {
      if (_acquisitionStopped) {
        return;
      }
      if (Platform.isAndroid && _interruptionPending) {
        // A connection/configuration handshake does not prove the data stream
        // resumed. End the gap only when an actual notification is received.
        _interruptionPending = false;
        unawaited(AcquisitionRecoveryStore.closeInterruption(
          _activeDevice.remoteId.toString(),
        ).then((_) => AcquisitionRecoveryStore.updateStatus(
          logicalRoute: _ActiveAcquisitionRuntime.isForegroundVisible
              ? 'acquisition' : 'background',
          status: 'running',
        )).catchError((_) { _interruptionPending = true; }));
      }

      if (mounted) {
        setState(() {
          _messages.add(message);
          _updateLiveMeasurement(message);
        });
      } else {
        _messages.add(message);
        _updateLiveMeasurement(message);
      }
      if (_acquisitionStarted && _csvLogger.isStarted) {
        unawaited(
          _csvLogger.appendBleMessage(
            receivedAt: message.receivedAt,
            deviceName: _deviceDisplayName,
            gpsCoordinates: _gpsLocationService.currentCoordinates,
            value: message.value,
          ),
        );
      }
      unawaited(_publishPm10IfConnected(message.value));
    });
    _attachConnectionListener();
    _mqttStateSubscription = _mqttService.states.listen((state) {
      if (!mounted) {
        return;
      }

      setState(() {
        _mqttState = state;
      });

      if (state.status == OpenRemoteMqttStatus.failed &&
          state.message != null) {
        _appendLog('OpenRemote: ${state.message}');
      }
    });


  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _syncSingleBleDisconnectionAlertDialog();
      });
      return;
    }

    _stopSingleBleAlertAlarm();
  }

  void _attachConnectionListener() {
    unawaited(_connectionSubscription?.cancel());
    _connectionSubscription = _service.connectionState.listen((state) {
      if (_acquisitionStopped ||
          _isStoppingAcquisition ||
          (Platform.isAndroid && recoverySnapshot != null && _isInitializing) ||
          state != BluetoothConnectionState.disconnected) {
        return;
      }

      if (_acquisitionStarted) {
        _markSingleBleDisconnectedDuringAcquisition();
        return;
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _isInitializing = false;
        _errorMessage = 'BLE device disconnected.';
        _canRetry = true;
        _requiresReconnect = true;
      });
      _initializationStarted = false;
    });
  }

  void _markSingleBleDisconnectedDuringAcquisition() {
    if (_isStoppingAcquisition || _acquisitionStopped) {
      return;
    }

    if (_bleDisconnectedDuringActiveAcquisition &&
        _bleReconnectStatus != _BleReconnectStatus.reconnected) {
      return;
    }

    if (mounted) {
      setState(() {
        _isInitializing = false;
        _bleDisconnectedDuringActiveAcquisition = true;
        _bleDisconnectionAlertVersion += 1;
        _bleReconnectStatus = _BleReconnectStatus.disconnected;
        _bleReconnectFailureMessage = null;
      });
    } else {
      _bleDisconnectedDuringActiveAcquisition = true;
      _bleDisconnectionAlertVersion += 1;
      _bleReconnectStatus = _BleReconnectStatus.disconnected;
      _bleReconnectFailureMessage = null;
    }
    _notifySingleBleAlertChanged();
    if (Platform.isAndroid) {
      _interruptionPending = true;
      _backgroundStatusMessage = _mergeStatusMessage(
        _backgroundStatusMessage,
        'Data reception was interrupted. The interruption is recorded in session metadata beside the CSV.',
      );
      unawaited(AcquisitionRecoveryStore.recordInterruption(
        deviceId: _activeDevice.remoteId.toString(),
        startedAt: DateTime.now(),
        reason: 'BLE connection interrupted',
      ));
    }
    _initializationStarted = false;

    unawaited(
      AndroidAcquisitionForegroundService.showBleDisconnectionAlert(
        _deviceDisplayName,
      ),
    );
    _bleAutoReconnectCoordinator.start();

    if (!_ActiveAcquisitionRuntime.isForegroundVisible) {
      return;
    }

    _syncSingleBleDisconnectionAlertDialog();
  }

  void _disposeRuntime() {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _bleAutoReconnectCoordinator.cancel(notify: false);
    _stopSingleBleAlertAlarm();
    _bleAlertRevision.dispose();
    if (_androidResourcesStopped) {
      super.dispose();
      return;
    }
    if (_acquisitionStarted && !_acquisitionStopped) {
      super.dispose();
      return;
    }

    unawaited(_messagesSubscription?.cancel());
    unawaited(_connectionSubscription?.cancel());
    unawaited(_mqttStateSubscription?.cancel());
    if (!_acquisitionStarted || _acquisitionStopped) {
      unawaited(_csvLogger.stop());
      unawaited(_gpsLocationService.dispose());
      unawaited(_mqttService.dispose());
      unawaited(_service.dispose());
      unawaited(AndroidAcquisitionForegroundService.stop());
    }
    super.dispose();
  }

  Future<void> _startInitialization() async {
    if (_initializationStarted || _disposed) return;
    _initializationStarted = true;
    setState(() {
      _isInitializing = true;
      _errorMessage = null;
      _canRetry = false;
      _requiresReconnect = false;
      if (!_acquisitionStarted) {
        _messages.clear();
        _liveMeasurementValues.clear();
        _chartSamplesByPrefix.clear();
      }
    });
    try {
      if (Platform.isAndroid) {
        if (recoverySnapshot != null && recoverySnapshot!.csvFilePath == null) {
          throw StateError('The original acquisition CSV path is unavailable.');
        }
        final previous = recoverySnapshot;
        if (previous != null) {
          _interruptionPending = true;
          await AcquisitionRecoveryStore.recordInterruption(
            deviceId: _activeDevice.remoteId.toString(),
            startedAt: DateTime.tryParse(previous.lastHeartbeatIso8601 ?? '') ??
                DateTime.tryParse(previous.startedAtIso8601 ?? '') ?? DateTime.now(),
            reason: 'Acquisition process interrupted; samples may be missing since the last persisted heartbeat',
          );
        }
        // Open and persist the original output before enabling data streams.
        await _csvLogger.start(
          existingFilePath: recoverySnapshot?.csvFilePath,
          existingFileName: recoverySnapshot?.csvFileName,
          startedAt: _startedAt,
          sessionId: _sessionId,
        );
        await _activateAndroidBackgroundSupport();
        _androidSessionPrepared = true;
        await _gpsLocationService.start();
        if (recoverySnapshot != null) {
          _acquisitionStarted = true;
          _needsProcessRecovery = true;
          _backgroundStatusMessage = _mergeStatusMessage(
            _backgroundStatusMessage,
            'Acquisition resumed after an interruption. Samples during the interruption may be missing; details are retained with the CSV.',
          );
          if (recoverySnapshot!.runtimeState['openRemoteEnabled'] == true) {
            unawaited(_connectOpenRemote());
          }
          final gpsStatusMessage = _gpsLocationService.statusMessage;
          if (gpsStatusMessage != null) {
            _backgroundStatusMessage = _mergeStatusMessage(
              _backgroundStatusMessage, gpsStatusMessage,
            );
          }
          await AcquisitionRecoveryStore.updateStatus(
            logicalRoute: 'acquisition', status: 'recovering',
          );
          _isInitializing = false;
          // Present the recovered acquisition immediately. The existing
          // coordinator exclusively owns connection/configuration attempts,
          // so startup does not wait for an absent device or create a second
          // competing reconnect operation.
          _markSingleBleDisconnectedDuringAcquisition();
          return;
        }
      }
      await _service.initialize(configuration);
      _needsProcessRecovery = false;
      if (!_csvLogger.isStarted) {
        await _csvLogger.start();
        await _gpsLocationService.start();
      }
      final gpsStatusMessage = _gpsLocationService.statusMessage;
      if (gpsStatusMessage != null) {
        _backgroundStatusMessage = _mergeStatusMessage(_backgroundStatusMessage, gpsStatusMessage);
      }
      _acquisitionStarted = true;
      if (!Platform.isAndroid) await _activateAndroidBackgroundSupport();
      if (Platform.isAndroid) {
        await AcquisitionRecoveryStore.updateStatus(logicalRoute: 'acquisition', status: 'running');
      }
      setState(() {
        _isInitializing = false;
        _bleDisconnectedDuringActiveAcquisition = false;
        _bleReconnectStatus = _BleReconnectStatus.reconnected;
      });
    } catch (error) {
      if (_disposed) return;
      if (Platform.isAndroid && recoverySnapshot != null &&
          (!_csvLogger.isStarted || !_androidSessionPrepared)) {
        await _abandonFailedRestoration();
        rethrow;
      }
      if (Platform.isAndroid && recoverySnapshot != null && _csvLogger.isStarted) {
        // Missing devices remain part of this session. Retry with the same
        // coordinator and timing as an ordinary active-acquisition disconnect.
        _acquisitionStarted = true;
        _needsProcessRecovery = true;
        _isInitializing = false;
        _errorMessage = null;
        _markSingleBleDisconnectedDuringAcquisition();
        return;
      }
      setState(() {
        _isInitializing = false;
        _errorMessage = error.toString();
        _canRetry = error is BleConfigurationException && error.canRetry;
        _requiresReconnect = false;
      });
      await AndroidAcquisitionForegroundService.clearBleDisconnectionAlert();
      // An Android session with an open CSV remains recoverable on reopening.
      if (!Platform.isAndroid || !_csvLogger.isStarted) {
        await AndroidAcquisitionForegroundService.stop();
      }
    }
  }

  Future<void> _abandonFailedRestoration() async {
    // Keep the recovery envelope intact so an unavailable original CSV can be
    // retried. This partially constructed controller must not own the screen.
    _bleAutoReconnectCoordinator.cancel(notify: false);
    try {
      await _messagesSubscription?.cancel();
      await _connectionSubscription?.cancel();
      await _mqttStateSubscription?.cancel();
      await Future.wait<void>([
        _csvLogger.stop(), _gpsLocationService.dispose(),
        _mqttService.dispose(), _service.dispose(),
      ]);
    } catch (_) {
      // The original restoration error remains the useful user-facing error.
    }
    _androidResourcesStopped = true;
    _disposeRuntime();
    await _ActiveAcquisitionRuntime.markInactive();
    try {
      await AndroidAcquisitionForegroundService.stop();
    } catch (_) {}
  }

  Future<void> _activateAndroidBackgroundSupport() async {
    if (!Platform.isAndroid) return;
    if (await AndroidAcquisitionForegroundService.isActivityAttached()) {
      final notificationStatus = await Permission.notification.request();
      if (!notificationStatus.isGranted) {
        _backgroundStatusMessage = _mergeStatusMessage(
          _backgroundStatusMessage,
          'Android background acquisition may be unreliable without the persistent notification.',
        );
      }
    }
    final session = _ConnectedDeviceSession(
      device: _activeDevice,
      deviceId: _activeDevice.remoteId.toString(),
      deviceName: _deviceDisplayName,
      type: KnownDeviceType.environmentalMonitor,
    )..environmentalConfiguration = configuration;
    await AcquisitionRecoveryStore.saveActive(
      sessionId: _sessionId,
      workflow: 'single-environmental',
      devices: [session.toRecoveryDevice()],
      runtimeState: {
        ...?recoverySnapshot?.runtimeState,
        'gpsEnabled': true,
      },
      acquisitionType: 'environmentalMonitor',
      deviceNames: [_deviceDisplayName],
      deviceTypes: [KnownDeviceType.environmentalMonitor.name],
      configurationSummaries: [_summarizeEnvironmentalConfiguration(configuration)],
      startedAt: _startedAt,
      logicalRoute: 'acquisition',
      status: _acquisitionStarted ? 'running' : 'initializing',
      csvFileName: _csvLogger.fileName,
      csvFilePath: _csvLogger.file?.path,
    );
    await _ActiveAcquisitionRuntime.markActive();
    try {
      await AndroidAcquisitionForegroundService.start();
      _foregroundServiceStarted = true;
    } catch (error) {
      _backgroundStatusMessage = _mergeStatusMessage(
        _backgroundStatusMessage,
        'Android background acquisition may be unreliable: $error',
      );
    }
  }

  Future<void> _retryInitialization() async {
    if (_isInitializing) {
      return;
    }

    _initializationStarted = false;
    await _startInitialization();
  }

  Future<void> _reconnectAndRestartInitialization() async {
    if (_acquisitionStarted && _bleDisconnectedDuringActiveAcquisition) {
      await _reconnectSingleEnvironmentalAfterDisconnection();
      return;
    }

    if (_isInitializing) {
      return;
    }

    if (mounted) {
      setState(() {
        _isInitializing = true;
        _errorMessage = null;
        _canRetry = false;
      });
    }

    try {
      await _activeDevice.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 12),
      );
      _initializationStarted = false;
      await _startInitialization();
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isInitializing = false;
        _errorMessage = 'Could not reconnect to $_deviceDisplayName: $error';
        _canRetry = true;
        _requiresReconnect = true;
      });
    }
  }

  Future<void> _reconnectSingleEnvironmentalAfterDisconnection() async {
    if (!_canAttemptSingleBleReconnect()) {
      return;
    }

    await _bleAutoReconnectCoordinator.requestImmediate(
      operation: _runSingleBleReconnectAttempt,
    );
  }

  Future<void> _runSingleAutomaticBleReconnectCycle() async {
    if (!_canAttemptSingleBleReconnect()) {
      return;
    }

    await _runSingleBleReconnectAttempt();
  }

  Future<void> _runSingleBleReconnectAttempt() async {
    if (!_canAttemptSingleBleReconnect()) {
      return;
    }

    setState(() {
      _bleReconnectStatus = _BleReconnectStatus.reconnecting;
      _bleReconnectFailureMessage = null;
    });
    _notifySingleBleAlertChanged();

    try {
      final reconnectedDevice = await _BleReconnectHelper.reconnect(
        currentDevice: _activeDevice,
        deviceId: _activeDevice.remoteId.toString(),
        deviceName: _deviceDisplayName,
      );
      _activeDevice = reconnectedDevice;
      if (!_canContinueSingleAutomaticBleReconnect()) {
        return;
      }
      if (_needsProcessRecovery) {
        _service.device = reconnectedDevice;
        await _service.initialize(configuration);
        _needsProcessRecovery = false;
      } else {
        await _service.resumeNotificationsAfterReconnect(
          reconnectedDevice: reconnectedDevice,
        );
      }
      _attachConnectionListener();

      if (!_canContinueSingleAutomaticBleReconnect()) {
        return;
      }

      setState(() {
        _bleDisconnectedDuringActiveAcquisition = false;
        _bleReconnectStatus = _BleReconnectStatus.reconnected;
        _bleReconnectFailureMessage = null;
      });
      _notifySingleBleAlertChanged();
      unawaited(AndroidAcquisitionForegroundService.clearBleDisconnectionAlert());
      _closeSingleBleAlertDialog(dismissCurrentDevice: false);
    } catch (_) {
      try {
        await _activeDevice.disconnect();
      } catch (_) {}

      if (!_canContinueSingleAutomaticBleReconnect()) {
        return;
      }

      setState(() {
        _bleDisconnectedDuringActiveAcquisition = true;
        _bleReconnectStatus = _BleReconnectStatus.failed;
        _bleReconnectFailureMessage =
            'Could not reconnect to $_deviceDisplayName. Move closer and try again.';
      });
      _notifySingleBleAlertChanged();
    }
  }

  bool _hasSingleAutomaticBleReconnectWork() {
    return _bleDisconnectedDuringActiveAcquisition &&
        !_dismissedBleAlertKeys.contains(_singleBleAlertKey);
  }

  bool _canContinueSingleAutomaticBleReconnect() {
    return !_disposed && !_isStoppingAcquisition && !_acquisitionStopped;
  }

  bool _canAttemptSingleBleReconnect() {
    return _canContinueSingleAutomaticBleReconnect() &&
        _acquisitionStarted &&
        _bleDisconnectedDuringActiveAcquisition &&
        !_dismissedBleAlertKeys.contains(_singleBleAlertKey) &&
        _bleReconnectStatus != _BleReconnectStatus.reconnecting &&
        _bleReconnectStatus != _BleReconnectStatus.reconnected;
  }

  void _handleSingleAutoReconnectStateChanged() {
    _notifySingleBleAlertChanged();
    if (mounted) {
      setState(() {});
    }
  }

  void _syncSingleBleDisconnectionAlertDialog() {
    if (!_viewAttached || !Platform.isAndroid) {
      return;
    }

    if (_bleAlertDialogOpen) {
      if (!_bleDisconnectedDuringActiveAcquisition) {
        _closeSingleBleAlertDialog(dismissCurrentDevice: false);
      }
      return;
    }

    if (!_ActiveAcquisitionRuntime.isForegroundVisible ||
        !_bleDisconnectedDuringActiveAcquisition ||
        _dismissedBleAlertKeys.contains(_singleBleAlertKey)) {
      return;
    }

    _showSingleBleAlertDialog();
  }

  void _showSingleBleAlertDialog() {
    if (_bleAlertDialogOpen || !_viewAttached) {
      return;
    }

    _bleAlertDialogOpen = true;
    _startSingleBleAlertAlarm();
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          _bleAlertDialogContext = dialogContext;
          return ValueListenableBuilder<int>(
            valueListenable: _bleAlertRevision,
            builder: (_, _, _) {
              return _BleDisconnectionAlertDialog(
                items: [_singleBleAlertItem],
                onClose: () {
                  _closeSingleBleAlertDialog(dismissCurrentDevice: true);
                },
              );
            },
          );
        },
      ).whenComplete(() {
        _bleAlertDialogOpen = false;
        _bleAlertDialogContext = null;
        _stopSingleBleAlertAlarm();
        if (mounted) {
          setState(() {});
        }
      }),
    );
  }

  _BleDisconnectionAlertItem get _singleBleAlertItem {
    return _BleDisconnectionAlertItem(
      id: _activeDevice.remoteId.toString(),
      deviceName: _deviceDisplayName,
      status: _bleReconnectStatus,
      reconnectEnabled: !_bleAutoReconnectCoordinator.isOperationInProgress &&
          !_isStoppingAcquisition &&
          !_acquisitionStopped,
      failureMessage: _bleReconnectFailureMessage,
      onReconnect: () {
        unawaited(_reconnectSingleEnvironmentalAfterDisconnection());
      },
    );
  }

  void _closeSingleBleAlertDialog({required bool dismissCurrentDevice}) {
    if (dismissCurrentDevice && _bleDisconnectedDuringActiveAcquisition) {
      _dismissedBleAlertKeys.add(_singleBleAlertKey);
      _bleAutoReconnectCoordinator.cancel();
    }

    _stopSingleBleAlertAlarm();
    final dialogContext = _bleAlertDialogContext;
    _bleAlertDialogContext = null;
    if (dialogContext != null && dialogContext.mounted) {
      Navigator.of(dialogContext).pop();
    }
  }

  void _startSingleBleAlertAlarm() {
    _stopSingleBleAlertAlarm();
    _playSingleBleAlertCue();
    _bleAlertBeepTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _playSingleBleAlertCue();
    });
  }

  void _stopSingleBleAlertAlarm() {
    _bleAlertBeepTimer?.cancel();
    _bleAlertBeepTimer = null;
  }

  void _playSingleBleAlertCue() {
    if (!Platform.isAndroid) {
      return;
    }

    unawaited(AndroidAcquisitionForegroundService.playBleDisconnectionAlarmCue());
    unawaited(SystemSound.play(SystemSoundType.alert).catchError((_) {}));
    unawaited(HapticFeedback.vibrate().catchError((_) {}));
  }

  void _notifySingleBleAlertChanged() {
    _bleAlertRevision.value += 1;
  }

  String get _singleBleAlertKey {
    return '${_activeDevice.remoteId}:$_bleDisconnectionAlertVersion';
  }

  Future<void> _connectOpenRemote() async {
    if (_mqttState.status == OpenRemoteMqttStatus.connecting ||
        _mqttState.status == OpenRemoteMqttStatus.connected) {
      return;
    }

    // Preserve the legacy target explicitly; device mapping belongs to the
    // current multi-device session manager only.
    if (Platform.isAndroid) {
      await AcquisitionRecoveryStore.mergeRuntimeState({
        'openRemoteEnabled': true,
        'openRemoteAssetId': '1zKVSJ8J0enUWtWRBY4bul',
      });
    }
    await _mqttService.connect(assetId: '1zKVSJ8J0enUWtWRBY4bul');
  }

  Future<void> _publishPm10IfConnected(String bleValue) async {
    if (!_mqttService.isConnected) {
      return;
    }

    final pm10 = parsePm10Value(bleValue);
    if (pm10 == null) {
      return;
    }

    final sent = await _mqttService.publishPm10(pm10);
    if (!sent || !mounted) {
      return;
    }

    _appendLog('MQTT sent — PM10: ${_formatPm10(pm10)}');
  }

  void _updateLiveMeasurement(BleNotificationMessage message) {
    final separatorIndex = message.value.indexOf(':');
    if (separatorIndex <= 0) {
      return;
    }

    final prefix = message.value.substring(0, separatorIndex);
    final definition = _visibleMeasurementsByPrefix[prefix];
    if (definition == null) {
      return;
    }

    final rawValue = message.value.substring(separatorIndex + 1);
    final parsedValue = double.tryParse(rawValue);
    if (parsedValue == null) {
      return;
    }

    final previous = _liveMeasurementValues[definition.prefix];
    _liveMeasurementValues[definition.prefix] = _LiveMeasurementValue(
      formattedValue: parsedValue.toStringAsFixed(1),
      updatedAt: message.receivedAt,
      updateCount: (previous?.updateCount ?? 0) + 1,
    );

    final samples = _chartSamplesByPrefix.putIfAbsent(
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

  void _appendLog(String value) {
    if (!mounted) {
      return;
    }

    setState(() {
      _messages.add(
        BleNotificationMessage(
          receivedAt: DateTime.now(),
          value: value,
        ),
      );
    });
  }

  String _formatPm10(double value) {
    if (value == value.truncateToDouble()) {
      return value.toInt().toString();
    }

    return value.toString();
  }

  String _formatDashboardTime(DateTime value) {
    final local = value.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    final second = local.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  String _deviceName(BluetoothDevice device) {
    final platformName = device.platformName.trim();
    return platformName.isEmpty ? 'Unknown device' : platformName;
  }

  Future<void> _requestStopAcquisition() async {
    if (!_viewAttached ||
        _stopConfirmationOpen ||
        _isStoppingAcquisition ||
        _acquisitionStopped) {
      return;
    }

    _stopConfirmationOpen = true;
    final bool confirmed;
    try {
      confirmed = await _confirmStopAcquisition(context);
    } finally {
      _stopConfirmationOpen = false;
    }
    if (!_viewAttached || !confirmed) {
      return;
    }
    await _stopAcquisition();
  }

  Future<void> _stopAcquisition() async {
    if (Platform.isAndroid) {
      await _stopAndroidAcquisition();
      return;
    }
    if (_isStoppingAcquisition || _acquisitionStopped) {
      return;
    }

    if (Platform.isAndroid) await AcquisitionRecoveryStore.markStopping();
    _ActiveAcquisitionRuntime.beginStopping();
    _bleAutoReconnectCoordinator.cancel();
    setState(() {
      _isStoppingAcquisition = true;
      _acquisitionStopped = true;
    });

    try {
      await _messagesSubscription?.cancel();
      _messagesSubscription = null;
      await _csvLogger.stop();
      await _gpsLocationService.stop();
      if (Platform.isAndroid) {
        await _connectionSubscription?.cancel();
        _connectionSubscription = null;
        await _mqttStateSubscription?.cancel();
        _mqttStateSubscription = null;
        await _mqttService.dispose();
        await _service.dispose();
      }
      await AndroidAcquisitionForegroundService.clearBleDisconnectionAlert();
      await AndroidAcquisitionForegroundService.stop();
      await AcquisitionRecoveryStore.clear();
      await _ActiveAcquisitionRuntime.markInactive();

      if (!_viewAttached) {
        return;
      }
      final viewContext = context;
      if (!viewContext.mounted) {
        return;
      }

      await Navigator.of(viewContext).push(
        MaterialPageRoute<void>(
          builder: (_) => AcquisitionCompletedPage(csvLogger: _csvLogger),
        ),
      );
    } catch (error) {
      if (!_viewAttached) {
        return;
      }
      final viewContext = context;
      if (!viewContext.mounted) {
        return;
      }

      setState(() {
        _acquisitionStopped = false;
        _isStoppingAcquisition = false;
      });
      ScaffoldMessenger.of(viewContext).showSnackBar(
        const SnackBar(content: Text('Could not stop acquisition')),
      );
    }
  }

  Future<void> _stopAndroidAcquisition() async {
    if (_isStoppingAcquisition || _acquisitionStopped) return;
    try {
      await AcquisitionRecoveryStore.markStopping();
      _ActiveAcquisitionRuntime.beginStopping();
    } catch (error) {
      if (_viewAttached) {
        final viewContext = context;
        if (!viewContext.mounted) {
          return;
        }
        ScaffoldMessenger.of(viewContext).showSnackBar(
          const SnackBar(content: Text('Could not save acquisition stop. Please try again.')),
        );
      }
      return;
    }
    _bleAutoReconnectCoordinator.cancel();
    _stopSingleBleAlertAlarm();
    _closeSingleBleAlertDialog(dismissCurrentDevice: false);
    setState(() {
      _isStoppingAcquisition = true;
      _acquisitionStopped = true;
    });
    Object? cleanupError;
    Future<void> clean(Future<void> Function() operation) async {
      try {
        await operation();
      } catch (error) {
        cleanupError ??= error;
      }
    }
    // Teardown all owners even if one plugin fails. The durable tombstone is
    // already terminal, so neither a late callback nor a restart can resume it.
    await clean(_bleAutoReconnectCoordinator.waitForIdle);
    await clean(() async { await _messagesSubscription?.cancel(); });
    _messagesSubscription = null;
    await clean(() async { await _connectionSubscription?.cancel(); });
    _connectionSubscription = null;
    await clean(_csvLogger.stop);
    await clean(_gpsLocationService.dispose);
    await clean(() async { await _mqttStateSubscription?.cancel(); });
    _mqttStateSubscription = null;
    await clean(_mqttService.dispose);
    await clean(_service.dispose);
    await clean(() => _activeDevice.disconnect());
    await clean(AndroidAcquisitionForegroundService.clearBleDisconnectionAlert);
    await clean(AndroidAcquisitionForegroundService.stop);
    await clean(AcquisitionRecoveryStore.clear);
    _androidResourcesStopped = true;
    await _ActiveAcquisitionRuntime.markInactive();
    if (!_viewAttached) return;
    final viewContext = context;
    if (!viewContext.mounted) {
      return;
    }
    if (cleanupError != null) {
      ScaffoldMessenger.of(viewContext).showSnackBar(
        SnackBar(content: Text('Acquisition stopped. Some resources could not be closed cleanly: $cleanupError')),
      );
    }
    await Navigator.of(viewContext).push(
      MaterialPageRoute<void>(builder: (_) => AcquisitionCompletedPage(csvLogger: _csvLogger)),
    );
  }

  Widget build(BuildContext context) {
    final title = _isInitializing || (_errorMessage != null && !_acquisitionStarted)
        ? 'Acquisition Initialization'
        : 'Acquisition in progress...';

    return PopScope(
        canPop: Platform.isAndroid ? !_isInitializing && !_acquisitionStarted : !_isInitializing,
      child: AbsorbPointer(
        absorbing: _isInitializing,
        child: Scaffold(
          backgroundColor: Colors.white,
          appBar: AppBar(
            backgroundColor: Colors.white,
            title: Text(title),
          ),
          body: SafeArea(
            child: _buildBody(context),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_isInitializing) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (_errorMessage != null && !_acquisitionStarted) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              if (_canRetry) ...[
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _requiresReconnect
                      ? _reconnectAndRestartInitialization
                      : _retryInitialization,
                  child: Text(_requiresReconnect ? 'Reconnect' : 'Retry'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        _buildVisualizationModeSelector(),
        if (_bleDisconnectedDuringActiveAcquisition)
          _buildSingleBleDisconnectedBanner(),
        _buildBackgroundStatus(),
        Expanded(
          child: _buildLiveVisualization(),
        ),
        _buildStopAcquisitionButton(),
        _buildOpenRemoteBanner(context),
      ],
    );
  }

  Widget _buildSingleBleDisconnectedBanner() {
    final colorScheme = Theme.of(context).colorScheme;
    final message = _bleReconnectFailureMessage ?? _bleReconnectStatus.label;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                color: colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: colorScheme.onErrorContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBackgroundStatus() {
    if (!Platform.isAndroid) {
      return const SizedBox.shrink();
    }

    final warning = _backgroundStatusMessage;
    final colorScheme = Theme.of(context).colorScheme;
    final backgroundColor = warning == null
        ? Colors.green.shade50
        : colorScheme.errorContainer;
    final foregroundColor = warning == null
        ? Colors.green.shade900
        : colorScheme.onErrorContainer;
    final text = warning ??
        (_foregroundServiceStarted
            ? 'Background acquisition active'
            : 'Background acquisition starting');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(
                warning == null
                    ? Icons.notifications_active
                    : Icons.warning_amber_rounded,
                size: 18,
                color: foregroundColor,
              ),
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

  Widget _buildVisualizationModeSelector() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Align(
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
          selected: {_visualizationMode},
          onSelectionChanged: (selection) {
            setState(() {
              _visualizationMode = selection.first;
            });
          },
        ),
      ),
    );
  }

  Widget _buildLiveVisualization() {
    return switch (_visualizationMode) {
      _LiveVisualizationMode.cards => _buildLiveMeasurementsGrid(),
      _LiveVisualizationMode.charts => _buildLiveMeasurementsCharts(),
    };
  }

  Widget _buildStopAcquisitionButton() {
    return SafeArea(
      top: false,
      bottom: false,
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: SizedBox(
        width: double.infinity,
        height: 48,
        child: FilledButton(
          onPressed: _isStoppingAcquisition ? null : _requestStopAcquisition,
          child: Text(
            _isStoppingAcquisition ? 'Stopping...' : 'Stop acquisition',
          ),
        ),
      ),
    );
  }

  Widget _buildLiveMeasurementsGrid() {
    if (_visibleMeasurements.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No measurements selected.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _visibleMeasurements.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.9,
      ),
      itemBuilder: (context, index) {
        final definition = _visibleMeasurements[index];
        final value = _liveMeasurementValues[definition.prefix];

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

  Widget _buildLiveMeasurementsCharts() {
    if (_visibleMeasurements.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No measurements selected.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _visibleMeasurements.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final definition = _visibleMeasurements[index];
        final samples = _chartSamplesByPrefix[definition.prefix] ?? const [];
        final value = _liveMeasurementValues[definition.prefix];

        return _LiveMeasurementChartCard(
          definition: definition,
          samples: samples,
          currentValue: value,
          formatTime: _formatDashboardTime,
        );
      },
    );
  }

  Widget _buildOpenRemoteBanner(BuildContext context) {
    final status = _mqttState.status;
    final canTap = status == OpenRemoteMqttStatus.disconnected ||
        status == OpenRemoteMqttStatus.failed;
    final colorScheme = Theme.of(context).colorScheme;

    final text = switch (status) {
      OpenRemoteMqttStatus.connecting => 'Connecting to OpenRemote...',
      OpenRemoteMqttStatus.connected => 'Connected to OpenRemote',
      OpenRemoteMqttStatus.failed => 'Connection failed — Tap to retry',
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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Material(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: canTap ? _connectOpenRemote : null,
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
                          _mqttState.message != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          _mqttState.message!,
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

class AcquisitionCompletedPage extends StatelessWidget {
  const AcquisitionCompletedPage({
    super.key,
    required this.csvLogger,
  });

  final AcquisitionCsvLogger csvLogger;

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
