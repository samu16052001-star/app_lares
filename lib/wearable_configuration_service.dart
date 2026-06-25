import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class WearableConfigurationBleService {
  WearableConfigurationBleService(
    this.device, {
    this.onStateChanged,
  });

  static const String wearableServiceUuid =
      '00005678-1212-efde-1523-785feabcd123';
  static const String writeCharacteristicUuid =
      '00002a04-1212-efde-1523-785feabcd123';
  static const String notifyCharacteristicUuid =
      '00002a05-1212-efde-1523-785feabcd123';

  final BluetoothDevice device;
  final VoidCallback? onStateChanged;

  final StreamController<List<String>> _logController =
      StreamController<List<String>>.broadcast();
  final List<String> _logs = [];

  BluetoothCharacteristic? _writeCharacteristic;
  BluetoothCharacteristic? _notifyCharacteristic;
  StreamSubscription<List<int>>? _notificationSubscription;

  bool _isDisposed = false;
  bool _mtuRequested = false;
  bool _hasBlockingMtuIssue = false;
  bool _serviceDiscoveryCompleted = false;
  bool _targetServiceFound = false;
  bool _writeCharacteristicFound = false;
  bool _notifyCharacteristicFound = false;
  bool _notificationsEnabled = false;

  Stream<List<String>> get logsStream => _logController.stream;

  List<String> get logs => List.unmodifiable(_logs);

  bool get isReadyToContinue {
    return _mtuRequested &&
        !_hasBlockingMtuIssue &&
        _serviceDiscoveryCompleted &&
        _targetServiceFound &&
        _writeCharacteristicFound &&
        _notifyCharacteristicFound &&
        _notificationsEnabled;
  }

  Future<void> initialize() async {
    if (_isDisposed) {
      return;
    }

    await _requestMtu();
    if (_isDisposed) {
      return;
    }

    await _discoverWearableService();
    if (_isDisposed) {
      return;
    }

    await _enableNotifications();
  }

  Future<void> sendConfig({
    required int odr,
    required int mag,
    required int accG,
    required int gyrDPS,
  }) async {
    final characteristic = _writeCharacteristic;
    final command = 'CONFIG:$odr,$mag,$accG,$gyrDPS';

    if (characteristic == null || !isReadyToContinue) {
      final message = 'CONFIG write blocked: BLE setup is not complete.';
      _log(message);
      throw StateError(message);
    }

    try {
      await characteristic.write(
        utf8.encode(command),
        withoutResponse: true,
      );
      _log('CONFIG command sent: $command');
    } catch (error) {
      _log('CONFIG write error: $error');
      rethrow;
    }
  }

  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }

    _isDisposed = true;
    _log('Wearable BLE service disposal started.');

    try {
      await _notificationSubscription?.cancel();
      _log('Notification subscription cancelled.');
    } catch (error) {
      _log('Notification subscription cancellation error: $error');
    }
    _notificationSubscription = null;

    final notifyCharacteristic = _notifyCharacteristic;
    if (_notificationsEnabled && notifyCharacteristic != null) {
      try {
        await notifyCharacteristic.setNotifyValue(false);
        _log('Notifications disabled.');
      } catch (error) {
        _log('Notification disable error: $error');
      }
    }

    _notificationsEnabled = false;
    _log('Disconnection-related BLE cleanup completed.');
    _log('Wearable BLE service disposed.');
    await _logController.close();
  }

  Future<void> _requestMtu() async {
    _log('MTU request started: requesting 247 bytes.');
    _mtuRequested = true;

    try {
      final mtu = await device.requestMtu(247);
      _log('MTU request success/result: $mtu bytes.');
      _checkMtu(mtu);
    } catch (error) {
      _log('MTU request error: $error');
      _log('Continuing BLE setup; MTU size could not be confirmed.');
    }
  }

  void _checkMtu(int mtu) {
    if (mtu < 47) {
      _hasBlockingMtuIssue = true;
      _log(
        'MTU lower than 47 warning/error: negotiated MTU is $mtu bytes. Continue disabled.',
      );
      return;
    }

    _hasBlockingMtuIssue = false;
    _log('MTU check passed: negotiated MTU is at least 47 bytes.');
  }

  Future<void> _discoverWearableService() async {
    _log('Service discovery started.');

    try {
      final services = await device.discoverServices();
      _serviceDiscoveryCompleted = true;

      BluetoothService? targetService;
      for (final service in services) {
        if (_sameUuid(service.uuid, wearableServiceUuid)) {
          targetService = service;
          break;
        }
      }

      if (targetService == null) {
        _targetServiceFound = false;
        _log('Target service not found: $wearableServiceUuid');
        return;
      }

      _targetServiceFound = true;
      _log('Target service found: $wearableServiceUuid');

      for (final characteristic in targetService.characteristics) {
        if (_sameUuid(characteristic.uuid, writeCharacteristicUuid)) {
          _writeCharacteristic = characteristic;
          _writeCharacteristicFound = true;
        }

        if (_sameUuid(characteristic.uuid, notifyCharacteristicUuid)) {
          _notifyCharacteristic = characteristic;
          _notifyCharacteristicFound = true;
        }
      }

      if (_writeCharacteristicFound) {
        _log('Write characteristic found: $writeCharacteristicUuid');
      } else {
        _log('Write characteristic not found: $writeCharacteristicUuid');
      }

      if (_notifyCharacteristicFound) {
        _log('Notify/read characteristic found: $notifyCharacteristicUuid');
      } else {
        _log('Notify/read characteristic not found: $notifyCharacteristicUuid');
      }
    } catch (error) {
      _serviceDiscoveryCompleted = false;
      _targetServiceFound = false;
      _writeCharacteristicFound = false;
      _notifyCharacteristicFound = false;
      _log('Service discovery error: $error');
    }
  }

  Future<void> _enableNotifications() async {
    final characteristic = _notifyCharacteristic;
    if (characteristic == null) {
      _log('Notification enabling skipped: notify/read characteristic missing.');
      return;
    }

    _log('Notification enabling started.');

    try {
      await _notificationSubscription?.cancel();
      _notificationSubscription =
          characteristic.onValueReceived.listen(_handleNotification);
      await characteristic.setNotifyValue(true);
      _notificationsEnabled = true;
      _log('Notification enabling success.');
    } catch (error) {
      _notificationsEnabled = false;
      _log('Notification enabling error: $error');
    }
  }

  void _handleNotification(List<int> value) {
    final payload = utf8.decode(value, allowMalformed: true);
    if (payload.trim() == 'CONFIG_DONE') {
      _log('Notification received: CONFIG_DONE');
      return;
    }

    _log('Notification received: $payload');
  }

  bool _sameUuid(Guid value, String uuid) {
    return value.toString().toLowerCase() == uuid;
  }

  void _log(String message) {
    if (_isDisposed && _logController.isClosed) {
      return;
    }

    final timestamp = DateTime.now();
    final formattedTime =
        '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}';
    final entry = '[$formattedTime] $message';

    _logs.add(entry);
    debugPrint(entry);

    if (!_logController.isClosed) {
      _logController.add(logs);
    }
    onStateChanged?.call();
  }
}
