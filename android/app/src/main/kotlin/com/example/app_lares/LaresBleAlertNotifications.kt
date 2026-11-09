package com.example.app_lares

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator

// Disconnection alert of a BLE device: notification + vibration, no sound.
object LaresBleAlertNotifications {
    private const val CHANNEL_ID = "lares_ble_alerts_v3"
    private val LEGACY_CHANNEL_IDS = listOf("lares_ble_alerts", "lares_ble_alerts_v2")
    private const val CHANNEL_NAME = "BLE alerts"
    private const val NOTIFICATION_ID = 4206
    private const val NOTIFICATION_TITLE = "BLE device disconnected"
    // IMU connected but silent.
    private const val NO_DATA_NOTIFICATION_ID = 4207
    private const val NO_DATA_TITLE = "No IMU data"
    // Blue of the LaRes logo.
    private const val NOTIFICATION_COLOR = 0xFF013988.toInt()
    private val VIBRATION_PATTERN = longArrayOf(0, 350, 180, 350)

    fun show(context: Context, deviceName: String) {
        try {
            if (!canPostNotifications(context)) {
                return
            }

            createChannel(context)
            val notification = buildNotification(context, deviceName)
            val notificationManager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.notify(NOTIFICATION_ID, notification)
        } catch (_: Exception) {
            // BLE acquisition must continue even if the alert notification fails.
        }
    }

    fun clear(context: Context) {
        try {
            val notificationManager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.cancel(NOTIFICATION_ID)
        } catch (_: Exception) {
            // Best effort only.
        }
    }

    // IMU still connected but sending no data.
    fun showNoData(context: Context, text: String, alert: Boolean) {
        try {
            if (!canPostNotifications(context)) {
                return
            }

            createChannel(context)
            val notification = buildAlertNotification(context, NO_DATA_TITLE, text, !alert)
            val notificationManager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.notify(NO_DATA_NOTIFICATION_ID, notification)
        } catch (_: Exception) {
            // Acquisition must continue even if the alert notification fails.
        }
    }

    fun clearNoData(context: Context) {
        try {
            val notificationManager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.cancel(NO_DATA_NOTIFICATION_ID)
        } catch (_: Exception) {
            // Best effort only.
        }
    }

    // Repeated while a device stays disconnected: vibration only, no sound.
    fun vibrateAlertCue(context: Context) {
        try {
            val vibrator = context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator.vibrate(
                    VibrationEffect.createWaveform(VIBRATION_PATTERN, -1)
                )
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(VIBRATION_PATTERN, -1)
            }
        } catch (_: Exception) {
            // Vibration is best effort.
        }
    }

    private fun buildNotification(context: Context, deviceName: String): Notification =
        buildAlertNotification(
            context,
            NOTIFICATION_TITLE,
            "$deviceName disconnected. Tap to return to the acquisition screen.",
            false
        )

    private fun buildAlertNotification(
        context: Context,
        title: String,
        text: String,
        onlyAlertOnce: Boolean
    ): Notification {
        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent(context, MainActivity::class.java)
        launchIntent.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP

        val pendingIntent = PendingIntent.getActivity(
            context,
            1,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or immutablePendingIntentFlag()
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            Notification.Builder(context)
        }

        builder
            .setPriority(Notification.PRIORITY_HIGH)
            .setDefaults(Notification.DEFAULT_VIBRATE)
            .setVibrate(VIBRATION_PATTERN)

        return builder
            .setSmallIcon(R.drawable.ic_stat_lares)
            .setColor(NOTIFICATION_COLOR)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_ALARM)
            .setOnlyAlertOnce(onlyAlertOnce)
            .build()
    }

    private fun createChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }

        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = NOTIFICATION_TITLE
            enableVibration(true)
            vibrationPattern = VIBRATION_PATTERN
            // No sound: heads-up notification and vibration only.
            setSound(null, null)
        }

        val notificationManager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        for (legacyId in LEGACY_CHANNEL_IDS) {
            notificationManager.deleteNotificationChannel(legacyId)
        }
        notificationManager.createNotificationChannel(channel)
    }

    private fun canPostNotifications(context: Context): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
    }

    private fun immutablePendingIntentFlag(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_IMMUTABLE
        } else {
            0
        }
    }
}
