import 'dart:async';
import 'dart:convert';

import 'package:app_lares/environmental_v2_ble_service.dart';
import 'package:app_lares/environmental_v2_configuration.dart';
import 'package:app_lares/environmental_v2_message_parser.dart';
import 'package:app_lares/main.dart';
import 'package:app_lares/services/environmental_open_remote.dart';
import 'package:app_lares/services/mqtt_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingMqttService extends OpenRemoteMqttService {
  bool connected = true;
  bool sendSucceeds = true;
  bool throwOnSend = false;
  Completer<bool>? pendingLocation;
  final measurements = <({String attribute, double value})>[];
  final locations = <({String attribute, Object value})>[];

  @override
  bool get isConnected => connected;

  @override
  Future<bool> publishAttributeValue({
    required String attribute,
    required double value,
  }) async {
    if (throwOnSend) throw StateError('MQTT unavailable');
    measurements.add((attribute: attribute, value: value));
    return sendSucceeds;
  }

  @override
  Future<bool> publishJsonAttributeValue({
    required String attribute,
    required Object value,
  }) async {
    if (throwOnSend) throw StateError('MQTT unavailable');
    locations.add((attribute: attribute, value: value));
    final pending = pendingLocation;
    if (pending != null) return pending.future;
    return sendSucceeds;
  }
}

const _measurementCases = <(String, String, double)>[
  ('PM1:1.23456789', 'pm1', 1.23456789),
  ('PM2.5:12.5', 'pm2_5', 12.5),
  ('PM10:15.75', 'pm10', 15.75),
  ('VOCi:123', 'vocIndex', 123),
  ('NOXi:42', 'noxIndex', 42),
  ('Temp:24.7', 'internalTemperature', 24.7),
  ('Hum:65.125', 'internalHumidity', 65.125),
  ('CO2:567', 'co2', 567),
  ('Accx=-0.034', 'xAcceleration', -0.034),
  ('Accy=-0.123456789', 'yAcceleration', -0.123456789),
  ('Accz=0.987654321', 'zAcceleration', 0.987654321),
  ('Act:2', 'activity', 2),
  ('Act=2', 'activity', 2),
];

