import '../environmental_v2_ble_service.dart';
import '../environmental_v2_configuration.dart';
import '../environmental_v2_message_parser.dart';
import 'mqtt_service.dart';

abstract final class EnvironmentalOpenRemote {
  // Keys are the original BLE names, never user-defined display names.
  static const assetIdByDeviceName = <String, String>{
    'LARES_ENV_V1_106': '7l9c0BynTv7UqckE045gaf',
    'LARES_ENV_V1_06': '39xOKe65bmS7yhutTrk100',
    'LARES_ENV_V2_03': '69sL57iS78gErbeFx9E6rw',
  };

  static bool isEligible({
    required int sessionDeviceCount,
    required String bleDeviceName,
    required bool isEnvironmentalV1,
    required bool isEnvironmentalV2,
  }) {
    return sessionDeviceCount == 1 &&
        (isEnvironmentalV2 ||
            (isEnvironmentalV1 &&
                assetIdByDeviceName.containsKey(bleDeviceName)));
  }

  static String missingAssetMessage(String bleDeviceName) =>
      'No OpenRemote asset has been configured for $bleDeviceName.';
}

/// Publishes parsed BLE messages using the acquisition's existing MQTT client.
/// One instance belongs to one V2 device session, including its GPS pair state.
class EnvironmentalV2OpenRemotePublisher {
  EnvironmentalV2OpenRemotePublisher(this.mqttService);

  static const gpsPairingWindow = Duration(seconds: 5);

  static const attributeByMessageType = <String, String>{
    EnvironmentalV2MessageTypes.pm1: 'pm1',
    EnvironmentalV2MessageTypes.pm25: 'pm2_5',
    EnvironmentalV2MessageTypes.pm10: 'pm10',
    EnvironmentalV2MessageTypes.vocIndex: 'vocIndex',
    EnvironmentalV2MessageTypes.noxIndex: 'noxIndex',
    EnvironmentalV2MessageTypes.temperature: 'internalTemperature',
    EnvironmentalV2MessageTypes.humidity: 'internalHumidity',
    EnvironmentalV2MessageTypes.co2: 'co2',
    EnvironmentalV2MessageTypes.accelerometerX: 'xAcceleration',
    EnvironmentalV2MessageTypes.accelerometerY: 'yAcceleration',
    EnvironmentalV2MessageTypes.accelerometerZ: 'zAcceleration',
    EnvironmentalV2MessageTypes.activity: 'activity',
  };

  final OpenRemoteMqttService mqttService;
  ({double value, DateTime receivedAt})? _latitude;
  ({double value, DateTime receivedAt})? _longitude;
  ({double latitude, double longitude})? _lastLocation;
  int _generation = 0;

  void reset() {
    _clearPendingCoordinates();
    _lastLocation = null;
    _generation++;
  }

  void _clearPendingCoordinates() {
    _latitude = null;
    _longitude = null;
  }

  Future<void> publish({
    required EnvironmentalV2NotificationMessage message,
    required EnvironmentalV2Configuration configuration,
  }) async {
    if (!mqttService.isConnected) {
      reset();
      return;
    }
    if (!configuration.isEnabled(EnvironmentalV2Option.gps)) {
      reset();
    }
    if (!configuration.isMessageTypeEnabled(message.type)) {
      return;
    }

    final value = message.numericValue;
    final isCoordinate =
        message.type == EnvironmentalV2MessageTypes.latitude ||
        message.type == EnvironmentalV2MessageTypes.longitude;
    if (value == null || !value.isFinite) {
      if (isCoordinate) _clearPendingCoordinates();
      return;
    }

    // Publication is independent of CSV and charts, including failed futures.
    try {
      final attribute = attributeByMessageType[message.type];
      if (attribute != null) {
        await mqttService.publishAttributeValue(
          attribute: attribute,
          value: value,
        );
      } else if (isCoordinate) {
        await _publishCoordinate(message.type, value, message.receivedAt);
      }
    } catch (_) {
      // An MQTT failure must never escape into the BLE acquisition stream.
    }
  }

  Future<void> _publishCoordinate(
    String type,
    double value,
    DateTime receivedAt,
  ) async {
    final isLatitude = type == EnvironmentalV2MessageTypes.latitude;
    final limit = isLatitude ? 90 : 180;
    if (value < -limit || value > limit) {
      _clearPendingCoordinates();
      return;
    }

    // Consume both components after every complete pair. Each subsequent point
    // needs two new notifications; a recent component cannot be reused.
    if (isLatitude) {
      _latitude = (value: value, receivedAt: receivedAt);
    } else {
      _longitude = (value: value, receivedAt: receivedAt);
    }
    final latitude = _latitude;
    final longitude = _longitude;
    if (latitude == null || longitude == null) return;
    final separation = latitude.receivedAt.difference(longitude.receivedAt);
    if (separation.abs() > gpsPairingWindow) {
      if (latitude.receivedAt.isBefore(longitude.receivedAt)) {
        _latitude = null;
      } else {
        _longitude = null;
      }
      return;
    }
    _clearPendingCoordinates();

    final location = (latitude: latitude.value, longitude: longitude.value);
    if (_lastLocation == location) return;
    // Reserve the point before awaiting MQTT so overlapping notifications also
    // suppress duplicates. A failed send permits retry with a fresh pair.
    _lastLocation = location;
    final generation = ++_generation;
    var sent = false;
    try {
      sent = await mqttService.publishJsonAttributeValue(
        attribute: 'location',
        value: <String, Object>{
          'type': 'Point',
          'coordinates': <double>[location.longitude, location.latitude],
        },
      );
    } finally {
      if (!sent && generation == _generation && _lastLocation == location) {
        _lastLocation = null;
      }
    }
  }
}
