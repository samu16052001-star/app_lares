import 'dart:io';

import 'package:flutter/services.dart';

class AndroidAcquisitionForegroundService {
  const AndroidAcquisitionForegroundService._();

  static const MethodChannel _channel = MethodChannel(
    'app_lares/acquisition_foreground_service',
  );

  static void setActivityAttachedHandler(Future<void> Function() handler) {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'acquisitionActivityAttached') await handler();
    });
  }

  static Future<bool> isActivityAttached() async {
    if (!Platform.isAndroid) return true;
    return await _channel.invokeMethod<bool>('isActivityAttached') ?? false;
  }

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

  static Future<void> playBleDisconnectionAlarmCue() async {
    if (!Platform.isAndroid) {
      return;
    }

    try {
      await _channel.invokeMethod<void>('playBleDisconnectionAlarmCue');
    } catch (_) {
      // Audio/vibration failures must never interrupt acquisition.
    }
  }
}
