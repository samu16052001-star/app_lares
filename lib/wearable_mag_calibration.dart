/// Magnetometer calibration (hard-iron offset) of the IMU.
class WearableMagCalibrationResult {
  const WearableMagCalibrationResult._({
    required this.success,
    this.offsetX,
    this.offsetY,
    this.offsetZ,
    this.fieldMicroTesla,
    this.failure,
    this.failureValue,
  });

  static const String command = 'CALIB_MAG_START';

  /// Rotation time (CALIB_MAG_SECONDS in the firmware).
  static const Duration duration = Duration(seconds: 20);

  static const String _donePrefix = 'CALIB_MAG_DONE:';
  static const String _failPrefix = 'CALIB_MAG_FAIL:';

  final bool success;

  /// Hard-iron offset in uT (success only).
  final double? offsetX;
  final double? offsetY;
  final double? offsetZ;

  /// Magnitude of the field seen during the rotation, in uT (success only).
  final int? fieldMicroTesla;

  final WearableMagCalibrationFailure? failure;

  /// Coverage %, field (uT) or spread % depending on [failure].
  final int? failureValue;

  /// Text for the log and the warning in the UI.
  String get summary {
    if (success) {
      return 'Magnetometer calibrated: offset '
          'x=${offsetX!.toStringAsFixed(1)}, '
          'y=${offsetY!.toStringAsFixed(1)}, '
          'z=${offsetZ!.toStringAsFixed(1)} uT '
          '(field $fieldMicroTesla uT).';
    }

    const kept = 'The previous offset is still used.';
    return switch (failure!) {
      WearableMagCalibrationFailure.rotation => failureValue == 0
          ? 'Magnetometer calibration failed: the IMU did not move. '
              'Rotate it slowly in all directions during the calibration. $kept'
          : 'Magnetometer calibration failed: the IMU was not rotated in '
              'enough directions (coverage $failureValue%). Turn it upside '
              'down and on every side during the calibration. $kept',
      WearableMagCalibrationFailure.field =>
        'Magnetometer calibration failed: measured field $failureValue uT, '
            'expected about 25-65 uT. Keep the IMU away from magnets and '
            'metal objects. $kept',
      WearableMagCalibrationFailure.fit =>
        'Magnetometer calibration failed: the readings were disturbed '
            '(spread $failureValue%). Keep the IMU away from metal objects '
            'and try again. $kept',
      WearableMagCalibrationFailure.noMagnetometer =>
        'Magnetometer calibration skipped: the magnetometer of this IMU does '
            'not answer.',
      WearableMagCalibrationFailure.busy =>
        'Magnetometer calibration refused: the IMU was busy. $kept',
    };
  }

  /// Null when [text] is not a reply to CALIB_MAG_START.
  static WearableMagCalibrationResult? tryParse(String text) {
    final trimmed = text.trim();
    if (trimmed.startsWith(_donePrefix)) {
      final fields = trimmed.substring(_donePrefix.length).split(',');
      if (fields.length != 4) {
        return null;
      }
      final x = double.tryParse(fields[0].trim());
      final y = double.tryParse(fields[1].trim());
      final z = double.tryParse(fields[2].trim());
      final field = int.tryParse(fields[3].trim());
      if (x == null || y == null || z == null || field == null || field < 0) {
        return null;
      }
      return WearableMagCalibrationResult._(
        success: true,
        offsetX: x,
        offsetY: y,
        offsetZ: z,
        fieldMicroTesla: field,
      );
    }

    if (!trimmed.startsWith(_failPrefix)) {
      return null;
    }
    final fields = trimmed.substring(_failPrefix.length).split(',');
    final reason = fields.first.trim();
    switch (reason) {
      case 'NOMAG':
        return const WearableMagCalibrationResult._(
          success: false,
          failure: WearableMagCalibrationFailure.noMagnetometer,
        );
      case 'BUSY':
        return const WearableMagCalibrationResult._(
          success: false,
          failure: WearableMagCalibrationFailure.busy,
        );
    }

    final failure = switch (reason) {
      'ROT' => WearableMagCalibrationFailure.rotation,
      'FIELD' => WearableMagCalibrationFailure.field,
      'FIT' => WearableMagCalibrationFailure.fit,
      _ => null,
    };
    if (failure == null || fields.length != 2) {
      return null;
    }
    final value = int.tryParse(fields[1].trim());
    if (value == null || value < 0) {
      return null;
    }
    return WearableMagCalibrationResult._(
      success: false,
      failure: failure,
      failureValue: value,
    );
  }
}

enum WearableMagCalibrationFailure {
  rotation,
  field,
  fit,
  noMagnetometer,
  busy,
}
