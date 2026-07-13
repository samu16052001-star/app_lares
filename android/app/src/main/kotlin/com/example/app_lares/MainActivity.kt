package com.example.app_lares

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var polarH10Manager: PolarH10Manager? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        polarH10Manager = PolarH10Manager(
            this,
            flutterEngine.dartExecutor.binaryMessenger
        )

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app_lares/acquisition_foreground_service"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startAcquisitionForegroundService" -> {
                    try {
                        LaresAcquisitionForegroundService.start(this)
                        result.success(null)
                    } catch (error: Exception) {
                        result.error(
                            "FOREGROUND_SERVICE_START_FAILED",
                            error.message,
                            null
                        )
                    }
                }
                "stopAcquisitionForegroundService" -> {
                    try {
                        LaresAcquisitionForegroundService.stop(this)
                        result.success(null)
                    } catch (error: Exception) {
                        result.error(
                            "FOREGROUND_SERVICE_STOP_FAILED",
                            error.message,
                            null
                        )
                    }
                }
                "showBleDisconnectionAlert" -> {
                    val deviceName = call.argument<String>("deviceName")
                        ?: "BLE device"
                    LaresBleAlertNotifications.show(this, deviceName)
                    result.success(null)
                }
                "clearBleDisconnectionAlert" -> {
                    LaresBleAlertNotifications.clear(this)
                    result.success(null)
                }
                "playBleDisconnectionAlarmCue" -> {
                    LaresBleAlertNotifications.playAlarmCue(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        polarH10Manager?.dispose()
        polarH10Manager = null
        super.onDestroy()
    }
}
