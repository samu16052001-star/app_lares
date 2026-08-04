import 'polar_h10_models.dart';

sealed class PolarH10Event {
  const PolarH10Event();
}

class PolarH10ConnectionStateEvent extends PolarH10Event {
  const PolarH10ConnectionStateEvent({
    required this.status,
    this.deviceId,
    this.deviceName,
    this.address,
    this.message,
  });

  final PolarH10Status status;
  final String? deviceId;
  final String? deviceName;
  final String? address;
  final String? message;
}

class PolarH10HrSampleEvent extends PolarH10Event {
  const PolarH10HrSampleEvent(this.sample);

  final PolarH10HrSample sample;
}

class PolarH10EcgSamplesEvent extends PolarH10Event {
  const PolarH10EcgSamplesEvent(this.samples);

  final List<PolarH10EcgSample> samples;
}

class PolarH10AccelerometerSamplesEvent extends PolarH10Event {
  const PolarH10AccelerometerSamplesEvent({
    required this.samples,
    required this.samplingRateHz,
  });

  final List<PolarH10AccelerometerSample> samples;
  final int samplingRateHz;
}

class PolarH10BatteryLevelEvent extends PolarH10Event {
  const PolarH10BatteryLevelEvent(this.level);

  final int level;
}

class PolarH10ErrorEvent extends PolarH10Event {
  const PolarH10ErrorEvent({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;
}
