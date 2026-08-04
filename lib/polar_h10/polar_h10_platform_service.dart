import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'polar_h10_configuration.dart';
import 'polar_h10_event.dart';
import 'polar_h10_models.dart';

class PolarH10PlatformService {
  PolarH10PlatformService._();

  static final PolarH10PlatformService instance = PolarH10PlatformService._();
  static final DateTime _polarTimestampEpochUtc = DateTime.utc(2000);
  static final DateTime _minimumReasonablePolarTimestampUtc =
      DateTime.utc(2020);
  static const Duration _maximumPolarTimestampReceptionSkew = Duration(hours: 12);

  static const MethodChannel _controlChannel =
      MethodChannel('app_lares/polar_h10_control');
  static const EventChannel _eventsChannel =
      EventChannel('app_lares/polar_h10_events');

  Stream<PolarH10Event>? _events;

  Stream<PolarH10Event> get events {
    if (!Platform.isAndroid) {
      return const Stream<PolarH10Event>.empty();
    }

    return _events ??= _eventsChannel.receiveBroadcastStream().map(
          (event) => _parseEvent(Map<Object?, Object?>.from(event as Map)),
        );
  }

  Future<void> prepare({
    required PolarH10DeviceIdentity identity,
    required PolarH10Configuration configuration,
  }) {
    return _invoke('prepare', identity, configuration);
  }

  Future<void> startStreams({
    required PolarH10DeviceIdentity identity,
    required PolarH10Configuration configuration,
  }) {
    return _invoke('startStreams', identity, configuration);
  }

  Future<void> reconnectAndStart({
    required PolarH10DeviceIdentity identity,
    required PolarH10Configuration configuration,
  }) {
    return _invoke('reconnectAndStart', identity, configuration);
  }

  Future<void> stop({
    bool disconnect = true,
  }) async {
    if (!Platform.isAndroid) {
      return;
    }

    await _controlChannel.invokeMethod<void>('stop', {
      'disconnect': disconnect,
    });
  }

  Future<void> foregroundEntered() async {
    if (!Platform.isAndroid) {
      return;
    }

    await _controlChannel.invokeMethod<void>('foregroundEntered');
  }

