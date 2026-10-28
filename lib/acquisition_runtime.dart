part of 'main.dart';

// The retained Android engine owns this model. Views only observe it; neither
// Activity detachment nor disposal of an acquisition view ends the session.
Map<String, dynamic> _encodeAcquisitionDevice(_ConnectedDeviceSession session) {
  return <String, dynamic>{
    'deviceId': session.deviceId,
    'deviceName': session.deviceName,
    'type': session.type.name,
    'customName': session.customName,
    'polarDeviceId': session.polarDeviceId,
    'polarAddress': session.polarAddress,
    'polarRssi': session.polarRssi,
    if (session.environmentalConfiguration case final configuration?)
      'configuration': {
        'enabledOptions': configuration.enabledOptions,
        'samplingFrequencySeconds': configuration.samplingFrequencySeconds,
      },
    if (session.environmentalV2Configuration case final configuration?)
      'configuration': {
        'enabledOptions': {
          for (final entry in configuration.enabledOptions.entries)
            entry.key.name: entry.value,
        },
      },
    if (session.wearableConfiguration case final configuration?)
      'configuration': {
        'odr': configuration.odr,
        'mag': configuration.mag,
        'accG': configuration.accG,
        'gyrDPS': configuration.gyrDPS,
        'calibrationEnabled': configuration.calibrationEnabled,
      },
    if (session.polarConfiguration case final configuration?)
      'configuration': {
        'hrEnabled': configuration.hrEnabled,
        'rawEcgEnabled': configuration.rawEcgEnabled,
        'accelerometerEnabled': configuration.accelerometerEnabled,
      },
  };
}

_ConnectedDeviceSession _decodeAcquisitionDevice(Map<String, dynamic> value) {
  final id = value['deviceId'] as String;
  if (id.isEmpty) throw StateError('Stored device identity is missing.');
  final type = KnownDeviceType.values.byName(value['type'] as String);
  final configuration = Map<String, dynamic>.from(value['configuration'] as Map);
  final session = _ConnectedDeviceSession(
    device: type == KnownDeviceType.polarH10 ? null : BluetoothDevice.fromId(id),
    deviceId: id,
    deviceName: value['deviceName'] as String,
    type: type,
    customName: value['customName'] as String?,
    polarAddress: value['polarAddress'] as String?,
    polarRssi: value['polarRssi'] as int?,
  )..polarDeviceId = value['polarDeviceId'] as String?;
  switch (type) {
    case KnownDeviceType.environmentalMonitor:
      session.environmentalConfiguration = BleConfiguration(
        enabledOptions: Map<String, bool>.from(configuration['enabledOptions'] as Map),
        samplingFrequencySeconds: configuration['samplingFrequencySeconds'] as int,
      );
      break;
    case KnownDeviceType.environmentalMonitorV2:
      final options = Map<String, dynamic>.from(configuration['enabledOptions'] as Map);
      session.environmentalV2Configuration = EnvironmentalV2Configuration(
        enabledOptions: {
          for (final entry in options.entries)
            EnvironmentalV2Option.values.byName(entry.key): entry.value as bool,
        },
      );
      break;
    case KnownDeviceType.respiratoryMonitor:
      session.wearableConfiguration = WearableDeviceConfiguration(
        odr: configuration['odr'] as int,
        mag: configuration['mag'] as int,
        accG: configuration['accG'] as int,
        gyrDPS: configuration['gyrDPS'] as int,
        calibrationEnabled: configuration['calibrationEnabled'] as bool,
      );
      break;
    case KnownDeviceType.polarH10:
      session.polarConfiguration = PolarH10Configuration(
        hrEnabled: configuration['hrEnabled'] as bool,
        rawEcgEnabled: configuration['rawEcgEnabled'] as bool,
        accelerometerEnabled: configuration['accelerometerEnabled'] as bool,
      );
      break;
    case KnownDeviceType.unsupported:
      throw StateError('The stored device type cannot be recovered.');
  }
  if (!session.isConfigured) throw StateError('Stored device configuration is incomplete.');
  return session;
}

Future<void> _restoreSavedAcquisition(AcquisitionRecoverySnapshot snapshot) async {
  if (snapshot.devices.isEmpty || snapshot.csvFilePath == null ||
      snapshot.startedAtIso8601 == null) {
    throw StateError('This session predates automatic recovery or has incomplete saved information. '
        'Its original CSV has been preserved.');
  }
  if (snapshot.workflow == 'single-environmental') {
    await _EnvironmentalAcquisitionController.restore(snapshot);
    return;
  }
  if (snapshot.workflow == 'single-wearable') {
    await _WearableAcquisitionController.restore(snapshot);
    return;
  }
  if (snapshot.workflow != 'multi-device') {
    throw StateError('The saved acquisition workflow is not supported.');
  }
  await _MultiDeviceSessionManager.restore(snapshot);
}

