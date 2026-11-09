import 'package:app_lares/wearable_agm_packet_parser.dart';
import 'package:app_lares/wearable_imu_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('STATUS reply of an IMU that is recording', () {
    final status = WearableImuStatus.tryParse('STATUS:1,2,3605');
    expect(status, isNotNull);
    expect(status!.recording, isTrue);
    expect(status.recordingsSincePowerOn, 2);
    expect(status.uptimeSeconds, 3605);
  });

  test('STATUS reply of an IMU switched off and on', () {
    final status = WearableImuStatus.tryParse('STATUS:0,0,6\n');
    expect(status, isNotNull);
    expect(status!.recording, isFalse);
    expect(status.recordingsSincePowerOn, 0);
    expect(status.uptimeSeconds, 6);
  });

  test('other text and malformed replies are not STATUS replies', () {
    expect(WearableImuStatus.tryParse('CONFIG_DONE'), isNull);
    expect(WearableImuStatus.tryParse('STATUS'), isNull);
    expect(WearableImuStatus.tryParse('STATUS:2,0,6'), isNull);
    expect(WearableImuStatus.tryParse('STATUS:1,0'), isNull);
    expect(WearableImuStatus.tryParse('STATUS:1,x,6'), isNull);
  });

  test('the longest STATUS reply is never taken for an AGM batch', () {
    // Firmware buffer: 32 bytes; AGM batches are 43, 86, ... bytes long.
    for (final reply in ['STATUS:0,0,0', 'STATUS:1,65535,4294967']) {
      expect(reply.length, lessThan(32));
      expect(WearableAgmPacketParser.hasValidLength(reply.codeUnits), isFalse);
    }
  });
}
