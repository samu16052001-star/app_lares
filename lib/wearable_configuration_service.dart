import 'dart:async';
import 'dart:convert';

import 'package:app_lares/wearable_agm_packet_parser.dart';
import 'package:app_lares/wearable_sds_packet_parser.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:ntp/ntp.dart';

enum WearableBleSequenceState {
  idle,
  configSent,
  waitingConfigDone,
  configDone,
  calibrationStartSent,
  waitingCalibrationDone,
  calibrationDone,
  preparingStart,
  startSent,
  streaming,
  stopping,
  stopped,
  timeout,
  error,
}

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

  static const Duration _configDoneTimeout = Duration(seconds: 10);
  static const Duration _calibrationDoneTimeout = Duration(seconds: 22);
  static const int _maxLogEntries = 200;

  final BluetoothDevice device;
  final VoidCallback? onStateChanged;

  final StreamController<List<String>> _logController =
      StreamController<List<String>>.broadcast();
  final StreamController<WearableAgmReceivedSample> _agmSamplesController =
      StreamController<WearableAgmReceivedSample>.broadcast();
  final StreamController<WearableSdsReceivedStatus> _sdsStatusController =
      StreamController<WearableSdsReceivedStatus>.broadcast();
  final List<String> _logs = [];

  BluetoothCharacteristic? _writeCharacteristic;
  BluetoothCharacteristic? _notifyCharacteristic;
  StreamSubscription<List<int>>? _notificationSubscription;
  Timer? _sequenceTimer;

  bool _isDisposed = false;
  bool _mtuRequested = false;
  bool _hasBlockingMtuIssue = false;
  bool _serviceDiscoveryCompleted = false;
  bool _targetServiceFound = false;
  bool _writeCharacteristicFound = false;
  bool _notifyCharacteristicFound = false;
  bool _notificationsEnabled = false;
  bool _calibrationEnabled = false;
  WearableBleSequenceState _sequenceState = WearableBleSequenceState.idle;

  Stream<List<String>> get logsStream => _logController.stream;

  Stream<WearableAgmReceivedSample> get agmSamplesStream =>
      _agmSamplesController.stream;

  Stream<WearableSdsReceivedStatus> get sdsStatusStream =>
      _sdsStatusController.stream;

  List<String> get logs => List.unmodifiable(_logs);

  WearableBleSequenceState get sequenceState => _sequenceState;

  bool get blocksBackNavigation {
    return switch (_sequenceState) {
      WearableBleSequenceState.waitingConfigDone ||
      WearableBleSequenceState.configDone ||
      WearableBleSequenceState.calibrationStartSent ||
      WearableBleSequenceState.waitingCalibrationDone ||
      WearableBleSequenceState.calibrationDone ||
      WearableBleSequenceState.preparingStart ||
      WearableBleSequenceState.streaming ||
      WearableBleSequenceState.stopping => true,
      _ => false,
    };
  }

  bool get isStopping => _sequenceState == WearableBleSequenceState.stopping;

  bool get isStopped => _sequenceState == WearableBleSequenceState.stopped;

  bool get isReadyToContinue {
    return _mtuRequested &&
        !_hasBlockingMtuIssue &&
        _serviceDiscoveryCompleted &&
        _targetServiceFound &&
        _writeCharacteristicFound &&
        _notifyCharacteristicFound &&
        _notificationsEnabled &&
        _sequenceState == WearableBleSequenceState.idle;
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

  Future<void> startConfigurationSequence({
    required int odr,
    required int mag,
    required int accG,
    required int gyrDPS,
    required bool calibrationEnabled,
  }) async {
    final command = 'CONFIG:$odr,$mag,$accG,$gyrDPS';

    if (!isReadyToContinue) {
      final message = 'CONFIG write blocked: BLE setup is not complete.';
      _log(message);
      throw StateError(message);
    }

    _calibrationEnabled = calibrationEnabled;
    _setSequenceState(WearableBleSequenceState.configSent);

    try {
      await _writeCommand(command);
      _log('CONFIG command sent: $command');
      _setSequenceState(WearableBleSequenceState.waitingConfigDone);
      _startTimeout(
        timeout: _configDoneTimeout,
        expectedPayload: 'CONFIG_DONE',
        timeoutMessage: 'Timeout waiting for CONFIG_DONE after 10 seconds.',
      );
    } catch (error) {
      _setSequenceState(WearableBleSequenceState.error);
      _log('CONFIG write error: $error');
      rethrow;
    }
  }

  Future<void> stopAcquisition() async {
    if (_isDisposed || isStopping || isStopped) {
      return;
    }

    _setSequenceState(WearableBleSequenceState.stopping);
    _sequenceTimer?.cancel();
    _sequenceTimer = null;
    _log('Sending STOP command.');

    try {
      await _writeCommand('STOP');
    } catch (error) {
      _setSequenceState(WearableBleSequenceState.error);
      _log('STOP write error: $error');
      rethrow;
    }

    _log('STOP command sent successfully.');
    await _cleanupAfterStop();

    try {
      await device.disconnect();
      _log('Wearable BLE device disconnected after STOP.');
    } catch (error) {
      _log('Wearable BLE disconnect after STOP error: $error');
    }

    _setSequenceState(WearableBleSequenceState.stopped);
    _isDisposed = true;
    await _logController.close();
    await _agmSamplesController.close();
    await _sdsStatusController.close();
  }

  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }

    _isDisposed = true;
    _sequenceTimer?.cancel();
    _sequenceTimer = null;
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
    await _agmSamplesController.close();
    await _sdsStatusController.close();
  }

  Future<void> _cleanupAfterStop() async {
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
    if (isStopping || isStopped) {
      return;
    }

    final receivedAt = DateTime.now();
    if (WearableAgmPacketParser.startsWithAgmHeader(value)) {
      _handleAgmPacket(value, receivedAt);
      return;
    }

    if (WearableSdsPacketParser.startsWithSdsHeader(value)) {
      _handleSdsPacket(value, receivedAt);
      return;
    }

    final payload = _tryDecodeText(value);
    if (payload == null) {
      _log('Unknown binary payload: ${_hexPayload(value)}');
      return;
    }

    _log(payload);
    _handleTextNotification(payload);
  }

  void _handleAgmPacket(List<int> value, DateTime receivedAt) {
    if (!WearableAgmPacketParser.hasValidLength(value)) {
      _log(
        'Invalid AGM packet length: ${value.length} bytes | ${_hexPayload(value)}',
      );
      return;
    }

    try {
      final sample = WearableAgmPacketParser.parse(value);
      if (!_agmSamplesController.isClosed) {
        _agmSamplesController.add(
          WearableAgmReceivedSample(
            receivedAt: receivedAt,
            sample: sample,
          ),
        );
      }
      _log(_formatAgmSample(sample));
    } catch (error) {
      _log('Invalid AGM packet: $error | ${_hexPayload(value)}');
    }
  }

  void _handleSdsPacket(List<int> value, DateTime receivedAt) {
    try {
      final status = WearableSdsPacketParser.parse(value);
      if (!_sdsStatusController.isClosed) {
        _sdsStatusController.add(
          WearableSdsReceivedStatus(
            receivedAt: receivedAt,
            batteryPercent: status.batteryPercent,
            flushFailureRate: status.flushFailureRate,
          ),
        );
      }
    } catch (_) {
      // Invalid SDS packets are intentionally ignored.
    }
  }

  void _handleTextNotification(String payload) {
    final trigger = payload.trim();

    if (_sequenceState == WearableBleSequenceState.waitingConfigDone &&
        trigger == 'CONFIG_DONE') {
      _handleConfigDone();
      return;
    }

    if (_sequenceState == WearableBleSequenceState.waitingCalibrationDone &&
        trigger == 'CALIB_DONE') {
      _handleCalibrationDone();
    }
  }

  void _handleConfigDone() {
    _sequenceTimer?.cancel();
    _sequenceTimer = null;
    _setSequenceState(WearableBleSequenceState.configDone);

    if (_calibrationEnabled) {
      unawaited(_sendCalibrationStart());
      return;
    }

    unawaited(_sendStart());
  }

  Future<void> _sendCalibrationStart() async {
    if (_isDisposed) {
      return;
    }

    _setSequenceState(WearableBleSequenceState.calibrationStartSent);

    try {
      await _writeCommand('CALIB_ACC_START');
      _log('CALIB_ACC_START command sent.');
      _setSequenceState(WearableBleSequenceState.waitingCalibrationDone);
      _startTimeout(
        timeout: _calibrationDoneTimeout,
        expectedPayload: 'CALIB_DONE',
        timeoutMessage: 'Timeout waiting for CALIB_DONE after 22 seconds.',
      );
    } catch (error) {
      _setSequenceState(WearableBleSequenceState.error);
      _log('CALIB_ACC_START write error: $error');
    }
  }

  void _handleCalibrationDone() {
    _sequenceTimer?.cancel();
    _sequenceTimer = null;
    _setSequenceState(WearableBleSequenceState.calibrationDone);
    unawaited(_sendStart());
  }

  Future<void> _sendStart() async {
    if (_isDisposed) {
      return;
    }

    _setSequenceState(WearableBleSequenceState.preparingStart);

    try {
      final timestamp = await _currentLocalTimestamp();
      final command = 'START:$timestamp';
      await _writeCommand(command);
      _log('START command sent: $command');
      _setSequenceState(WearableBleSequenceState.startSent);
      _setSequenceState(WearableBleSequenceState.streaming);
      _log('Streaming mode active.');
    } catch (error) {
      _setSequenceState(WearableBleSequenceState.error);
      _log('START write error: $error');
    }
  }

  Future<void> _writeCommand(String command) async {
    final characteristic = _writeCharacteristic;
    if (characteristic == null || _isDisposed) {
      throw StateError('Write characteristic is not available.');
    }

    await characteristic.write(
      utf8.encode(command),
      withoutResponse: true,
    );
  }

  void _startTimeout({
    required Duration timeout,
    required String expectedPayload,
    required String timeoutMessage,
  }) {
    _sequenceTimer?.cancel();
    _sequenceTimer = Timer(timeout, () {
      if (_isDisposed) {
        return;
      }

      _sequenceTimer = null;
      _setSequenceState(WearableBleSequenceState.timeout);
      _log(timeoutMessage);
      _log('Automatic sequence stopped while waiting for $expectedPayload.');
    });
  }

  Future<String> _currentLocalTimestamp() async {
    DateTime localTime;
    try {
      localTime = (await NTP.now().timeout(const Duration(seconds: 5)))
          .toLocal();
    } catch (_) {
      _log('Internet time unavailable, using device local time');
      localTime = DateTime.now();
    }

    return _formatTimestamp(localTime);
  }

  String _formatTimestamp(DateTime value) {
    final year = value.year.toString().padLeft(4, '0');
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    final second = value.second.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute:$second';
  }

  String _formatAgmSample(WearableAgmSample sample) {
    return 'AGM | '
        't=${sample.timestampMs} ms | '
        'acc=(${sample.accX.toStringAsFixed(3)}, '
        '${sample.accY.toStringAsFixed(3)}, '
        '${sample.accZ.toStringAsFixed(3)}) g | '
        'gyr=(${sample.gyrX.toStringAsFixed(2)}, '
        '${sample.gyrY.toStringAsFixed(2)}, '
        '${sample.gyrZ.toStringAsFixed(2)}) dps | '
        'mag=(${sample.magX.toStringAsFixed(2)}, '
        '${sample.magY.toStringAsFixed(2)}, '
        '${sample.magZ.toStringAsFixed(2)})';
  }

  String? _tryDecodeText(List<int> value) {
    try {
      final text = utf8.decode(value, allowMalformed: false);
      final isReadableText = text.runes.every((rune) {
        return rune == 0x09 ||
            rune == 0x0A ||
            rune == 0x0D ||
            (rune >= 0x20 && rune <= 0x7E);
      });

      return isReadableText ? text : null;
    } catch (_) {
      return null;
    }
  }

  String _hexPayload(List<int> value) {
    return value
        .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');
  }

  void _setSequenceState(WearableBleSequenceState state) {
    _sequenceState = state;
    _log('Sequence state: ${state.name}.');
  }

  bool _sameUuid(Guid value, String uuid) {
    return value.toString().toLowerCase() == uuid;
  }

  void _log(String message) {
    if (_isDisposed && _logController.isClosed) {
      return;
    }

    if (_logs.length >= _maxLogEntries) {
      _logs.removeAt(0);
    }
    _logs.add(message);
    debugPrint(message);

    if (!_logController.isClosed) {
      _logController.add(logs);
    }
    onStateChanged?.call();
  }
}

class WearableAgmReceivedSample {
  const WearableAgmReceivedSample({
    required this.receivedAt,
    required this.sample,
  });

  final DateTime receivedAt;
  final WearableAgmSample sample;
}

class WearableSdsReceivedStatus {
  const WearableSdsReceivedStatus({
    required this.receivedAt,
    required this.batteryPercent,
    required this.flushFailureRate,
  });

  final DateTime receivedAt;
  final int batteryPercent;
  final int flushFailureRate;
}
