import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:app_lares/ble_configuration_service.dart';
import 'package:app_lares/services/acquisition_csv_logger.dart';
import 'package:app_lares/services/gps_location_service.dart';
import 'package:app_lares/services/mqtt_service.dart';
import 'package:app_lares/services/pm10_parser.dart';
import 'package:app_lares/services/wearable_acquisition_csv_logger.dart';
import 'package:app_lares/wearable_configuration_service.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  FlutterBluePlus.setOperationQueueMode(OperationQueueMode.perDevice);
  runApp(const LaresApp());
}

class LaresApp extends StatelessWidget {
  const LaresApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lares',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const AccessCodePage(),
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

class BluetoothScanningPage extends StatefulWidget {
  const BluetoothScanningPage({super.key});

  @override
  State<BluetoothScanningPage> createState() => _BluetoothScanningPageState();
}

class _BluetoothScanningPageState extends State<BluetoothScanningPage> {
  final Map<String, ScanResult> _scanResults = {};
  final Map<String, int> _discoveryOrder = {};
  final Set<String> _connectingDeviceIds = {};
  final Set<String> _connectedDeviceIds = {};
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<bool>? _isScanningSubscription;

  int _nextDiscoveryIndex = 0;
  bool _isScanning = false;
  bool _showOnlyLaresDevices = false;
  bool _sortBySignalStrength = false;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _listenToScanState();
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _isScanningSubscription?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
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

  Future<void> _startScan() async {
    setState(() {
      _scanResults.clear();
      _discoveryOrder.clear();
      _nextDiscoveryIndex = 0;
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

    if (_connectedDeviceIds.contains(id)) {
      await _disconnectFromDevice(result);
      return;
    }

    await _connectToDevice(result);
  }

  Future<void> _connectToDevice(ScanResult result) async {
    final device = result.device;
    final id = _deviceId(device);
    final displayName = _displayDeviceName(result);

    setState(() {
      _connectingDeviceIds.add(id);
      _statusMessage = null;
    });

    try {
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 12),
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _connectedDeviceIds.add(id);
      });

      if (_isEnvDevice(result)) {
        await _openDeviceConfigurationPage(device);
      } else if (_isWearableConfigurationDevice(result)) {
        await _openWearableDeviceConfigurationPage(device, displayName);
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

  bool _isEnvDevice(ScanResult result) {
    return _matchesAnyDeviceName(result, const ['env']);
  }

  bool _isWearableConfigurationDevice(ScanResult result) {
    return _matchesAnyDeviceName(
      result,
      const ['respiratorymonitor', 'imu'],
    );
  }

  bool _isLaresFilterDevice(ScanResult result) {
    return _matchesAnyDeviceName(
      result,
      const ['lares', 'respiratorymonitor', 'imu'],
    );
  }

  bool _matchesAnyDeviceName(ScanResult result, List<String> needles) {
    return _deviceNameCandidates(result).any((name) {
      final normalizedName = _normalizeDeviceName(name);
      return needles.any((needle) => normalizedName.contains(needle));
    });
  }

  String _normalizeDeviceName(String value) {
    return value.trim().toLowerCase();
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
    final names = _deviceNameCandidates(result);
    return names.isEmpty ? 'Unknown device' : names.first;
  }

  Future<void> _openDeviceConfigurationPage(BluetoothDevice device) async {
    await _stopScanBeforeNavigation();
    if (!mounted) {
      return;
    }

    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DeviceConfigurationPage(device: device),
        ),
      ),
    );
  }

  Future<void> _openWearableDeviceConfigurationPage(
    BluetoothDevice device,
    String deviceName,
  ) async {
    await _stopScanBeforeNavigation();
    if (!mounted) {
      return;
    }

    unawaited(
      Navigator.of(context)
          .push(
            MaterialPageRoute<void>(
              builder: (_) => WearableDeviceConfigurationPage(
                device: device,
                deviceName: deviceName,
                onDisconnected: () => _markDeviceDisconnected(device),
              ),
            ),
          )
          .whenComplete(() => _markDeviceDisconnected(device)),
    );
  }