void main() {
  final allEnabled = EnvironmentalV2Configuration(
    enabledOptions: {
      for (final option in EnvironmentalV2Option.values) option: true,
    },
  );
  final epoch = DateTime.utc(2026, 10, 28);
  late _RecordingMqttService mqtt;
  late EnvironmentalV2OpenRemotePublisher publisher;

  EnvironmentalV2NotificationMessage notification(
    String raw, [
    int seconds = 0,
  ]) {
    final parsed = parseEnvironmentalV2Message(raw);
    expect(parsed, isNotNull, reason: raw);
    return EnvironmentalV2NotificationMessage.fromParsed(
      receivedAt: epoch.add(Duration(seconds: seconds)),
      message: parsed!,
    );
  }

  Future<void> send(String raw, [int seconds = 0]) => publisher.publish(
    message: notification(raw, seconds),
    configuration: allEnabled,
  );

  Future<void> pair([int seconds = 0]) async {
    await send('Lat:45.464211', seconds);
    await send('Long:9.191383', seconds);
  }

  setUp(() {
    mqtt = _RecordingMqttService();
    publisher = EnvironmentalV2OpenRemotePublisher(mqtt);
  });
  tearDown(() => mqtt.dispose());

  group('session eligibility and asset associations', () {
    bool eligible(List<String> names) {
      final name = names.firstOrNull ?? '';
      final type = KnownDeviceClassifier.fromNames([name]);
      return EnvironmentalOpenRemote.isEligible(
        sessionDeviceCount: names.length,
        bleDeviceName: name,
        isEnvironmentalV1: type == KnownDeviceType.environmentalMonitor,
        isEnvironmentalV2: type == KnownDeviceType.environmentalMonitorV2,
      );
    }

    for (final name in [
      'LARES_ENV_V1_106',
      'LARES_ENV_V1_06',
      'LARES_ENV_V2_03',
      'LARES_ENV_V2_04',
      'LARES_ENV_V2_NEW',
    ]) {
      test('single $name is eligible', () {
        expect(eligible([name]), isTrue);
      });
    }
    for (final names in <List<String>>[
      [],
      ['LARES_ENV_V1_99'],
      ['LARES_ENV_V2_03', 'LARES_ENV_V2_04'],
      ['LARES_ENV_V1_06', 'LARES_ENV_V2_03'],
      ['LARES_ENV_V2_03', 'Polar H10'],
      ['LARES_RESP_V1_03'],
      ['Polar H10'],
      ['unknown'],
    ]) {
      test('$names is not eligible regardless of connected count', () {
        expect(eligible(names), isFalse);
      });
    }
    test('only explicit BLE name associations resolve', () {
      expect(EnvironmentalOpenRemote.assetIdByDeviceName, {
        'LARES_ENV_V1_106': '7l9c0BynTv7UqckE045gaf',
        'LARES_ENV_V1_06': '39xOKe65bmS7yhutTrk100',
        'LARES_ENV_V2_03': '69sL57iS78gErbeFx9E6rw',
      });
      expect(
        EnvironmentalOpenRemote.assetIdByDeviceName['LARES_ENV_V2_04'],
        isNull,
      );
      expect(
        EnvironmentalOpenRemote.assetIdByDeviceName['Holtair_V2_03'],
        isNull,
      );
      expect(
        EnvironmentalOpenRemote.missingAssetMessage('LARES_ENV_V2_04'),
        'No OpenRemote asset has been configured for LARES_ENV_V2_04.',
      );
    });
    test('device family must also be environmental', () {
      expect(
        EnvironmentalOpenRemote.isEligible(
          sessionDeviceCount: 1,
          bleDeviceName: 'LARES_ENV_V2_03',
          isEnvironmentalV1: false,
          isEnvironmentalV2: false,
        ),
        isFalse,
      );
    });
  });

  group('parsed measurements', () {
    for (final (raw, attribute, expected) in _measurementCases) {
      test(
        '$raw publishes numeric $attribute without conversion or rounding',
        () async {
          await send(raw);
          expect(mqtt.measurements, [(attribute: attribute, value: expected)]);
          expect(mqtt.locations, isEmpty);
        },
      );
      test('$raw is suppressed when its sensor is disabled', () async {
        final message = notification(raw);
        await publisher.publish(
          message: message,
          configuration: allEnabled.copyWithOption(message.option, false),
        );
        expect(mqtt.measurements, isEmpty);
        expect(mqtt.locations, isEmpty);
      });
      test('$raw is suppressed while MQTT is disconnected', () async {
        mqtt.connected = false;
        await send(raw);
        expect(mqtt.measurements, isEmpty);
      });
    }
    test(
      'both activity separators preserve integer validation and normalization',
      () {
        for (final prefix in ['Act:', 'Act=']) {
          final message = parseEnvironmentalV2Message('\u0000 $prefix+2\r\n');
          expect(message?.type, EnvironmentalV2MessageTypes.activity);
          expect(message?.numericValue, 2);
          expect(message?.option, EnvironmentalV2Option.accelerometer);
          for (final value in ['2.1', '2.0', 'NaN', 'Infinity', '2x', '']) {
            expect(parseEnvironmentalV2Message('$prefix$value'), isNull);
          }
        }
        expect(parseEnvironmentalV2Message('Accx:-0.034'), isNull);
        expect(parseEnvironmentalV2Message('Accy:-0.034'), isNull);
        expect(parseEnvironmentalV2Message('Accz:-0.034'), isNull);
      },
    );
    test(
      'parser rejects malformed, non-finite and unsupported notifications',
      () {
        for (final raw in [
          'PM1:NaN',
          'PM2.5:Infinity',
          'Temp:-Infinity',
          'Hum:1e999',
          'Accx=NaN',
          'VOCi:1.2',
          'NOXi:bad',
          'CO2:12.5',
          'PM10:',
          'bad',
          'Unknown:12',
          'PM1=1',
        ]) {
          expect(parseEnvironmentalV2Message(raw), isNull, reason: raw);
        }
      },
    );
    test('publisher also rejects invalid parsed values defensively', () async {
      for (final value in [
        null,
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        await publisher.publish(
          message: EnvironmentalV2NotificationMessage(
            receivedAt: epoch,
            type: EnvironmentalV2MessageTypes.temperature,
            value: '$value',
            numericValue: value,
            option: EnvironmentalV2Option.temperature,
          ),
          configuration: allEnabled,
        );
      }
      expect(mqtt.measurements, isEmpty);
    });
    test(
      'date, time and unsupported types never become numeric MQTT attributes',
      () async {
        await send('Date:2026-10-28');
        await send('Time:12:34:56');
        await publisher.publish(
          message: EnvironmentalV2NotificationMessage(
            receivedAt: epoch,
            type: 'Unknown',
            value: '12',
            numericValue: 12,
            option: EnvironmentalV2Option.temperature,
          ),
          configuration: allEnabled,
        );
        expect(mqtt.measurements, isEmpty);
        expect(mqtt.locations, isEmpty);
      },
    );
    test(
      'a thrown MQTT error cannot escape or stop subsequent measurements',
      () async {
        mqtt.throwOnSend = true;
        await send('Temp:24.7');
        mqtt.throwOnSend = false;
        await send('PM2.5:12.5');
        expect(mqtt.measurements.single.attribute, 'pm2_5');
      },
    );
  });

  group('BLE GPS pairing', () {
    for (final longitudeFirst in [false, true]) {
      test(
        'publishes correct GeoJSON with longitudeFirst=$longitudeFirst',
        () async {
          await send(longitudeFirst ? 'Long:9.191383' : 'Lat:45.464211');
          expect(mqtt.locations, isEmpty);
          await send(longitudeFirst ? 'Lat:45.464211' : 'Long:9.191383', 1);
          expect(mqtt.locations.single.attribute, 'location');
          expect(
            jsonEncode(mqtt.locations.single.value),
            '{"type":"Point","coordinates":[9.191383,45.464211]}',
          );
          expect(mqtt.measurements, isEmpty);
        },
      );
    }
    test(
      'consumes both components and suppresses unchanged complete pairs',
      () async {
        await pair();
        await send('Lat:46.000001', 1);
        expect(mqtt.locations, hasLength(1));
        await send('Long:10.000001', 1);
        expect(mqtt.locations, hasLength(2));
        await send('Lat:46.000001', 2);
        await send('Long:10.000001', 2);
        expect(mqtt.locations, hasLength(2));
        await pair(3);
        expect(mqtt.locations, hasLength(3));
      },
    );
    for (final latitudeFirst in [true, false]) {
      test(
        'rejects stale component with latitudeFirst=$latitudeFirst',
        () async {
          await send(latitudeFirst ? 'Lat:45.464211' : 'Long:9.191383');
          await send(latitudeFirst ? 'Long:9.191383' : 'Lat:45.464211', 6);
          expect(mqtt.locations, isEmpty);
          // The newer component remains eligible within its own pairing window.
          await send(latitudeFirst ? 'Lat:45.464212' : 'Long:9.191384', 7);
          expect(mqtt.locations, hasLength(1));
        },
      );
    }
    test('accepts the pairing-window boundary', () async {
      await send('Lat:45.464211');
      await send('Long:9.191383', 5);
      expect(mqtt.locations, hasLength(1));
    });
    test('uses the most recent component when notifications repeat', () async {
      await send('Lat:45.464211');
      await send('Lat:46.000001', 4);
      await send('Long:9.191383', 6);
      expect(mqtt.locations.single.value, {
        'type': 'Point',
        'coordinates': [9.191383, 46.000001],
      });
    });
    test(
      'invalid coordinates do not cause an unchanged point to be resent',
      () async {
        await pair();
        await send('Lat:91', 1);
        await pair(2);
        expect(mqtt.locations, hasLength(1));
        await publisher.publish(
          message: EnvironmentalV2NotificationMessage(
            receivedAt: epoch.add(const Duration(seconds: 3)),
            type: EnvironmentalV2MessageTypes.latitude,
            value: 'NaN',
            numericValue: double.nan,
            option: EnvironmentalV2Option.gps,
          ),
          configuration: allEnabled,
        );
        await pair(4);
        expect(mqtt.locations, hasLength(1));
      },
    );
    for (final raw in [
      'Lat:90.000001',
      'Lat:-90.000001',
      'Long:180.000001',
      'Long:-180.000001',
    ]) {
      test('rejects $raw and invalidates an incomplete pair', () async {
        await send(raw.startsWith('Lat') ? 'Long:9.191383' : 'Lat:45.464211');
        await send(raw);
        await send(
          raw.startsWith('Lat') ? 'Lat:45.464211' : 'Long:9.191383',
          1,
        );
        expect(mqtt.locations, isEmpty);
      });
    }
    test('accepts valid coordinate extremes', () async {
      await send('Lat:-90');
      await send('Long:180');
      expect(mqtt.locations.single.value, {
        'type': 'Point',
        'coordinates': [180.0, -90.0],
      });
    });
    for (final value in [
      null,
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      test('rejects non-finite or missing coordinate $value', () async {
        await send('Lat:45.464211');
        await publisher.publish(
          message: EnvironmentalV2NotificationMessage(
            receivedAt: epoch,
            type: EnvironmentalV2MessageTypes.longitude,
            value: '$value',
            numericValue: value,
            option: EnvironmentalV2Option.gps,
          ),
          configuration: allEnabled,
        );
        await send('Long:9.191383');
        expect(mqtt.locations, isEmpty);
      });
    }
    test(
      'GPS disabled cannot publish or retain a component across re-enabling',
      () async {
        await send('Lat:45.464211');
        final gpsOff = allEnabled.copyWithOption(
          EnvironmentalV2Option.gps,
          false,
        );
        await publisher.publish(
          message: notification('Long:9.191383'),
          configuration: gpsOff,
        );
        expect(mqtt.locations, isEmpty);
        await send('Long:9.191383', 1);
        expect(mqtt.locations, isEmpty);
        await send('Lat:45.464211', 1);
        expect(mqtt.locations, hasLength(1));
      },
    );
    test(
      'no publication before MQTT connection and no reuse of offline GPS',
      () async {
        mqtt.connected = false;
        await pair();
        expect(mqtt.locations, isEmpty);
        mqtt.connected = true;
        await send('Long:9.191383', 1);
        expect(mqtt.locations, isEmpty);
        await send('Lat:45.464211', 1);
        expect(mqtt.locations, hasLength(1));
      },
    );
    test('MQTT outage invalidates a previously received component', () async {
      await send('Lat:45.464211');
      mqtt.connected = false;
      await send('Long:9.191383');
      mqtt.connected = true;
      await send('Long:9.191383', 1);
      expect(mqtt.locations, isEmpty);
      await send('Lat:45.464211', 1);
      expect(mqtt.locations, hasLength(1));
    });
    test('lifecycle reset clears incomplete pairs', () async {
      await send('Lat:45.464211');
      publisher.reset();
      await send('Long:9.191383', 1);
      expect(mqtt.locations, isEmpty);
      await send('Lat:45.464211', 1);
      expect(mqtt.locations, hasLength(1));
    });
    test('a recovered session starts without any coordinates', () async {
      await send('Lat:45.464211');
      publisher = EnvironmentalV2OpenRemotePublisher(mqtt);
      await send('Long:9.191383');
      expect(mqtt.locations, isEmpty);
      await send('Lat:45.464211');
      expect(mqtt.locations, hasLength(1));
    });
    test('GPS state belongs to each device publisher', () async {
      await send('Lat:45.464211');
      final otherPublisher = EnvironmentalV2OpenRemotePublisher(mqtt);
      await otherPublisher.publish(
        message: notification('Long:9.191383'),
        configuration: allEnabled,
      );
      expect(mqtt.locations, isEmpty);
    });
    for (final throws in [false, true]) {
      test(
        'failed GPS send allows retry using a fresh pair (throws=$throws)',
        () async {
          mqtt.sendSucceeds = false;
          mqtt.throwOnSend = throws;
          await pair();
          mqtt.sendSucceeds = true;
          mqtt.throwOnSend = false;
          mqtt.locations.clear();
          await send('Lat:45.464211', 1);
          expect(mqtt.locations, isEmpty);
          await send('Long:9.191383', 1);
          expect(mqtt.locations, hasLength(1));
        },
      );
    }
    test(
      'overlapping complete pairs do not duplicate an in-flight point',
      () async {
        mqtt.pendingLocation = Completer<bool>();
        final first = pair();
        await Future<void>.delayed(Duration.zero);
        await pair(1);
        expect(mqtt.locations, hasLength(1));
        mqtt.pendingLocation!.complete(true);
        await first;
      },
    );
  });
}
