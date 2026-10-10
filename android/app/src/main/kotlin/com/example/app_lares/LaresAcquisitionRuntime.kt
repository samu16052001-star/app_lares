package com.example.app_lares

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * One engine per Android process, shared by the foreground service and the UI.
 * Flutter plugins are engine-owned; Activity attachment is needed only for UI
 * operations such as granting permissions. No second background isolate exists.
 */
object LaresAcquisitionRuntime {
    var activityAttached = false
    private var flutterEngine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var polarBridge: PolarH10Bridge? = null
    private var locationBridge: LaresAcquisitionLocationBridge? = null
    var foregroundService: LaresAcquisitionForegroundService? = null

    @Synchronized
    fun engine(context: Context): FlutterEngine {
        flutterEngine?.let { return it }
        val application = context.applicationContext
        // The default constructor registers GeneratedPluginRegistrant exactly once.
        val created = FlutterEngine(application)
        flutterEngine = created
        val messenger = created.dartExecutor.binaryMessenger
        polarBridge = PolarH10Bridge(application, messenger)
        locationBridge = LaresAcquisitionLocationBridge(application, messenger)
        channel = MethodChannel(messenger, CHANNEL).also { control ->
            control.setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "startAcquisitionForegroundService" -> {
                            LaresAcquisitionForegroundService.start(application) { error ->
                                if (error == null) result.success(null)
                                else result.error("FOREGROUND_SERVICE_START_FAILED", error.message, null)
                            }
                        }
                        "stopAcquisitionForegroundService" -> {
                            LaresAcquisitionForegroundService.stop(application)
                            result.success(null)
                        }
                        "getAcquisitionStorageDirectory" -> {
                            val directory = File(application.filesDir, "acquisitions")
                            check(directory.isDirectory || directory.mkdirs()) {
                                "The acquisition storage directory could not be created."
                            }
                            result.success(directory.absolutePath)
                        }
                        "getAcquisitionRuntimeState" -> result.success(
                            mapOf(
                                "active" to isRequested(application),
                                "activityAttached" to activityAttached,
                                "locationServiceEnabled" to
                                    (foregroundService?.locationServiceEnabled == true)
                            )
                        )
                        "isActivityAttached" -> result.success(activityAttached)
                        "showBleDisconnectionAlert" -> {
                            LaresBleAlertNotifications.show(
                                application, call.argument<String>("deviceName") ?: "BLE device"
                            )
                            result.success(null)
                        }
                        "clearBleDisconnectionAlert" -> {
                            LaresBleAlertNotifications.clear(application)
                            result.success(null)
                        }
                        "playBleDisconnectionAlarmCue" -> {
                            LaresBleAlertNotifications.playAlarmCue(application)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("ACQUISITION_RUNTIME_FAILED", error.message, null)
                }
            }
        }
        // Also runs after a system-authorized sticky service restart. Dart loads the
        // durable session before showing its UI and recovers the original writer.
        created.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        return created
    }

    fun onActivityResumed() {
        activityAttached = true
        foregroundService?.promoteLocationIfAllowed()
        locationBridge?.resumeIfNeeded()
        channel?.invokeMethod("acquisitionActivityAttached", null)
    }

    fun onActivityDestroyed(context: Context, changingConfiguration: Boolean) {
        activityAttached = false
        if (changingConfiguration || isRequested(context) || foregroundService != null) return
        // With no acquisition, retain the normal cold-launch behavior and release
        // scanning/configuration resources when the UI is closed.
        val previous = flutterEngine ?: return
        flutterEngine = null
        locationBridge?.dispose()
        locationBridge = null
        polarBridge?.dispose()
        polarBridge = null
        channel?.setMethodCallHandler(null)
        channel = null
        previous.destroy()
    }

    fun isRequested(context: Context): Boolean =
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .getBoolean(ACTIVE, false)

    fun setRequested(context: Context, active: Boolean) {
        // commit is deliberate: a process kill must not race the stop tombstone.
        check(context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .edit().putBoolean(ACTIVE, active).commit()) {
            "The acquisition service state could not be saved."
        }
    }

    private const val CHANNEL = "app_lares/acquisition_foreground_service"
    private const val PREFERENCES = "lares_acquisition_runtime"
    private const val ACTIVE = "requested"
}
