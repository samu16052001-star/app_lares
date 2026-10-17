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
  });
}
