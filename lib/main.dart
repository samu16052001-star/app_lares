import 'dart:async';
import 'dart:io';

import 'package:app_lares/ble_configuration_service.dart';
import 'package:app_lares/services/mqtt_service.dart';
import 'package:app_lares/services/pm10_parser.dart';
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

  Future<void> _toggleConnection(BluetoothDevice device) async {
    final id = _deviceId(device);

    if (_connectedDeviceIds.contains(id)) {
      await _disconnectFromDevice(device);
      return;
    }

    await _connectToDevice(device);
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    final id = _deviceId(device);

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

      if (_isEnvDevice(device)) {
        _openDeviceConfigurationPage(device);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _statusMessage = 'Could not connect to ${_deviceName(device)}: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _connectingDeviceIds.remove(id);
        });
      }
    }
  }

  bool _isEnvDevice(BluetoothDevice device) {
    return _deviceName(device).toLowerCase().contains('env');
  }

  void _openDeviceConfigurationPage(BluetoothDevice device) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DeviceConfigurationPage(device: device),
      ),
    );
  }

  Future<void> _disconnectFromDevice(BluetoothDevice device) async {
    final id = _deviceId(device);

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
        _statusMessage = 'Could not disconnect ${_deviceName(device)}: $error';
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

  String _deviceName(BluetoothDevice device) {
    final platformName = device.platformName.trim();
    return platformName.isEmpty ? 'Unknown device' : platformName;
  }

  String _visibleDeviceName(BluetoothDevice device) {
    return device.platformName.trim();
  }

  List<ScanResult> _displayDevices() {
    var devices = _scanResults.values.toList();

    if (_showOnlyLaresDevices) {
      devices = devices.where((result) {
        final name = _visibleDeviceName(result.device);
        return name.isNotEmpty && name.toLowerCase().contains('lares');
      }).toList();
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
      (a, b) => _deviceName(a.device).compareTo(_deviceName(b.device)),
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
            _buildScanOptionButtons(context),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: Icon(_isScanning ? Icons.bluetooth_searching : Icons.search),
              label: Text(_isScanning ? 'Scanning...' : 'Scan Bluetooth Devices'),
              onPressed: _isScanning ? null : _startScan,
            ),
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
                          title: Text(_deviceName(device)),
                          subtitle: Text('$id - RSSI ${result.rssi} dBm'),
                          trailing: FilledButton(
                            onPressed: isBusy
                                ? null
                                : () => _toggleConnection(device),
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
  static const List<String> _measurementOptions = [
    'CO2',
    'CO',
    'NH3',
    'NO2',
    'VOC',
    'NOX',
    'VOC Index',
    'NOX Index',
    'PM1.0',
    'PM2.5',
    'PM10',
    'Internal Temperature',
    'External Temperature',
    'Internal Humidity',
    'External Humidity',
    'Atmospheric Pressure',
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

  final List<BleNotificationMessage> _messages = [];
  StreamSubscription<BleNotificationMessage>? _messagesSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<OpenRemoteMqttState>? _mqttStateSubscription;

  bool _isInitializing = true;
  bool _initializationStarted = false;
  String? _errorMessage;
  bool _canRetry = false;
  OpenRemoteMqttState _mqttState = const OpenRemoteMqttState(
    status: OpenRemoteMqttStatus.disconnected,
  );

  @override
  void initState() {
    super.initState();
    _service = BleConfigurationService(widget.device);
    _mqttService = OpenRemoteMqttService();
    _messagesSubscription = _service.messages.listen((message) {
      if (!mounted) {
        return;
      }

      setState(() {
        _messages.add(message);
      });
      unawaited(_publishPm10IfConnected(message.value));
    });
    _connectionSubscription = _service.connectionState.listen((state) {
      if (!mounted || state != BluetoothConnectionState.disconnected) {
        return;
      }

      setState(() {
        _isInitializing = false;
        _errorMessage = 'BLE device disconnected.';
        _canRetry = false;
      });
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
        _messages.clear();
      });
    }

    try {
      await _service.initialize(widget.configuration);
      if (!mounted) {
        return;
      }

      setState(() {
        _isInitializing = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isInitializing = false;
        _errorMessage = error.toString();
        _canRetry = error is BleConfigurationException && error.canRetry;
      });
    }
  }

  void _retryInitialization() {
    if (_isInitializing) {
      return;
    }

    _initializationStarted = false;
    _startInitialization();
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
                  onPressed: _retryInitialization,
                  child: const Text('Retry'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: _buildMessagesLog(),
        ),
        _buildOpenRemoteBanner(context),
      ],
    );
  }

  Widget _buildMessagesLog() {
    if (_messages.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Waiting for BLE notifications...',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _messages.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(_messages[index].displayText),
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
