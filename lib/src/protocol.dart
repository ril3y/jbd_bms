// JBD / LOSSIGY BMS protocol: frame building, reassembly and parsing.
// Pure Dart (no Flutter deps) so it can be unit-tested. See PROTOCOL.md at the repo root.

import 'dart:typed_data';

const String kServiceUuid = '0000ff00-0000-1000-8000-00805f9b34fb';
const String kNotifyUuid = '0000ff01-0000-1000-8000-00805f9b34fb';
const String kWriteUuid = '0000ff02-0000-1000-8000-00805f9b34fb';

const int kStart = 0xDD;
const int kEnd = 0x77;
const int kRead = 0xA5;
const int kWrite = 0x5A;

const int cmdEnterFactory = 0x00;
const int cmdExitFactory = 0x01;
const int cmdBasicInfo = 0x03;
const int cmdCellVoltages = 0x04;
const int cmdHardwareVersion = 0x05;
const int cmdProtectionCounts = 0xAA;
const int cmdParams = 0xFA;

/// Legacy (pre-0xFA) EEPROM registers, readable only in factory mode.
const int regDesignCapacity = 0x10;
const int regCycleCapacity = 0x11;
const int regCycleCount = 0x17;

/// 0xFA parameter indexes (newer firmware), as used by the stock app.
const int paramNominalCapacity = 0;
const int paramFullChargeCapacity = 112;

/// Checksum over [bytes] (cmd/status, len, data): two's complement of the sum, big-endian.
List<int> jbdChecksum(List<int> bytes) {
  final sum = bytes.fold<int>(0, (a, b) => a + (b & 0xFF));
  final c = (0x10000 - sum) & 0xFFFF;
  return [c >> 8, c & 0xFF];
}

/// Build a request frame, e.g. readFrame(cmdBasicInfo) -> DD A5 03 00 FF FD 77.
Uint8List buildFrame(int op, int cmd, [List<int> data = const []]) {
  final body = [cmd, data.length, ...data];
  return Uint8List.fromList([kStart, op, ...body, ...jbdChecksum(body), kEnd]);
}

Uint8List readFrame(int cmd) => buildFrame(kRead, cmd);

/// Factory mode is needed for legacy register reads. Bytes match the stock app.
Uint8List enterFactoryFrame() => buildFrame(kWrite, cmdEnterFactory, [0x56, 0x78]);
Uint8List exitFactoryFrame() => buildFrame(kWrite, cmdExitFactory, [0x28, 0x28]);

/// Read [count] 16-bit parameters starting at [index] (newer firmware).
Uint8List readParamsFrame(int index, int count) =>
    buildFrame(kRead, cmdParams, [0x00, index, count]);

/// Reassembles BLE notification chunks (≤20 bytes) into complete frames using the length byte.
class FrameAssembler {
  final List<int> _buf = [];

  /// Feed one notification; returns any complete, checksum-valid frames.
  List<Uint8List> add(List<int> chunk) {
    _buf.addAll(chunk);
    final out = <Uint8List>[];
    while (true) {
      final start = _buf.indexOf(kStart);
      if (start < 0) {
        _buf.clear();
        break;
      }
      if (start > 0) _buf.removeRange(0, start);
      if (_buf.length < 4) break;
      final total = _buf[3] + 7;
      if (_buf.length < total) break;
      final frame = _buf.sublist(0, total);
      if (frame.last == kEnd && _checksumOk(frame)) {
        out.add(Uint8List.fromList(frame));
        _buf.removeRange(0, total);
      } else {
        _buf.removeAt(0); // resync on next 0xDD
      }
    }
    return out;
  }

  static bool _checksumOk(List<int> f) {
    final len = f[3];
    final c = jbdChecksum(f.sublist(2, 4 + len));
    return f[4 + len] == c[0] && f[5 + len] == c[1];
  }
}

int _u16(List<int> b, int i) => (b[i] << 8) | b[i + 1];
int _s16(List<int> b, int i) {
  final v = _u16(b, i);
  return v >= 0x8000 ? v - 0x10000 : v;
}

const List<String> kProtectionLabels = [
  'Cell over-voltage', 'Cell under-voltage', 'Pack over-voltage', 'Pack under-voltage',
  'Charge over-temp', 'Charge under-temp', 'Discharge over-temp', 'Discharge under-temp',
  'Charge over-current', 'Discharge over-current', 'Short circuit', 'Front-end IC error',
  'MOS software lock',
];

