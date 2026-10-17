import 'dart:typed_data';

/// "END" packet sent by the IMU firmware after the last sample of an
/// acquisition, once STOP has been received and the BLE queue is empty.
///
/// Layout (little-endian, 13 bytes):
/// - [0-2]   "END"
/// - [3-6]   uint32, samples recorded by the IMU since START
/// - [7-10]  uint32, sensor time of the last sample (25 us ticks, low 32 bits)
/// - [11-12] uint16, SD file number (IMU<n>_<num>.TXT), 0 = no SD file
class WearableEndPacket {
  const WearableEndPacket({
    required this.totalSamples,
    required this.lastSampleTicks,
    required this.sdFileNumber,
  });

  final int totalSamples;
  final int lastSampleTicks;
  final int sdFileNumber;

  /// Sensor time of the last sample in milliseconds, rounded like the AG2
  /// sample timestamps.
  int get lastSampleTimestampMs => (lastSampleTicks * 25 + 500) ~/ 1000;
}

class WearableEndPacketParser {
  static const int packetLength = 13;

  static bool startsWithEndHeader(List<int> payload) {
    return payload.length >= 3 &&
        payload[0] == 0x45 &&
        payload[1] == 0x4E &&
        payload[2] == 0x44;
  }

  static WearableEndPacket parse(List<int> payload) {
    if (!startsWithEndHeader(payload)) {
      throw const FormatException('Missing END header.');
    }
    if (payload.length != packetLength) {
      throw FormatException('Invalid END packet length: ${payload.length}.');
    }

    final data = ByteData.sublistView(Uint8List.fromList(payload));
    return WearableEndPacket(
      totalSamples: data.getUint32(3, Endian.little),
      lastSampleTicks: data.getUint32(7, Endian.little),
      sdFileNumber: data.getUint16(11, Endian.little),
    );
  }
}
