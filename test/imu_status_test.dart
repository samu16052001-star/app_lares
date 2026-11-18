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

  test('magnetometer found, also after a failed try', () {
    final first = WearableMagStatus.tryParse('MAG_FOUND:1');
    expect(first, isNotNull);
    expect(first!.found, isTrue);
    expect(first.tries, 1);
    expect(first.summary, 'Magnetometer found');
    final second = WearableMagStatus.tryParse('MAG_FOUND:2\n');
    expect(second!.found, isTrue);
    expect(second.summary, 'Magnetometer found at try 2');
  });

  test('magnetometer not found, with the reason of the last try', () {
    final nack = WearableMagStatus.tryParse('MAG_NOT_FOUND:3,NACK');
    expect(nack, isNotNull);
    expect(nack!.found, isFalse);
    expect(nack.tries, 3);
    expect(nack.reason, 'NACK');
    expect(
      nack.summary,
      'Magnetometer not found after 3 tries (no answer at its address)',
    );
    final id = WearableMagStatus.tryParse('MAG_NOT_FOUND:3,ID,3D');
    expect(id!.reason, 'ID');
    expect(id.whoAmI, 0x3D);
    expect(id.reasonDescription, 'wrong WHO_AM_I 0x3D');
    expect(
      WearableMagStatus.tryParse('MAG_NOT_FOUND:3,TIMEOUT')!.reasonDescription,
      'the sensor hub did not finish',
    );
  });

  test('other text and malformed magnetometer reports', () {
    expect(WearableMagStatus.tryParse('CONFIG_DONE'), isNull);
    expect(WearableMagStatus.tryParse('CALIB_MAG_FAIL:NOMAG'), isNull);
    expect(WearableMagStatus.tryParse('MAG_FOUND:'), isNull);
    expect(WearableMagStatus.tryParse('MAG_FOUND:0'), isNull);
    expect(WearableMagStatus.tryParse('MAG_NOT_FOUND:3'), isNull);
    expect(WearableMagStatus.tryParse('MAG_NOT_FOUND:x,NACK'), isNull);
    expect(WearableMagStatus.tryParse('MAG_NOT_FOUND:3,ID,zz'), isNull);
  });

  test('fatal error report', () {
    final report = WearableFatalReport.tryParse(
      'FATAL:2,4,0002A1B4,ble_thread',
    );
    expect(report, isNotNull);
    expect(report!.reason, 2);
    expect(report.exception, 4);
    expect(report.programCounter, 0x0002A1B4);
    expect(report.thread, 'ble_thread');
    expect(
      report.summary,
      'stack overflow of a thread (MemManage) in thread ble_thread, '
      'PC 0x0002A1B4',
    );
    expect(
      WearableFatalReport.tryParse('FATAL:3,11,00012345,BT RX')!.summary,
      contains('k_oops'),
    );
    // The test build (fatal_test.conf): invalid instruction in imu_thread.
    expect(
      WearableFatalReport.tryParse(
        'FATAL:36,6,00013784,imu_thread_id',
      )!.summary,
      'UsageFault: invalid instruction (UsageFault) in thread imu_thread_id, '
      'PC 0x00013784',
    );
    expect(
      WearableFatalReport.tryParse('FATAL:23,5,00012345,x')!.reasonDescription,
      'BusFault',
    );
    expect(WearableFatalReport.tryParse('FATAL:2,4,0002A1B4'), isNull);
    expect(WearableFatalReport.tryParse('FATAL:2,4,xyz,ble_thread'), isNull);
    expect(WearableFatalReport.tryParse('STATUS:0,1,7'), isNull);
  });

  test('the longest IMU reports are never taken for an AGM batch', () {
    for (final reply in [
      'MAG_NOT_FOUND:3,TIMEOUT',
      'MAG_NOT_FOUND:3,ID,FF',
      'FATAL:16,511,FFFFFFFF,abcdefghijklmno',
    ]) {
      expect(reply.length, lessThan(43));
      expect(WearableAgmPacketParser.hasValidLength(reply.codeUnits), isFalse);
    }
  });
}