class BasicInfo {
  final double voltage; // V
  final double current; // A, + charging / - discharging
  final double remainingAh;
  final double nominalAh;
  final int cycles;
  final DateTime? productionDate;
  final int balanceMask; // bit n = cell n+1 balancing (cells 1-32)
  final int protectionMask;
  final String softwareVersion;
  final int soc; // %
  final bool chargeFetOn;
  final bool dischargeFetOn;
  final bool heaterOn;
  final int cellCount;
  final List<double> temperaturesC;

  /// Newer firmware appends extra bytes after the NTCs and supports 0xFA
  /// parameter reads; older firmware needs factory-mode register reads.
  final bool newProtocol;

  BasicInfo._({
    required this.newProtocol,
    required this.voltage,
    required this.current,
    required this.remainingAh,
    required this.nominalAh,
    required this.cycles,
    required this.productionDate,
    required this.balanceMask,
    required this.protectionMask,
    required this.softwareVersion,
    required this.soc,
    required this.chargeFetOn,
    required this.dischargeFetOn,
    required this.heaterOn,
    required this.cellCount,
    required this.temperaturesC,
  });

  double get powerW => voltage * current;

  List<String> get activeProtections => [
        for (var i = 0; i < 16; i++)
          if (protectionMask & (1 << i) != 0)
            i < kProtectionLabels.length ? kProtectionLabels[i] : 'Unknown bit $i',
      ];

  /// Hours to full (charging) or empty (discharging); null when idle.
  double? get hoursRemaining {
    if (current > 0) return (nominalAh - remainingAh) / current;
    if (current < 0) return remainingAh / -current;
    return null;
  }

  /// [f] is a full validated frame with f[1] == 0x03.
  factory BasicInfo.parse(List<int> f) {
    final ntc = f[26];
    final date = _u16(f, 14);
    final ver = f[22];
    return BasicInfo._(
      newProtocol: f[3] > 22 + ntc * 2 + 5,
      voltage: _u16(f, 4) / 100,
      current: _s16(f, 6) / 100,
      remainingAh: _u16(f, 8) / 100,
      nominalAh: _u16(f, 10) / 100,
      cycles: _u16(f, 12),
      productionDate: date == 0
          ? null
          : DateTime(2000 + (date >> 9), (date >> 5) & 0x0F, date & 0x1F),
      balanceMask: _u16(f, 16) | (_u16(f, 18) << 16),
      protectionMask: _u16(f, 20),
      softwareVersion: '${ver >> 4}.${ver & 0x0F}',
      soc: f[23],
      chargeFetOn: f[24] & 0x01 != 0,
      dischargeFetOn: f[24] & 0x02 != 0,
      heaterOn: f[24] & 0x08 != 0,
      cellCount: f[25],
      temperaturesC: [
        for (var i = 0; i < ntc; i++) (_u16(f, 27 + i * 2) - 2731) / 10,
      ],
    );
  }
}

/// [f] is a full validated frame with f[1] == 0x04. Returns volts per cell.
List<double> parseCellVoltages(List<int> f) {
  final len = f[3];
  return [for (var i = 4; i < 4 + len; i += 2) _u16(f, i) / 1000];
}

/// 0x05 response: ASCII hardware/BMS version string.
String parseHardwareVersion(List<int> f) =>
    String.fromCharCodes(f.sublist(4, 4 + f[3])).trim();

/// Labels for the 0xAA counters, in order. This is the standard JBD layout;
/// the stock LOSSIGY app reads 0xAA but never labels it, so verify on hardware.
const List<String> kProtectionCountLabels = [
  'Short circuit', 'Charge over-current', 'Discharge over-current',
  'Cell over-voltage', 'Cell under-voltage', 'Charge over-temp',
  'Charge under-temp', 'Discharge over-temp', 'Discharge under-temp',
  'Pack over-voltage', 'Pack under-voltage',
];

/// 0xAA response: lifetime protection-event counters (u16 each).
/// Keys beyond the known labels are reported as "Counter n".
Map<String, int> parseProtectionCounts(List<int> f) {
  final len = f[3];
  return {
    for (var i = 0; i * 2 + 1 < len; i++)
      (i < kProtectionCountLabels.length ? kProtectionCountLabels[i] : 'Counter $i'):
          _u16(f, 4 + i * 2),
  };
}

/// 0xFA response: `DD FA 00 len 00 index count words... chk 77`.
/// Returns the 16-bit words keyed by parameter index.
Map<int, int> parseParams(List<int> f) {
  final index = f[5];
  final count = f[6];
  return {for (var i = 0; i < count; i++) index + i: _u16(f, 7 + i * 2)};
}

/// Legacy register read response: `DD reg 00 02 hi lo chk 77`.
int parseRegister(List<int> f) => _u16(f, 4);
