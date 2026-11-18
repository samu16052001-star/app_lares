/// Reply of the IMU to the STATUS command:
/// `STATUS:<recording 0/1>,<recordings since power-on>,<uptime s>`.
///
/// The app asks it after a reconnection during an acquisition: recording = 1
/// means that only the link dropped; recording = 0 means that the IMU was
/// switched off and on, so it lost CONFIG and START.
class WearableImuStatus {
  const WearableImuStatus({
    required this.recording,
    required this.recordingsSincePowerOn,
    required this.uptimeSeconds,
  });

  static const String command = 'STATUS';
  static const String _prefix = 'STATUS:';

  final bool recording;
  final int recordingsSincePowerOn;
  final int uptimeSeconds;

  String get summary {
    return 'recording: ${recording ? 'yes' : 'no'}, '
        'recordings since power-on: $recordingsSincePowerOn, '
        'uptime: $uptimeSeconds s';
  }

  /// Null when [text] is not a valid STATUS reply.
  static WearableImuStatus? tryParse(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith(_prefix)) {
      return null;
    }

    final fields = trimmed.substring(_prefix.length).split(',');
    if (fields.length != 3) {
      return null;
    }

    final recording = int.tryParse(fields[0].trim());
    final recordings = int.tryParse(fields[1].trim());
    final uptime = int.tryParse(fields[2].trim());
    if (recording == null ||
        recordings == null ||
        uptime == null ||
        (recording != 0 && recording != 1) ||
        recordings < 0 ||
        uptime < 0) {
      return null;
    }

    return WearableImuStatus(
      recording: recording == 1,
      recordingsSincePowerOn: recordings,
      uptimeSeconds: uptime,
    );
  }
}

/// Result of the magnetometer search, sent by the IMU just before CONFIG_DONE
/// when the CONFIG asks for the magnetometer:
/// `MAG_FOUND:<tries>` or `MAG_NOT_FOUND:<tries>,<reason>[,<WHO_AM_I hex>]`.
///
/// The IMU tries [maxTriesPerConfig] times, resetting the sensor hub between
/// the tries. Reasons: NACK (the LIS2MDL did not answer at its address),
/// TIMEOUT (the sensor hub did not finish), ID (it answered with another
/// WHO_AM_I), CFG (found but its configuration failed), I2C (error on the bus
/// of the microcontroller).
class WearableMagStatus {
  const WearableMagStatus({
    required this.found,
    required this.tries,
    this.reason,
    this.whoAmI,
  });

  static const int maxTriesPerConfig = 3;
  static const String _foundPrefix = 'MAG_FOUND:';
  static const String _notFoundPrefix = 'MAG_NOT_FOUND:';

  final bool found;
  final int tries;

  /// Why the last try failed (NACK, TIMEOUT, ID, CFG, I2C), null when found
  /// at the first try.
  final String? reason;

  /// WHO_AM_I read when [reason] is ID.
  final int? whoAmI;

  String get reasonDescription {
    switch (reason) {
      case 'NACK':
        return 'no answer at its address';
      case 'TIMEOUT':
        return 'the sensor hub did not finish';
      case 'ID':
        final who = whoAmI;
        return who == null
            ? 'wrong WHO_AM_I'
            : 'wrong WHO_AM_I 0x${who.toRadixString(16).padLeft(2, '0').toUpperCase()}';
      case 'CFG':
        return 'its configuration failed';
      case 'I2C':
        return 'I2C error';
      default:
        return reason ?? 'unknown';
    }
  }

  String get summary {
    if (found) {
      return tries > 1
          ? 'Magnetometer found at try $tries'
          : 'Magnetometer found';
    }
    return 'Magnetometer not found after $tries tries ($reasonDescription)';
  }

