package com.example.app_lares

import android.view.WindowManager
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
                "showImuNoDataAlert" -> {
                    val text = call.argument<String>("text") ?: "No IMU data"
                    val alert = call.argument<Boolean>("alert") ?: true
                    LaresBleAlertNotifications.showNoData(this, text, alert)
                    result.success(null)
                }
                "clearImuNoDataAlert" -> {
                    LaresBleAlertNotifications.clearNoData(this)
                    result.success(null)
                }
                "vibrateBleDisconnectionAlert" -> {
                    LaresBleAlertNotifications.vibrateAlertCue(this)
                    result.success(null)
                }
                // Stopwatch running: screen kept on, like the
                // wake lock of time.sesnext.uk.
                "setKeepScreenOn" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    if (on) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
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
