import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

class AcquisitionRecoverySnapshot {
  const AcquisitionRecoverySnapshot({
    required this.isActive,
    required this.acquisitionType,
    required this.deviceNames,
    required this.deviceTypes,
    required this.configurationSummaries,
    required this.startedAtIso8601,
    required this.logicalRoute,
    required this.status,
    this.csvFileName,
    this.csvFilePath,
    this.sessionId = '',
    this.workflow = '',
    this.devices = const [],
    this.runtimeState = const {},
    this.lastHeartbeatIso8601,
    this.interruptions = const [],
  });

  final bool isActive;
  final String acquisitionType;
  final List<String> deviceNames;
  final List<String> deviceTypes;
  final List<String> configurationSummaries;
  final String? startedAtIso8601;
  final String logicalRoute;
  final String status;
  final String? csvFileName;
  final String? csvFilePath;
  final String sessionId;
  final String workflow;
  final List<Map<String, dynamic>> devices;
  final Map<String, dynamic> runtimeState;
  final String? lastHeartbeatIso8601;
  final List<Map<String, dynamic>> interruptions;

  Map<String, dynamic> _toJson() => {
    'version': 2, 'isActive': isActive, 'acquisitionType': acquisitionType,
    'deviceNames': deviceNames, 'deviceTypes': deviceTypes,
    'configurationSummaries': configurationSummaries,
    'startedAt': startedAtIso8601, 'logicalRoute': logicalRoute,
    'status': status, 'csvFileName': csvFileName, 'csvFilePath': csvFilePath,
    'sessionId': sessionId, 'workflow': workflow, 'devices': devices,
    'runtimeState': runtimeState, 'lastHeartbeat': lastHeartbeatIso8601,
    'interruptions': interruptions,
  };

  factory AcquisitionRecoverySnapshot._fromJson(Map<String, dynamic> json) {
    List<String> strings(String key) =>
        (json[key] as List? ?? const []).whereType<String>().toList();
    List<Map<String, dynamic>> maps(String key) =>
        (json[key] as List? ?? const []).whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item)).toList();
    return AcquisitionRecoverySnapshot(
      isActive: json['isActive'] == true,
      acquisitionType: json['acquisitionType'] as String? ?? 'unknown',
      deviceNames: strings('deviceNames'), deviceTypes: strings('deviceTypes'),
      configurationSummaries: strings('configurationSummaries'),
      startedAtIso8601: json['startedAt'] as String?,
      logicalRoute: json['logicalRoute'] as String? ?? 'unknown',
      status: json['status'] as String? ?? 'interrupted',
      csvFileName: json['csvFileName'] as String?,
      csvFilePath: json['csvFilePath'] as String?,
      sessionId: json['sessionId'] as String? ?? '',
      workflow: json['workflow'] as String? ?? '', devices: maps('devices'),
      runtimeState: Map<String, dynamic>.from(json['runtimeState'] as Map? ?? const {}),
      lastHeartbeatIso8601: json['lastHeartbeat'] as String?,
      interruptions: maps('interruptions'),
    );
  }
}

class AcquisitionRecoveryStore {
  const AcquisitionRecoveryStore._();

  static const String _envelopeKey = 'acquisition_recovery.session_v2';
  static const String _isActiveKey = 'acquisition_recovery.is_active';
  static const String _typeKey = 'acquisition_recovery.type';
  static const String _deviceNamesKey = 'acquisition_recovery.device_names';
  static const String _deviceTypesKey = 'acquisition_recovery.device_types';
  static const String _configurationSummariesKey = 'acquisition_recovery.configuration_summaries';
  static const String _startedAtKey = 'acquisition_recovery.started_at';
  static const String _routeKey = 'acquisition_recovery.route';
  static const String _statusKey = 'acquisition_recovery.status';
  static const String _csvFileNameKey = 'acquisition_recovery.csv_file_name';
  static const String _csvFilePathKey = 'acquisition_recovery.csv_file_path';
  static Future<void> _pending = Future<void>.value();

