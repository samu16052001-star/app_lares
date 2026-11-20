import 'package:app_lares/environmental_v2_ble_service.dart';
import 'package:app_lares/environmental_v2_configuration.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingCharacteristic extends Fake implements BluetoothCharacteristic {
  _RecordingCharacteristic(String uuid) : uuid = Guid(uuid);

  @override
  final Guid uuid;

  @override
  CharacteristicProperties get properties =>
      const CharacteristicProperties(write: true, notify: true);

  int failuresRemaining = 0;
  final writes = <({List<int> value, bool withoutResponse})>[];

  @override
  Future<void> write(
    List<int> value, {
    bool withoutResponse = false,
    bool allowLongWrite = false,
    int timeout = 15,
  }) async {
    writes.add((value: List<int>.of(value), withoutResponse: withoutResponse));
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw StateError('Simulated BLE write failure');
    }
  }
}

class _FakeBluetoothService extends Fake implements BluetoothService {
  _FakeBluetoothService(this.characteristics);

  @override
  final List<BluetoothCharacteristic> characteristics;
}

class _FakeBluetoothDevice extends Fake implements BluetoothDevice {
  _FakeBluetoothDevice(this._discoveredServices);

  final List<BluetoothService> _discoveredServices;

  @override
  Future<List<BluetoothService>> discoverServices({
    bool subscribeToServicesChanged = true,
    int timeout = 15,
  }) async => _discoveredServices;
}

void main() {
  late Map<EnvironmentalV2Option, _RecordingCharacteristic> characteristics;
  late EnvironmentalV2BleService service;

  final allEnabled = EnvironmentalV2Configuration(
    enabledOptions: {
      for (final option in EnvironmentalV2Option.values) option: true,
    },
  );

  setUp(() {
    characteristics = {
      for (final option in EnvironmentalV2Option.values)
        option: _RecordingCharacteristic(option.characteristicUuid),
    };
    service = EnvironmentalV2BleService(
      _FakeBluetoothDevice([
        _FakeBluetoothService(characteristics.values.toList()),
      ]),
    );
  });
  tearDown(() => service.dispose());

  test(
    'writes 0 for deselected PM2.5 and 1 for every selected option',
    () async {
      final configuration = allEnabled.copyWithOption(
        EnvironmentalV2Option.pm25,
        false,
      );
      await service.initialize(configuration);

      for (final entry in characteristics.entries) {
        final write = entry.value.writes.single;
        expect(
          write.value,
          entry.key == EnvironmentalV2Option.pm25 ? [0x00] : [0x01],
        );
        expect(write.withoutResponse, isFalse);
      }
      expect(service.isInitialized, isTrue);
      expect(service.configuration, same(configuration));
    },
  );

  test('all-off configuration explicitly writes 0 to every option', () async {
    await service.initialize(EnvironmentalV2Configuration.allOff());

    for (final characteristic in characteristics.values) {
      expect(characteristic.writes.single.value, [0x00]);
      expect(characteristic.writes.single.withoutResponse, isFalse);
    }
    expect(service.isInitialized, isTrue);
  });

  test('all-enabled configuration still writes 1 to every option', () async {
    await service.initialize(allEnabled);

    for (final characteristic in characteristics.values) {
      expect(characteristic.writes.single.value, [0x01]);
    }
  });

  test(
    'applying a changed configuration turns a previously enabled option off',
    () async {
      await service.initialize(allEnabled);
      await service.initialize(
        allEnabled.copyWithOption(EnvironmentalV2Option.pm25, false),
      );

      expect(
        characteristics[EnvironmentalV2Option.pm25]!.writes.map(
          (write) => write.value,
        ),
        [
          [0x01],
          [0x00],
        ],
      );
      expect(
        service.configuration!.isEnabled(EnvironmentalV2Option.pm25),
        isFalse,
      );
    },
  );

  test(
    'disabled-option writes retain their 0 payload across retries',
    () async {
      final pm25 = characteristics[EnvironmentalV2Option.pm25]!
        ..failuresRemaining = 2;
      await service.initialize(EnvironmentalV2Configuration.allOff());

      expect(pm25.writes, hasLength(3));
      for (final write in pm25.writes) {
        expect(write.value, [0x00]);
        expect(write.withoutResponse, isFalse);
      }
      expect(service.isInitialized, isTrue);
    },
  );

  test(
    'failed disabled-option writes report failure after the existing retry limit',
    () async {
      final pm25 = characteristics[EnvironmentalV2Option.pm25]!
        ..failuresRemaining = 6;
      await expectLater(
        service.initialize(EnvironmentalV2Configuration.allOff()),
        throwsA(
          isA<EnvironmentalV2BleException>().having(
            (error) => error.message,
            'message',
            contains(
              'BLE write failed for ${EnvironmentalV2Option.pm25.characteristicUuid} after 6 attempts',
            ),
          ),
        ),
      );
      expect(pm25.writes, hasLength(6));
      expect(service.isInitialized, isFalse);
    },
  );

  test(
    'validates disabled characteristics before sending configuration writes',
    () async {
      await service.dispose();
      service = EnvironmentalV2BleService(
        _FakeBluetoothDevice([
          _FakeBluetoothService([
            for (final entry in characteristics.entries)
              if (entry.key != EnvironmentalV2Option.pm25) entry.value,
          ]),
        ]),
      );

      await expectLater(
        service.initialize(EnvironmentalV2Configuration.allOff()),
        throwsA(
          isA<EnvironmentalV2BleException>()
              .having(
                (error) => error.message,
                'message',
                contains(EnvironmentalV2Option.pm25.characteristicUuid),
              )
              .having((error) => error.canRetry, 'canRetry', isFalse),
        ),
      );
      for (final characteristic in characteristics.values) {
        expect(characteristic.writes, isEmpty);
      }
      expect(service.isInitialized, isFalse);
    },
  );
}
