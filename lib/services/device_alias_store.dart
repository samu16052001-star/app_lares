import 'package:shared_preferences/shared_preferences.dart';

/// User-defined display names for BLE devices, keyed by device ID.
///
/// The device ID is the BLE address on Android and the CoreBluetooth UUID on
/// iOS, so aliases are local to this phone. The advertised name is left
/// untouched: it is still used for device type detection.
class DeviceAliasStore {
  const DeviceAliasStore._();

  static const String _keyPrefix = 'device_alias.';
  static const int maxLength = 40;

  static final Map<String, String> _aliases = {};
  static Future<void>? _loading;

  static Future<void> load() {
    return _loading ??= _loadFromPreferences();
  }

  static Future<void> _loadFromPreferences() async {
    final preferences = await SharedPreferences.getInstance();
    for (final key in preferences.getKeys()) {
      if (!key.startsWith(_keyPrefix)) {
        continue;
      }
      final alias = preferences.getString(key);
      if (alias != null && alias.isNotEmpty) {
        _aliases[key.substring(_keyPrefix.length)] = alias;
      }
    }
  }

  static String? aliasFor(String deviceId) => _aliases[deviceId];

  /// Trims the input and removes characters that would break a CSV row.
  static String normalize(String value) {
    return value
        .replaceAll(RegExp(r'[;"\r\n\t]'), ' ')
        .replaceAll(RegExp(r' {2,}'), ' ')
        .trim();
  }

  /// Returns the device ID that already uses [alias], ignoring case.
  static String? deviceIdUsingAlias(String alias, {String? exceptDeviceId}) {
    final expected = alias.toLowerCase();
    for (final entry in _aliases.entries) {
      if (entry.key != exceptDeviceId &&
          entry.value.toLowerCase() == expected) {
        return entry.key;
      }
    }
    return null;
  }

  /// Saves [alias] for [deviceId]; a null or empty alias removes it.
  static Future<void> setAlias(String deviceId, String? alias) async {
    await load();
    final preferences = await SharedPreferences.getInstance();
    final normalized = alias == null ? '' : normalize(alias);
    if (normalized.isEmpty) {
      _aliases.remove(deviceId);
      await preferences.remove('$_keyPrefix$deviceId');
      return;
    }

    _aliases[deviceId] = normalized;
    await preferences.setString('$_keyPrefix$deviceId', normalized);
  }
}