  // All mutations and reads share the engine's queue. A late status update or
  // heartbeat can never resurrect a session that the user deliberately stopped.
  static Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  static Future<void> saveActive({
    required String acquisitionType,
    required List<String> deviceNames,
    required List<String> deviceTypes,
    required List<String> configurationSummaries,
    required DateTime startedAt,
    required String logicalRoute,
    required String status,
    String? csvFileName,
    String? csvFilePath,
    String? sessionId,
    String? workflow,
    List<Map<String, dynamic>>? devices,
    Map<String, dynamic>? runtimeState,
  }) {
    final snapshot = AcquisitionRecoverySnapshot(
      isActive: true, acquisitionType: acquisitionType,
      deviceNames: List.of(deviceNames), deviceTypes: List.of(deviceTypes),
      configurationSummaries: List.of(configurationSummaries),
      startedAtIso8601: startedAt.toIso8601String(), logicalRoute: logicalRoute,
      status: status, csvFileName: csvFileName, csvFilePath: csvFilePath,
      sessionId: sessionId ?? 'lares_${startedAt.toUtc().microsecondsSinceEpoch}',
      workflow: workflow ?? acquisitionType, devices: devices ?? const [],
      runtimeState: runtimeState ?? const {},
      lastHeartbeatIso8601: DateTime.now().toUtc().toIso8601String(),
    );
    final incoming = Map<String, dynamic>.from(jsonDecode(jsonEncode(snapshot._toJson())) as Map);
    return _serialized(() async {
      final preferences = await SharedPreferences.getInstance();
      if (!Platform.isAndroid) {
        await _saveLegacy(preferences, snapshot);
        return;
      }
      final previous = await _readAndroid(preferences);
      final sameSession = previous?['sessionId'] == incoming['sessionId'];
      if (sameSession && !_isRecoverable(previous!)) return;
      if (previous != null && _isRecoverable(previous) && !sameSession) {
        throw StateError('An acquisition session is already active.');
      }
      if (sameSession && previous != null) {
        incoming['interruptions'] = previous['interruptions'] ?? [];
        incoming['revision'] = previous['revision'] ?? 0;
        if (devices == null) incoming['devices'] = previous['devices'] ?? [];
        incoming['runtimeState'] = {
          ...Map<String, dynamic>.from(previous['runtimeState'] as Map? ?? {}),
          ...Map<String, dynamic>.from(incoming['runtimeState'] as Map),
        };
        incoming['csvFilePath'] ??= previous['csvFilePath'];
        incoming['csvFileName'] ??= previous['csvFileName'];
      }
      await _writeAndroid(preferences, incoming);
    });
  }

  static Future<void> updateStatus({required String logicalRoute, required String status}) =>
      _serialized(() async {
    final preferences = await SharedPreferences.getInstance();
    if (!Platform.isAndroid) {
      if (!(preferences.getBool(_isActiveKey) ?? false)) return;
      await preferences.setString(_routeKey, logicalRoute);
      await preferences.setString(_statusKey, status);
      return;
    }
    final value = await _readAndroid(preferences);
    if (value == null || !_isRecoverable(value)) return;
    value['logicalRoute'] = logicalRoute;
    value['status'] = status;
    await _writeAndroid(preferences, value);
  });

  static Future<void> heartbeat() => _mutateActive((value) async {
    value['lastHeartbeat'] = DateTime.now().toUtc().toIso8601String();
  });

  static Future<void> mergeRuntimeState(Map<String, dynamic> updates) {
    final copied = Map<String, dynamic>.from(jsonDecode(jsonEncode(updates)) as Map);
    return _mutateActive((value) async {
      value['runtimeState'] = {
        ...Map<String, dynamic>.from(value['runtimeState'] as Map? ?? {}), ...copied,
      };
    });
  }

  // Await this BEFORE hardware teardown: a death during stopping must not restart.
  static Future<void> markStopping() => _mutateActive((value) async {
    value['isActive'] = false;
    value['status'] = 'stopping';
    value['stoppedAt'] = DateTime.now().toUtc().toIso8601String();
  });

