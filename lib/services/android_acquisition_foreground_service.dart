import 'dart:io';

import 'package:flutter/services.dart';

class AndroidAcquisitionForegroundService {
  const AndroidAcquisitionForegroundService._();

  static const MethodChannel _channel = MethodChannel(
    'app_lares/acquisition_foreground_service',
  );

  static Future<void> start() async {
    if (!Platform.isAndroid) {
      return;
    }

    await _channel.invokeMethod<void>('startAcquisitionForegroundService');
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) {
      return;
    }

    await _channel.invokeMethod<void>('stopAcquisitionForegroundService');
  }

  static Future<void> showBleDisconnectionAlert(String deviceName) async {
    if (!Platform.isAndroid) {
      return;
    }

    try {
      await _channel.invokeMethod<void>(
        'showBleDisconnectionAlert',
        <String, Object?>{'deviceName': deviceName},
      );
    } catch (_) {
      // Alert notification failures must never interrupt acquisition.
    }
  }

  static Future<void> clearBleDisconnectionAlert() async {
    if (!Platform.isAndroid) {
      return;
    }

    try {
      await _channel.invokeMethod<void>('clearBleDisconnectionAlert');
    } catch (_) {
      // Best effort cleanup only.
    }
  }

  /// "No IMU data" notification: separate from
  /// the disconnection alert, silent, vibrates when [alert] is true.
  static Future<void> showImuNoDataAlert({
    required String text,
    required bool alert,
  }) async {
    if (!Platform.isAndroid) {
      return;
    }

    try {
      await _channel.invokeMethod<void>(
        'showImuNoDataAlert',
        <String, Object?>{'text': text, 'alert': alert},
      );
    } catch (_) {
      // Alert notification failures must never interrupt acquisition.
    }
  }

  static Future<void> clearImuNoDataAlert() async {
    if (!Platform.isAndroid) {
      return;
    }

    try {
      await _channel.invokeMethod<void>('clearImuNoDataAlert');
    } catch (_) {
      // Best effort cleanup only.
    }
  }

  /// Keeps the screen on while the stopwatch runs, like the
  /// wake lock of time.sesnext.uk.
  static Future<void> setKeepScreenOn(bool on) async {
    if (!Platform.isAndroid) {
      return;
    }

    try {
      await _channel.invokeMethod<void>(
        'setKeepScreenOn',
        <String, Object?>{'on': on},
      );
    } catch (_) {
      // Best effort only.
    }
  }

  /// Vibration repeated while a device stays disconnected.
  static Future<void> vibrateBleDisconnectionAlert() async {
    if (!Platform.isAndroid) {
      return;
    }

    try {
      await _channel.invokeMethod<void>('vibrateBleDisconnectionAlert');
    } catch (_) {
      // Vibration failures must never interrupt acquisition.
    }
  }
}