Future<void> _restoreMultiDeviceAcquisition(AcquisitionRecoverySnapshot snapshot) async {
  final sessions = snapshot.devices.map(_ConnectedDeviceSession.fromRecoveryDevice).toList();
  if (sessions.map((session) => session.deviceId).toSet().length != sessions.length) {
    throw StateError('The saved session contains duplicate device identities.');
  }
  final manager = _MultiDeviceSessionManager()
    .._sessionId = snapshot.sessionId
    .._startedAt = DateTime.parse(snapshot.startedAtIso8601!)
    .._initializationStarted = true
    .._openRemoteConnectRequested = snapshot.runtimeState['openRemoteConnectRequested'] == true;
  try {
    // This can fail when Android does not permit a background FGS launch. Keep
    // the snapshot intact; the recovery page retries when an Activity returns.
    await AndroidAcquisitionForegroundService.start();
    manager._foregroundServiceStarted = true;
    await manager.csvLogger.start(
      existingFilePath: snapshot.csvFilePath,
      existingFileName: snapshot.csvFileName,
      startedAt: manager._startedAt,
      sessionId: snapshot.sessionId,
    );
    await manager.gpsLocationService.start();
  } catch (_) {
    await manager.csvLogger.stop();
    await manager.gpsLocationService.dispose();
    await AndroidAcquisitionForegroundService.stop();
    rethrow;
  }
  manager._acquisitionStarted = true;
  manager._sessions.addAll(sessions);
  _ActiveAcquisitionRuntime.registerSingleOwner(
    manager, () => _MultiDeviceAcquisitionPage(manager: manager), () async {},
  );
  _ActiveAcquisitionRuntime.registerMultiDeviceManager(manager);
  final lastAlive = DateTime.tryParse(snapshot.lastHeartbeatIso8601 ?? '') ?? manager._startedAt!;
  manager.backgroundStatusMessage = 'Acquisition was interrupted after '
      '${lastAlive.toLocal()}. Samples may be missing. Continuing the original CSV.';
  final gpsMessage = manager.gpsLocationService.statusMessage;
  if (gpsMessage != null) {
    manager.backgroundStatusMessage = _mergeStatusMessage(manager.backgroundStatusMessage, gpsMessage);
  }
  for (final session in sessions) {
    session
      ..isConnected = false
      ..needsProcessRecovery = true
      ..interruptionPending = true
      ..disconnectedDuringAcquisition = true
      ..disconnectionAlertVersion = 1;
    await AcquisitionRecoveryStore.recordInterruption(
      deviceId: session.deviceId,
      startedAt: lastAlive,
      reason: 'process_termination_possible_data_loss',
    );
    manager._attachConnectionListener(session);
  }
  manager._openRemoteLocationSubscription = manager.gpsLocationService.livePositions.listen(
    manager._handleOpenRemoteLivePosition,
  );
  if (manager.canUseOpenRemote) {
    manager._mqttStateSubscription = manager.mqttService.states.listen(
      manager._handleOpenRemoteMqttState,
    );
  }
  await AcquisitionRecoveryStore.updateStatus(logicalRoute: 'acquisition', status: 'recovering');
  await _ActiveAcquisitionRuntime.markActive();
  // Recovery uses the same device-by-device coordinator and retry cadence as a
  // radio disconnect. Failure of one sensor never stops the other streams.
  manager._bleAutoReconnectCoordinator.start();
  if (manager._openRemoteConnectRequested) unawaited(manager.connectOpenRemote());
}

extension _PersistentMultiDeviceRuntime on _MultiDeviceSessionManager {
  Future<void> _stopAndroidResources() async {
    // This must succeed before teardown begins. A process killed during Stop
    // must see a terminal snapshot, even if a peripheral never acknowledges it.
    await AcquisitionRecoveryStore.markStopping();
    _ActiveAcquisitionRuntime.beginStopping();
    _isStopping = true;
    _bleAutoReconnectCoordinator.cancel();
    _invalidateOpenRemoteLocationAuthorization();
    _notifySessionChanged();
    Object? cleanupError;
    Future<void> finish(Future<void> Function() operation) async {
      try { await operation(); } catch (error) { cleanupError ??= error; }
    }
    await finish(_bleAutoReconnectCoordinator.waitForIdle);
    await finish(() async { await _streamStartup; });
    await finish(() async { await _openRemoteLocationSubscription?.cancel(); });
    _openRemoteLocationSubscription = null;
    for (final session in _sessions) {
      await finish(session.cancelConnectionSubscription);
      await finish(session.cancelLiveSubscriptions);
      if (session.isPolarManaged) {
        await finish(() => PolarH10PlatformService.forDevice(session.deviceId).stop());
      } else {
        await finish(() async { await session.environmentalService?.dispose(); });
        await finish(() async { await session.environmentalV2Service?.dispose(); });
        final wearable = session.wearableService;
        if (wearable != null) {
          await finish(wearable.stopAcquisition);
          await finish(wearable.dispose);
        }
        await finish(() => session.bleDevice.disconnect());
      }
      session.isConnected = false;
    }
    await finish(() async { await _mqttStateSubscription?.cancel(); });
    _mqttStateSubscription = null;
    await finish(mqttService.dispose);
    await finish(gpsLocationService.stop);
    await finish(csvLogger.stop);
    await finish(AcquisitionRecoveryStore.clear);
    await _ActiveAcquisitionRuntime.markInactive();
    await finish(AndroidAcquisitionForegroundService.clearBleDisconnectionAlert);
    await finish(AndroidAcquisitionForegroundService.stop);
    _foregroundServiceStarted = false;
    _acquisitionStarted = false;
    _isStopping = false;
    if (cleanupError != null) {
      backgroundStatusMessage = 'Acquisition stopped. Some resources could not be closed cleanly: $cleanupError';
    }
    _notifySessionChanged();
  }