  /// Null when [text] is not a magnetometer report.
  static WearableMagStatus? tryParse(String text) {
    final trimmed = text.trim();
    if (trimmed.startsWith(_foundPrefix)) {
      final tries = int.tryParse(trimmed.substring(_foundPrefix.length).trim());
      if (tries == null || tries < 1) {
        return null;
      }
      return WearableMagStatus(found: true, tries: tries);
    }
    if (!trimmed.startsWith(_notFoundPrefix)) {
      return null;
    }

    final fields = trimmed.substring(_notFoundPrefix.length).split(',');
    if (fields.length < 2 || fields.length > 3) {
      return null;
    }
    final tries = int.tryParse(fields[0].trim());
    final reason = fields[1].trim();
    if (tries == null || tries < 1 || reason.isEmpty) {
      return null;
    }
    int? whoAmI;
    if (fields.length == 3) {
      whoAmI = int.tryParse(fields[2].trim(), radix: 16);
      if (whoAmI == null) {
        return null;
      }
    }
    return WearableMagStatus(
      found: false,
      tries: tries,
      reason: reason,
      whoAmI: whoAmI,
    );
  }
}

/// The IMU restarted after a firmware fatal error. Sent right after the
/// STATUS reply: `FATAL:<reason>,<exception>,<PC hex>,<thread>`.
///
/// reason = Zephyr K_ERR_* code; exception = Cortex-M exception active
/// when the error happened; PC = address of the instruction (the function is
/// found with addr2line and the zephyr.elf of the same firmware). The same
/// information is in the header of the next SD file ("# Last fatal error").
class WearableFatalReport {
  const WearableFatalReport({
    required this.reason,
    required this.exception,
    required this.programCounter,
    required this.thread,
  });

  static const String _prefix = 'FATAL:';

  final int reason;
  final int exception;
  final int programCounter;
  final String thread;

  String get reasonDescription {
    switch (reason) {
      case 0:
        return 'CPU exception';
      case 1:
        return 'interrupt without a handler';
      case 2:
        return 'stack overflow of a thread';
      case 3:
        return 'k_oops (error detected by the software)';
      case 4:
        return 'k_panic';
      // On the Cortex-M Zephyr gives the precise fault (K_ERR_ARM_*).
      case 19:
        return 'MemManage: forbidden data access';
      case 20:
        return 'MemManage: execution from a forbidden area';
      case 25:
        return 'BusFault: read or write at an invalid address';
      case 26:
        return 'BusFault: write at an invalid address';
      case 27:
        return 'BusFault: instruction from an invalid address';
      case 30:
        return 'UsageFault: division by zero';
      case 31:
        return 'UsageFault: unaligned access';
      case 32:
        return 'UsageFault: stack overflow';
      case 35:
        return 'UsageFault: jump to an invalid address';
      case 36:
        return 'UsageFault: invalid instruction';
      default:
        if (reason >= 16 && reason <= 21) {
          return 'MemManage';
        }
        if (reason >= 22 && reason <= 28) {
          return 'BusFault';
        }
        if (reason >= 29 && reason <= 36) {
          return 'UsageFault';
        }
        return 'reason $reason';
    }
  }

  String get exceptionName {
    switch (exception) {
      case 3:
        return 'HardFault';
      case 4:
        return 'MemManage';
      case 5:
        return 'BusFault';
      case 6:
        return 'UsageFault';
      case 11:
        return 'SVCall';
      default:
        return 'exception $exception';
    }
  }

  String get programCounterHex =>
      '0x${programCounter.toRadixString(16).padLeft(8, '0').toUpperCase()}';

  String get summary {
    return '$reasonDescription ($exceptionName) in thread $thread, '
        'PC $programCounterHex';
  }

  /// Null when [text] is not a fatal error report.
  static WearableFatalReport? tryParse(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith(_prefix)) {
      return null;
    }

    final fields = trimmed.substring(_prefix.length).split(',');
    if (fields.length != 4) {
      return null;
    }
    final reason = int.tryParse(fields[0].trim());
    final exception = int.tryParse(fields[1].trim());
    final programCounter = int.tryParse(fields[2].trim(), radix: 16);
    final thread = fields[3].trim();
    if (reason == null ||
        exception == null ||
        programCounter == null ||
        reason < 0 ||
        exception < 0 ||
        thread.isEmpty) {
      return null;
    }
    return WearableFatalReport(
      reason: reason,
      exception: exception,
      programCounter: programCounter,
      thread: thread,
    );
  }
}
