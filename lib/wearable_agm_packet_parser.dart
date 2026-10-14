import 'dart:typed_data';

class WearableAgmSample {
  const WearableAgmSample({
    required this.timestampMs,
    required this.accX,
    required this.accY,
    required this.accZ,
    required this.gyrX,
    required this.gyrY,
    required this.gyrZ,
    required this.magX,
    required this.magY,
    required this.magZ,
  });

  final int timestampMs;
  final double accX;
  final double accY;
  final double accZ;
  final double gyrX;
  final double gyrY;
  final double gyrZ;
  final double magX;
  final double magY;
  final double magZ;
}

class WearableAgmPacketParser {
  static const int packetLength = 43;
  static const int maxSamplesPerBatch = 5;
  static const Set<int> validBatchLengths = {
    packetLength,
    packetLength * 2,
    packetLength * 3,
    packetLength * 4,
    packetLength * maxSamplesPerBatch,
  };

  static bool startsWithAgmHeader(List<int> payload) {
    return payload.length >= 3 &&
        payload[0] == 0x41 &&
        payload[1] == 0x47 &&
        payload[2] == 0x4D;
  }

  static bool hasValidLength(List<int> payload) {
    return validBatchLengths.contains(payload.length);
  }

  static WearableAgmSample parse(List<int> payload) {
    if (payload.length != packetLength) {
      throw FormatException('Invalid AGM packet length: ${payload.length}.');
    }

    return parseBatch(payload).single;
  }

  static List<WearableAgmSample> parseBatch(List<int> payload) {
    if (!hasValidLength(payload)) {
      throw FormatException('Invalid AGM batch length: ${payload.length}.');
    }

    final sampleCount = payload.length ~/ packetLength;
    for (var index = 0; index < sampleCount; index += 1) {
      final offset = index * packetLength;
      if (!_startsWithAgmHeaderAt(payload, offset)) {
        throw FormatException('Missing AGM header at block $index.');
      }
    }

    final bytes = Uint8List.fromList(payload);
    final data = ByteData.sublistView(bytes);
    final samples = <WearableAgmSample>[];

    for (var index = 0; index < sampleCount; index += 1) {
      samples.add(_parseSample(data, index * packetLength));
    }

    return List.unmodifiable(samples);
  }

  static bool _startsWithAgmHeaderAt(List<int> payload, int offset) {
    return payload.length >= offset + 3 &&
        payload[offset] == 0x41 &&
        payload[offset + 1] == 0x47 &&
        payload[offset + 2] == 0x4D;
  }

  static WearableAgmSample _parseSample(ByteData data, int offset) {
    return WearableAgmSample(
      timestampMs: data.getUint32(offset + 3, Endian.little),
      accX: data.getFloat32(offset + 7, Endian.little),
      accY: data.getFloat32(offset + 11, Endian.little),
      accZ: data.getFloat32(offset + 15, Endian.little),
      gyrX: data.getFloat32(offset + 19, Endian.little),
      gyrY: data.getFloat32(offset + 23, Endian.little),
      gyrZ: data.getFloat32(offset + 27, Endian.little),
      magX: data.getFloat32(offset + 31, Endian.little),
      magY: data.getFloat32(offset + 35, Endian.little),
      magZ: data.getFloat32(offset + 39, Endian.little),
    );
  }
}

/// Compact "AG2" IMU packet (RespirHo firmware, October 2026).
///
/// Header, once per notification (12 bytes, little-endian):
///   [0-2]   "AG2"
///   [3]     packet counter (uint8), restarts from 0 at every START
///   [4]     n = number of samples in this notification
///   [5]     full scale: bits 0-1 accelerometer (0=2 g, 1=4 g, 2=8 g, 3=16 g),
///           bits 2-4 gyroscope (0=125, 1=250, 2=500, 3=1000, 4=2000 dps)
///   [6-9]   t0 = sensor hardware timestamp of the first sample (25 us ticks)
///   [10-11] dt = ticks between two consecutive samples (384 = 9.6 ms @ 104 Hz)
/// Then n samples of 12 bytes: ax, ay, az, gx, gy, gz as int16 sensor LSB with
/// the calibration bias already removed by the firmware.
///
/// The samples of one notification are always consecutive, so sample i was
/// taken at t0 + i * dt.
class WearableAg2Packet {
  const WearableAg2Packet({
    required this.packetCounter,
    required this.fullScaleCode,
    required this.firstTicks,
    required this.stepTicks,
    required this.samples,
  });

