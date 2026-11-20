import 'dart:io';

import 'package:app_lares/services/acquisition_event_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('file name follows the data file', () {
    expect(
      AcquisitionEventLog.fileNameFor('Acquisition_data_2026-11-09_15-59-47.csv'),
      'Acquisition_events_2026-11-09_15-59-47.csv',
    );
  });

  test('row format: phone time in ms, separators and quotes escaped', () {
    final row = AcquisitionEventLog.formatRow(
      AcquisitionEvent(
        time: DateTime(2026, 11, 9, 15, 59, 26, 190),
        event: 'LINK_DISCONNECTED',
        deviceName: 'LARES_RESP_V1_03',
        deviceType: 'Respiratory Monitor / IMU',
        details: 'phase: acquisition; reason 19 "remote"\nend',
      ),
    );
    expect(
      row,
      '2026-11-09T15:59:26,190;LARES_RESP_V1_03;Respiratory Monitor / IMU;'
      'LINK_DISCONNECTED;"phase: acquisition; reason 19 ""remote"" end"',
    );
  });

  test('events before open are written to the file, later ones appended',
      () async {
    final directory = await Directory.systemTemp.createTemp('event_log_test');
    addTearDown(() => directory.delete(recursive: true));
    var now = DateTime(2026, 11, 9, 15, 58, 55, 425);
    final log = AcquisitionEventLog(clock: () => now);

    log.add('SCAN_PAGE_OPENED');
    now = now.add(const Duration(milliseconds: 500));
    log.add('CONNECTED', deviceName: 'LARES_ENV_V1_201', details: 'MTU 247');

    final first = File('${directory.path}/Acquisition_events_1.csv');
    await log.open(first);
    now = now.add(const Duration(seconds: 1));
    log.add('INITIALIZATION_STARTED');
    await log.close();
    log.add('STOPPED');

    final lines = await first.readAsLines();
    expect(lines, [
      AcquisitionEventLog.header,
      '2026-11-09T15:58:55,425;;;SCAN_PAGE_OPENED;',
      '2026-11-09T15:58:55,925;LARES_ENV_V1_201;;CONNECTED;MTU 247',
      '2026-11-09T15:58:56,925;;;INITIALIZATION_STARTED;',
    ]);

    // A second file (initialization started again) has the whole history.
    final second = File('${directory.path}/Acquisition_events_2.csv');
    await log.open(second);
    await log.close();
    expect((await second.readAsLines()).length, 1 + 4);
    expect(log.events.last.event, 'STOPPED');
  });

  test('append (acquisition recovered after an app restart) keeps the file',
      () async {
    final directory = await Directory.systemTemp.createTemp('event_log_test');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/Acquisition_events_1.csv');
    await file.writeAsString(
      '${AcquisitionEventLog.header}\n'
      '2026-11-20T10:00:00,000;;;ACQUISITION_STARTED;\n',
    );

    // New process: a new log with only the events after the restart.
    final log = AcquisitionEventLog(
      clock: () => DateTime(2026, 11, 20, 10, 30),
    );
    await log.open(file, append: true);
    log.add('ACQUISITION_RECOVERED');
    await log.close();

    expect(await file.readAsLines(), [
      AcquisitionEventLog.header,
      '2026-11-20T10:00:00,000;;;ACQUISITION_STARTED;',
      '2026-11-20T10:30:00,000;;;ACQUISITION_RECOVERED;',
    ]);
  });
}
