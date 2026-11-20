import 'dart:async';
import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'environmental_v2_configuration.dart';
import 'environmental_v2_message_parser.dart';

class EnvironmentalV2NotificationMessage {
  const EnvironmentalV2NotificationMessage({
    required this.receivedAt,
    required this.type,
    required this.value,
    required this.numericValue,
    required this.option,
  });

  factory EnvironmentalV2NotificationMessage.fromParsed({
    required DateTime receivedAt,
    required EnvironmentalV2ParsedMessage message,
  }) {
    return EnvironmentalV2NotificationMessage(
      receivedAt: receivedAt,
      type: message.type,
      value: message.value,
      numericValue: message.numericValue,
      option: message.option,
    );
  }

  final DateTime receivedAt;
  final String type;
  final String value;
  final double? numericValue;
  final EnvironmentalV2Option option;

  String get displayText {
    final local = receivedAt.toLocal();
    final time = <int>[
      local.hour,
      local.minute,
      local.second,
    ].map((part) => part.toString().padLeft(2, '0')).join(':');

    return '$time - $type: $value';
  }
}

class EnvironmentalV2BleException implements Exception {
  const EnvironmentalV2BleException(this.message, {this.canRetry = true});

  final String message;
  final bool canRetry;

  @override
  String toString() => message;
}

class EnvironmentalV2BleService {
  EnvironmentalV2BleService(this.device);

  BluetoothDevice device;

  final StreamController<EnvironmentalV2NotificationMessage>
  _messagesController =
      StreamController<EnvironmentalV2NotificationMessage>.broadcast();
  final List<_EnvironmentalV2NotificationRegistration>
  _notificationRegistrations = <_EnvironmentalV2NotificationRegistration>[];

  List<BluetoothService> _discoveredServices = <BluetoothService>[];
  List<BluetoothCharacteristic> _notificationCharacteristics =
      <BluetoothCharacteristic>[];
  EnvironmentalV2Configuration? _configuration;
  bool _isInitializing = false;
  bool _isStartingNotifications = false;
  bool _notificationsActive = false;
  bool _initialized = false;
  bool _disposed = false;
  int _notificationStartupGeneration = 0;
  Completer<void>? _notificationStartupCompleter;

  Stream<EnvironmentalV2NotificationMessage> get messages {
    return _messagesController.stream;
  }

  Stream<BluetoothConnectionState> get connectionState {
    return device.connectionState;
  }

  EnvironmentalV2Configuration? get configuration => _configuration;

  bool get isInitialized => _initialized;

  bool get notificationsActive => _notificationsActive;

  Future<void> initialize(EnvironmentalV2Configuration configuration) async {
    _throwIfDisposed();
    if (_isInitializing) {
      throw const EnvironmentalV2BleException(
        'Initialization is already running.',
      );
    }

    _isInitializing = true;
    _initialized = false;
    try {
      await _clearNotificationRegistrations();
      await _discoverAndValidateNotificationCharacteristics(
        canRetryWhenMissing: false,
      );

      final characteristicMap = _buildCharacteristicMap(_discoveredServices);
      _verifyConfigurationCharacteristics(characteristicMap);

      for (final option in EnvironmentalV2Option.values) {
        await _writeWithRetries(
          characteristicMap[option.characteristicUuid]!,
          option.characteristicUuid,
          enabled: configuration.isEnabled(option),
        );
      }

      _configuration = configuration;
      _initialized = true;
    } finally {
      _isInitializing = false;
    }
  }

  Future<void> startNotificationsForAcquisition({
    BluetoothDevice? reconnectedDevice,
  }) async {
    _throwIfDisposed();
    if (!_initialized || _configuration == null) {
      throw const EnvironmentalV2BleException(
        'Environmental Monitor V2 is not initialized.',
        canRetry: false,
      );
    }
    if (_isStartingNotifications) {
      throw const EnvironmentalV2BleException(
        'Notification startup is already running.',
      );
    }
    if (_notificationsActive) {
      return;
    }

    _isStartingNotifications = true;
    final startupGeneration = ++_notificationStartupGeneration;
    final startupCompleter = Completer<void>();
    _notificationStartupCompleter = startupCompleter;
    try {
      if (reconnectedDevice != null) {
        await _clearNotificationRegistrations();
        device = reconnectedDevice;
        await _discoverAndValidateNotificationCharacteristics(
          canRetryWhenMissing: true,
        );
      }
      await _subscribeToNotifications(startupGeneration);
    } finally {
      _isStartingNotifications = false;
      if (!startupCompleter.isCompleted) {
        startupCompleter.complete();
      }
      if (identical(_notificationStartupCompleter, startupCompleter)) {
        _notificationStartupCompleter = null;
      }
    }
  }

  Future<void> resumeNotificationsAfterReconnect({
    BluetoothDevice? reconnectedDevice,
  }) async {
    _throwIfDisposed();
    if (!_initialized || _configuration == null) {
      throw const EnvironmentalV2BleException(
        'Environmental Monitor V2 is not initialized.',
        canRetry: false,
      );
    }
    if (_isStartingNotifications) {
      throw const EnvironmentalV2BleException(
        'Notification startup is already running.',
      );
    }

    _isStartingNotifications = true;
    final startupGeneration = ++_notificationStartupGeneration;
    final startupCompleter = Completer<void>();
    _notificationStartupCompleter = startupCompleter;
    try {
      await _clearNotificationRegistrations();
      if (reconnectedDevice != null) {
        device = reconnectedDevice;
      }
      await _discoverAndValidateNotificationCharacteristics(
        canRetryWhenMissing: true,
      );
      await _subscribeToNotifications(startupGeneration);
    } finally {
      _isStartingNotifications = false;
      if (!startupCompleter.isCompleted) {
        startupCompleter.complete();
      }
      if (identical(_notificationStartupCompleter, startupCompleter)) {
        _notificationStartupCompleter = null;
      }
    }
  }