  final int packetCounter;
  final int fullScaleCode;
  final int firstTicks;
  final int stepTicks;
  final List<WearableAgmSample> samples;

  /// Sensor ticks (32-bit) expected for the first sample of the next packet.
  int get nextTicks => (firstTicks + samples.length * stepTicks) & 0xFFFFFFFF;
}

class WearableAg2PacketParser {
  static const int headerLength = 12;
  static const int sampleLength = 12;

  /// 12 + 19 * 12 = 240 bytes, the largest packet that fits in MTU 247.
  static const int maxSamplesPerPacket = 19;

  static const List<double> _accMilliGPerLsb = [0.061, 0.122, 0.244, 0.488];
  static const List<double> _gyrMilliDpsPerLsb = [4.375, 8.75, 17.5, 35.0, 70.0];

  static bool startsWithAg2Header(List<int> payload) {
    return payload.length >= 3 &&
        payload[0] == 0x41 &&
        payload[1] == 0x47 &&
        payload[2] == 0x32;
  }

  static List<WearableAgmSample> parse(List<int> payload) {
    return parsePacket(payload).samples;
  }

  static WearableAg2Packet parsePacket(List<int> payload) {
    if (!startsWithAg2Header(payload)) {
      throw const FormatException('Missing AG2 header.');
    }
    if (payload.length < headerLength + sampleLength) {
      throw FormatException('Invalid AG2 packet length: ${payload.length}.');
    }

    final bytes = Uint8List.fromList(payload);
    final data = ByteData.sublistView(bytes);
    final count = data.getUint8(4);
    if (count < 1 ||
        count > maxSamplesPerPacket ||
        payload.length != headerLength + count * sampleLength) {
      throw FormatException(
        'Invalid AG2 packet length: ${payload.length} bytes for $count samples.',
      );
    }

    final fullScaleCode = data.getUint8(5);
    final accIndex = fullScaleCode & 0x03;
    final gyrIndex = (fullScaleCode >> 2) & 0x07;
    if (gyrIndex >= _gyrMilliDpsPerLsb.length) {
      throw FormatException('Invalid AG2 gyroscope full-scale code: $gyrIndex.');
    }
    final gPerLsb = _accMilliGPerLsb[accIndex] / 1000.0;
    final dpsPerLsb = _gyrMilliDpsPerLsb[gyrIndex] / 1000.0;

    final firstTicks = data.getUint32(6, Endian.little);
    final stepTicks = data.getUint16(10, Endian.little);

    final samples = <WearableAgmSample>[];
    for (var index = 0; index < count; index += 1) {
      final offset = headerLength + index * sampleLength;
      final ticks = firstTicks + index * stepTicks;
      samples.add(
        WearableAgmSample(
          // 25 us ticks -> milliseconds, rounded like the AGM timestamp.
          timestampMs: (ticks * 25 + 500) ~/ 1000,
          accX: data.getInt16(offset, Endian.little) * gPerLsb,
          accY: data.getInt16(offset + 2, Endian.little) * gPerLsb,
          accZ: data.getInt16(offset + 4, Endian.little) * gPerLsb,
          gyrX: data.getInt16(offset + 6, Endian.little) * dpsPerLsb,
          gyrY: data.getInt16(offset + 8, Endian.little) * dpsPerLsb,
          gyrZ: data.getInt16(offset + 10, Endian.little) * dpsPerLsb,
          magX: 0,
          magY: 0,
          magZ: 0,
        ),
      );
    }

    return WearableAg2Packet(
      packetCounter: data.getUint8(3),
      fullScaleCode: fullScaleCode,
      firstTicks: firstTicks,
      stepTicks: stepTicks,
      samples: List.unmodifiable(samples),
    );
  }
}
