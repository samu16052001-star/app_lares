import 'dart:typed_data';

/// "END" packet sent by the IMU firmware after the last sample of an
/// acquisition, once STOP has been received and the BLE queue is empty.
///
/// Layout (little-endian):
/// - [0-2]   "END"
/// - [3-6]   uint32, samples recorded by the IMU since START
/// - [7-10]  uint32, sensor time of the last sample (25 us ticks, low 32 bits)
/// - [11-12] uint16, recording number since power-on with an SD file
///           (1, 2, ...), 0 = no SD file.
/// - [13-14] uint16, BLE notifications that failed inside the IMU (data lost)
/// - [15-16] uint16, samples dropped because the BLE queue was full
/// - [17-18] uint16, samples dropped because the SD queue was full
class WearableEndPacket {
  const WearableEndPacket({
    required this.totalSamples,
    required this.lastSampleTicks,
    required this.sdFileNumber,
    this.bleNotifyFailures,
    this.bleQueueDrops,
    this.sdQueueDrops,
  });

  final int totalSamples;
  final int lastSampleTicks;
  final int sdFileNumber;

  final int? bleNotifyFailures;
  final int? bleQueueDrops;
  final int? sdQueueDrops;

  /// Sensor time of the last sample in milliseconds, rounded like the AG2
  /// sample timestamps.
  int get lastSampleTimestampMs => (lastSampleTicks * 25 + 500) ~/ 1000;
}

class WearableEndPacketParser {
  static const int packetLength = 13;
  static const int extendedPacketLength = 19;

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
    if (payload.length != packetLength &&
        payload.length != extendedPacketLength) {
      throw FormatException('Invalid END packet length: ${payload.length}.');
    }

    final data = ByteData.sublistView(Uint8List.fromList(payload));
    final extended = payload.length == extendedPacketLength;
    return WearableEndPacket(
      totalSamples: data.getUint32(3, Endian.little),
      lastSampleTicks: data.getUint32(7, Endian.little),
      sdFileNumber: data.getUint16(11, Endian.little),
      bleNotifyFailures: extended ? data.getUint16(13, Endian.little) : null,
      bleQueueDrops: extended ? data.getUint16(15, Endian.little) : null,
      sdQueueDrops: extended ? data.getUint16(17, Endian.little) : null,
    );
  }
}
