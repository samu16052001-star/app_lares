import 'dart:typed_data';

import 'package:app_lares/wearable_agm_packet_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds an IMD notification like the firmware (main.c, imd_add).
List<int> buildImdPacket({
  required int counter,
  required int mask,
  required int fullScaleCode,
  required int firstTicks,
  required int stepTicks,
  required List<List<int>> samples,
}) {
  final sampleLength = 6 * WearableSensorMask.countSensors(mask);
  final data = ByteData(13 + sampleLength * samples.length);
  data.setUint8(0, 0x49);
  data.setUint8(1, 0x4D);
  data.setUint8(2, 0x44);
  data.setUint8(3, counter);
  data.setUint8(4, mask);
  data.setUint8(5, samples.length);
  data.setUint8(6, fullScaleCode);
  data.setUint32(7, firstTicks, Endian.little);
  data.setUint16(11, stepTicks, Endian.little);
  for (var i = 0; i < samples.length; i += 1) {
    for (var k = 0; k < samples[i].length; k += 1) {
      data.setInt16(13 + sampleLength * i + 2 * k, samples[i][k], Endian.little);
    }
  }
  return data.buffer.asUint8List();
}

void main() {
  test('IMD bytes produced by the firmware encoder (acc + gyr + mag)', () {
    // Output of imd_add()/imd_send() from main.c compiled in a host test:
    // 2 samples, mask 7, 8 g / 500 dps, t0 = 1141322 ticks, counter 7.
    const firmwareBytes = [
      0x49, 0x4D, 0x44, 0x07, 0x07, 0x02, 0x0A, 0x4A, 0x6A, 0x11, 0x00, //
      0x80, 0x01, //
      0xA8, 0xFE, 0x7F, 0x0F, 0xA0, 0x02, 0x34, 0x00, 0xD9, 0xFF, 0x21, 0x00,
      0xD2, 0x04, 0xC9, 0xFD, 0xB6, 0xF4, //
      0xAC, 0xFE, 0x87, 0x0F, 0x98, 0x02, 0x1C, 0x00, 0xF1, 0xFF, 0x1D, 0x00,
      0xD8, 0x04, 0xD0, 0xFD, 0xBB, 0xF4, //
    ];

    expect(WearableImdPacketParser.startsWithImdHeader(firmwareBytes), isTrue);
    final packet = WearableImdPacketParser.parsePacket(firmwareBytes);
    expect(packet.packetCounter, 7);
    expect(packet.sensorMask, WearableSensorMask.all);
    expect(packet.samples.length, 2);
    expect(packet.nextTicks, 1141322 + 2 * 384);

    final first = packet.samples[0];
    expect(first.timestampMs, 28533);
    expect(packet.samples[1].timestampMs, 28543);
    expect(first.hasAccelerometer, isTrue);
    expect(first.hasGyroscope, isTrue);
    expect(first.hasMagnetometer, isTrue);
    expect(first.accX, closeTo(-0.084, 0.0005));
    expect(first.accY, closeTo(0.968, 0.0005));
    expect(first.accZ, closeTo(0.164, 0.0005));
    expect(first.gyrX, closeTo(0.910, 0.001));
    expect(first.gyrY, closeTo(-0.6825, 0.001));
    expect(first.gyrZ, closeTo(0.5775, 0.001));
    expect(first.magX, closeTo(185.1, 0.001));
    expect(first.magY, closeTo(-85.05, 0.001));
    expect(first.magZ, closeTo(-433.5, 0.001));
  });

  test('IMD bytes produced by the firmware encoder (gyroscope only)', () {
    const firmwareBytes = [
      0x49, 0x4D, 0x44, 0x00, 0x02, 0x01, 0x12, 0xE8, 0x03, 0x00, 0x00, //
      0x80, 0x01, 0xE8, 0x03, 0x00, 0x00, 0x18, 0xFC, //
    ];

    final sample = WearableImdPacketParser.parse(firmwareBytes).single;
    expect(sample.sensorMask, WearableSensorMask.gyroscope);
    expect(sample.hasAccelerometer, isFalse);
    expect(sample.hasMagnetometer, isFalse);
    expect(sample.timestampMs, 25);
    expect(sample.gyrX, closeTo(70.0, 0.001));
    expect(sample.gyrY, 0);
    expect(sample.gyrZ, closeTo(-70.0, 0.001));
    expect(sample.accX, 0);
  });

  test('every sensor combination has the expected sample size', () {
    for (var mask = 1; mask <= 7; mask += 1) {
      final sensors = WearableSensorMask.countSensors(mask);
      final maxSamples = (244 - 13) ~/ (6 * sensors);
      final payload = buildImdPacket(
        counter: 1,
        mask: mask,
        fullScaleCode: 2 | (2 << 2),
        firstTicks: 0,
        stepTicks: 384,
        samples: List.generate(
          maxSamples,
          (i) => List.filled(3 * sensors, i),
        ),
      );

      expect(payload.length, lessThanOrEqualTo(244));
      final packet = WearableImdPacketParser.parsePacket(payload);
      expect(packet.samples.length, maxSamples);
      expect(packet.samples.every((sample) => sample.sensorMask == mask),
          isTrue);
    }
  });

  test('one sensor: 38 samples per notification', () {
    final payload = buildImdPacket(
      counter: 0,
      mask: WearableSensorMask.accelerometer,
      fullScaleCode: 0,
      firstTicks: 4294967000,
      stepTicks: 384,
      samples: List.generate(38, (i) => [i, 0, 16393]),
    );

    expect(payload.length, 241);
    final packet = WearableImdPacketParser.parsePacket(payload);
    expect(packet.samples.length, WearableImdPacketParser.maxSamplesPerPacket);
    expect(packet.samples.last.accZ, closeTo(1.0, 0.001));
    expect(packet.nextTicks, (4294967000 + 38 * 384) & 0xFFFFFFFF);
  });

  test('IMD packets with a wrong length, mask or header are rejected', () {
    final good = buildImdPacket(
      counter: 0,
      mask: WearableSensorMask.accelerometerGyroscope,
      fullScaleCode: 2 | (2 << 2),
      firstTicks: 0,
      stepTicks: 384,
      samples: const [
        [0, 0, 0, 0, 0, 0],
      ],
    );

    expect(WearableImdPacketParser.parsePacket(good).samples.length, 1);
    expect(
      () => WearableImdPacketParser.parsePacket(good.sublist(0, 24)),
      throwsFormatException,
    );
    expect(
      () => WearableImdPacketParser.parsePacket([...good, 0]),
      throwsFormatException,
    );
    final noSensor = List<int>.from(good)..[4] = 0;
    expect(
      () => WearableImdPacketParser.parsePacket(noSensor),
      throwsFormatException,
    );
    final unknownBit = List<int>.from(good)..[4] = 0x0B;
    expect(
      () => WearableImdPacketParser.parsePacket(unknownBit),
      throwsFormatException,
    );
    expect(WearableAg2PacketParser.startsWithAg2Header(good), isFalse);
    expect(WearableAgmPacketParser.startsWithAgmHeader(good), isFalse);
  });

  test('an IMD packet as long as an AGM batch is still an IMD packet', () {
    // 13 + 5 * 6 = 43 bytes, the length of one AGM sample.
    final payload = buildImdPacket(
      counter: 0,
      mask: WearableSensorMask.magnetometer,
      fullScaleCode: 0,
      firstTicks: 0,
      stepTicks: 384,
      samples: List.generate(5, (i) => [100, 200, 300]),
    );

    expect(payload.length, 43);
    expect(WearableAgmPacketParser.hasValidLength(payload), isTrue);
    expect(WearableImdPacketParser.startsWithImdHeader(payload), isTrue);
    expect(WearableImdPacketParser.parse(payload).first.magZ,
        closeTo(45.0, 0.001));
  });

  test('CSV text contains only the sensors of the sample', () {
    final packet = WearableImdPacketParser.parsePacket(
      buildImdPacket(
        counter: 0,
        mask: WearableSensorMask.accelerometer | WearableSensorMask.magnetometer,
        fullScaleCode: 2,
        firstTicks: 1141322,
        stepTicks: 384,
        samples: const [
          [-344, 3967, 672, 1234, -567, -2890],
        ],
      ),
    );

    expect(
      formatWearableSampleForCsv(packet.samples.single),
      't=28533 ms, acc=(-0.084, 0.968, 0.164) g, '
      'mag=(185.10, -85.05, -433.50) uT',
    );
  });

  test('CSV text of accelerometer + gyroscope is unchanged', () {
    const sample = WearableAgmSample(
      timestampMs: 10,
      accX: 0.1,
      accY: 0.2,
      accZ: 0.3,
      gyrX: 1,
      gyrY: 2,
      gyrZ: 3,
      magX: 0,
      magY: 0,
      magZ: 0,
    );

    expect(
      formatWearableSampleForCsv(sample),
      't=10 ms, acc=(0.100, 0.200, 0.300) g, gyr=(1.000, 2.000, 3.000) dps',
    );
  });

  test('sensor mask from the CONFIG values (0 = off)', () {
    expect(
      WearableSensorMask.fromConfiguration(mag: 0, accG: 8, gyrDPS: 500),
      WearableSensorMask.accelerometerGyroscope,
    );
    expect(
      WearableSensorMask.fromConfiguration(mag: 1, accG: 0, gyrDPS: 0),
      WearableSensorMask.magnetometer,
    );
    expect(
      WearableSensorMask.fromConfiguration(mag: 1, accG: 2, gyrDPS: 125),
      WearableSensorMask.all,
    );
  });
}
