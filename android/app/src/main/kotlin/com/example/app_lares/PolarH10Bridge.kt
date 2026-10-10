package com.example.app_lares

import android.content.Context
import com.polar.androidcommunications.api.ble.model.DisInfo
import com.polar.sdk.api.PolarBleApi
import com.polar.sdk.api.PolarBleApiCallback
import com.polar.sdk.api.PolarBleApiDefaultImpl
import com.polar.sdk.api.model.PolarDeviceInfo
import com.polar.sdk.api.model.PolarHealthThermometerData
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Engine-owned bridge: one SDK, one manager per stable BLE identity. */
class PolarH10Bridge(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val managers = linkedMapOf<String, PolarH10Manager>()
    private var eventSink: EventChannel.EventSink? = null
    private val apiDelegate = lazy {
        PolarBleApiDefaultImpl.defaultImplementation(
            context.applicationContext,
            setOf(
                PolarBleApi.PolarBleSdkFeature.FEATURE_HR,
                PolarBleApi.PolarBleSdkFeature.FEATURE_DEVICE_INFO,
                PolarBleApi.PolarBleSdkFeature.FEATURE_BATTERY_INFO,
                PolarBleApi.PolarBleSdkFeature.FEATURE_POLAR_ONLINE_STREAMING,
                PolarBleApi.PolarBleSdkFeature.FEATURE_POLAR_SDK_MODE
            )
        ).also {
            it.setAutomaticReconnection(false)
            it.setApiCallback(object : PolarBleApiCallback() {
                override fun blePowerStateChanged(powered: Boolean) =
                    each { it.blePowerStateChanged(powered) }
                override fun deviceConnecting(info: PolarDeviceInfo) =
                    each { it.deviceConnecting(info) }
                override fun deviceConnected(info: PolarDeviceInfo) =
                    each { it.deviceConnected(info) }
                override fun deviceDisconnected(info: PolarDeviceInfo) =
                    each { it.deviceDisconnected(info) }
                override fun bleSdkFeatureReady(
                    identifier: String, feature: PolarBleApi.PolarBleSdkFeature
                ) = each { it.bleSdkFeatureReady(identifier, feature) }
                override fun batteryLevelReceived(identifier: String, level: Int) =
                    each { it.batteryLevelReceived(identifier, level) }
                override fun disInformationReceived(identifier: String, info: DisInfo) =
                    each { it.disInformationReceived(identifier, info) }
                override fun htsNotificationReceived(
                    identifier: String, data: PolarHealthThermometerData
                ) = each { it.htsNotificationReceived(identifier, data) }
            })
        }
    }
    private val api: PolarBleApi by apiDelegate

    init {
        MethodChannel(messenger, "app_lares/polar_h10_control").setMethodCallHandler(this)
        EventChannel(messenger, "app_lares/polar_h10_events").setStreamHandler(this)
    }

    private fun each(action: (PolarBleApiCallback) -> Unit) {
        // Snapshot because SDK callbacks may arrive while another device is added.
        synchronized(managers) { managers.values.toList() }.forEach { action(it.apiCallback) }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun dispose() {
        eventSink = null
        managers.values.forEach { it.dispose() }
        managers.clear()
        if (apiDelegate.isInitialized()) api.shutDown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "foregroundEntered") {
            try {
                api.foregroundEntered()
                result.success(null)
            } catch (error: Exception) {
                result.error("POLAR_H10_FOREGROUND_FAILED", error.message, null)
            }
            return
        }
        val deviceId = call.argument<String>("sessionDeviceId")
            ?: call.argument<Map<String, Any?>>("device")?.get("deviceId")?.toString()
        if (call.method == "stop") {
            val selected = if (deviceId == null) managers.values.toList()
                else listOfNotNull(managers[deviceId])
            if (selected.isEmpty()) {
                result.success(null)
                return
            }
            var remaining = selected.size
            var failure: Pair<String, String?>? = null
            val completion = object : MethodChannel.Result {
                private fun complete() {
                    remaining -= 1
                    if (remaining == 0) {
                        val error = failure
                        if (error == null) result.success(null)
                        else result.error(error.first, error.second, null)
                    }
                }
                override fun success(value: Any?) = complete()
                override fun error(code: String, message: String?, details: Any?) {
                    failure = code to message
                    complete()
                }
                override fun notImplemented() = error("POLAR_H10_STOP_FAILED", null, null)
            }
            selected.forEach { it.onMethodCall(call, completion) }
            return
        }
        if (call.method !in setOf("prepare", "startStreams", "reconnectAndStart")) {
            result.notImplemented()
            return
        }
        if (deviceId.isNullOrBlank()) {
            result.error("POLAR_H10_INVALID_DEVICE", "Polar H10 device identity is missing.", null)
            return
        }
        val manager = synchronized(managers) {
            managers.getOrPut(deviceId) {
                PolarH10Manager(context.applicationContext, { api }) { event ->
                    eventSink?.success(event + ("sessionDeviceId" to deviceId))
                }
            }
        }
        manager.onMethodCall(call, result)
    }
}
