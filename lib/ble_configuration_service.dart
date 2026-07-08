import 'dart:async';
import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class BleConfiguration {
  const BleConfiguration({
    required this.enabledOptions,
    required this.samplingFrequencySeconds,
  });

  final Map<String, bool> enabledOptions;
  final int samplingFrequencySeconds;

  bool isEnabled(String option) {
    return enabledOptions[option] ?? false;
  }
}

class BleNotificationMessage {
  const BleNotificationMessage({
    required this.receivedAt,
    required this.value,
  });

  final DateTime receivedAt;
  final String value;

  String get displayText {
    final local = receivedAt.toLocal();
    final time = [
      local.hour,
      local.minute,
      local.second,
    ].map((part) => part.toString().padLeft(2, '0')).join(':');

    return '$time - $value';
  }
}

class BleConfigurationException implements Exception {
  const BleConfigurationException(
    this.message, {
    this.canRetry = true,
  });

  final String message;
  final bool canRetry;

  @override
  String toString() => message;
}

class BleConfigurationService {
  BleConfigurationService(this.device);

  BluetoothDevice device;

  final StreamController<BleNotificationMessage> _messagesController =
      StreamController<BleNotificationMessage>.broadcast();
  final List<StreamSubscription<List<int>>> _notificationSubscriptions = [];

  List<BluetoothService> _discoveredServices = [];
  bool _isInitializing = false;
  bool _disposed = false;

  Stream<BleNotificationMessage> get messages => _messagesController.stream;

  Stream<BluetoothConnectionState> get connectionState =>
      device.connectionState;

  Future<void> initialize(BleConfiguration configuration) async {
    if (_isInitializing) {
      throw const BleConfigurationException(
        'Initialization is already running.',
      );
    }

    _isInitializing = true;
    try {
      await _clearNotificationSubscriptions();
      _discoveredServices = await device.discoverServices();
      final characteristics = _buildCharacteristicMap(_discoveredServices);
      _verifyRequiredCharacteristics(characteristics);

      await _runPhaseOne(configuration, characteristics);
      await Future.delayed(const Duration(seconds: 2));

      await _writeWithRetries(
        characteristics[_samplingFrequencyUuid]!,
        [configuration.samplingFrequencySeconds],
        _samplingFrequencyUuid,
      );
      await Future.delayed(const Duration(seconds: 2));

      final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      await _writeWithRetries(
        characteristics[_timestampUuid]!,
        ascii.encode(timestamp.toString()),
        _timestampUuid,
      );
      await _writeWithRetries(
        characteristics[_sdCardStorageUuid]!,
        _enabledPayload,
        _sdCardStorageUuid,
      );

      await _subscribeToNotifications();
    } finally {
      _isInitializing = false;
    }
  }

