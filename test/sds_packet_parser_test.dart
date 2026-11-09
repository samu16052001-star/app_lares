import 'package:app_lares/wearable_agm_packet_parser.dart';
import 'package:app_lares/wearable_sds_packet_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('6-byte SDS (older firmware) has no link status', () {
    const bytes = [0x53, 0x44, 0x53, 87, 0xFA, 0x00];
    final status = WearableSdsPacketParser.parse(bytes);
    expect(status.batteryPercent, 87);
    expect(status.flushFailureRate, 250);
    expect(status.link, isNull);
  });

  test('20-byte SDS (firmware 17/10) has the BLE link parameters', () {
    // ble_emit_stat(): 64%, rate 0, interval 39 (48.75 ms), latency 0,
    // timeout 42 (420 ms), PHY 2M/2M, data length 251/251, 5 failures.
    const bytes = [
      0x53, 0x44, 0x53, 64, 0x00, 0x00, //
      0x27, 0x00, 0x00, 0x00, 0x2A, 0x00, //
      0x02, 0x02, 0xFB, 0x00, 0xFB, 0x00, //
      0x05, 0x00, //
    ];

    final status = WearableSdsPacketParser.parse(bytes);
    final link = status.link!;
    expect(status.batteryPercent, 64);
    expect(link.connectionIntervalMs, closeTo(48.75, 0.001));
    expect(link.peripheralLatency, 0);
    expect(link.supervisionTimeoutMs, 420);
    expect(link.txPhy, 2);
    expect(link.rxPhy, 2);
    expect(link.txDataLength, 251);
    expect(link.rxDataLength, 251);
    expect(link.bleNotifyFailures, 5);
    expect(link.summary, contains('PHY 2M/2M'));
    expect(WearableAgmPacketParser.hasValidLength(bytes), isFalse);
  });

  test('SDS with another length is rejected', () {
    expect(
      () => WearableSdsPacketParser.parse(const [0x53, 0x44, 0x53, 50, 0, 0, 0]),
      throwsFormatException,
    );
  });
}
