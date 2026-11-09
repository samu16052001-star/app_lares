import 'package:app_lares/wearable_agm_packet_parser.dart';
import 'package:app_lares/wearable_imu_status.dart';
import 'package:app_lares/wearable_mag_calibration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('successful magnetometer calibration', () {
    final result =
        WearableMagCalibrationResult.tryParse('CALIB_MAG_DONE:134.9,-40.0,22.0,47');
    expect(result, isNotNull);
    expect(result!.success, isTrue);
    expect(result.offsetX, closeTo(134.9, 1e-9));
    expect(result.offsetY, closeTo(-40.0, 1e-9));
    expect(result.offsetZ, closeTo(22.0, 1e-9));
    expect(result.fieldMicroTesla, 47);
    expect(result.summary, contains('offset x=134.9, y=-40.0, z=22.0 uT'));
  });

  test('failed magnetometer calibrations', () {
    final rotation = WearableMagCalibrationResult.tryParse('CALIB_MAG_FAIL:ROT,12');
    expect(rotation!.success, isFalse);
    expect(rotation.failure, WearableMagCalibrationFailure.rotation);
    expect(rotation.failureValue, 12);
    expect(rotation.summary, contains('coverage 12%'));
    expect(rotation.summary, contains('previous offset'));

    final still = WearableMagCalibrationResult.tryParse('CALIB_MAG_FAIL:ROT,0');
    expect(still!.summary, contains('did not move'));

    final field = WearableMagCalibrationResult.tryParse('CALIB_MAG_FAIL:FIELD,180');
    expect(field!.failure, WearableMagCalibrationFailure.field);
    expect(field.failureValue, 180);

    final fit = WearableMagCalibrationResult.tryParse('CALIB_MAG_FAIL:FIT,18\n');
    expect(fit!.failure, WearableMagCalibrationFailure.fit);
    expect(fit.failureValue, 18);

    expect(
      WearableMagCalibrationResult.tryParse('CALIB_MAG_FAIL:NOMAG')!.failure,
      WearableMagCalibrationFailure.noMagnetometer,
    );
    expect(
      WearableMagCalibrationResult.tryParse('CALIB_MAG_FAIL:BUSY')!.failure,
      WearableMagCalibrationFailure.busy,
    );
  });

  test('other text and malformed replies are not calibration replies', () {
    for (final text in [
      'CALIB_DONE',
      'CONFIG_DONE',
      'STATUS:1,2,3',
      'CALIB_MAG_DONE:1,2,3',
      'CALIB_MAG_DONE:a,2,3,47',
      'CALIB_MAG_FAIL:ROT',
      'CALIB_MAG_FAIL:XYZ,3',
      'CALIB_MAG_FAIL:ROT,-1',
    ]) {
      expect(WearableMagCalibrationResult.tryParse(text), isNull, reason: text);
    }
    // A STATUS reply is not taken for a calibration reply and vice versa.
    expect(WearableImuStatus.tryParse('CALIB_MAG_DONE:1.0,2.0,3.0,47'), isNull);
  });

  test('the longest replies are never taken for an AGM batch', () {
    // Firmware buffer: 44 bytes; AGM batches are 43, 86, ... bytes long.
    for (final reply in [
      'CALIB_MAG_DONE:-999.9,-999.9,-999.9,150',
      'CALIB_MAG_FAIL:FIELD,9999',
      'CALIB_MAG_FAIL:ROT,100',
      'CALIB_MAG_FAIL:NOMAG',
    ]) {
      expect(reply.length, lessThan(43), reason: reply);
      expect(WearableAgmPacketParser.hasValidLength(reply.codeUnits), isFalse);
      expect(WearableMagCalibrationResult.tryParse(reply), isNotNull);
    }
  });
}
