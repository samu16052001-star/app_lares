package com.example.app_lares

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import com.polar.androidcommunications.api.ble.model.DisInfo
import com.polar.androidcommunications.api.ble.model.gatt.client.pmd.PmdMeasurementType
import com.polar.sdk.api.PolarBleApi
import com.polar.sdk.api.PolarBleApiCallback
import com.polar.sdk.api.PolarBleApiDefaultImpl
import com.polar.sdk.api.model.EcgSample
import com.polar.sdk.api.model.FecgSample
import com.polar.sdk.api.model.PolarDeviceInfo
import com.polar.sdk.api.model.PolarHealthThermometerData
import com.polar.sdk.api.model.PolarSensorSetting
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.TimeoutCancellationException
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

class PolarH10Manager(
    private val context: Context,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val controlChannel = MethodChannel(messenger, CONTROL_CHANNEL)
    private val eventsChannel = EventChannel(messenger, EVENTS_CHANNEL)
    private val stopping = AtomicBoolean(false)

    private var eventSink: EventChannel.EventSink? = null
    private var selectedDevice: PolarDeviceSelection? = null
    private var activeIdentifier: String? = null
    private var activeDeviceInfo: PolarDeviceInfo? = null
    private var activeDisplayName: String? = null
    private var cachedEcgSettings: PolarSensorSetting? = null
    private var cachedAccelerometerSettings: PolarSensorSetting? = null
    private var cachedAccelerometerSampleRateHz: Int? = null
    private var connectionWaiter: CompletableDeferred<PolarDeviceInfo>? = null
    private var connectionSelection: PolarDeviceSelection? = null
    private var connectionIdentifier: String? = null
    private val featureWaiters =
        mutableMapOf<PolarBleApi.PolarBleSdkFeature, CompletableDeferred<Unit>>()

    private var hrJob: Job? = null
    private var ecgJob: Job? = null
    private var accelerometerJob: Job? = null
    private var apiInstance: PolarBleApi? = null

    private val api: PolarBleApi
        get() {
            val existingApi = apiInstance
            if (existingApi != null) {
                return existingApi
            }

            return PolarBleApiDefaultImpl.defaultImplementation(
                context.applicationContext,
                setOf(
                    PolarBleApi.PolarBleSdkFeature.FEATURE_HR,
                    PolarBleApi.PolarBleSdkFeature.FEATURE_DEVICE_INFO,
                    PolarBleApi.PolarBleSdkFeature.FEATURE_BATTERY_INFO,
                    PolarBleApi.PolarBleSdkFeature.FEATURE_POLAR_ONLINE_STREAMING,
                    PolarBleApi.PolarBleSdkFeature.FEATURE_POLAR_SDK_MODE
                )
            ).also { polarApi ->
                polarApi.setAutomaticReconnection(false)
                polarApi.setApiCallback(apiCallback)
                apiInstance = polarApi
            }
        }

    private val apiCallback = object : PolarBleApiCallback() {
        override fun blePowerStateChanged(powered: Boolean) {
            if (!powered) {
                sendError(
                    "POLAR_H10_BLUETOOTH_OFF",
                    "Bluetooth is off. Turn on Bluetooth to use Polar H10."
                )
            }
        }

        override fun deviceConnecting(polarDeviceInfo: PolarDeviceInfo) {
            if (matchesPendingConnection(polarDeviceInfo)) {
                sendConnection("preparing", polarDeviceInfo)
            }
        }

        override fun deviceConnected(polarDeviceInfo: PolarDeviceInfo) {
            if (!matchesPendingConnection(polarDeviceInfo) &&
                !matchesSelectedDevice(polarDeviceInfo)
            ) {
                return
            }

            activeDeviceInfo = polarDeviceInfo
            activeIdentifier = polarDeviceInfo.deviceId.ifBlank {
                polarDeviceInfo.address
            }
            activeDisplayName = polarDeviceInfo.name.ifBlank {
                selectedDevice?.displayName ?: "POLAR_H10"
            }
            connectionWaiter?.complete(polarDeviceInfo)
            connectionWaiter = null
            connectionSelection = null
            connectionIdentifier = null
            sendConnection("connected", polarDeviceInfo)
        }

        override fun deviceDisconnected(polarDeviceInfo: PolarDeviceInfo) {
            if (!matchesActiveDevice(polarDeviceInfo) &&
                !matchesSelectedDevice(polarDeviceInfo)
            ) {
                return
            }

            activeDeviceInfo = null
            activeIdentifier = null
            accelerometerJob?.cancel()
            accelerometerJob = null
            cachedEcgSettings = null
            cachedAccelerometerSettings = null
            cachedAccelerometerSampleRateHz = null
            if (!stopping.get()) {
                sendConnection("disconnected", polarDeviceInfo)
            }
        }

        override fun bleSdkFeatureReady(
            identifier: String,
            feature: PolarBleApi.PolarBleSdkFeature
        ) {
            if (!matchesActiveIdentifier(identifier)) {
                return
            }

            featureWaiters.remove(feature)?.complete(Unit)
        }

        override fun batteryLevelReceived(identifier: String, level: Int) {
            if (!matchesActiveIdentifier(identifier)) {
                return
            }

            sendEvent(
                mapOf(
                    "type" to "battery",
                    "level" to level
                )
            )
        }

        override fun disInformationReceived(identifier: String, disInfo: DisInfo) {
            // Device information is not displayed or logged for Polar H10 yet.
        }

        override fun htsNotificationReceived(
            identifier: String,
            data: PolarHealthThermometerData
        ) {
            // Health thermometer notifications are unrelated to H10 HR/ECG acquisition.
        }
    }

    init {
        controlChannel.setMethodCallHandler(this)
        eventsChannel.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepare" -> launchResult(result) {
                val selection = call.deviceSelection()
                val configuration = call.polarConfiguration()
                prepare(selection, configuration)
            }

            "startStreams" -> launchResult(result) {
                val selection = call.deviceSelection()
                val configuration = call.polarConfiguration()
                startStreams(selection, configuration)
            }

            "reconnectAndStart" -> launchResult(result) {
                val selection = call.deviceSelection()
                val configuration = call.polarConfiguration()
                sendStatus("reconnecting")
                prepare(selection, configuration)
                startStreams(selection, configuration)
            }

            "stop" -> launchResult(result) {
                val disconnect = call.argument<Boolean>("disconnect") ?: true
                stop(disconnect)
            }

            "foregroundEntered" -> {
                try {
                    api.foregroundEntered()
                    result.success(null)
                } catch (error: Exception) {
                    result.error("POLAR_H10_FOREGROUND_FAILED", error.message, null)
                }
            }

            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun dispose() {
        scope.launch {
            stop(disconnect = true)
            apiInstance?.shutDown()
            apiInstance = null
            controlChannel.setMethodCallHandler(null)
            eventsChannel.setStreamHandler(null)
            scope.cancel()
        }
    }

    private fun launchResult(
        result: MethodChannel.Result,
        block: suspend () -> Unit
    ) {
        scope.launch {
            try {
                block()
                result.success(null)
            } catch (error: PolarH10BridgeException) {
                sendError(error.code, error.message ?: "Polar H10 error")
                result.error(error.code, error.message, null)
            } catch (error: SecurityException) {
                val message = "Bluetooth permission is required to use Polar H10."
                sendError("POLAR_H10_PERMISSION_MISSING", message)
                result.error("POLAR_H10_PERMISSION_MISSING", message, null)
            } catch (error: Exception) {
                val message = error.message ?: "Polar H10 operation failed."
                sendError("POLAR_H10_OPERATION_FAILED", message)
                result.error("POLAR_H10_OPERATION_FAILED", message, null)
            }
        }
    }

    private suspend fun prepare(
        selection: PolarDeviceSelection,
        configuration: PolarConfiguration
    ) {
        if (!configuration.isValid) {
            throw PolarH10BridgeException(
                "POLAR_H10_INVALID_CONFIGURATION",
                "Select HR, Raw ECG, or Accelerometer before continuing."
            )
        }

        ensureBluetoothPermissions()
        selectedDevice = selection
        cachedEcgSettings = null
        cachedAccelerometerSettings = null
        cachedAccelerometerSampleRateHz = null
        sendStatus("preparing")

        val deviceInfo = connectToSelectedDevice(selection)
        val identifier = activeIdentifier
            ?: deviceInfo.deviceId.ifBlank { deviceInfo.address }
        if (identifier.isBlank()) {
            throw PolarH10BridgeException(
                "POLAR_H10_CONNECTION_FAILED",
                "Polar H10 connection failed. Device identity is unavailable."
            )
        }

        if (configuration.hrEnabled) {
            waitForFeature(identifier, PolarBleApi.PolarBleSdkFeature.FEATURE_HR)
            ensureHrAvailable(identifier)
        }
        if (configuration.rawEcgEnabled) {
            waitForFeature(
                identifier,
                PolarBleApi.PolarBleSdkFeature.FEATURE_POLAR_ONLINE_STREAMING,
                "Raw ECG"
            )
            cachedEcgSettings = prepareEcgSettings(identifier)
        }
        if (configuration.accelerometerEnabled) {
            waitForFeature(
                identifier,
                PolarBleApi.PolarBleSdkFeature.FEATURE_POLAR_ONLINE_STREAMING,
                "Accelerometer"
            )
            val accelerometerSettings = prepareAccelerometerSettings(identifier)
            cachedAccelerometerSettings = accelerometerSettings.settings
            cachedAccelerometerSampleRateHz = accelerometerSettings.samplingRateHz
        }

        sendBatteryLevelIfAvailable(identifier)
        sendConnection("connected", deviceInfo)
    }

    private suspend fun startStreams(
        selection: PolarDeviceSelection,
        configuration: PolarConfiguration
    ) {
        if (!configuration.isValid) {
            throw PolarH10BridgeException(
                "POLAR_H10_INVALID_CONFIGURATION",
                "Select HR, Raw ECG, or Accelerometer before continuing."
            )
        }

        selectedDevice = selection
        val identifier = activeIdentifier
        if (identifier == null) {
            prepare(selection, configuration)
        }

        val streamIdentifier = activeIdentifier
            ?: throw PolarH10BridgeException(
                "POLAR_H10_CONNECTION_FAILED",
                "Polar H10 connection failed. Try reconnecting the strap."
            )

        stopStreamsOnly()
        stopping.set(false)

        if (configuration.hrEnabled) {
            startHrStream(streamIdentifier)
        }
        if (configuration.rawEcgEnabled) {
            startEcgStream(streamIdentifier)
        }
        if (configuration.accelerometerEnabled) {
            startAccelerometerStream(streamIdentifier)
        }

        sendStatus(streamingStatus(configuration))
    }

    private suspend fun stop(disconnect: Boolean) {
        stopping.set(true)
        stopStreamsOnly()
        val identifier = activeIdentifier
        if (disconnect && identifier != null) {
            try {
                api.disconnectFromDevice(identifier)
            } catch (_: Exception) {
            }
        }

        activeIdentifier = null
        activeDeviceInfo = null
        cachedEcgSettings = null
        cachedAccelerometerSettings = null
        cachedAccelerometerSampleRateHz = null
        sendStatus("disconnected")
        stopping.set(false)
    }

    private suspend fun stopStreamsOnly() {
        val jobs = listOfNotNull(hrJob, ecgJob, accelerometerJob)
        hrJob = null
        ecgJob = null
        accelerometerJob = null
        for (job in jobs) {
            job.cancelAndJoin()
        }

        activeIdentifier?.let { identifier ->
            try {
                api.stopHrStreaming(identifier)
            } catch (_: Exception) {
            }
            try {
                api.stopStreaming(identifier, PmdMeasurementType.ECG)
            } catch (_: Exception) {
            }
            try {
                api.stopStreaming(identifier, PmdMeasurementType.ACC)
            } catch (_: Exception) {
            }
        }
    }

    private suspend fun connectToSelectedDevice(
        selection: PolarDeviceSelection
    ): PolarDeviceInfo {
        activeDeviceInfo?.let { info ->
            if (matchesSelection(info, selection)) {
                return info
            }
        }

        val preferredIdentifier = selection.preferredIdentifier
            ?: throw PolarH10BridgeException(
                "POLAR_H10_CONNECTION_FAILED",
                "Polar H10 connection failed. Device identity is unavailable."
            )

        try {
            return connectByIdentifier(selection, preferredIdentifier)
        } catch (_: Exception) {
        }

        val scannedInfo = scanForSelectedDevice(selection)
            ?: throw PolarH10BridgeException(
                "POLAR_H10_NOT_FOUND",
                "Polar H10 not found. Keep the selected strap nearby and try again."
            )
        val scannedIdentifier = scannedInfo.deviceId.ifBlank { scannedInfo.address }
        if (scannedIdentifier.isBlank()) {
            throw PolarH10BridgeException(
                "POLAR_H10_CONNECTION_FAILED",
                "Polar H10 connection failed. Device identity is unavailable."
            )
        }

        return connectByIdentifier(selection, scannedIdentifier)
    }

    private suspend fun connectByIdentifier(
        selection: PolarDeviceSelection,
        identifier: String
    ): PolarDeviceInfo {
        val waiter = CompletableDeferred<PolarDeviceInfo>()
        connectionWaiter = waiter
        connectionSelection = selection
        connectionIdentifier = identifier

        try {
            api.connectToDevice(identifier)
            return withTimeout(CONNECT_TIMEOUT_MS) {
                waiter.await()
            }
        } catch (error: Exception) {
            connectionWaiter = null
            connectionSelection = null
            connectionIdentifier = null
            throw PolarH10BridgeException(
                "POLAR_H10_CONNECTION_FAILED",
                "Polar H10 connection failed. Make sure the strap is worn and another app is not connected."
            )
        }
    }

    private suspend fun scanForSelectedDevice(
        selection: PolarDeviceSelection
    ): PolarDeviceInfo? {
        ensureBluetoothPermissions()

        val exactMatch = CompletableDeferred<PolarDeviceInfo?>()
        val nameMatches = mutableListOf<PolarDeviceInfo>()
        val scanJob = scope.launch(Dispatchers.Default) {
            try {
                api.searchForDevice("Polar").collect { info ->
                    if (!looksLikePolarH10(info.name)) {
                        return@collect
                    }

                    if (selection.hasExactIdentityMatch(info)) {
                        if (!exactMatch.isCompleted) {
                            exactMatch.complete(info)
                        }
                        return@collect
                    }

                    if (selection.hasNameMatch(info)) {
                        val known = nameMatches.any { existing ->
                            samePolarDevice(existing, info)
                        }
                        if (!known) {
                            nameMatches.add(info)
                        }
                    }
                }
            } catch (_: Exception) {
                if (!exactMatch.isCompleted) {
                    exactMatch.complete(null)
                }
            }
        }

        val foundExact = withTimeoutOrNull(SCAN_TIMEOUT_MS) {
            exactMatch.await()
        }
        scanJob.cancelAndJoin()
        if (foundExact != null) {
            return foundExact
        }

        return if (nameMatches.size == 1) {
            nameMatches.first()
        } else {
            null
        }
    }

    private suspend fun waitForFeature(
        identifier: String,
        feature: PolarBleApi.PolarBleSdkFeature,
        streamNameOverride: String? = null
    ) {
        if (api.isFeatureReady(identifier, feature)) {
            return
        }

        val waiter = CompletableDeferred<Unit>()
        featureWaiters[feature] = waiter
        try {
            withTimeout(FEATURE_TIMEOUT_MS) {
                waiter.await()
            }
        } catch (error: TimeoutCancellationException) {
            featureWaiters.remove(feature)
            val streamName = streamNameOverride ?: if (
                feature == PolarBleApi.PolarBleSdkFeature.FEATURE_HR
            ) {
                "HR"
            } else {
                "Polar online streaming"
            }
            throw PolarH10BridgeException(
                "POLAR_H10_STREAM_UNAVAILABLE",
                "$streamName stream is not ready on this Polar H10."
            )
        }
    }

    private suspend fun ensureHrAvailable(identifier: String) {
        try {
            val dataTypes = api.getAvailableHRServiceDataTypes(identifier)
            if (!dataTypes.contains(PolarBleApi.PolarDeviceDataType.HR)) {
                throw PolarH10BridgeException(
                    "POLAR_H10_HR_UNAVAILABLE",
                    "HR stream is not supported or unavailable on this Polar H10."
                )
            }
        } catch (error: PolarH10BridgeException) {
            throw error
        } catch (error: Exception) {
            throw PolarH10BridgeException(
                "POLAR_H10_HR_UNAVAILABLE",
                "HR stream is not supported or unavailable on this Polar H10."
            )
        }
    }

    private suspend fun prepareEcgSettings(identifier: String): PolarSensorSetting {
        try {
            val dataTypes = api.getAvailableOnlineStreamDataTypes(identifier)
            if (!dataTypes.contains(PolarBleApi.PolarDeviceDataType.ECG)) {
                throw PolarH10BridgeException(
                    "POLAR_H10_ECG_UNAVAILABLE",
                    "Raw ECG stream is not supported or unavailable on this Polar H10."
                )
            }
            return api
                .requestStreamSettings(identifier, PolarBleApi.PolarDeviceDataType.ECG)
                .maxSettings()
        } catch (error: PolarH10BridgeException) {
            throw error
        } catch (error: Exception) {
            throw PolarH10BridgeException(
                "POLAR_H10_ECG_STREAM_FAILED",
                "Raw ECG stream failed. Make sure another app is not connected to the Polar H10."
            )
        }
    }

    private suspend fun prepareAccelerometerSettings(
        identifier: String
    ): AccelerometerStreamSettings {
        try {
            val dataTypes = api.getAvailableOnlineStreamDataTypes(identifier)
            if (!dataTypes.contains(PolarBleApi.PolarDeviceDataType.ACC)) {
                throw PolarH10BridgeException(
                    "POLAR_H10_ACC_UNAVAILABLE",
                    "Accelerometer stream is not supported or unavailable on this Polar H10."
                )
            }

            val availableSettings = api.requestStreamSettings(
                identifier,
                PolarBleApi.PolarDeviceDataType.ACC
            )
            val sampleRates =
                availableSettings.settings[PolarSensorSetting.SettingType.SAMPLE_RATE]
                    ?: emptySet()
            val minimumSampleRate = sampleRates.minOrNull()
                ?: throw PolarH10BridgeException(
                    "POLAR_H10_ACC_STREAM_FAILED",
                    "Accelerometer stream has no valid sample-rate setting on this Polar H10."
                )
            val selectedValues =
                mutableMapOf<PolarSensorSetting.SettingType, Int>()
            for ((settingType, settingValues) in availableSettings.maxSettings().settings) {
                val selectedValue =
                    if (settingType == PolarSensorSetting.SettingType.SAMPLE_RATE) {
                        minimumSampleRate
                    } else {
                        settingValues.maxOrNull()
                            ?: throw PolarH10BridgeException(
                                "POLAR_H10_ACC_STREAM_FAILED",
                                "Accelerometer stream has incomplete settings on this Polar H10."
                            )
                    }
                selectedValues[settingType] = selectedValue
            }
            selectedValues[PolarSensorSetting.SettingType.SAMPLE_RATE] = minimumSampleRate

            return AccelerometerStreamSettings(
                settings = PolarSensorSetting(selectedValues),
                samplingRateHz = minimumSampleRate
            )
        } catch (error: PolarH10BridgeException) {
            throw error
        } catch (error: Exception) {
            throw PolarH10BridgeException(
                "POLAR_H10_ACC_STREAM_FAILED",
                "Accelerometer stream failed. Make sure another app is not connected to the Polar H10."
            )
        }
    }

    private fun sendBatteryLevelIfAvailable(identifier: String) {
        try {
            val level = api.getBatteryLevel(identifier)
            if (level >= 0) {
                sendEvent(
                    mapOf(
                        "type" to "battery",
                        "level" to level
                    )
                )
            }
        } catch (_: Exception) {
        }
    }

    private fun startHrStream(identifier: String) {
        hrJob = scope.launch(Dispatchers.Default) {
            try {
                api.startHrStreaming(identifier).collect { data ->
                    val receivedAtMillis = System.currentTimeMillis()
                    for (sample in data.samples) {
                        sendEvent(
                            mapOf(
                                "type" to "hr",
                                "deviceId" to activeIdentifier,
                                "deviceName" to activeDisplayName,
                                "receivedAtMillis" to receivedAtMillis,
                                "hrBpm" to sample.hr,
                                "rrIntervalsMs" to sample.rrsMs
                            )
                        )
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                failActiveStreams(
                    "POLAR_H10_HR_STREAM_FAILED",
                    "HR stream failed. Make sure another app is not connected to the Polar H10."
                )
            }
        }
    }

    private suspend fun startEcgStream(identifier: String) {
        val settings = cachedEcgSettings ?: prepareEcgSettings(identifier)
        ecgJob = scope.launch(Dispatchers.Default) {
            try {
                api.startEcgStreaming(identifier, settings).collect { data ->
                    val samples = data.samples.mapNotNull { sample ->
                        when (sample) {
                            is EcgSample -> mapOf(
                                "value" to sample.voltage,
                                "sdkTimestamp" to sample.timeStamp
                            )

                            is FecgSample -> mapOf(
                                "value" to sample.ecg,
                                "sdkTimestamp" to sample.timeStamp
                            )

                            else -> null
                        }
                    }
                    if (samples.isNotEmpty()) {
                        sendEvent(
                            mapOf(
                                "type" to "ecg",
                                "deviceId" to activeIdentifier,
                                "deviceName" to activeDisplayName,
                                "receivedAtMillis" to System.currentTimeMillis(),
                                "samplingRateHz" to ECG_SAMPLE_RATE_HZ,
                                "samples" to samples
                            )
                        )
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                failActiveStreams(
                    "POLAR_H10_ECG_STREAM_FAILED",
                    "Raw ECG stream failed. Make sure another app is not connected to the Polar H10."
                )
            }
        }
    }

    private suspend fun startAccelerometerStream(identifier: String) {
        val preparedSettings = cachedAccelerometerSettings?.let { settings ->
            AccelerometerStreamSettings(
                settings = settings,
                samplingRateHz = cachedAccelerometerSampleRateHz
                    ?: settings.settings[PolarSensorSetting.SettingType.SAMPLE_RATE]
                        ?.minOrNull()
                    ?: 1
            )
        } ?: prepareAccelerometerSettings(identifier).also { prepared ->
            cachedAccelerometerSettings = prepared.settings
            cachedAccelerometerSampleRateHz = prepared.samplingRateHz
        }
        accelerometerJob = scope.launch(Dispatchers.Default) {
            try {
                api.startAccStreaming(identifier, preparedSettings.settings).collect { data ->
                    val samples = data.samples.map { sample ->
                        mapOf(
                            "x" to sample.x,
                            "y" to sample.y,
                            "z" to sample.z,
                            "sdkTimestamp" to sample.timeStamp
                        )
                    }
                    if (samples.isNotEmpty()) {
                        sendEvent(
                            mapOf(
                                "type" to "accelerometer",
                                "deviceId" to activeIdentifier,
                                "deviceName" to activeDisplayName,
                                "receivedAtMillis" to System.currentTimeMillis(),
                                "samplingRateHz" to preparedSettings.samplingRateHz,
                                "samples" to samples
                            )
                        )
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                failActiveStreams(
                    "POLAR_H10_ACC_STREAM_FAILED",
                    "Accelerometer stream failed. Make sure another app is not connected to the Polar H10."
                )
            }
        }
    }

    private fun failActiveStreams(code: String, message: String) {
        if (stopping.get()) {
            return
        }

        hrJob?.cancel()
        ecgJob?.cancel()
        accelerometerJob?.cancel()
        hrJob = null
        ecgJob = null
        accelerometerJob = null
        cachedEcgSettings = null
        cachedAccelerometerSettings = null
        cachedAccelerometerSampleRateHz = null
        sendStatus("error", message)
        sendError(code, message)
    }

    private fun streamingStatus(configuration: PolarConfiguration): String {
        val streamCount = listOf(
            configuration.hrEnabled,
            configuration.rawEcgEnabled,
            configuration.accelerometerEnabled
        ).count { it }
        return when {
            streamCount > 1 -> "streaming"
            configuration.hrEnabled -> "streamingHr"
            configuration.rawEcgEnabled -> "streamingEcg"
            configuration.accelerometerEnabled -> "streamingAccelerometer"
            else -> "connected"
        }
    }

    private fun ensureBluetoothPermissions() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val scanGranted = ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_SCAN
            ) == PackageManager.PERMISSION_GRANTED
            val connectGranted = ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_CONNECT
            ) == PackageManager.PERMISSION_GRANTED
            if (!scanGranted || !connectGranted) {
                throw SecurityException("Missing Bluetooth scan/connect permission.")
            }
            return
        }

        val locationGranted = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED || ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        if (!locationGranted) {
            throw SecurityException("Missing location permission for Bluetooth scan.")
        }
    }

    private fun matchesPendingConnection(info: PolarDeviceInfo): Boolean {
        val selection = connectionSelection ?: return false
        val identifier = connectionIdentifier
        return matchesSelection(info, selection) ||
            identifier.equals(info.deviceId, ignoreCase = true) ||
            identifier.equals(info.address, ignoreCase = true)
    }

    private fun matchesSelectedDevice(info: PolarDeviceInfo): Boolean {
        val selection = selectedDevice ?: return false
        return matchesSelection(info, selection)
    }

    private fun matchesActiveDevice(info: PolarDeviceInfo): Boolean {
        val activeInfo = activeDeviceInfo
        return activeInfo != null && samePolarDevice(activeInfo, info)
    }

    private fun matchesActiveIdentifier(identifier: String): Boolean {
        val active = activeIdentifier
        val info = activeDeviceInfo
        return active.equals(identifier, ignoreCase = true) ||
            info?.deviceId.equals(identifier, ignoreCase = true) ||
            info?.address.equals(identifier, ignoreCase = true)
    }

    private fun matchesSelection(
        info: PolarDeviceInfo,
        selection: PolarDeviceSelection
    ): Boolean {
        return selection.hasExactIdentityMatch(info) || selection.hasNameMatch(info)
    }

    private fun samePolarDevice(first: PolarDeviceInfo, second: PolarDeviceInfo): Boolean {
        val deviceIdMatches = first.deviceId.isNotBlank() &&
            first.deviceId.equals(second.deviceId, ignoreCase = true)
        val addressMatches = first.address.isNotBlank() &&
            first.address.equals(second.address, ignoreCase = true)
        return deviceIdMatches || addressMatches
    }

    private fun sendConnection(status: String, info: PolarDeviceInfo) {
        sendEvent(
            mapOf(
                "type" to "connection",
                "status" to status,
                "deviceId" to info.deviceId,
                "deviceName" to info.name.ifBlank { activeDisplayName ?: "POLAR_H10" },
                "address" to info.address
            )
        )
    }

    private fun sendStatus(status: String, message: String? = null) {
        sendEvent(
            mapOf(
                "type" to "status",
                "status" to status,
                "deviceId" to activeIdentifier,
                "deviceName" to activeDisplayName,
                "message" to message
            )
        )
    }

    private fun sendError(code: String, message: String) {
        sendEvent(
            mapOf(
                "type" to "error",
                "code" to code,
                "message" to message
            )
        )
    }

    private fun sendEvent(event: Map<String, Any?>) {
        mainHandler.post {
            eventSink?.success(event)
        }
    }

    private fun MethodCall.deviceSelection(): PolarDeviceSelection {
        val rawDevice = argument<Map<String, Any?>>("device")
            ?: throw PolarH10BridgeException(
                "POLAR_H10_INVALID_DEVICE",
                "Polar H10 device identity is missing."
            )
        val deviceId = rawDevice["deviceId"]?.toString().orEmpty()
        val displayName = rawDevice["displayName"]?.toString().orEmpty()
        val polarDeviceId = rawDevice["polarDeviceId"]?.toString()
        val address = rawDevice["address"]?.toString()
        val rssi = (rawDevice["rssi"] as? Number)?.toInt()

        return PolarDeviceSelection(
            deviceId = deviceId,
            displayName = displayName.ifBlank { "POLAR_H10" },
            polarDeviceId = polarDeviceId?.ifBlank { null },
            address = address?.ifBlank { null },
            rssi = rssi
        )
    }

    private fun MethodCall.polarConfiguration(): PolarConfiguration {
        val rawConfiguration = argument<Map<String, Any?>>("configuration")
            ?: throw PolarH10BridgeException(
                "POLAR_H10_INVALID_CONFIGURATION",
                "Polar H10 configuration is missing."
            )
        return PolarConfiguration(
            hrEnabled = rawConfiguration["hrEnabled"] as? Boolean ?: true,
            rawEcgEnabled = rawConfiguration["rawEcgEnabled"] as? Boolean ?: true,
            accelerometerEnabled =
                rawConfiguration["accelerometerEnabled"] as? Boolean ?: false
        )
    }

    private data class PolarConfiguration(
        val hrEnabled: Boolean = false,
        val rawEcgEnabled: Boolean = false,
        val accelerometerEnabled: Boolean = false
    ) {
        val isValid: Boolean
            get() = hrEnabled || rawEcgEnabled || accelerometerEnabled
    }

    private data class AccelerometerStreamSettings(
        val settings: PolarSensorSetting,
        val samplingRateHz: Int
    )

    private data class PolarDeviceSelection(
        val deviceId: String,
        val displayName: String,
        val polarDeviceId: String?,
        val address: String?,
        val rssi: Int?
    ) {
        val preferredIdentifier: String?
            get() = polarDeviceId
                ?: address
                ?: deviceId.takeIf { it.isNotBlank() }

        fun hasExactIdentityMatch(info: PolarDeviceInfo): Boolean {
            return (!polarDeviceId.isNullOrBlank() &&
                polarDeviceId.equals(info.deviceId, ignoreCase = true)) ||
                (!address.isNullOrBlank() &&
                    address.equals(info.address, ignoreCase = true)) ||
                (deviceId.isNotBlank() &&
                    deviceId.equals(info.deviceId, ignoreCase = true)) ||
                (deviceId.isNotBlank() &&
                    deviceId.equals(info.address, ignoreCase = true))
        }

        fun hasNameMatch(info: PolarDeviceInfo): Boolean {
            return looksLikePolarH10(info.name) &&
                normalizeName(info.name) == normalizeName(displayName)
        }
    }

    private class PolarH10BridgeException(
        val code: String,
        override val message: String
    ) : Exception(message)

    companion object {
        private const val CONTROL_CHANNEL = "app_lares/polar_h10_control"
        private const val EVENTS_CHANNEL = "app_lares/polar_h10_events"
        private const val CONNECT_TIMEOUT_MS = 18_000L
        private const val FEATURE_TIMEOUT_MS = 15_000L
        private const val SCAN_TIMEOUT_MS = 10_000L
        private const val ECG_SAMPLE_RATE_HZ = 130

        private fun looksLikePolarH10(name: String?): Boolean {
            val normalized = normalizeName(name.orEmpty())
            return normalized.contains("polar") && normalized.contains("h10")
        }

        private fun normalizeName(value: String): String {
            return value.trim().lowercase(Locale.US)
        }
    }
}
