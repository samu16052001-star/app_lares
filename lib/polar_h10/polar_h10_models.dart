enum PolarH10Status {
  disconnected,
  preparing,
  connected,
  streamingHr,
  streamingEcg,
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
      PolarH10Status.streaming => 'Streaming HR + ECG',
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
    required this.receivedAt,
    required this.ecgMicrovolts,
    this.sdkTimestamp,
  });

  final DateTime receivedAt;
  final int ecgMicrovolts;
  final int? sdkTimestamp;
}
