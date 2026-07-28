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
