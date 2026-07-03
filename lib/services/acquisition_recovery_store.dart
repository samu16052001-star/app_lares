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
}

class AcquisitionRecoveryStore {
  const AcquisitionRecoveryStore._();

  static const String _isActiveKey = 'acquisition_recovery.is_active';
  static const String _typeKey = 'acquisition_recovery.type';
  static const String _deviceNamesKey = 'acquisition_recovery.device_names';
  static const String _deviceTypesKey = 'acquisition_recovery.device_types';
  static const String _configurationSummariesKey =
      'acquisition_recovery.configuration_summaries';
  static const String _startedAtKey = 'acquisition_recovery.started_at';
  static const String _routeKey = 'acquisition_recovery.route';
  static const String _statusKey = 'acquisition_recovery.status';
  static const String _csvFileNameKey = 'acquisition_recovery.csv_file_name';
  static const String _csvFilePathKey = 'acquisition_recovery.csv_file_path';

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
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_isActiveKey, true);
    await preferences.setString(_typeKey, acquisitionType);
    await preferences.setStringList(_deviceNamesKey, deviceNames);
    await preferences.setStringList(_deviceTypesKey, deviceTypes);
    await preferences.setStringList(
      _configurationSummariesKey,
      configurationSummaries,
    );
    await preferences.setString(_startedAtKey, startedAt.toIso8601String());
    await preferences.setString(_routeKey, logicalRoute);
    await preferences.setString(_statusKey, status);
    if (csvFileName == null) {
      await preferences.remove(_csvFileNameKey);
    } else {
      await preferences.setString(_csvFileNameKey, csvFileName);
    }
    if (csvFilePath == null) {
      await preferences.remove(_csvFilePathKey);
    } else {
      await preferences.setString(_csvFilePathKey, csvFilePath);
    }
  }

  static Future<void> updateStatus({
    required String logicalRoute,
    required String status,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    if (!(preferences.getBool(_isActiveKey) ?? false)) {
      return;
    }

    await preferences.setString(_routeKey, logicalRoute);
    await preferences.setString(_statusKey, status);
  }

  static Future<AcquisitionRecoverySnapshot?> load() async {
    final preferences = await SharedPreferences.getInstance();
    final isActive = preferences.getBool(_isActiveKey) ?? false;
    if (!isActive) {
      return null;
    }

    return AcquisitionRecoverySnapshot(
      isActive: isActive,
      acquisitionType: preferences.getString(_typeKey) ?? 'unknown',
      deviceNames: preferences.getStringList(_deviceNamesKey) ?? const [],
      deviceTypes: preferences.getStringList(_deviceTypesKey) ?? const [],
      configurationSummaries:
          preferences.getStringList(_configurationSummariesKey) ?? const [],
      startedAtIso8601: preferences.getString(_startedAtKey),
      logicalRoute: preferences.getString(_routeKey) ?? 'unknown',
      status: preferences.getString(_statusKey) ?? 'interrupted',
      csvFileName: preferences.getString(_csvFileNameKey),
      csvFilePath: preferences.getString(_csvFilePathKey),
    );
  }

  static Future<void> clear() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_isActiveKey);
    await preferences.remove(_typeKey);
    await preferences.remove(_deviceNamesKey);
    await preferences.remove(_deviceTypesKey);
    await preferences.remove(_configurationSummariesKey);
    await preferences.remove(_startedAtKey);
    await preferences.remove(_routeKey);
    await preferences.remove(_statusKey);
    await preferences.remove(_csvFileNameKey);
    await preferences.remove(_csvFilePathKey);
  }
}
