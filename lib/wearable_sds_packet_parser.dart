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

/// State of the IMU's SD card (SDS byte 20).
enum WearableSdState {
  /// File open, writes completing.
  saving,

  /// A write or the opening of the file has been running for more than
  /// 2 s: the SD card is stuck.
  writeStalled,

  /// Recording without a file: nothing is saved.
  noFile,

  /// No SD card, or it could not be mounted.
  noCard,

  /// The last write failed.
  writeError,

  /// Code unknown to this app.
  unknown;

  /// Short name of the state, without the duration.
  String get label {
    return switch (this) {
      WearableSdState.saving => 'SD saving',
      WearableSdState.writeStalled => 'SD stuck',
      WearableSdState.noFile => 'SD not saving (no file)',
      WearableSdState.noCard => 'No SD card',
      WearableSdState.writeError => 'SD write errors',
      WearableSdState.unknown => 'SD state unknown',
    };
  }

  /// The state as the cause of a period without saving ("stuck, then write
  /// errors").
  String get cause {
    return switch (this) {
      WearableSdState.saving => 'saving',
      WearableSdState.writeStalled => 'stuck',
      WearableSdState.noFile => 'no file',
      WearableSdState.noCard => 'no card',
      WearableSdState.writeError => 'write errors',
      WearableSdState.unknown => 'unknown state',
    };
  }

  static WearableSdState fromCode(int code) {
    return switch (code) {
      0 => saving,
      1 => writeStalled,
      2 => noFile,
      3 => noCard,
      4 => writeError,
      _ => unknown,
    };
  }
}

/// SD card health reported by the IMU.
class WearableSdHealth {
  const WearableSdHealth({required this.state, required this.seconds});

  final WearableSdState state;

  /// How long the problem has lasted (writeStalled, noFile, writeError).
  final int seconds;

  bool get isSaving => state == WearableSdState.saving;

  /// Short text for the IMU card, the alert and the event log.
  String get description {
    return switch (state) {
      WearableSdState.writeStalled ||
      WearableSdState.noFile ||
      WearableSdState.writeError =>
        '${state.label} for $seconds s',
      _ => state.label,
    };
  }
}

class WearableSdsStatus {
  const WearableSdsStatus({
    required this.batteryPercent,
    required this.flushFailureRate,
    this.link,
    this.sdHealth,
  });

  final int batteryPercent;

  /// SD writes that failed in the last window, x100 (250 = 2.50%).
  final int flushFailureRate;

  final WearableLinkStatus? link;

  /// SD card state; null with firmware that sends the 20-byte packet.
  final WearableSdHealth? sdHealth;
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
/// Firmware from 12/11/2026 adds (23 bytes in total):
/// - [20]    SD state (WearableSdState: 0 saving, 1 write stuck, 2 no file,
///           3 no card, 4 write errors)
/// - [21-22] uint16, seconds the SD problem has lasted
/// (The 09/11 test firmware sent 24 bytes with the seconds at [22-23]: its
/// seconds are read wrongly, reflash it.)
/// Longer packets are accepted: fields added later are ignored.
class WearableSdsPacketParser {
  static const int packetLength = 6;
  static const int extendedPacketLength = 20;
  static const int sdHealthPacketLength = 23;

  static bool startsWithSdsHeader(List<int> payload) {
    return payload.length >= 3 &&
        payload[0] == 0x53 &&
        payload[1] == 0x44 &&
        payload[2] == 0x53;
  }

  static bool hasValidLength(List<int> payload) {
    return payload.length == packetLength ||
        payload.length >= extendedPacketLength;
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
    if (payload.length >= extendedPacketLength) {
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

    WearableSdHealth? sdHealth;
    if (payload.length >= sdHealthPacketLength) {
      sdHealth = WearableSdHealth(
        state: WearableSdState.fromCode(data.getUint8(20)),
        seconds: data.getUint16(21, Endian.little),
      );
    }

    return WearableSdsStatus(
      batteryPercent: batteryPercent,
      flushFailureRate: data.getUint16(4, Endian.little),
      link: link,
      sdHealth: sdHealth,
    );
  }
}