  Future<void> _initializeRecoveredDevice(_ConnectedDeviceSession session) async {
    await session.cancelLiveSubscriptions();
    await session.environmentalService?.dispose();
    await session.environmentalV2Service?.dispose();
    await session.wearableService?.dispose();
    session
      ..environmentalService = null
      ..environmentalV2Service = null
      ..wearableService = null;
    if (_isStopping) return;
    switch (session.type) {
      case KnownDeviceType.environmentalMonitor:
        await _initializeEnvironmental(session);
        break;
      case KnownDeviceType.environmentalMonitorV2:
        await _initializeEnvironmentalV2(session);
        if (_isStopping) return;
        session.environmentalV2NotificationsRequested = true;
        await session.environmentalV2Service!.startNotificationsForAcquisition();
        session.environmentalV2NotificationsStarted = true;
        break;
      case KnownDeviceType.respiratoryMonitor:
        await _initializeWearable(session);
        break;
      case KnownDeviceType.polarH10:
        await _reconnectPolarH10(session);
        break;
      case KnownDeviceType.unsupported:
        throw StateError('Unsupported stored device.');
    }
    session
      ..needsProcessRecovery = false
      ..isInitialized = true;
  }

  void _recordRecoveredSample(_ConnectedDeviceSession session) {
    if (!Platform.isAndroid || !session.interruptionPending) return;
    session.interruptionPending = false;
    unawaited(AcquisitionRecoveryStore.closeInterruption(session.deviceId));
    if (!_sessions.any((session) => session.interruptionPending)) {
      unawaited(AcquisitionRecoveryStore.updateStatus(logicalRoute: 'acquisition', status: 'running'));
    }
  }
}

class AcquisitionRecoveryPage extends StatefulWidget {
  const AcquisitionRecoveryPage({super.key, required this.snapshot});
  final AcquisitionRecoverySnapshot snapshot;

  @override
  State<AcquisitionRecoveryPage> createState() => _AcquisitionRecoveryPageState();
}

class _AcquisitionRecoveryPageState extends State<AcquisitionRecoveryPage>
    with WidgetsBindingObserver {
  bool _recovering = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      WidgetsBinding.instance.addObserver(this);
      unawaited(_recover());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_recover());
  }

  Future<void> _recover() async {
    if (_recovering) return;
    setState(() => _recovering = true);
    try {
      final snapshot = await AcquisitionRecoveryStore.load();
      if (snapshot == null && _ActiveAcquisitionRuntime.activeOwner == null) {
        if (!mounted) return;
        await Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(builder: (_) => const AccessCodePage()),
        );
        return;
      }
      await _ActiveAcquisitionRuntime.restore(snapshot);
    } catch (error) {
      _ActiveAcquisitionRuntime.recoveryError = 'Could not read the saved acquisition: $error';
    }
    if (!mounted) return;
    final page = _ActiveAcquisitionRuntime.activePage;
    if (page != null) {
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => page),
      );
    } else {
      setState(() => _recovering = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) return _LegacyAcquisitionRecoveryPage(snapshot: widget.snapshot);
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(title: const Text('Acquisition recovery'), automaticallyImplyLeading: false),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_recovering) const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(_recovering ? 'Restoring acquisition...'
                    : (_ActiveAcquisitionRuntime.recoveryError ?? 'Acquisition recovery is unavailable.'),
                    textAlign: TextAlign.center),
                const SizedBox(height: 12),
                Text('Devices: ${widget.snapshot.deviceNames.join(', ')}\n'
                    'CSV: ${widget.snapshot.csvFileName ?? 'unavailable'}',
                    textAlign: TextAlign.center),
                if (!_recovering) ...[
                  const SizedBox(height: 16),
                  FilledButton(onPressed: _recover, child: const Text('Retry recovery')),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
