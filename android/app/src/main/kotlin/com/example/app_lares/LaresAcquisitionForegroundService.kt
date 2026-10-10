package com.example.app_lares

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine

class LaresAcquisitionForegroundService : Service() {
    private var acquisitionEngine: FlutterEngine? = null
    private var wakeLock: PowerManager.WakeLock? = null
    var locationServiceEnabled = false
        private set

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!LaresAcquisitionRuntime.isRequested(this)) {
            stopSelf()
            return START_NOT_STICKY
        }

        try {
            // Meet Android's foreground deadline before loading Flutter on restart.
            startForeground(NOTIFICATION_ID, buildNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } catch (error: SecurityException) {
            // Permissions can be revoked while the process is gone. Keep Dart's
            // recovery record for the next visible launch; do not crash-loop.
            stopSelf()
            finishPendingStarts(error)
            return START_NOT_STICKY
        }
        LaresAcquisitionRuntime.foregroundService = this
        promoteLocationIfAllowed()
        if (wakeLock == null) {
            wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Lares:acquisition")
                .apply { setReferenceCounted(false); acquire() }
        }
        // This is the very same engine rendered by MainActivity, with the same
        // subscriptions, writers and session owner. Never start a second isolate.
        acquisitionEngine = LaresAcquisitionRuntime.engine(this)
        finishPendingStarts(null)
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Removing recent tasks closes only the presentation. The service owns
        // acquisition until the explicit stop command or Android terminates it.
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        if (LaresAcquisitionRuntime.foregroundService === this) {
            LaresAcquisitionRuntime.foregroundService = null
        }
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        acquisitionEngine = null
        // Do not clear durable recovery state on unexpected service destruction.
        super.onDestroy()
    }

    fun promoteLocationIfAllowed() {
        if (locationServiceEnabled ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) !=
                PackageManager.PERMISSION_GRANTED) {
            return
        }
        try {
            startForeground(NOTIFICATION_ID, buildNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
            locationServiceEnabled = true
        } catch (_: SecurityException) {
            // Android may deny while-in-use location after a background restart.
            // BLE remains active; location is retried when an Activity resumes.
        }
    }

    private fun buildNotification(): Notification {
        val launchIntent = Intent(this, MainActivity::class.java)
            .putExtra("restoreAcquisition", true)
        launchIntent.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or immutablePendingIntentFlag()
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }

        return builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("Lares acquisition")
            .setContentText(NOTIFICATION_TEXT)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(Notification.PRIORITY_LOW)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }

        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = NOTIFICATION_TEXT
            setShowBadge(false)
        }

        val notificationManager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.createNotificationChannel(channel)
    }

    private fun immutablePendingIntentFlag(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_IMMUTABLE
        } else {
            0
        }
    }

    companion object {
        private const val CHANNEL_ID = "lares_acquisition"
        private const val CHANNEL_NAME = "Lares acquisition"
        private const val NOTIFICATION_ID = 4205
        private const val NOTIFICATION_TEXT = "Acquisition in progress..."
        private val pendingStarts = mutableListOf<(Exception?) -> Unit>()

        private fun finishPendingStarts(error: Exception?) {
            val callbacks = pendingStarts.toList()
            pendingStarts.clear()
            callbacks.forEach { it(error) }
        }

        fun start(context: Context, completion: (Exception?) -> Unit) {
            val alreadyRequested = LaresAcquisitionRuntime.isRequested(context)
            LaresAcquisitionRuntime.setRequested(context, true)
            LaresAcquisitionRuntime.foregroundService?.let {
                it.promoteLocationIfAllowed()
                completion(null)
                return
            }
            val intent = Intent(context, LaresAcquisitionForegroundService::class.java)
            try {
                pendingStarts.add(completion)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (error: Exception) {
                pendingStarts.remove(completion)
                LaresAcquisitionRuntime.setRequested(context, alreadyRequested)
                throw error
            }
        }

        fun stop(context: Context) {
            LaresAcquisitionRuntime.setRequested(context, false)
            finishPendingStarts(IllegalStateException("Acquisition was stopped before its service started."))
            val intent = Intent(context, LaresAcquisitionForegroundService::class.java)
            context.stopService(intent)
            LaresBleAlertNotifications.clear(context)
        }
    }
}
