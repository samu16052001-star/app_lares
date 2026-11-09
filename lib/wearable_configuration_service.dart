import 'dart:async';
import 'dart:convert';

import 'package:app_lares/wearable_agm_packet_parser.dart';
import 'package:app_lares/wearable_end_packet_parser.dart';
import 'package:app_lares/wearable_imu_status.dart';
import 'package:app_lares/wearable_mag_calibration.dart';
import 'package:app_lares/wearable_reception_monitor.dart';
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
  magCalibrationStartSent,
  waitingMagCalibrationDone,
  magCalibrationDone,
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
  static const Duration _statusReplyTimeout = Duration(seconds: 2);
  static const Duration _calibrationDoneTimeout = Duration(seconds: 22);
  // Magnetometer calibration: 20 s of rotation plus margin.
  static const Duration _magCalibrationDoneTimeout =
      Duration(seconds: 32);
  static const Duration _periodicTimestampInterval = Duration(seconds: 60);
  // After STOP the app keeps listening until the IMU sends its END packet or until this timeout.
  static const Duration _endOfAcquisitionTimeout =
      Duration(milliseconds: 1500);
  static const int _requestedAttMtu = 247;
  static const int _minimumBatchedAgmAttMtu = 218;
  static const int _maxLogEntries = 200;

  BluetoothDevice device;
  final VoidCallback? onStateChanged;

  final StreamController<List<String>> _logController =
      StreamController<List<String>>.broadcast();
  final StreamController<WearableAgmReceivedBatch> _agmBatchesController =
      StreamController<WearableAgmReceivedBatch>.broadcast();
  final StreamController<WearableSdsReceivedStatus> _sdsStatusController =
      StreamController<WearableSdsReceivedStatus>.broadcast();
  final StreamController<WearableBleSequenceState> _sequenceStateController =
      StreamController<WearableBleSequenceState>.broadcast();
  final List<String> _logs = [];

  BluetoothCharacteristic? _writeCharacteristic;
  BluetoothCharacteristic? _notifyCharacteristic;
  StreamSubscription<List<int>>? _notificationSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  Timer? _sequenceTimer;
  Timer? _periodicTimestampTimer;

  bool _isDisposed = false;
  bool _periodicTimestampWriteInProgress = false;
  bool _mtuRequested = false;
  int? _lastPacketCounter;
  int? _expectedNextTicks;
  int _samplesReceivedSinceStart = 0;
  int? _configuredSensorMask;
  int _configuredOdr = 104;
  // Last CONFIG command: sent again when an IMU that was switched off and on
  // during the acquisition reconnects (_restartAcquisitionIfImuRebooted).
  String? _lastConfigCommand;
  Completer<WearableImuStatus>? _statusReplyCompleter;
  bool _restartingAfterReboot = false;
  final WearableReceptionMonitor _receptionMonitor = WearableReceptionMonitor();
  Completer<WearableEndPacket?>? _endOfAcquisitionCompleter;
  WearableEndPacket? _lastEndPacket;
  bool _hasBlockingMtuIssue = false;
  bool _serviceDiscoveryCompleted = false;
  bool _targetServiceFound = false;
  bool _writeCharacteristicFound = false;
  bool _notifyCharacteristicFound = false;
  bool _notificationsEnabled = false;
  bool _calibrationEnabled = false;
  bool _magCalibrationEnabled = false;
  DateTime? _magCalibrationStartedAt;
  WearableMagCalibrationResult? _lastMagCalibration;
  String? _magCalibrationWarning;
  // Data watchdog: last data packet, moment from which data are
  // expected (START, reconnection) and link state seen by the phone.
  DateTime? _lastDataAt;
  DateTime? _noDataWatchdogArmedAt;
  bool _linkConnected = true;
  // Safety net of the IMU link. While the app is still
  // configuring the other devices it reconnects nobody, so the IMU is told
  // INIT_BUSY before START (it then keeps a slow link instead of
  // disconnecting) and INIT_DONE when the initialization is finished (sent
  // again after a reconnection if the IMU was disconnected at that moment).
  bool _holdSafetyNet = false;
  bool _initDonePending = false;
  WearableBleSequenceState _sequenceState = WearableBleSequenceState.idle;

  Stream<List<String>> get logsStream => _logController.stream;

  Stream<WearableAgmReceivedBatch> get agmBatchesStream =>
      _agmBatchesController.stream;

  Stream<WearableSdsReceivedStatus> get sdsStatusStream =>
      _sdsStatusController.stream;

  Stream<WearableBleSequenceState> get sequenceStateStream =>
      _sequenceStateController.stream;

  Stream<BluetoothConnectionState> get connectionState =>
      device.connectionState;

  List<String> get logs => List.unmodifiable(_logs);

  WearableBleSequenceState get sequenceState => _sequenceState;

  bool get blocksBackNavigation {
    return switch (_sequenceState) {
      WearableBleSequenceState.waitingConfigDone ||
      WearableBleSequenceState.configDone ||
      WearableBleSequenceState.calibrationStartSent ||
      WearableBleSequenceState.waitingCalibrationDone ||
      WearableBleSequenceState.calibrationDone ||
      WearableBleSequenceState.magCalibrationStartSent ||
      WearableBleSequenceState.waitingMagCalibrationDone ||
      WearableBleSequenceState.magCalibrationDone ||
      WearableBleSequenceState.preparingStart ||
      WearableBleSequenceState.streaming ||
      WearableBleSequenceState.stopping => true,
      _ => false,
    };
  }

  bool get isStopping => _sequenceState == WearableBleSequenceState.stopping;

  bool get isStopped => _sequenceState == WearableBleSequenceState.stopped;

  /// Samples received since the last START (AGM, AG2 and IMD).
  int get samplesReceivedSinceStart => _samplesReceivedSinceStart;

  /// Received/missing samples over the last 10 s (indicator in the UI).
  WearableReceptionMonitor get receptionMonitor => _receptionMonitor;

  /// Sensors requested with the last CONFIG ([WearableSensorMask] bits), null
  /// before CONFIG. The data packets say which sensors really arrived.
  int? get configuredSensorMask => _configuredSensorMask;

  /// END packet received after the last STOP, if the firmware sent one.
  WearableEndPacket? get lastEndPacket => _lastEndPacket;

  /// What the person holding the IMU must do while it calibrates, shown in
  /// the UI; null when no calibration is running. The accelerometer and
  /// gyroscope calibration assumes the IMU still, flat and face up (a tilted
  /// IMU gives a wrong accelerometer bias); the magnetometer calibration
  /// needs the IMU rotated in all directions.
  String? get calibrationInstruction {
    switch (_sequenceState) {
      case WearableBleSequenceState.calibrationStartSent:
      case WearableBleSequenceState.waitingCalibrationDone:
        return 'Calibrating: keep the IMU still, flat and face up.';
      case WearableBleSequenceState.magCalibrationStartSent:
      case WearableBleSequenceState.waitingMagCalibrationDone:
        final startedAt = _magCalibrationStartedAt;
        final elapsed = startedAt == null
            ? Duration.zero
            : DateTime.now().difference(startedAt);
        final remaining = WearableMagCalibrationResult.duration - elapsed;
        final remainingText = remaining > Duration.zero
            ? '${(remaining.inMilliseconds / 1000).ceil()} s left'
            : 'finishing';
        return 'Magnetometer calibration: rotate the IMU slowly in all '
            'directions (upside down and on every side), away from metal '
            'objects ($remainingText).';
      default:
        return null;
    }
  }

  /// Result of the last magnetometer calibration.
  WearableMagCalibrationResult? get lastMagCalibration => _lastMagCalibration;

  /// Set when the magnetometer calibration failed or got no reply: the IMU
  /// goes on with its previous offset. Shown in the UI.
  String? get magCalibrationWarning => _magCalibrationWarning;

  /// Silence that triggers the "no IMU data" alert for the configured sensors
  /// and ODR (2 s at 104 Hz), see [WearableNoDataWatchdog].
  Duration get noDataAlertThreshold => WearableNoDataWatchdog.thresholdFor(
        sensorMask: _configuredSensorMask,
        odr: _configuredOdr,
      );

  /// How long this IMU has sent no data, when that reaches
  /// [noDataAlertThreshold] while it should be streaming; null otherwise (not
  /// streaming, stopping, link already closed by the phone, data arriving).
  Duration? noDataFor(DateTime now) {
    if (_isDisposed ||
        !_linkConnected ||
        _sequenceState != WearableBleSequenceState.streaming) {
      return null;
    }
    return WearableNoDataWatchdog.silenceBeyond(
      now: now,
      lastDataAt: _lastDataAt,
      armedAt: _noDataWatchdogArmedAt,
      threshold: noDataAlertThreshold,
    );
  }

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

    _listenToConnectionState();
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

  Future<void> resumeNotificationsAfterReconnect({
    BluetoothDevice? reconnectedDevice,
  }) async {
    if (_isDisposed) {
      throw StateError('Wearable BLE service is disposed.');
    }

    if (reconnectedDevice != null) {
      await _cancelConnectionStateSubscription();
      device = reconnectedDevice;
    }

    _listenToConnectionState();
    await _clearNotificationSubscriptionForReconnect();
    await _discoverWearableService();
    if (_isDisposed) {
      return;
    }

    await _enableNotifications();
    if (!_targetServiceFound ||
        !_writeCharacteristicFound ||
        !_notifyCharacteristicFound ||
        !_notificationsEnabled) {
      throw StateError('Wearable BLE notification resume is not complete.');
    }
    // Link back: data are expected again from now (data watchdog).
    _linkConnected = true;
    _noDataWatchdogArmedAt = DateTime.now();
    _resumePeriodicTimestampTimerIfStreaming();
    await _restartAcquisitionIfImuRebooted();
  }

  Future<void> startConfigurationSequence({
    required int odr,
    required int mag,
    required int accG,
    required int gyrDPS,
    required bool calibrationEnabled,
    bool magCalibrationEnabled = false,
    bool holdSafetyNetUntilInitDone = false,
  }) async {
    // 0 = sensor off: accG = 0 accelerometer off,
    // gyrDPS = 0 gyroscope off, mag = 0 magnetometer off.
    final command = 'CONFIG:$odr,$mag,$accG,$gyrDPS';

    if (!isReadyToContinue) {
      final message = 'CONFIG write blocked: BLE setup is not complete.';
      _log(message);
      throw StateError(message);
    }

    _calibrationEnabled = calibrationEnabled;
    _holdSafetyNet = holdSafetyNetUntilInitDone;
    _initDonePending = false;
    // The magnetometer calibration needs the magnetometer on (CONFIG mag = 1).
    _magCalibrationEnabled = magCalibrationEnabled && mag == 1;
    _magCalibrationWarning = null;
    _configuredSensorMask = WearableSensorMask.fromConfiguration(
      mag: mag,
      accG: accG,
      gyrDPS: gyrDPS,
    );
    _configuredOdr = odr;
    _lastConfigCommand = command;
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
    _stopPeriodicTimestampTimer();
    // Created before writing STOP: the END packet can arrive before the write
    // future completes.
    _endOfAcquisitionCompleter = Completer<WearableEndPacket?>();
    _lastEndPacket = null;
    _log('Sending STOP command.');

    try {
      await _writeCommand('STOP');
    } catch (error) {
      _endOfAcquisitionCompleter = null;
      _setSequenceState(WearableBleSequenceState.error);
      _log('STOP write error: $error');
      rethrow;
    }

    _log('STOP command sent successfully. Waiting for the last samples.');
    // Notifications are still processed while stopping: the samples produced
    // before the IMU received STOP, and the last partial AG2 packet, still
    // reach the CSV. Before this change they were dropped (6-32 samples per
    // IMU at the end of every recording, still present on the SD).
    final endPacket = await _waitForEndOfAcquisition();
    if (endPacket == null) {
      _log(
        'No END packet within ${_endOfAcquisitionTimeout.inMilliseconds} ms '
        '(firmware older than 14/10/2026?): closing anyway.',
      );
    }
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
    await _agmBatchesController.close();
    await _sdsStatusController.close();
    await _sequenceStateController.close();
  }

  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }

    _isDisposed = true;
    _sequenceTimer?.cancel();
    _sequenceTimer = null;
    _stopPeriodicTimestampTimer();
    _log('Wearable BLE service disposal started.');

    await _cancelConnectionStateSubscription();

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
    await _agmBatchesController.close();
    await _sdsStatusController.close();
    await _sequenceStateController.close();
  }

  Future<void> _cleanupAfterStop() async {
    _stopPeriodicTimestampTimer();
    await _cancelConnectionStateSubscription();

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

  Future<void> _clearNotificationSubscriptionForReconnect() async {
    try {
      await _notificationSubscription?.cancel();
      _log('Notification subscription cancelled for reconnect.');
    } catch (error) {
      _log('Notification subscription cancellation error: $error');
    }
    _notificationSubscription = null;
    _notificationsEnabled = false;
  }

  void _listenToConnectionState() {
    _connectionStateSubscription ??= device.connectionState.listen((state) {
      _linkConnected = state == BluetoothConnectionState.connected;
      if (state == BluetoothConnectionState.disconnected) {
        _stopPeriodicTimestampTimer();
      }
    });
  }

  Future<void> _cancelConnectionStateSubscription() async {
    try {
      await _connectionStateSubscription?.cancel();
    } catch (error) {
      debugPrint('Wearable connection listener cancellation error: $error');
    }
    _connectionStateSubscription = null;
  }

  Future<void> _requestMtu() async {
    _log('MTU request started: requesting $_requestedAttMtu bytes.');
    _mtuRequested = true;

    try {
      final mtu = await device.requestMtu(_requestedAttMtu);
      _log('MTU request success/result: $mtu bytes.');
      _checkMtu(mtu);
    } catch (error) {
      _log('MTU request error: $error');
      _log('Continuing BLE setup; MTU size could not be confirmed.');
    }
  }

  void _checkMtu(int mtu) {
    if (mtu < _minimumBatchedAgmAttMtu) {
      _hasBlockingMtuIssue = true;
      _log(
        'MTU lower than $_minimumBatchedAgmAttMtu warning/error: negotiated MTU is $mtu bytes. Continue disabled.',
      );
      return;
    }

    _hasBlockingMtuIssue = false;
    _log(
      'MTU check passed: negotiated MTU is at least $_minimumBatchedAgmAttMtu bytes.',
    );
  }

  Future<void> _discoverWearableService() async {
    _log('Service discovery started.');
    _targetServiceFound = false;
    _writeCharacteristicFound = false;
    _notifyCharacteristicFound = false;
    _writeCharacteristic = null;
    _notifyCharacteristic = null;

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
    // While stopping, notifications are still handled (last samples + END).
    if (isStopped) {
      return;
    }

    final receivedAt = DateTime.now();
    if (WearableEndPacketParser.startsWithEndHeader(value)) {
      _handleEndPacket(value);
      return;
    }

    if (WearableAg2PacketParser.startsWithAg2Header(value)) {
      _handleAg2Packet(value, receivedAt);
      return;
    }

    // Before the AGM length check: an IMD packet can be 43, 86, ... bytes long.
    if (WearableImdPacketParser.startsWithImdHeader(value)) {
      _handleImdPacket(value, receivedAt);
      return;
    }

    if (WearableAgmPacketParser.startsWithAgmHeader(value) ||
        WearableAgmPacketParser.hasValidLength(value)) {
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
    try {
      final samples = WearableAgmPacketParser.parseBatch(value);
      _lastDataAt = receivedAt;
      _receptionMonitor.addAgmSamples(
        receivedAt: receivedAt,
        timestampsMs: [for (final sample in samples) sample.timestampMs],
        stepMs: _nominalStepTicks(_configuredOdr) * 0.025,
      );
      _publishImuSamples(samples, receivedAt);
    } catch (_) {
      // Invalid AGM batches are intentionally ignored.
    }
  }

  void _handleAg2Packet(List<int> value, DateTime receivedAt) {
    try {
      final packet = WearableAg2PacketParser.parsePacket(value);
      _handleTickPacket(
        label: 'AG2',
        packetCounter: packet.packetCounter,
        firstTicks: packet.firstTicks,
        stepTicks: packet.stepTicks,
        sampleCount: packet.samples.length,
        receivedAt: receivedAt,
      );
      _publishImuSamples(packet.samples, receivedAt);
    } catch (_) {
      // Invalid AG2 packets are intentionally ignored, like invalid AGM batches.
    }
  }

  void _handleImdPacket(List<int> value, DateTime receivedAt) {
    try {
      final packet = WearableImdPacketParser.parsePacket(value);
      _handleTickPacket(
        label: 'IMD',
        packetCounter: packet.packetCounter,
        firstTicks: packet.firstTicks,
        stepTicks: packet.stepTicks,
        sampleCount: packet.samples.length,
        receivedAt: receivedAt,
      );
      _publishImuSamples(packet.samples, receivedAt);
    } catch (_) {
      // Invalid IMD packets are intentionally ignored, like invalid AGM batches.
    }
  }

  /// Sensor ticks (25 us) between two samples at a native ODR, like the
  /// firmware (6666.67 Hz / 2^k): 384 ticks = 9.6 ms at 104 Hz.
  static int _nominalStepTicks(int odr) {
    return switch (odr) {
      12 || 13 => 3072,
      26 => 1536,
      52 => 768,
      104 => 384,
      208 => 192,
      _ => 96,
    };
  }

  /// AGM, AG2 and IMD samples go to the same stream, so CSV logging, charts
  /// and MQTT work the same way with all packet formats.
  void _publishImuSamples(
    List<WearableAgmSample> samples,
    DateTime receivedAt,
  ) {
    _samplesReceivedSinceStart += samples.length;
    if (!isStopping) {
      _startPeriodicTimestampTimerIfNeeded(receivedAt);
    }
    if (!_agmBatchesController.isClosed) {
      _agmBatchesController.add(
        WearableAgmReceivedBatch(
          receivedAt: receivedAt,
          samples: samples,
        ),
      );
    }
    _log(_formatAgmSample(samples.first));
  }

  /// AG2 and IMD packets: logs lost notifications (packet counter jump) and
  /// missing samples (first timestamp not equal to the one expected after the
  /// previous packet), and feeds the reception indicator.
  void _handleTickPacket({
    required String label,
    required int packetCounter,
    required int firstTicks,
    required int stepTicks,
    required int sampleCount,
    required DateTime receivedAt,
  }) {
    final lastCounter = _lastPacketCounter;
    final expectedTicks = _expectedNextTicks;
    // Counter 0 = first packet after START; after 255 it is just the wrap.
    final isNewAcquisition =
        packetCounter == 0 && (lastCounter == null || lastCounter != 0xFF);

    if (!isNewAcquisition && lastCounter != null) {
      final expectedCounter = (lastCounter + 1) & 0xFF;
      if (packetCounter != expectedCounter) {
        _log(
          '$label packet counter jump: expected $expectedCounter, '
          'received $packetCounter.',
        );
      }
    }

    if (!isNewAcquisition &&
        expectedTicks != null &&
        stepTicks > 0 &&
        firstTicks != expectedTicks) {
      final deltaTicks = (firstTicks - expectedTicks) & 0xFFFFFFFF;
      _log(
        '$label gap: about ${deltaTicks ~/ stepTicks} samples missing '
        'before this packet.',
      );
    }

    _lastDataAt = receivedAt;
    _receptionMonitor.addTickPacket(
      receivedAt: receivedAt,
      firstTicks: firstTicks,
      stepTicks: stepTicks,
      sampleCount: sampleCount,
      newAcquisition: isNewAcquisition,
    );
    _lastPacketCounter = packetCounter;
    _expectedNextTicks = (firstTicks + sampleCount * stepTicks) & 0xFFFFFFFF;
  }

  /// END packet: the IMU has sent its last sample after STOP. Logs how many
  /// samples the IMU recorded and how many reached the app.
  void _handleEndPacket(List<int> value) {
    final WearableEndPacket packet;
    try {
      packet = WearableEndPacketParser.parse(value);
    } catch (_) {
      _log('Invalid END packet: ${_hexPayload(value)}');
      return;
    }

    _lastEndPacket = packet;
    final received = _samplesReceivedSinceStart;
    final counters = packet.bleNotifyFailures == null
        ? ''
        : ' Failed notifications in the IMU: ${packet.bleNotifyFailures}, '
            'dropped from the BLE queue: ${packet.bleQueueDrops}, '
            'dropped from the SD queue: ${packet.sdQueueDrops}.';
    _log(
      'END: the IMU recorded ${packet.totalSamples} samples, the app received '
      '$received (missing: ${packet.totalSamples - received}). '
      'SD recording number: ${packet.sdFileNumber}.$counters',
    );

    final completer = _endOfAcquisitionCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(packet);
    }
  }

  Future<WearableEndPacket?> _waitForEndOfAcquisition() async {
    final completer = _endOfAcquisitionCompleter;
    if (completer == null) {
      return null;
    }

    try {
      return await completer.future.timeout(_endOfAcquisitionTimeout);
    } on TimeoutException {
      return null;
    } finally {
      _endOfAcquisitionCompleter = null;
    }
  }

  void _handleSdsPacket(List<int> value, DateTime receivedAt) {
    try {
      final status = WearableSdsPacketParser.parse(value);
      final link = status.link;
      if (link != null) {
        _log('BLE link: ${link.summary}.');
      }
      if (!_sdsStatusController.isClosed) {
        _sdsStatusController.add(
          WearableSdsReceivedStatus(
            receivedAt: receivedAt,
            batteryPercent: status.batteryPercent,
            flushFailureRate: status.flushFailureRate,
            link: link,
          ),
        );
      }
    } catch (_) {
      // Invalid SDS packets are intentionally ignored.
    }
  }

  void _handleTextNotification(String payload) {
    final trigger = payload.trim();

    final status = WearableImuStatus.tryParse(trigger);
    if (status != null) {
      final completer = _statusReplyCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete(status);
      }
      return;
    }

    if (_sequenceState == WearableBleSequenceState.waitingConfigDone &&
        trigger == 'CONFIG_DONE') {
      _handleConfigDone();
      return;
    }

    if (_sequenceState == WearableBleSequenceState.waitingCalibrationDone &&
        trigger == 'CALIB_DONE') {
      _handleCalibrationDone();
      return;
    }

    final magCalibration = WearableMagCalibrationResult.tryParse(trigger);
    if (magCalibration != null &&
        _sequenceState == WearableBleSequenceState.waitingMagCalibrationDone) {
      _handleMagCalibrationResult(magCalibration);
    }
  }

  void _handleConfigDone() {
    _sequenceTimer?.cancel();
    _sequenceTimer = null;
    _setSequenceState(WearableBleSequenceState.configDone);

    // After an IMU restart the biases saved in its flash are used: no
    // calibration while the subject is wearing the IMU.
    final restarting = _restartingAfterReboot;
    _restartingAfterReboot = false;
    if (_calibrationEnabled && !restarting) {
      unawaited(_sendCalibrationStart());
      return;
    }
    if (_magCalibrationEnabled && !restarting) {
      unawaited(_sendMagCalibrationStart());
      return;
    }

    unawaited(_sendStart());
  }

  /// Called after a reconnection while streaming. If only the link dropped,
  /// the IMU is still recording (SD and data go on). If the IMU was switched
  /// off and on, it has lost CONFIG and START: the IMU says which case it is
  /// (STATUS) and in the second case the same CONFIG
  /// and a new START are sent, without calibration. The recording goes on in
  /// a new SD file.
  Future<void> _restartAcquisitionIfImuRebooted() async {
    if (_isDisposed || _sequenceState != WearableBleSequenceState.streaming) {
      return;
    }

    final status = await _queryImuStatus();
    if (_isDisposed || _sequenceState != WearableBleSequenceState.streaming) {
      return;
    }
    if (status == null) {
      _log(
        'No STATUS reply (firmware older than 20/10/2026?): the IMU is not '
        'restarted automatically.',
      );
      await _sendInitDoneIfPending();
      return;
    }
    if (status.recording) {
      _log('IMU still recording after the reconnection (${status.summary}).');
      await _sendInitDoneIfPending();
      return;
    }

    final configCommand = _lastConfigCommand;
    if (configCommand == null) {
      _log(
        'IMU not recording after the reconnection (${status.summary}), but '
        'there is no CONFIG to send again.',
      );
      return;
    }

    _log(
      'IMU not recording after the reconnection (${status.summary}): it was '
      'switched off and on. Sending CONFIG and START again.',
    );
    _restartingAfterReboot = true;
    // New acquisition: packet counter and sensor time start again from 0.
    _lastPacketCounter = null;
    _expectedNextTicks = null;
    _setSequenceState(WearableBleSequenceState.configSent);

    try {
      await _writeCommand(configCommand);
      _log('CONFIG command sent: $configCommand');
      _setSequenceState(WearableBleSequenceState.waitingConfigDone);
      _startTimeout(
        timeout: _configDoneTimeout,
        expectedPayload: 'CONFIG_DONE',
        timeoutMessage: 'Timeout waiting for CONFIG_DONE after 10 seconds.',
      );
    } catch (error) {
      _restartingAfterReboot = false;
      _setSequenceState(WearableBleSequenceState.error);
      _log('CONFIG write error: $error');
    }
  }

  /// Asks the IMU whether it is recording. Null if it does not answer within
  /// [_statusReplyTimeout].
  Future<WearableImuStatus?> _queryImuStatus() async {
    final completer = Completer<WearableImuStatus>();
    _statusReplyCompleter = completer;

    try {
      await _writeCommand(WearableImuStatus.command);
      return await completer.future.timeout(_statusReplyTimeout);
    } on TimeoutException {
      return null;
    } catch (error) {
      _log('STATUS write error: $error');
      return null;
    } finally {
      if (identical(_statusReplyCompleter, completer)) {
        _statusReplyCompleter = null;
      }
    }
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
    if (_magCalibrationEnabled) {
      unawaited(_sendMagCalibrationStart());
      return;
    }
    unawaited(_sendStart());
  }

  /// Magnetometer calibration: the person rotates
  /// the IMU for [WearableMagCalibrationResult.duration]. Whatever the result
  /// (or no reply) the acquisition then starts: after a
  /// failure the IMU keeps its previous offset and a warning stays visible.
  Future<void> _sendMagCalibrationStart() async {
    if (_isDisposed) {
      return;
    }

    _magCalibrationStartedAt = null;
    _setSequenceState(WearableBleSequenceState.magCalibrationStartSent);

    try {
      await _writeCommand(WearableMagCalibrationResult.command);
      _magCalibrationStartedAt = DateTime.now();
      _log(
        '${WearableMagCalibrationResult.command} command sent: rotate the IMU '
        'slowly in all directions for '
        '${WearableMagCalibrationResult.duration.inSeconds} s.',
      );
      _setSequenceState(WearableBleSequenceState.waitingMagCalibrationDone);
      _sequenceTimer?.cancel();
      _sequenceTimer = Timer(_magCalibrationDoneTimeout, () {
        _sequenceTimer = null;
        if (_isDisposed ||
            _sequenceState !=
                WearableBleSequenceState.waitingMagCalibrationDone) {
          return;
        }
        _magCalibrationWarning =
            'Magnetometer calibration: no reply from the IMU. The magnetometer offset was not updated.';
        _log(_magCalibrationWarning!);
        _setSequenceState(WearableBleSequenceState.magCalibrationDone);
        unawaited(_sendStart());
      });
    } catch (error) {
      _setSequenceState(WearableBleSequenceState.error);
      _log('${WearableMagCalibrationResult.command} write error: $error');
    }
  }

  void _handleMagCalibrationResult(WearableMagCalibrationResult result) {
    _sequenceTimer?.cancel();
    _sequenceTimer = null;
    _lastMagCalibration = result;
    _magCalibrationWarning = result.success ? null : result.summary;
    _log(result.summary);
    _setSequenceState(WearableBleSequenceState.magCalibrationDone);
    unawaited(_sendStart());
  }

  Future<void> _sendStart() async {
    if (_isDisposed) {
      return;
    }

    _setSequenceState(WearableBleSequenceState.preparingStart);
    _samplesReceivedSinceStart = 0;

    try {
      final timestamp = await _currentLocalTimestamp();
      if (_holdSafetyNet) {
        await _sendInitBusy();
      }
      final command = 'START:$timestamp';
      await _writeCommand(command);
      _log('START command sent: $command');
      _setSequenceState(WearableBleSequenceState.startSent);
      _setSequenceState(WearableBleSequenceState.streaming);
      _log('Streaming mode active.');
      // Restart after a reboot while the initialization was already finished.
      await _sendInitDoneIfPending();
    } catch (error) {
      _setSequenceState(WearableBleSequenceState.error);
      _log('START write error: $error');
    }
  }

  static const String _initBusyCommand = 'INIT_BUSY';
  static const String _initDoneCommand = 'INIT_DONE';

  /// Before START during a multi-device initialization: the
  /// IMU must not disconnect by itself until INIT_DONE.
  Future<void> _sendInitBusy() async {
    try {
      await _writeCommand(_initBusyCommand);
      _log('INIT_BUSY sent: the IMU keeps its link until the other devices '
          'are configured.');
    } catch (error) {
      _log('INIT_BUSY write error: $error');
    }
  }

  /// The multi-device initialization is finished: from now on
  /// the IMU may disconnect by itself if its link loses data, and it is
  /// reconnected right away. If the IMU is disconnected now, INIT_DONE is
  /// sent after the reconnection.
  Future<void> notifyInitializationDone() async {
    if (!_holdSafetyNet && !_initDonePending) {
      return;
    }
    _holdSafetyNet = false;
    _initDonePending = true;
    await _sendInitDoneIfPending();
  }

  Future<void> _sendInitDoneIfPending() async {
    if (!_initDonePending || _isDisposed || !_linkConnected) {
      return;
    }
    try {
      await _writeCommand(_initDoneCommand);
      _initDonePending = false;
      _log('INIT_DONE sent: the IMU may now disconnect by itself if its link '
          'loses data.');
    } catch (error) {
      _log('INIT_DONE write error: $error (sent again after the reconnection)');
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

  void _startPeriodicTimestampTimerIfNeeded(DateTime firstValidAgmReceivedAt) {
    if (_periodicTimestampTimer != null || _isDisposed) {
      return;
    }

    final firstSendAt =
        firstValidAgmReceivedAt.add(_periodicTimestampInterval);
    final delay = firstSendAt.difference(DateTime.now());
    final initialDelay = delay.isNegative ? Duration.zero : delay;

    _periodicTimestampTimer = Timer(initialDelay, () {
      if (_isDisposed || !_canSendPeriodicTimestamp) {
        _stopPeriodicTimestampTimer();
        return;
      }

      unawaited(_sendPeriodicTimestamp());
      _periodicTimestampTimer = Timer.periodic(
        _periodicTimestampInterval,
        (_) {
          unawaited(_sendPeriodicTimestamp());
        },
      );
    });
  }

  void _stopPeriodicTimestampTimer() {
    _periodicTimestampTimer?.cancel();
    _periodicTimestampTimer = null;
    _periodicTimestampWriteInProgress = false;
  }

  void _resumePeriodicTimestampTimerIfStreaming() {
    if (_sequenceState != WearableBleSequenceState.streaming ||
        _periodicTimestampTimer != null ||
        _isDisposed) {
      return;
    }

    _periodicTimestampTimer = Timer.periodic(
      _periodicTimestampInterval,
      (_) {
        unawaited(_sendPeriodicTimestamp());
      },
    );
    _log('Periodic timestamp timer resumed after reconnect.');
  }

  bool get _canSendPeriodicTimestamp {
    return !_isDisposed &&
        _writeCharacteristic != null &&
        _sequenceState == WearableBleSequenceState.streaming;
  }

  Future<void> _sendPeriodicTimestamp() async {
    if (!_canSendPeriodicTimestamp || _periodicTimestampWriteInProgress) {
      return;
    }

    _periodicTimestampWriteInProgress = true;
    final timestamp = _formatTimestamp(DateTime.now());
    try {
      await _writeCommand('TIMESTAMP:$timestamp');
    } catch (error) {
      debugPrint('Periodic timestamp write error: $error');
    } finally {
      _periodicTimestampWriteInProgress = false;
    }
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
    return [
      'IMU',
      't=${sample.timestampMs} ms',
      if (sample.hasAccelerometer)
        'acc=(${sample.accX.toStringAsFixed(3)}, '
            '${sample.accY.toStringAsFixed(3)}, '
            '${sample.accZ.toStringAsFixed(3)}) g',
      if (sample.hasGyroscope)
        'gyr=(${sample.gyrX.toStringAsFixed(2)}, '
            '${sample.gyrY.toStringAsFixed(2)}, '
            '${sample.gyrZ.toStringAsFixed(2)}) dps',
      if (sample.hasMagnetometer)
        'mag=(${sample.magX.toStringAsFixed(2)}, '
            '${sample.magY.toStringAsFixed(2)}, '
            '${sample.magZ.toStringAsFixed(2)}) uT',
    ].join(' | ');
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
    if (state == WearableBleSequenceState.streaming) {
      // START sent: data are expected from now (data watchdog).
      _noDataWatchdogArmedAt = DateTime.now();
    }
    if (_shouldStopPeriodicTimestampForState(state)) {
      _stopPeriodicTimestampTimer();
    }
    if (!_sequenceStateController.isClosed) {
      _sequenceStateController.add(state);
    }
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

  bool _shouldStopPeriodicTimestampForState(WearableBleSequenceState state) {
    return switch (state) {
      WearableBleSequenceState.stopping ||
      WearableBleSequenceState.stopped ||
      WearableBleSequenceState.timeout ||
      WearableBleSequenceState.error => true,
      _ => false,
    };
  }
}

class WearableAgmReceivedBatch {
  WearableAgmReceivedBatch({
    required this.receivedAt,
    required List<WearableAgmSample> samples,
  }) : samples = List.unmodifiable(samples) {
    if (this.samples.isEmpty ||
        this.samples.length > WearableImdPacketParser.maxSamplesPerPacket) {
      throw ArgumentError.value(
        samples.length,
        'samples.length',
        'IMU batches must contain between 1 and '
            '${WearableImdPacketParser.maxSamplesPerPacket} samples '
            '(5 for AGM, up to 19 for AG2, up to 38 for IMD).',
      );
    }
  }

  final DateTime receivedAt;
  final List<WearableAgmSample> samples;

  WearableAgmSample get firstSample => samples.first;
}

class WearableSdsReceivedStatus {
  const WearableSdsReceivedStatus({
    required this.receivedAt,
    required this.batteryPercent,
    required this.flushFailureRate,
    this.link,
  });

  final DateTime receivedAt;
  final int batteryPercent;
  final int flushFailureRate;

  /// BLE link parameters.
  final WearableLinkStatus? link;
}
