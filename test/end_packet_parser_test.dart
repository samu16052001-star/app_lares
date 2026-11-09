import 'package:app_lares/wearable_agm_packet_parser.dart';
import 'package:app_lares/wearable_end_packet_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WearableEndPacketParser', () {
    // Bytes produced by the firmware function ble_emit_end() in a host test:
    // 5905 samples, last sample at 3315700 ticks, SD file IMU1_004.TXT.
    const endBytes = [
      0x45, 0x4E, 0x44, //
      0x11, 0x17, 0x00, 0x00, //
      0xF4, 0x97, 0x32, 0x00, //
      0x04, 0x00, //
    ];

    test('parses total samples, last sample time and SD file number', () {
      expect(WearableEndPacketParser.startsWithEndHeader(endBytes), isTrue);
      final packet = WearableEndPacketParser.parse(endBytes);
      expect(packet.totalSamples, 5905);
      expect(packet.lastSampleTicks, 3315700);
      expect(packet.lastSampleTimestampMs, 82893);
      expect(packet.sdFileNumber, 4);
    });

    test('rejects a wrong length or header', () {
      expect(
        () => WearableEndPacketParser.parse(endBytes.sublist(0, 12)),
        throwsFormatException,
      );
      final wrongHeader = List<int>.from(endBytes)..[0] = 0x41;
      expect(WearableEndPacketParser.startsWithEndHeader(wrongHeader), isFalse);
      expect(
        () => WearableEndPacketParser.parse(wrongHeader),
        throwsFormatException,
      );
    });

    test('is not mistaken for an AGM or AG2 packet', () {
      expect(WearableAgmPacketParser.hasValidLength(endBytes), isFalse);
      expect(WearableAg2PacketParser.startsWithAg2Header(endBytes), isFalse);
    });

    test('13-byte END has no counters', () {
      final packet = WearableEndPacketParser.parse(endBytes);
      expect(packet.bleNotifyFailures, isNull);
      expect(packet.bleQueueDrops, isNull);
      expect(packet.sdQueueDrops, isNull);
    });

    test('19-byte has the loss counters', () {
      // ble_emit_end(): 5905 samples, recording 2, 3 failed notifications,
      // 0 BLE queue drops, 1 SD queue drop.
      const extendedBytes = [
        0x45, 0x4E, 0x44, //
        0x11, 0x17, 0x00, 0x00, //
        0xF4, 0x97, 0x32, 0x00, //
        0x02, 0x00, //
        0x03, 0x00, //
        0x00, 0x00, //
        0x01, 0x00, //
      ];

      final packet = WearableEndPacketParser.parse(extendedBytes);
      expect(packet.totalSamples, 5905);
      expect(packet.sdFileNumber, 2);
      expect(packet.bleNotifyFailures, 3);
      expect(packet.bleQueueDrops, 0);
      expect(packet.sdQueueDrops, 1);
      expect(WearableAgmPacketParser.hasValidLength(extendedBytes), isFalse);
      expect(
        () => WearableEndPacketParser.parse(extendedBytes.sublist(0, 18)),
        throwsFormatException,
      );
    });
  });
}
