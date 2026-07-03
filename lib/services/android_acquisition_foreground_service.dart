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
}
