package com.example.app_lares

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
                else -> result.notImplemented()
            }
        }
    }
}
