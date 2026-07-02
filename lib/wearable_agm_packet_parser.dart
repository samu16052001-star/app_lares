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

  static bool startsWithAgmHeader(List<int> payload) {
    return payload.length >= 3 &&
        payload[0] == 0x41 &&
        payload[1] == 0x47 &&
        payload[2] == 0x4D;
  }

  static bool hasValidLength(List<int> payload) {
    return payload.length == packetLength;
  }

  static WearableAgmSample parse(List<int> payload) {
    if (!startsWithAgmHeader(payload)) {
      throw const FormatException('Missing AGM header.');
    }
    if (!hasValidLength(payload)) {
      throw FormatException('Invalid AGM packet length: ${payload.length}.');
    }

    final bytes = Uint8List.fromList(payload);
    final data = ByteData.sublistView(bytes);

    return WearableAgmSample(
      timestampMs: data.getUint32(3, Endian.little),
      accX: data.getFloat32(7, Endian.little),
      accY: data.getFloat32(11, Endian.little),
      accZ: data.getFloat32(15, Endian.little),
      gyrX: data.getFloat32(19, Endian.little),
      gyrY: data.getFloat32(23, Endian.little),
      gyrZ: data.getFloat32(27, Endian.little),
      magX: data.getFloat32(31, Endian.little),
      magY: data.getFloat32(35, Endian.little),
      magZ: data.getFloat32(39, Endian.little),
    );
  }
}
