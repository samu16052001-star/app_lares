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

  test('20-byte SDS has no SD state', () {
    final bytes = [
      0x53, 0x44, 0x53, 64, 0x00, 0x00, //
      0x27, 0x00, 0x00, 0x00, 0xF4, 0x01, //
      0x02, 0x02, 0xFB, 0x00, 0xFB, 0x00, //
      0x00, 0x00, //
    ];
    expect(WearableSdsPacketParser.parse(bytes).sdHealth, isNull);
  });

  test('23-byte SDS (firmware 12/11) has the SD state', () {
    // SD write stuck for 12 s, flush failure rate 2.50%.
    const bytes = [
      0x53, 0x44, 0x53, 80, 0xFA, 0x00, //
      0x27, 0x00, 0x00, 0x00, 0xF4, 0x01, //
      0x02, 0x02, 0xFB, 0x00, 0xFB, 0x00, //
      0x00, 0x00, //
      0x01, 0x0C, 0x00, //
    ];

    final status = WearableSdsPacketParser.parse(bytes);
    expect(status.flushFailureRate, 250);
    expect(status.link!.txDataLength, 251);
    final sd = status.sdHealth!;
    expect(sd.state, WearableSdState.writeStalled);
    expect(sd.seconds, 12);
    expect(sd.isSaving, isFalse);
    expect(sd.description, 'SD stuck for 12 s');
    expect(sd.state.label, 'SD stuck');
    // Not taken for an AGM data packet (checked before SDS).
    expect(WearableAgmPacketParser.hasValidLength(bytes), isFalse);
  });

  test('SD states and longer packets', () {
    List<int> packet(int state, {int extra = 0}) => [
          0x53, 0x44, 0x53, 50, 0, 0, //
          0x27, 0, 0, 0, 0xF4, 0x01, 2, 2, 0xFB, 0, 0xFB, 0, 0, 0, //
          state, 0x17, 0, //
          for (var i = 0; i < extra; i += 1) 0,
        ];
    WearableSdHealth sdOf(int code) =>
        WearableSdsPacketParser.parse(packet(code)).sdHealth!;

    expect(sdOf(0).isSaving, isTrue);
    expect(sdOf(2).state, WearableSdState.noFile);
    expect(sdOf(2).description, 'SD not saving (no file) for 23 s');
    expect(sdOf(3).description, 'No SD card');
    expect(sdOf(3).state, WearableSdState.noCard);
    expect(sdOf(4).state, WearableSdState.writeError);
    expect(sdOf(9).state, WearableSdState.unknown);
    // Fields added by a later firmware are ignored.
    expect(
      WearableSdsPacketParser.parse(packet(1, extra: 4)).sdHealth!.state,
      WearableSdState.writeStalled,
    );
  });

  test('SDS with another length is rejected', () {
    expect(
      () => WearableSdsPacketParser.parse(const [0x53, 0x44, 0x53, 50, 0, 0, 0]),
      throwsFormatException,
    );
  });
}
