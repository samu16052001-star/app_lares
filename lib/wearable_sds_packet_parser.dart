import 'dart:typed_data';

class WearableSdsStatus {
  const WearableSdsStatus({
    required this.batteryPercent,
    required this.flushFailureRate,
  });

  final int batteryPercent;
  final int flushFailureRate;
}

class WearableSdsPacketParser {
  static const int packetLength = 6;

  static bool startsWithSdsHeader(List<int> payload) {
    return payload.length >= 3 &&
        payload[0] == 0x53 &&
        payload[1] == 0x44 &&
        payload[2] == 0x53;
  }

  static bool hasValidLength(List<int> payload) {
    return payload.length == packetLength;
  }

  static WearableSdsStatus parse(List<int> payload) {
    if (!startsWithSdsHeader(payload)) {
      throw const FormatException('Missing SDS header.');
    }
    if (!hasValidLength(payload)) {
      throw FormatException('Invalid SDS packet length: ${payload.length}.');
    }

    final bytes = Uint8List.fromList(payload);
    final data = ByteData.sublistView(bytes);
    final batteryPercent = data.getUint8(3);
    if (batteryPercent > 100) {
      throw FormatException('Invalid SDS battery value: $batteryPercent.');
    }

    return WearableSdsStatus(
      batteryPercent: batteryPercent,
      flushFailureRate: data.getUint16(4, Endian.little),
    );
  }
}