  Future<void> _invoke(
    String method,
    PolarH10DeviceIdentity identity,
    PolarH10Configuration configuration,
  ) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('Polar H10 acquisition is implemented on Android only.');
    }
    if (!configuration.isValid) {
      throw ArgumentError(
        'Select HR, Raw ECG, or Accelerometer before continuing.',
      );
    }

    await _controlChannel.invokeMethod<void>(method, {
      'device': identity.toJson(),
      'configuration': {
        'hrEnabled': configuration.hrEnabled,
        'rawEcgEnabled': configuration.rawEcgEnabled,
        'accelerometerEnabled': configuration.accelerometerEnabled,
      },
    });
  }

  PolarH10Event _parseEvent(Map<Object?, Object?> raw) {
    final type = raw['type']?.toString();
    return switch (type) {
      'connection' || 'status' => PolarH10ConnectionStateEvent(
          status: _parseStatus(raw['status']?.toString()),
          deviceId: raw['deviceId']?.toString(),
          deviceName: raw['deviceName']?.toString(),
          address: raw['address']?.toString(),
          message: raw['message']?.toString(),
        ),
      'hr' => PolarH10HrSampleEvent(
          PolarH10HrSample(
            receivedAt: _dateTimeFromMillis(raw['receivedAtMillis']),
            hrBpm: _asInt(raw['hrBpm']) ?? 0,
            rrIntervalsMs: _intList(raw['rrIntervalsMs']),
          ),
        ),
      'ecg' => PolarH10EcgSamplesEvent(_parseEcgSamples(raw)),
      'accelerometer' => PolarH10AccelerometerSamplesEvent(
          samples: _parseAccelerometerSamples(raw),
          samplingRateHz:
              (_asInt(raw['samplingRateHz']) ?? 1).clamp(1, 1000).toInt(),
        ),
      'battery' => PolarH10BatteryLevelEvent(_asInt(raw['level']) ?? 0),
      'error' => PolarH10ErrorEvent(
          code: raw['code']?.toString() ?? 'POLAR_H10_ERROR',
          message: raw['message']?.toString() ?? 'Polar H10 error',
        ),
      _ => PolarH10ErrorEvent(
          code: 'POLAR_H10_UNKNOWN_EVENT',
          message: 'Unknown Polar H10 event: $raw',
        ),
    };
  }

  PolarH10Status _parseStatus(String? value) {
    return switch (value) {
      'preparing' => PolarH10Status.preparing,
      'connected' => PolarH10Status.connected,
      'streamingHr' => PolarH10Status.streamingHr,
      'streamingEcg' => PolarH10Status.streamingEcg,
      'streamingAccelerometer' => PolarH10Status.streamingAccelerometer,
      'streaming' => PolarH10Status.streaming,
      'reconnecting' => PolarH10Status.reconnecting,
      'error' => PolarH10Status.error,
      _ => PolarH10Status.disconnected,
    };
  }

  List<PolarH10EcgSample> _parseEcgSamples(Map<Object?, Object?> raw) {
    final rawSamples = raw['samples'];
    if (rawSamples is! List || rawSamples.isEmpty) {
      return const [];
    }

    final receivedAt = _dateTimeFromMillis(raw['receivedAtMillis']);
    final samplingRateHz =
        (_asNum(raw['samplingRateHz']) ?? 130).clamp(1, 1000).toDouble();
    final intervalUs = (Duration.microsecondsPerSecond / samplingRateHz).round();
    final firstDisplaySampleUs =
        receivedAt.microsecondsSinceEpoch - intervalUs * (rawSamples.length - 1);

    return [
      for (var index = 0; index < rawSamples.length; index += 1)
        _parseSingleEcgSample(
          rawSamples[index],
          receivedAt: receivedAt,
          displayTimestamp: DateTime.fromMicrosecondsSinceEpoch(
            firstDisplaySampleUs + intervalUs * index,
          ),
        ),
    ];
  }

  PolarH10EcgSample _parseSingleEcgSample(
    Object? rawSample, {
    required DateTime receivedAt,
    required DateTime displayTimestamp,
  }) {
    final sample = rawSample is Map
        ? Map<Object?, Object?>.from(rawSample)
        : const <Object?, Object?>{};
    final sdkTimestamp = _asInt(sample['sdkTimestamp']);
    final sampleTimestamp = _dateTimeFromPolarSdkTimestamp(
      sdkTimestamp,
      receivedAt: receivedAt,
    );

    return PolarH10EcgSample(
      sampleTimestamp: sampleTimestamp ?? receivedAt,
      receivedAt: receivedAt,
      displayTimestamp: displayTimestamp,
      ecgMicrovolts: _asInt(sample['value']) ?? 0,
      sdkTimestamp: sdkTimestamp,
      timestampFallbackUsed: sampleTimestamp == null,
    );
  }

  List<PolarH10AccelerometerSample> _parseAccelerometerSamples(
    Map<Object?, Object?> raw,
  ) {
    final rawSamples = raw['samples'];
    if (rawSamples is! List || rawSamples.isEmpty) {
      return const [];
    }

    final receivedAt = _dateTimeFromMillis(raw['receivedAtMillis']);
    final samplingRateHz =
        (_asNum(raw['samplingRateHz']) ?? 1).clamp(1, 1000).toDouble();
    final intervalUs = (Duration.microsecondsPerSecond / samplingRateHz).round();
    final firstDisplaySampleUs =
        receivedAt.microsecondsSinceEpoch - intervalUs * (rawSamples.length - 1);

    return [
      for (var index = 0; index < rawSamples.length; index += 1)
        _parseSingleAccelerometerSample(
          rawSamples[index],
          receivedAt: receivedAt,
          displayTimestamp: DateTime.fromMicrosecondsSinceEpoch(
            firstDisplaySampleUs + intervalUs * index,
          ),
        ),
    ];
  }

  PolarH10AccelerometerSample _parseSingleAccelerometerSample(
    Object? rawSample, {
    required DateTime receivedAt,
    required DateTime displayTimestamp,
  }) {
    final sample = rawSample is Map
        ? Map<Object?, Object?>.from(rawSample)
        : const <Object?, Object?>{};
    final sdkTimestamp = _asInt(sample['sdkTimestamp']);
    final sampleTimestamp = _dateTimeFromPolarSdkTimestamp(
      sdkTimestamp,
      receivedAt: receivedAt,
    );

    return PolarH10AccelerometerSample(
      sampleTimestamp: sampleTimestamp ?? receivedAt,
      receivedAt: receivedAt,
      displayTimestamp: displayTimestamp,
      xMilliG: _asInt(sample['x']) ?? 0,
      yMilliG: _asInt(sample['y']) ?? 0,
      zMilliG: _asInt(sample['z']) ?? 0,
      sdkTimestamp: sdkTimestamp,
      timestampFallbackUsed: sampleTimestamp == null,
    );
  }

  DateTime? _dateTimeFromPolarSdkTimestamp(
    int? sdkTimestamp, {
    required DateTime receivedAt,
  }) {
    if (sdkTimestamp == null || sdkTimestamp <= 0) {
      return null;
    }

    // Polar SDK sample timestamps are nanoseconds since the Polar epoch.
    final microsecondsSincePolarEpoch = sdkTimestamp ~/ 1000;
    final candidate = _polarTimestampEpochUtc.add(
      Duration(microseconds: microsecondsSincePolarEpoch),
    );
    if (!_isReasonablePolarSampleTimestamp(candidate, receivedAt)) {
      return null;
    }

    return candidate;
  }

  bool _isReasonablePolarSampleTimestamp(
    DateTime candidate,
    DateTime receivedAt,
  ) {
    if (candidate.isBefore(_minimumReasonablePolarTimestampUtc)) {
      return false;
    }

    final skew = candidate.difference(receivedAt.toUtc()).abs();
    return skew <= _maximumPolarTimestampReceptionSkew;
  }

  DateTime _dateTimeFromMillis(Object? value) {
    final millis = _asInt(value);
    if (millis == null) {
      return DateTime.now();
    }

    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  List<int> _intList(Object? value) {
    if (value is! List) {
      return const [];
    }

    return [
      for (final item in value)
        if (_asInt(item) != null) _asInt(item)!,
    ];
  }

  int? _asInt(Object? value) {
    return switch (value) {
      int() => value,
      num() => value.toInt(),
      String() => int.tryParse(value),
      _ => null,
    };
  }

  num? _asNum(Object? value) {
    return switch (value) {
      num() => value,
      String() => num.tryParse(value),
      _ => null,
    };
  }
}