  Future<void> _stopScanBeforeNavigation() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {
      // Best effort: navigation should not be blocked by a stale scan state.
    }
  }

  void _markDeviceDisconnected(BluetoothDevice device) {
    if (!mounted) {
      return;
    }

    final id = _deviceId(device);
    setState(() {
      _connectedDeviceIds.remove(id);
      _connectingDeviceIds.remove(id);
    });
  }

  Future<void> _disconnectFromDevice(ScanResult result) async {
    final device = result.device;
    final id = _deviceId(device);
    final displayName = _displayDeviceName(result);

    setState(() {
      _connectingDeviceIds.add(id);
      _statusMessage = null;
    });

    try {
      await device.disconnect();

      if (!mounted) {
        return;
      }

      setState(() {
        _connectedDeviceIds.remove(id);
      });
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

    if (_showOnlyLaresDevices) {
      devices = devices.where(_isLaresFilterDevice).toList();
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

  void _toggleLaresFilter() {
    setState(() {
      _showOnlyLaresDevices = !_showOnlyLaresDevices;
    });
  }

  void _toggleSignalSort() {
    setState(() {
      _sortBySignalStrength = !_sortBySignalStrength;
    });
  }

  Widget _buildScanOptionButtons(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        _buildScanOptionButton(
          context,
          label: 'LARES Devices',
          selected: _showOnlyLaresDevices,
          onPressed: _toggleLaresFilter,
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
    final devices = _displayDevices();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scanning Bluetooth Devices'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              icon: Icon(_isScanning ? Icons.bluetooth_searching : Icons.search),
              label: Text(_isScanning ? 'Scanning...' : 'Scan Bluetooth Devices'),
              onPressed: _isScanning ? null : _startScan,
            ),
            const SizedBox(height: 12),
            _buildScanOptionButtons(context),
            if (_statusMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _statusMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            Expanded(
              child: devices.isEmpty
                  ? const Center(
                      child: Text(
                        'Press the scan button to find nearby Bluetooth LE devices.',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.separated(
                      itemCount: devices.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final result = devices[index];
                        final device = result.device;
                        final id = _deviceId(device);
                        final isConnected = _connectedDeviceIds.contains(id);
                        final isBusy = _connectingDeviceIds.contains(id);

                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(_displayDeviceName(result)),
                          subtitle: Text('$id - RSSI ${result.rssi} dBm'),
                          trailing: FilledButton(
                            onPressed: isBusy
                                ? null
                                : () => _toggleConnection(result),
                            child: Text(
                              isBusy
                                  ? 'Wait'
                                  : isConnected
                                      ? 'Disconnect'
                                      : 'Connect',
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class WearableDeviceConfigurationPage extends StatefulWidget {
  const WearableDeviceConfigurationPage({
    super.key,
    required this.device,
    required this.deviceName,
    this.onDisconnected,
  });

  final BluetoothDevice device;
  final String deviceName;
  final VoidCallback? onDisconnected;

  @override
  State<WearableDeviceConfigurationPage> createState() =>
      _WearableDeviceConfigurationPageState();
}

class _WearableDeviceConfigurationPageState
    extends State<WearableDeviceConfigurationPage> {
  late final WearableConfigurationBleService _service;
  late final WearableAcquisitionCsvLogger _csvLogger;
  late final GpsLocationService _gpsLocationService;

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
  bool _isDisposing = false;
  bool _disconnectionNotified = false;
  StreamSubscription<WearableAgmReceivedSample>? _agmSamplesSubscription;

  @override
  void initState() {
    super.initState();
    _service = WearableConfigurationBleService(
      widget.device,
      onStateChanged: () {
        if (!mounted || _isDisposing) {
          return;
        }

        setState(() {});
      },
    );
    _csvLogger = WearableAcquisitionCsvLogger();
    _gpsLocationService = GpsLocationService();
    unawaited(_service.initialize());
  }

  @override
  void dispose() {
    _isDisposing = true;
    _notifyDisconnected();
    unawaited(_cleanupAndDisconnect());
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
    await _service.dispose();

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
    if (!_service.isReadyToContinue ||
        _isSendingConfig ||
        _configurationSequenceStarted) {
      return;
    }

    setState(() {
      _isSendingConfig = true;
      _configurationSequenceStarted = true;
    });

    var csvLoggingStarted = false;
    try {
      await _startWearableCsvLogging();
      csvLoggingStarted = true;
      await _service.startConfigurationSequence(
        odr: odr,
        mag: mag,
        accG: accG,
        gyrDPS: gyrDPS,
        calibrationEnabled: calibrationEnabled,
      );
      if (!mounted) {
        return;
      }

      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => WearableBleCommunicationLogPage(
            service: _service,
            csvLogger: _csvLogger,
            stopWearableCsvLogging: _stopWearableCsvLogging,
            onAcquisitionStopped: _notifyDisconnected,
          ),
        ),
      );
    } catch (error) {
      await _stopWearableCsvLogging();
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not start acquisition: $error')),
      );
      if (!csvLoggingStarted) {
        setState(() {
          _configurationSequenceStarted = false;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSendingConfig = false;
        });
      }
    }
  }

  Future<void> _startWearableCsvLogging() async {
    await _csvLogger.start();
    await _gpsLocationService.start();
    await _agmSamplesSubscription?.cancel();
    _agmSamplesSubscription = _service.agmSamplesStream.listen((event) {
      unawaited(
        _csvLogger.appendAgmSample(
          receivedAt: event.receivedAt,
          deviceName: widget.deviceName,
          gpsCoordinates: _gpsLocationService.currentCoordinates,
          sample: event.sample,
        ),
      );
    });
  }

  Future<void> _stopWearableCsvLogging() async {
    await _agmSamplesSubscription?.cancel();
    _agmSamplesSubscription = null;
    await _gpsLocationService.stop();
    await _csvLogger.stop();
  }

  @override
  Widget build(BuildContext context) {
    final canContinue = _service.isReadyToContinue &&
        !_isSendingConfig &&
        !_configurationSequenceStarted;

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
                onPressed:
                    canContinue ? _startConfigurationSequenceAndOpenLog : null,
                child: Text(_isSendingConfig ? 'Sending...' : 'Continue'),
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
    required this.stopWearableCsvLogging,
    required this.onAcquisitionStopped,
  });

  final WearableConfigurationBleService service;
  final WearableAcquisitionCsvLogger csvLogger;
  final Future<void> Function() stopWearableCsvLogging;
  final VoidCallback onAcquisitionStopped;

  @override
  State<WearableBleCommunicationLogPage> createState() =>
      _WearableBleCommunicationLogPageState();
}

class _WearableBleCommunicationLogPageState
    extends State<WearableBleCommunicationLogPage> {
  static const Duration _visibleChartWindow = Duration(seconds: 2);
  static const Duration _uiRefreshInterval = Duration(milliseconds: 500);

  final Map<_WearableMetric, _WearableMetricSeries> _metricSeries = {
    for (final definition in _wearableMetricDefinitions)
      definition.metric: _WearableMetricSeries(),
  };

  StreamSubscription<WearableAgmReceivedSample>? _agmSamplesSubscription;
  Timer? _uiRefreshTimer;
  DateTime? _lastUiRefreshAt;
  DateTime? _latestSampleReceivedAt;
  int? _latestBatteryPercent;
  bool _isStoppingAcquisition = false;

  @override
  void initState() {
    super.initState();
    _agmSamplesSubscription = widget.service.agmSamplesStream.listen(
      _handleAgmSample,
    );
  }

  @override
  void dispose() {
    unawaited(_agmSamplesSubscription?.cancel());
    _uiRefreshTimer?.cancel();
    super.dispose();
  }

  void _handleAgmSample(WearableAgmReceivedSample event) {
    _latestSampleReceivedAt = event.receivedAt;
    if (event.sample.batteryPercent != null) {
      _latestBatteryPercent = event.sample.batteryPercent;
    }

    final cutoff = event.receivedAt.subtract(_visibleChartWindow);
    for (final definition in _wearableMetricDefinitions) {
      final series = _metricSeries[definition.metric];
      if (series == null) {
        continue;
      }

      series
        ..addSample(
          receivedAt: event.receivedAt,
          value: _valueForMetric(definition.metric, event),
        )
        ..pruneBefore(cutoff);
    }

    _requestThrottledUiRefresh();
  }

  double _valueForMetric(
    _WearableMetric metric,
    WearableAgmReceivedSample event,
  ) {
    final sample = event.sample;
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

  Future<void> _stopAcquisition() async {
    if (_isStoppingAcquisition || widget.service.isStopping) {
      return;
    }

    setState(() {
      _isStoppingAcquisition = true;
    });

    try {
      await widget.service.stopAcquisition();
      var csvFinalizeFailed = false;
      try {
        await widget.stopWearableCsvLogging();
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
            Expanded(
              child: _buildWearableDashboard(),
            ),
            _buildStopAcquisitionButton(),
          ],
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
          return _buildBatteryBanner(context);
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

  Widget _buildBatteryBanner(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final batteryText = _latestBatteryPercent == null
        ? 'Battery: N/A'
        : 'Battery: $_latestBatteryPercent%';

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
              Icons.battery_std,
              color: colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Text(
              batteryText,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
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
          onPressed: isStopping ? null : _stopAcquisition,
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
  });

  final BluetoothDevice device;

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

  int get _selectedSamplingFrequency {
    return _samplingFrequencies[_samplingFrequencyIndex];
  }

  bool get _allMeasurementsEnabled {
    return _measurementOptions.every((option) => _options[option] ?? false);
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

    setState(() {
      _isContinuing = true;
    });

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AcquisitionInitializationPage(
          device: widget.device,
          configuration: BleConfiguration(
            enabledOptions: Map<String, bool>.from(_options),
            samplingFrequencySeconds: _selectedSamplingFrequency,
          ),
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
                child: Text(_isContinuing ? 'Opening...' : 'Continue'),
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

class _MeasurementDefinition {
  const _MeasurementDefinition({
    required this.label,
    required this.prefix,
    required this.unit,
  });

  final String label;
  final String prefix;
  final String unit;
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
  });

  final BluetoothDevice device;
  final BleConfiguration configuration;

  @override
  State<AcquisitionInitializationPage> createState() =>
      _AcquisitionInitializationPageState();
}

class _AcquisitionInitializationPageState
    extends State<AcquisitionInitializationPage> {
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
  _LiveVisualizationMode _visualizationMode = _LiveVisualizationMode.cards;
  OpenRemoteMqttState _mqttState = const OpenRemoteMqttState(
    status: OpenRemoteMqttStatus.disconnected,
  );

  @override
  void initState() {
    super.initState();
    _service = BleConfigurationService(widget.device);
    _mqttService = OpenRemoteMqttService();
    _csvLogger = AcquisitionCsvLogger();
    _gpsLocationService = GpsLocationService();
    _visibleMeasurements = _measurementDefinitions
        .where(
          (definition) =>
              widget.configuration.enabledOptions[definition.label] ?? false,
        )
        .toList(growable: false);
    _visibleMeasurementsByPrefix = {
      for (final definition in _visibleMeasurements)
        definition.prefix: definition,
    };
    _messagesSubscription = _service.messages.listen((message) {
      if (!mounted || _acquisitionStopped) {
        return;
      }

      setState(() {
        _messages.add(message);
        _updateLiveMeasurement(message);
      });
      if (_acquisitionStarted && _csvLogger.isStarted) {
        unawaited(
          _csvLogger.appendBleMessage(
            receivedAt: message.receivedAt,
            deviceName: _deviceName(widget.device),
            gpsCoordinates: _gpsLocationService.currentCoordinates,
            value: message.value,
          ),
        );
      }
      unawaited(_publishPm10IfConnected(message.value));
    });
    _connectionSubscription = _service.connectionState.listen((state) {
      if (!mounted ||
          _acquisitionStopped ||
          state != BluetoothConnectionState.disconnected) {
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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startInitialization();
    });
  }

  @override
  void dispose() {
    unawaited(_messagesSubscription?.cancel());
    unawaited(_connectionSubscription?.cancel());
    unawaited(_mqttStateSubscription?.cancel());
    unawaited(_csvLogger.stop());
    unawaited(_gpsLocationService.dispose());
    unawaited(_mqttService.dispose());
    unawaited(_service.dispose());
    super.dispose();
  }

  Future<void> _startInitialization() async {
    if (_initializationStarted) {
      return;
    }

    _initializationStarted = true;

    if (mounted) {
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
    }

    try {
      await _service.initialize(widget.configuration);
      if (!_csvLogger.isStarted) {
        await _csvLogger.start();
        unawaited(_gpsLocationService.start());
      }
      if (!mounted) {
        return;
      }

      setState(() {
        _isInitializing = false;
        _acquisitionStarted = true;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isInitializing = false;
        _errorMessage = error.toString();
        _canRetry = error is BleConfigurationException && error.canRetry;
        _requiresReconnect = false;
      });
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
      await widget.device.connect(
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
        _errorMessage = 'Could not reconnect to ${_deviceName(widget.device)}: $error';
        _canRetry = true;
        _requiresReconnect = true;
      });
    }
  }

  Future<void> _connectOpenRemote() async {
    if (_mqttState.status == OpenRemoteMqttStatus.connecting ||
        _mqttState.status == OpenRemoteMqttStatus.connected) {
      return;
    }

    await _mqttService.connect();
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

  Future<void> _stopAcquisition() async {
    if (_isStoppingAcquisition || _acquisitionStopped) {
      return;
    }

    setState(() {
      _isStoppingAcquisition = true;
      _acquisitionStopped = true;
    });

    try {
      await _messagesSubscription?.cancel();
      _messagesSubscription = null;
      await _csvLogger.stop();
      await _gpsLocationService.stop();

      if (!mounted) {
        return;
      }

      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AcquisitionCompletedPage(csvLogger: _csvLogger),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _acquisitionStopped = false;
        _isStoppingAcquisition = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not stop acquisition')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _isInitializing || _errorMessage != null
        ? 'Acquisition Initialization'
        : 'Acquisition in progress...';

    return PopScope(
      canPop: !_isInitializing,
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

    if (_errorMessage != null) {
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
        Expanded(
          child: _buildLiveVisualization(),
        ),
        _buildStopAcquisitionButton(),
        _buildOpenRemoteBanner(context),
      ],
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
          onPressed: _isStoppingAcquisition ? null : _stopAcquisition,
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