  static Future<void> recordInterruption({
    required String deviceId, required DateTime startedAt,
    DateTime? endedAt, required String reason,
  }) => _mutateActive((value) async {
    final entries = (value['interruptions'] as List? ?? [])
        .map((entry) => Map<String, dynamic>.from(entry as Map)).toList();
    if (entries.any((entry) => entry['deviceId'] == deviceId && entry['endedAt'] == null)) return;
    final entry = <String, dynamic>{
      'id': '${value['sessionId']}:$deviceId:${startedAt.microsecondsSinceEpoch}',
      'deviceId': deviceId, 'startedAt': startedAt.toUtc().toIso8601String(),
      'endedAt': endedAt?.toUtc().toIso8601String(), 'reason': reason,
    };
    entries.add(entry);
    value['interruptions'] = entries;
    await _appendEvent(value, {'type': 'interruption', ...entry});
  });

  static Future<void> closeInterruption(String deviceId) => _mutateActive((value) async {
    final entries = (value['interruptions'] as List? ?? [])
        .map((entry) => Map<String, dynamic>.from(entry as Map)).toList();
    for (final entry in entries) {
      if (entry['deviceId'] != deviceId || entry['endedAt'] != null) continue;
      entry['endedAt'] = DateTime.now().toUtc().toIso8601String();
      await _appendEvent(value, {'type': 'interruption_ended', ...entry});
    }
    value['interruptions'] = entries;
  });

  static Future<void> _mutateActive(Future<void> Function(Map<String, dynamic>) mutate) =>
      _serialized(() async {
    if (!Platform.isAndroid) return;
    final preferences = await SharedPreferences.getInstance();
    final value = await _readAndroid(preferences);
    if (value == null || !_isRecoverable(value)) return;
    await mutate(value);
    await _writeAndroid(preferences, value);
  });

  static Future<AcquisitionRecoverySnapshot?> load() => _serialized(() async {
    final preferences = await SharedPreferences.getInstance();
    if (!Platform.isAndroid) return _loadLegacy(preferences);
    final value = await _readAndroid(preferences);
    if (value == null || !_isRecoverable(value)) return null;
    return AcquisitionRecoverySnapshot._fromJson(value);
  });

  static Future<void> clear() => _serialized(() async {
    final preferences = await SharedPreferences.getInstance();
    if (Platform.isAndroid) {
      final value = await _readAndroid(preferences) ?? <String, dynamic>{};
      value['isActive'] = false;
      value['status'] = 'completed';
      value['stoppedAt'] ??= DateTime.now().toUtc().toIso8601String();
      // Retain a terminal tombstone and sidecars; never fall back to stale keys.
      await _writeAndroid(preferences, value);
    }
    for (final key in [
      _isActiveKey, _typeKey, _deviceNamesKey, _deviceTypesKey,
      _configurationSummariesKey, _startedAtKey, _routeKey, _statusKey,
      _csvFileNameKey, _csvFilePathKey,
    ]) {
      await preferences.remove(key);
    }
  });

  static bool _isRecoverable(Map<String, dynamic> value) =>
      value['isActive'] == true && value['status'] != 'stopping' && value['status'] != 'completed';

  static Future<Map<String, dynamic>?> _readAndroid(SharedPreferences preferences) async {
    final encoded = preferences.getString(_envelopeKey);
    if (encoded == null) return _loadLegacy(preferences)?._toJson();
    final value = Map<String, dynamic>.from(jsonDecode(encoded) as Map);
    final csvPath = value['csvFilePath'] as String?;
    if (csvPath == null) return value;
    try {
      final mirror = File('$csvPath.session.json');
      if (!await mirror.exists()) return value;
      final mirrored = Map<String, dynamic>.from(jsonDecode(await mirror.readAsString()) as Map);
      if (mirrored['sessionId'] == value['sessionId'] &&
          (mirrored['revision'] as int? ?? 0) >= (value['revision'] as int? ?? 0)) {
        return mirrored;
      }
    } on FileSystemException {
      // The preference envelope remains usable when storage is unavailable.
    } on FormatException {
      // Ignore a damaged mirror when the envelope is intact.
    }
    return value;
  }