  Future<void> resumeNotificationsAfterReconnect({
    BluetoothDevice? reconnectedDevice,
  }) async {
    if (_disposed) {
      throw const BleConfigurationException(
        'BLE service is disposed.',
        canRetry: false,
      );
    }

    if (reconnectedDevice != null) {
      device = reconnectedDevice;
    }

    await _clearNotificationSubscriptions();
    _discoveredServices = await device.discoverServices();
    await _subscribeToNotifications();
    if (_notificationSubscriptions.isEmpty) {
      throw const BleConfigurationException(
        'No BLE notification characteristics found after reconnect.',
      );
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _clearNotificationSubscriptions();
    await _messagesController.close();
  }

  Map<String, BluetoothCharacteristic> _buildCharacteristicMap(
    List<BluetoothService> services,
  ) {
    final characteristics = <String, BluetoothCharacteristic>{};

    for (final service in services) {
      for (final characteristic in service.characteristics) {
        characteristics[_normalizeUuid(characteristic.uuid.toString())] =
            characteristic;
      }
    }

    return characteristics;
  }

  void _verifyRequiredCharacteristics(
    Map<String, BluetoothCharacteristic> characteristics,
  ) {
    for (final uuid in _requiredUuids) {
      if (!characteristics.containsKey(uuid)) {
        throw BleConfigurationException(
          'Missing BLE characteristic: $uuid',
          canRetry: false,
        );
      }
    }
  }

  Future<void> _runPhaseOne(
    BleConfiguration configuration,
    Map<String, BluetoothCharacteristic> characteristics,
  ) async {
    for (final write in _sensorWrites) {
      if (!configuration.isEnabled(write.option)) {
        continue;
      }

      await _writeWithRetries(
        characteristics[write.uuid]!,
        _enabledPayload,
        write.uuid,
      );
    }

    await _writeWithRetries(
      characteristics[_batteryUpdatesUuid]!,
      _enabledPayload,
      _batteryUpdatesUuid,
    );
  }

  Future<void> _writeWithRetries(
    BluetoothCharacteristic characteristic,
    List<int> payload,
    String uuid,
  ) async {
    Object? lastError;

    for (var attempt = 0; attempt <= _maxAdditionalWriteAttempts; attempt++) {
      try {
        await characteristic.write(payload, withoutResponse: false);
        return;
      } catch (error) {
        lastError = error;
      }
    }

    throw BleConfigurationException(
      'BLE write failed for $uuid after '
      '${_maxAdditionalWriteAttempts + 1} attempts: $lastError',
    );
  }

  Future<void> _subscribeToNotifications() async {
    await _clearNotificationSubscriptions();

    for (final service in _discoveredServices) {
      for (final characteristic in service.characteristics) {
        final properties = characteristic.properties;
        if (!properties.notify && !properties.indicate) {
          continue;
        }

        final subscription = characteristic.onValueReceived.listen((value) {
          if (_disposed || _messagesController.isClosed) {
            return;
          }

          _messagesController.add(
            BleNotificationMessage(
              receivedAt: DateTime.now(),
              value: _formatPayload(value),
            ),
          );
        });
        _notificationSubscriptions.add(subscription);

        await characteristic.setNotifyValue(true);
      }
    }
  }

  Future<void> _clearNotificationSubscriptions() async {
    for (final subscription in _notificationSubscriptions) {
      await subscription.cancel();
    }
    _notificationSubscriptions.clear();
  }

  String _formatPayload(List<int> value) {
    try {
      return utf8.decode(value, allowMalformed: false);
    } on FormatException {
      return '[${value.map(_formatByte).join(', ')}]';
    }
  }

  String _formatByte(int value) {
    return '0x${value.toRadixString(16).padLeft(2, '0').toUpperCase()}';
  }

  static String _normalizeUuid(String uuid) => uuid.toLowerCase();

  static const int _maxAdditionalWriteAttempts = 5;
  static const List<int> _enabledPayload = [0x01];

  static const String _batteryUpdatesUuid =
      '12341610-1234-5678-1234-56789abcdef0';
  static const String _samplingFrequencyUuid =
      '12341530-1234-5678-1234-56789abcdef0';
  static const String _timestampUuid =
      '12341533-1234-5678-1234-56789abcdef0';
  static const String _sdCardStorageUuid =
      '12341532-1234-5678-1234-56789abcdef0';

  static const List<_SensorWrite> _sensorWrites = [
    _SensorWrite('CO2', '1234152a-1234-5678-1234-56789abcdef0'),
    _SensorWrite('CO', '1234152b-1234-5678-1234-56789abcdef0'),
    _SensorWrite('NH3', '12341609-1234-5678-1234-56789abcdef0'),
    _SensorWrite('NO2', '12341611-1234-5678-1234-56789abcdef0'),
    _SensorWrite('VOC', '12341604-1234-5678-1234-56789abcdef0'),
    _SensorWrite('NOX', '12341605-1234-5678-1234-56789abcdef0'),
    _SensorWrite('VOC Index', '12341606-1234-5678-1234-56789abcdef0'),
    _SensorWrite('NOX Index', '12341607-1234-5678-1234-56789abcdef0'),
    _SensorWrite('PM1.0', '12341612-1234-5678-1234-56789abcdef0'),
    _SensorWrite('PM2.5', '1234152c-1234-5678-1234-56789abcdef0'),
    _SensorWrite('PM10', '1234152d-1234-5678-1234-56789abcdef0'),
    _SensorWrite(
      'Internal Temperature',
      '12341602-1234-5678-1234-56789abcdef0',
    ),
    _SensorWrite(
      'External Temperature',
      '12341613-1234-5678-1234-56789abcdef0',
    ),
    _SensorWrite(
      'Internal Humidity',
      '12341603-1234-5678-1234-56789abcdef0',
    ),
    _SensorWrite(
      'External Humidity',
      '12341614-1234-5678-1234-56789abcdef0',
    ),
    _SensorWrite(
      'Atmospheric Pressure',
      '12341615-1234-5678-1234-56789abcdef0',
    ),
    _SensorWrite('Fan', '12341800-1234-5678-1234-56789abcdef0'),
  ];

  static final Set<String> _requiredUuids = {
    for (final write in _sensorWrites) write.uuid,
    _batteryUpdatesUuid,
    _samplingFrequencyUuid,
    _timestampUuid,
    _sdCardStorageUuid,
  };
}

class _SensorWrite {
  const _SensorWrite(this.option, this.uuid);

  final String option;
  final String uuid;
}
