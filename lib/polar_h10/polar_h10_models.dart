enum PolarH10Status {
  disconnected,
  preparing,
  connected,
  streamingHr,
  streamingEcg,
  streamingAccelerometer,
  streaming,
  reconnecting,
  error,
}

extension PolarH10StatusLabel on PolarH10Status {
  String get label {
    return switch (this) {
      PolarH10Status.disconnected => 'Disconnected',
      PolarH10Status.preparing => 'Preparing',
      PolarH10Status.connected => 'Connected',
      PolarH10Status.streamingHr => 'Streaming HR',
      PolarH10Status.streamingEcg => 'Streaming ECG',
      PolarH10Status.streamingAccelerometer => 'Streaming Accelerometer',
      PolarH10Status.streaming => 'Streaming',
      PolarH10Status.reconnecting => 'Reconnecting',
      PolarH10Status.error => 'Error',
    };
  }
}

class PolarH10DeviceIdentity {
  const PolarH10DeviceIdentity({
    required this.deviceId,
    required this.displayName,
    this.polarDeviceId,
    this.address,
    this.rssi,
  });

  final String deviceId;
  final String displayName;
  final String? polarDeviceId;
  final String? address;
  final int? rssi;

  Map<String, Object?> toJson() {
    return {
      'deviceId': deviceId,
      'displayName': displayName,
      'polarDeviceId': polarDeviceId,
      'address': address,
      'rssi': rssi,
    };
  }
}

class PolarH10HrSample {
  const PolarH10HrSample({
    required this.receivedAt,
    required this.hrBpm,
    this.rrIntervalsMs = const [],
  });

  final DateTime receivedAt;
  final int hrBpm;
  final List<int> rrIntervalsMs;
}

class PolarH10EcgSample {
  const PolarH10EcgSample({
    required this.sampleTimestamp,
    required this.receivedAt,
    required this.displayTimestamp,
    required this.ecgMicrovolts,
    this.sdkTimestamp,
    this.timestampFallbackUsed = false,
  });

  /// Polar SDK/device ECG sample timestamp. Used for CSV logging.
  final DateTime sampleTimestamp;

  /// Phone timestamp when the ECG SDK event/batch was received.
  final DateTime receivedAt;

  /// Phone-based reconstructed timestamp used only for live ECG charting.
  /// This timestamp must not be used for CSV logging.
  final DateTime displayTimestamp;

  final int ecgMicrovolts;
  final int? sdkTimestamp;

  /// True when sampleTimestamp fell back to receivedAt because the Polar
  /// SDK/device timestamp was missing or invalid.
  final bool timestampFallbackUsed;
}

class PolarH10AccelerometerSample {
  const PolarH10AccelerometerSample({
    required this.sampleTimestamp,
    required this.receivedAt,
    required this.displayTimestamp,
    required this.xMilliG,
    required this.yMilliG,
    required this.zMilliG,
    this.sdkTimestamp,
    this.timestampFallbackUsed = false,
  });

  /// Polar SDK/device ACC sample timestamp. Used for CSV logging.
  final DateTime sampleTimestamp;

  /// Phone timestamp when the ACC SDK event/batch was received.
  final DateTime receivedAt;

  /// Phone-based reconstructed timestamp used only for live ACC charting.
  /// This timestamp must not be used for CSV logging.
  final DateTime displayTimestamp;

  final int xMilliG;
  final int yMilliG;
  final int zMilliG;
  final int? sdkTimestamp;

  /// True when sampleTimestamp fell back to receivedAt because the Polar
  /// SDK/device timestamp was missing or invalid.
  final bool timestampFallbackUsed;
}