  static Future<void> _writeAndroid(SharedPreferences preferences, Map<String, dynamic> value) async {
    value['version'] = 2;
    value['revision'] = (value['revision'] as int? ?? 0) + 1;
    final encoded = jsonEncode(value);
    final csvPath = value['csvFilePath'] as String?;
    var mirrorWritten = false;
    if (csvPath != null) {
      // Same-directory rename is atomic on Android. Flush before replacing the
      // snapshot, especially the intentional-stop tombstone.
      try {
        final temporary = File('$csvPath.session.json.tmp');
        await temporary.writeAsString(encoded, flush: true);
        await temporary.rename('$csvPath.session.json');
        mirrorWritten = true;
      } on FileSystemException {
        // In particular, an unavailable CSV directory must not prevent saving
        // the intentional-stop tombstone in the independent preferences file.
      }
    }
    final previousEncoded = preferences.getString(_envelopeKey);
    try {
      if (await preferences.setString(_envelopeKey, encoded)) return;
    } catch (_) {
      // A flushed mirror remains authoritative when the already stored envelope
      // still points to this same session. New sessions require their pointer.
    }
    if (mirrorWritten && previousEncoded != null) {
      try {
        final previous = jsonDecode(previousEncoded) as Map;
        if (previous['sessionId'] == value['sessionId'] &&
            previous['csvFilePath'] == csvPath) {
          return;
        }
      } on FormatException {
        // A damaged pointer cannot locate the durable mirror reliably.
      }
    }
    throw FileSystemException('Could not persist acquisition session.');
  }

  static Future<void> _appendEvent(Map<String, dynamic> value, Map<String, dynamic> event) async {
    final csvPath = value['csvFilePath'] as String?;
    if (csvPath == null) return;
    try {
      await File('$csvPath.events.jsonl').writeAsString(
        '${jsonEncode({'sessionId': value['sessionId'], ...event})}\n',
        mode: FileMode.append, flush: true,
      );
    } on FileSystemException catch (error) {
      // The envelope still retains interruptions if the optional journal fails.
      value['interruptionLogError'] = error.toString();
    }
  }

  static AcquisitionRecoverySnapshot? _loadLegacy(SharedPreferences preferences) {
    if (!(preferences.getBool(_isActiveKey) ?? false)) return null;
    final startedAt = preferences.getString(_startedAtKey);
    return AcquisitionRecoverySnapshot(
      isActive: true,
      acquisitionType: preferences.getString(_typeKey) ?? 'unknown',
      deviceNames: preferences.getStringList(_deviceNamesKey) ?? const [],
      deviceTypes: preferences.getStringList(_deviceTypesKey) ?? const [],
      configurationSummaries: preferences.getStringList(_configurationSummariesKey) ?? const [],
      startedAtIso8601: startedAt,
      logicalRoute: preferences.getString(_routeKey) ?? 'unknown',
      status: preferences.getString(_statusKey) ?? 'interrupted',
      csvFileName: preferences.getString(_csvFileNameKey),
      csvFilePath: preferences.getString(_csvFilePathKey),
      sessionId: startedAt == null ? '' : 'lares_${DateTime.parse(startedAt).toUtc().microsecondsSinceEpoch}',
    );
  }

  static Future<void> _saveLegacy(SharedPreferences preferences, AcquisitionRecoverySnapshot value) async {
    await preferences.setBool(_isActiveKey, true);
    await preferences.setString(_typeKey, value.acquisitionType);
    await preferences.setStringList(_deviceNamesKey, value.deviceNames);
    await preferences.setStringList(_deviceTypesKey, value.deviceTypes);
    await preferences.setStringList(_configurationSummariesKey, value.configurationSummaries);
    await preferences.setString(_startedAtKey, value.startedAtIso8601!);
    await preferences.setString(_routeKey, value.logicalRoute);
    await preferences.setString(_statusKey, value.status);
    if (value.csvFileName == null) {
      await preferences.remove(_csvFileNameKey);
    } else {
      await preferences.setString(_csvFileNameKey, value.csvFileName!);
    }
    if (value.csvFilePath == null) {
      await preferences.remove(_csvFilePathKey);
    } else {
      await preferences.setString(_csvFilePathKey, value.csvFilePath!);
    }
  }
}
