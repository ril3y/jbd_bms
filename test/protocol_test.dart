import 'package:flutter_test/flutter_test.dart';
import 'package:jbd_bms/jbd_bms.dart';

/// Build a response frame the way the BMS does: DD cmd status len data chk 77.
List<int> response(int cmd, List<int> data) {
  final body = [0x00, data.length, ...data];
  return [0xDD, cmd, ...body, ...jbdChecksum(body), 0x77];
}

List<int> u16(int v) => [(v >> 8) & 0xFF, v & 0xFF];

/// 12S pack, 2 NTCs, discharging at 12.34 A.
List<int> basicInfoData() => [
      ...u16(4012), // 40.12 V
      ...u16(0x10000 - 1234), // -12.34 A
      ...u16(7550), // 75.50 Ah remaining
      ...u16(10000), // 100.00 Ah nominal
      ...u16(42), // cycles
      ...u16(((2023 - 2000) << 9) | (5 << 5) | 17), // 2023-05-17
      ...u16(0x0005), // balancing cells 1 and 3
      ...u16(0),
      ...u16(0x0402), // cell UV + short circuit
      0x23, // sw 2.3
      76, // SOC
      0x03, // charge + discharge FETs on
      12, // cells
      2, // NTCs
      ...u16(2731 + 215), // 21.5 C
      ...u16(2731 - 50), // -5.0 C
    ];

void main() {
  group('request frames', () {
    test('match the stock app byte-for-byte', () {
      expect(readFrame(cmdBasicInfo), [0xDD, 0xA5, 0x03, 0x00, 0xFF, 0xFD, 0x77]);
      expect(readFrame(cmdCellVoltages), [0xDD, 0xA5, 0x04, 0x00, 0xFF, 0xFC, 0x77]);
      expect(readFrame(cmdHardwareVersion), [0xDD, 0xA5, 0x05, 0x00, 0xFF, 0xFB, 0x77]);
      expect(buildFrame(kWrite, 0x00, [0x56, 0x78]),
          [0xDD, 0x5A, 0x00, 0x02, 0x56, 0x78, 0xFF, 0x30, 0x77]);
    });
  });

  group('FrameAssembler', () {
    test('reassembles 20-byte chunks and survives 0x77 inside data', () {
      final frame = response(cmdCellVoltages, [...u16(0x0D77), ...List.filled(22, 0x0C)]);
      final a = FrameAssembler();
      final out = <List<int>>[];
      for (var i = 0; i < frame.length; i += 20) {
        out.addAll(a.add(frame.sublist(i, i + 20 > frame.length ? frame.length : i + 20)));
      }
      expect(out, hasLength(1));
      expect(out.single, frame);
    });

    test('drops a frame with a bad checksum and resyncs', () {
      final bad = response(cmdBasicInfo, basicInfoData())..[10] ^= 0xFF;
      final good = response(cmdCellVoltages, u16(3300));
      final out = FrameAssembler().add([0x01, 0x02, ...bad, ...good]);
      expect(out, hasLength(1));
      expect(out.single[1], cmdCellVoltages);
    });
  });

  group('BasicInfo.parse', () {
    final info = BasicInfo.parse(response(cmdBasicInfo, basicInfoData()));

    test('electrical values', () {
      expect(info.voltage, 40.12);
      expect(info.current, -12.34);
      expect(info.remainingAh, 75.5);
      expect(info.nominalAh, 100.0);
      expect(info.soc, 76);
      expect(info.powerW, closeTo(-495.08, 0.01));
      expect(info.hoursRemaining, closeTo(75.5 / 12.34, 1e-9));
    });

    test('status and metadata', () {
      expect(info.cycles, 42);
      expect(info.productionDate, DateTime(2023, 5, 17));
      expect(info.balanceMask, 0x5);
      expect(info.activeProtections, ['Cell under-voltage', 'Short circuit']);
      expect(info.softwareVersion, '2.3');
      expect(info.chargeFetOn, isTrue);
      expect(info.dischargeFetOn, isTrue);
      expect(info.heaterOn, isFalse);
      expect(info.cellCount, 12);
      expect(info.temperaturesC, [21.5, -5.0]);
    });
  });

  test('factory mode and param frames match the stock app', () {
    expect(enterFactoryFrame(), [0xDD, 0x5A, 0x00, 0x02, 0x56, 0x78, 0xFF, 0x30, 0x77]);
    expect(exitFactoryFrame(), [0xDD, 0x5A, 0x01, 0x02, 0x28, 0x28, 0xFF, 0xAD, 0x77]);
    expect(readFrame(cmdProtectionCounts), [0xDD, 0xA5, 0xAA, 0x00, 0xFF, 0x56, 0x77]);
    // Stock app: [221, 165, 250, 3, 0, 34, 4] + checksum
    expect(readParamsFrame(34, 4).sublist(0, 7), [0xDD, 0xA5, 0xFA, 0x03, 0x00, 34, 4]);
  });

  test('newProtocol detection', () {
    expect(BasicInfo.parse(response(cmdBasicInfo, basicInfoData())).newProtocol, isFalse);
    final extended = [...basicInfoData(), 0, 0, 0, 0, 0, 0];
    expect(BasicInfo.parse(response(cmdBasicInfo, extended)).newProtocol, isTrue);
  });

  test('parseProtectionCounts labels known slots and keeps extras', () {
    final f = response(cmdProtectionCounts, [for (var i = 1; i <= 12; i++) ...u16(i)]);
    final c = parseProtectionCounts(f);
    expect(c['Short circuit'], 1);
    expect(c['Pack under-voltage'], 11);
    expect(c['Counter 11'], 12);
    expect(c, hasLength(12));
  });

  test('parseParams and parseRegister', () {
    final f = response(cmdParams, [0x00, 112, 2, ...u16(10000), ...u16(9420)]);
    expect(parseParams(f), {112: 10000, 113: 9420});
    expect(parseRegister(response(regDesignCapacity, u16(10000))), 10000);
  });

  test('parseHardwareVersion', () {
    final f = response(cmdHardwareVersion, 'JBD-SP04S020 '.codeUnits);
    expect(parseHardwareVersion(f), 'JBD-SP04S020');
  });

  test('parseCellVoltages', () {
    final f = response(cmdCellVoltages, [...u16(3301), ...u16(3299), ...u16(3650)]);
    expect(parseCellVoltages(f), [3.301, 3.299, 3.65]);
  });
}
