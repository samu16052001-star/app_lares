import 'dart:typed_data';

/// BLE link parameters reported by the IMU.
class WearableLinkStatus {
  const WearableLinkStatus({
    required this.connectionIntervalUnits,
    required this.peripheralLatency,
    required this.supervisionTimeoutUnits,
    required this.txPhy,
    required this.rxPhy,
    required this.txDataLength,
    required this.rxDataLength,
    required this.bleNotifyFailures,
  });

  /// Connection interval in units of 1.25 ms.
  final int connectionIntervalUnits;
  final int peripheralLatency;

  /// Supervision timeout in units of 10 ms.
  final int supervisionTimeoutUnits;

  /// 1 = 1M, 2 = 2M, 4 = Coded (0 = unknown).
  final int txPhy;
  final int rxPhy;

  /// Maximum link-layer payload in bytes (27 without data length extension).
  final int txDataLength;
  final int rxDataLength;

  /// BLE notifications that failed inside the IMU since START.
  final int bleNotifyFailures;

  double get connectionIntervalMs => connectionIntervalUnits * 1.25;

  int get supervisionTimeoutMs => supervisionTimeoutUnits * 10;

  static String phyName(int phy) {
    return switch (phy) {
      1 => '1M',
      2 => '2M',
      4 => 'Coded',
      _ => '?',
    };
  }

  String get summary {
    return 'interval ${connectionIntervalMs.toStringAsFixed(2)} ms, '
        'latency $peripheralLatency, timeout $supervisionTimeoutMs ms, '
        'PHY ${phyName(txPhy)}/${phyName(rxPhy)}, '
        'data length $txDataLength/$rxDataLength, '
        'failed notifications $bleNotifyFailures';
  }
}

class WearableSdsStatus {
  const WearableSdsStatus({
    required this.batteryPercent,
    required this.flushFailureRate,
    this.link,
  });

  final int batteryPercent;
  final int flushFailureRate;

  final WearableLinkStatus? link;
}

/// "SDS" status packet.
///
/// Layout (little-endian):
/// - [0-2]   "SDS"
/// - [3]     battery %
/// - [4-5]   uint16, SD flush failure rate x100
/// Firmware from 17/10/2026 adds (20 bytes in total):
/// - [6-7]   uint16, connection interval (1.25 ms units)
/// - [8-9]   uint16, peripheral latency
/// - [10-11] uint16, supervision timeout (10 ms units)
/// - [12]    TX PHY, [13] RX PHY (1 = 1M, 2 = 2M, 4 = Coded)
/// - [14-15] uint16, TX data length, [16-17] uint16, RX data length
/// - [18-19] uint16, BLE notifications that failed inside the IMU since START
class WearableSdsPacketParser {
  static const int packetLength = 6;
  static const int extendedPacketLength = 20;

  static bool startsWithSdsHeader(List<int> payload) {
    return payload.length >= 3 &&
        payload[0] == 0x53 &&
        payload[1] == 0x44 &&
        payload[2] == 0x53;
  }

  static bool hasValidLength(List<int> payload) {
    return payload.length == packetLength ||
        payload.length == extendedPacketLength;
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

    WearableLinkStatus? link;
    if (payload.length == extendedPacketLength) {
      link = WearableLinkStatus(
        connectionIntervalUnits: data.getUint16(6, Endian.little),
        peripheralLatency: data.getUint16(8, Endian.little),
        supervisionTimeoutUnits: data.getUint16(10, Endian.little),
        txPhy: data.getUint8(12),
        rxPhy: data.getUint8(13),
        txDataLength: data.getUint16(14, Endian.little),
        rxDataLength: data.getUint16(16, Endian.little),
        bleNotifyFailures: data.getUint16(18, Endian.little),
      );
    }

    return WearableSdsStatus(
      batteryPercent: batteryPercent,
      flushFailureRate: data.getUint16(4, Endian.little),
      link: link,
    );
  }
}
