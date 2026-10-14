import 'dart:typed_data';

import 'package:app_lares/wearable_agm_packet_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds an AG2 notification exactly as the firmware does (see main.c, ag2_add).
List<int> buildAg2Packet({
  required int counter,
  required int fullScaleCode,
  required int firstTicks,
  required int stepTicks,
  required List<List<int>> samples,
}) {
  final data = ByteData(12 + 12 * samples.length);
  data.setUint8(0, 0x41);
  data.setUint8(1, 0x47);
  data.setUint8(2, 0x32);
  data.setUint8(3, counter);
  data.setUint8(4, samples.length);
  data.setUint8(5, fullScaleCode);
  data.setUint32(6, firstTicks, Endian.little);
  data.setUint16(10, stepTicks, Endian.little);
  for (var i = 0; i < samples.length; i += 1) {
    for (var k = 0; k < 6; k += 1) {
      data.setInt16(12 + 12 * i + 2 * k, samples[i][k], Endian.little);
    }
  }
  return data.buffer.asUint8List();
}

void main() {
  test('AG2 at 8 g / 500 dps matches the SD values of the 13/10 bench test', () {
    // First SD rows: t = 28533.05 and 28542.65 ms (1141322 and 1141706 ticks),
    // acc = (-0.084, 0.968, 0.164) g, gyr = (0.910, -0.683, 0.578) dps.
    final packet = WearableAg2PacketParser.parsePacket(
      buildAg2Packet(
        counter: 7,
        fullScaleCode: 2 | (2 << 2),
        firstTicks: 1141322,
        stepTicks: 384,
        samples: const [
          [-344, 3967, 672, 52, -39, 33],
          [-340, 3975, 664, 28, -15, 29],
        ],
      ),
    );

    expect(packet.packetCounter, 7);
    expect(packet.samples.length, 2);
    expect(packet.samples[0].timestampMs, 28533);
    expect(packet.samples[1].timestampMs, 28543);
    expect(packet.samples[0].accX, closeTo(-0.084, 0.0005));
    expect(packet.samples[0].accY, closeTo(0.968, 0.0005));
    expect(packet.samples[0].accZ, closeTo(0.164, 0.0005));
    expect(packet.samples[0].gyrX, closeTo(0.910, 0.009));
    expect(packet.samples[0].gyrY, closeTo(-0.683, 0.009));
    expect(packet.samples[0].gyrZ, closeTo(0.578, 0.009));
    expect(packet.samples[0].magX, 0);
    expect(packet.nextTicks, 1141322 + 2 * 384);
  });

  test('AG2 full-scale codes 16 g / 2000 dps', () {
    final samples = WearableAg2PacketParser.parse(
      buildAg2Packet(
        counter: 0,
        fullScaleCode: 3 | (4 << 2),
        firstTicks: 0,
        stepTicks: 384,
        samples: const [
          [2049, 0, -2049, 1000, 0, -1000],
        ],
      ),
    );

    expect(samples.single.accX, closeTo(1.0, 0.001));
    expect(samples.single.accZ, closeTo(-1.0, 0.001));
    expect(samples.single.gyrX, closeTo(70.0, 0.001));
    expect(samples.single.gyrZ, closeTo(-70.0, 0.001));
  });

  test('a full AG2 packet (19 samples, 240 bytes) is accepted', () {
    final payload = buildAg2Packet(
      counter: 1,
      fullScaleCode: 2 | (2 << 2),
      firstTicks: 4294967000,
      stepTicks: 384,
      samples: List.generate(19, (i) => [i, 0, 4096, 0, 0, -i]),
    );

    expect(payload.length, 240);
    final packet = WearableAg2PacketParser.parsePacket(payload);
    expect(packet.samples.length, 19);
    expect(
      packet.samples[18].timestampMs - packet.samples[0].timestampMs,
      closeTo(18 * 9.6, 1),
    );
    expect(packet.nextTicks, (4294967000 + 19 * 384) & 0xFFFFFFFF);
  });

  test('AG2 packets with a wrong length or header are rejected', () {
    final good = buildAg2Packet(
      counter: 0,
      fullScaleCode: 2 | (2 << 2),
      firstTicks: 0,
      stepTicks: 384,
      samples: const [
        [0, 0, 0, 0, 0, 0],
      ],
    );

    expect(
      () => WearableAg2PacketParser.parsePacket(good.sublist(0, 23)),
      throwsFormatException,
    );
    expect(
      () => WearableAg2PacketParser.parsePacket([...good, 0]),
      throwsFormatException,
    );
    expect(WearableAgmPacketParser.startsWithAgmHeader(good), isFalse);
    expect(WearableAg2PacketParser.startsWithAg2Header(good), isTrue);
  });

  test('old AGM batches are still parsed', () {
    final data = ByteData(43);
    data.setUint8(0, 0x41);
    data.setUint8(1, 0x47);
    data.setUint8(2, 0x4D);
    data.setUint32(3, 28533, Endian.little);
    data.setFloat32(11, 0.968, Endian.little);
    final samples =
        WearableAgmPacketParser.parseBatch(data.buffer.asUint8List());

    expect(samples.single.timestampMs, 28533);
    expect(samples.single.accY, closeTo(0.968, 0.0001));
    expect(WearableAg2PacketParser.startsWithAg2Header(data.buffer.asUint8List()), isFalse);
  });
}
