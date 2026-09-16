import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Local notifications for BLE disconnections, iOS only.
///
/// With the app in background iOS blocks the haptic APIs, so a local
/// notification is the only way to alert the user: it vibrates the phone and
/// shows the device name on the lock screen.
///
/// Android is not handled here: LaresBleAlertNotifications.kt already posts a
/// notification with its own vibration pattern through the foreground service.
class DisconnectionNotifications {
  const DisconnectionNotifications._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static Future<bool>? _initialization;
  static final Map<String, int> _notificationIdsByDevice = {};
  static int _nextNotificationId = 1;

  /// Initializes the plugin and asks for the notification permission.
  /// Safe to call more than once: the work happens only on the first call.
  static Future<bool> initialize() {
    return _initialization ??= _initialize();
  }

  static Future<bool> _initialize() async {
    if (!Platform.isIOS) {
      return false;
    }

    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          iOS: DarwinInitializationSettings(
            requestAlertPermission: true,
            requestSoundPermission: true,
            requestBadgePermission: false,
          ),
        ),
      );

      final granted = await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, sound: true, badge: false);
      if (granted != true) {
        debugPrint('Notification permission not granted: BLE disconnection '
            'alerts will be silent on iOS.');
      }
      return granted ?? false;
    } catch (error, stackTrace) {
      debugPrint('Notification setup error: $error');
      debugPrint('$stackTrace');
      return false;
    }
  }

  /// One notification per disconnection, tagged with the device name.
  /// Each device keeps its own notification id, so simultaneous
  /// disconnections do not overwrite each other.
  ///
  /// With the app in foreground the alert is left to the in-app cue (sound and
  /// vibration) plus the dialog, so the notification is skipped: iOS would
  /// otherwise add a banner with a second sound.
  static Future<void> showDisconnected(
    String deviceName, {
    required bool appInForeground,
  }) async {
    if (!Platform.isIOS || appInForeground) {
      return;
    }

    if (!await initialize()) {
      return;
    }

    try {
      await _plugin.show(
        id: _notificationIdFor(deviceName),
        title: 'BLE device disconnected',
        body: '$deviceName stopped sending data. '
            'The app is trying to reconnect.',
        notificationDetails: const NotificationDetails(
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
            presentBadge: false,
          ),
        ),
      );
    } catch (error) {
      // An alert failure must never interrupt the acquisition.
      debugPrint('Disconnection notification error: $error');
    }
  }

  /// Clears the alerts, e.g. when the acquisition stops.
  static Future<void> clearAll() async {
    if (!Platform.isIOS) {
      return;
    }

    try {
      await _plugin.cancelAll();
    } catch (error) {
      debugPrint('Disconnection notification cleanup error: $error');
    }
  }

  static int _notificationIdFor(String deviceName) {
    return _notificationIdsByDevice.putIfAbsent(
      deviceName,
      () => _nextNotificationId++,
    );
  }
}
