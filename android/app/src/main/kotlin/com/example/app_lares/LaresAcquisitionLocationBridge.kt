package com.example.app_lares

import android.content.Context
import com.baseflow.geolocator.location.GeolocationManager
import com.baseflow.geolocator.location.LocationClient
import com.baseflow.geolocator.location.LocationMapper
import com.baseflow.geolocator.location.LocationOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

/**
 * Reuses geolocator's provider and mapping, but owns the acquisition subscription
 * at engine scope. Its standard non-service stream is stopped on Activity detach.
 */
class LaresAcquisitionLocationBridge(
    private val context: Context,
    messenger: BinaryMessenger
) : EventChannel.StreamHandler {
    private val manager = GeolocationManager.getInstance()
    private var client: LocationClient? = null
    private var events: EventChannel.EventSink? = null
    private var options: LocationOptions? = null

    init {
        EventChannel(messenger, "app_lares/acquisition_location").setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        stopClient()
        this.events = events
        @Suppress("UNCHECKED_CAST")
        val settings = arguments as? Map<String, Any>
        options = LocationOptions.parseArguments(settings)
        resumeIfNeeded()
    }

    fun resumeIfNeeded() {
        val sink = events ?: return
        if (client != null) return
        if (!LaresAcquisitionRuntime.activityAttached &&
            LaresAcquisitionRuntime.foregroundService?.locationServiceEnabled != true) {
            sink.error("LOCATION_REQUIRES_FOREGROUND",
                "GPS will resume when Lares is opened; Android has restricted background location.", null)
            return
        }
        val created = manager.createLocationClient(context, false, options)
        client = created
        try {
            manager.startPositionUpdates(created, null,
                { location -> sink.success(LocationMapper.toHashMap(location)) },
                { error ->
                    stopClient()
                    sink.error(error.toString(), error.toDescription(), null)
                })
        } catch (error: Exception) {
            stopClient()
            sink.error("ACQUISITION_LOCATION_FAILED", error.message, null)
        }
    }

    override fun onCancel(arguments: Any?) {
        events = null
        options = null
        stopClient()
    }

    fun dispose() = onCancel(null)

    private fun stopClient() {
        client?.let { manager.stopPositionUpdates(it) }
        client = null
    }
}
