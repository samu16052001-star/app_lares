import 'package:shared_preferences/shared_preferences.dart';

class RespiratoryDeviceNameStore {
  const RespiratoryDeviceNameStore._();

  static const _keyPrefix = 'respiratory_device_name.';

  static Future<Map<String, String>> loadAll() async {
    final preferences = await SharedPreferences.getInstance();
    final names = <String, String>{};
    for (final key in preferences.getKeys()) {
      if (!key.startsWith(_keyPrefix)) {
        continue;
      }
      final name = preferences.getString(key)?.trim();
      if (name != null && name.isNotEmpty) {
        names[key.substring(_keyPrefix.length)] = name;
      }
    }
    return names;
  }

  static Future<String?> load(String deviceId) async {
    final preferences = await SharedPreferences.getInstance();
    final name = preferences.getString('$_keyPrefix$deviceId')?.trim();
    return name == null || name.isEmpty ? null : name;
  }

  static Future<void> save(String deviceId, String name) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Device name must not be empty.');
    }
    final preferences = await SharedPreferences.getInstance();
    final saved = await preferences.setString(
      '$_keyPrefix$deviceId',
      trimmedName,
    );
    if (!saved) {
      throw StateError('Could not save the respiratory monitor name.');
    }
  }
}