  Future<void> stopNotifications() async {
    _notificationStartupGeneration += 1;
    await _notificationStartupCompleter?.future;
    await _clearNotificationRegistrations();
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }

    _disposed = true;
    _notificationStartupGeneration += 1;
    await _notificationStartupCompleter?.future;
    await _clearNotificationRegistrations();
    await _messagesController.close();
  }

  Future<void> _discoverAndValidateNotificationCharacteristics({
    required bool canRetryWhenMissing,
  }) async {
    _discoveredServices = await device.discoverServices();
    _notificationCharacteristics = <BluetoothCharacteristic>[
      for (final service in _discoveredServices)
        for (final characteristic in service.characteristics)
          if (characteristic.properties.notify ||
              characteristic.properties.indicate)
            characteristic,
    ];

    if (_notificationCharacteristics.isEmpty) {
      throw EnvironmentalV2BleException(
        'No BLE notification characteristics found.',
        canRetry: canRetryWhenMissing,
      );
    }
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

  void _verifyConfigurationCharacteristics(
    Map<String, BluetoothCharacteristic> characteristics,
  ) {
    for (final option in EnvironmentalV2Option.values) {
      if (!characteristics.containsKey(option.characteristicUuid)) {
        throw EnvironmentalV2BleException(
          'Missing BLE characteristic: ${option.characteristicUuid}',
          canRetry: false,
        );
      }
    }
  }

  Future<void> _writeWithRetries(
    BluetoothCharacteristic characteristic,
    String uuid, {
    required bool enabled,
  }) async {
    final payload = enabled ? _enabledPayload : _disabledPayload;
    Object? lastError;

    for (var attempt = 0; attempt <= _maxAdditionalWriteAttempts; attempt++) {
      try {
        await characteristic.write(payload, withoutResponse: false);
        return;
      } catch (error) {
        lastError = error;
      }
    }

    throw EnvironmentalV2BleException(
      'BLE write failed for $uuid after '
      '${_maxAdditionalWriteAttempts + 1} attempts: $lastError',
    );
  }

  Future<void> _subscribeToNotifications(int startupGeneration) async {
    await _clearNotificationRegistrations();
    _throwIfNotificationStartupCancelled(startupGeneration);

    try {
      for (final characteristic in _notificationCharacteristics) {
        _throwIfNotificationStartupCancelled(startupGeneration);
        final registration = _EnvironmentalV2NotificationRegistration(
          characteristic: characteristic,
          subscription: characteristic.onValueReceived.listen(
            _handleNotificationValue,
          ),
        );
        _notificationRegistrations.add(registration);

        registration.notifyEnableAttempted = true;
        final enabled = await characteristic.setNotifyValue(true);
        if (!enabled) {
          throw EnvironmentalV2BleException(
            'Could not enable BLE notifications for '
            '${characteristic.uuid}.',
          );
        }
        _throwIfNotificationStartupCancelled(startupGeneration);
      }

      _throwIfNotificationStartupCancelled(startupGeneration);
      _notificationsActive = true;
    } catch (error) {
      await _clearNotificationRegistrations();
      if (error is EnvironmentalV2BleException) {
        rethrow;
      }
      throw EnvironmentalV2BleException(
        'Could not start Environmental Monitor V2 notifications: $error',
      );
    }
  }

  void _handleNotificationValue(List<int> payload) {
    if (_disposed || !_notificationsActive || _messagesController.isClosed) {
      return;
    }

    final receivedAt = DateTime.now();
    final String decoded;
    try {
      decoded = utf8.decode(payload, allowMalformed: false);
    } on FormatException {
      return;
    }

    final parsed = parseEnvironmentalV2Message(decoded);
    final configuration = _configuration;
    if (parsed == null ||
        configuration == null ||
        !configuration.isEnabled(parsed.option)) {
      return;
    }

    _messagesController.add(
      EnvironmentalV2NotificationMessage.fromParsed(
        receivedAt: receivedAt,
        message: parsed,
      ),
    );
  }

  Future<void> _clearNotificationRegistrations() async {
    final registrations = List<_EnvironmentalV2NotificationRegistration>.from(
      _notificationRegistrations,
    );
    _notificationRegistrations.clear();
    _notificationsActive = false;

    for (final registration in registrations) {
      try {
        await registration.subscription.cancel();
      } catch (_) {}
    }

    for (final registration in registrations) {
      if (!registration.notifyEnableAttempted) {
        continue;
      }
      try {
        await registration.characteristic.setNotifyValue(false);
      } catch (_) {}
    }
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw const EnvironmentalV2BleException(
        'BLE service is disposed.',
        canRetry: false,
      );
    }
  }

  void _throwIfNotificationStartupCancelled(int startupGeneration) {
    if (_disposed || startupGeneration != _notificationStartupGeneration) {
      throw const EnvironmentalV2BleException(
        'Notification startup was cancelled.',
        canRetry: false,
      );
    }
  }

  static String _normalizeUuid(String uuid) => uuid.toLowerCase();

  static const int _maxAdditionalWriteAttempts = 5;
  static const List<int> _enabledPayload = <int>[0x01];
  static const List<int> _disabledPayload = <int>[0x00];
}

class _EnvironmentalV2NotificationRegistration {
  _EnvironmentalV2NotificationRegistration({
    required this.characteristic,
    required this.subscription,
  });

  final BluetoothCharacteristic characteristic;
  final StreamSubscription<List<int>> subscription;
  bool notifyEnableAttempted = false;
}
