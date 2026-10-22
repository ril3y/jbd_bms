// BLE client for JBD / LOSSIGY BMS boards, built on universal_ble
// (iOS, macOS, Windows, Android, Linux).

import 'dart:async';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import 'protocol.dart';

/// Expand 16-bit UUIDs ("ff00") to the full 128-bit form and lowercase.
String _normUuid(String uuid) {
  final u = uuid.toLowerCase();
  return u.length == 4 ? '0000$u-0000-1000-8000-00805f9b34fb' : u;
}

/// Lifetime / identity data used to judge a battery's remaining life.
class BatteryHealth {
  final int cycles;
  final DateTime? productionDate;
  final String? hardwareVersion;
  final String softwareVersion;

  /// Capacity the BMS was configured with (Ah).
  final double? designCapacityAh;

  /// Capacity the BMS has learned / been told is the current full charge (Ah).
  final double? fullChargeCapacityAh;

  /// Lifetime protection-event counters (empty if the BMS didn't answer 0xAA).
  final Map<String, int> protectionCounts;

  const BatteryHealth({
    required this.cycles,
    required this.productionDate,
    required this.hardwareVersion,
    required this.softwareVersion,
    required this.designCapacityAh,
    required this.fullChargeCapacityAh,
    required this.protectionCounts,
  });

  /// Full-charge / design capacity, as a BMS-estimated state of health.
  /// Only meaningful if the BMS actually learns capacity; a real discharge
  /// test is the ground truth.
  double? get stateOfHealth =>
      designCapacityAh != null && fullChargeCapacityAh != null && designCapacityAh! > 0
          ? fullChargeCapacityAh! / designCapacityAh!
          : null;

  int get totalProtectionEvents => protectionCounts.values.fold(0, (a, b) => a + b);
}

class JbdBmsClient {
  final BleDevice device;
  BleCharacteristic? _tx;
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _poll;
  final _assembler = FrameAssembler();

  // Every command goes through this chain so requests never interleave.
  Future<void> _queue = Future.value();

  final _frames = StreamController<Uint8List>.broadcast();
  final _basic = StreamController<BasicInfo>.broadcast();
  final _cells = StreamController<List<double>>.broadcast();
  final _connected = StreamController<bool>.broadcast();

  BasicInfo? lastBasicInfo;

  /// Every complete, checksum-valid frame received.
  Stream<Uint8List> get frames => _frames.stream;
  Stream<BasicInfo> get basicInfo => _basic.stream;
  Stream<List<double>> get cellVoltages => _cells.stream;
  Stream<bool> get connection => _connected.stream;

  JbdBmsClient(this.device);

  /// Start scanning for batteries advertising the FF00 service.
  /// Results arrive on [UniversalBle.scanStream].
  static Future<void> startScan() => UniversalBle.startScan(
        scanFilter: ScanFilter(withServices: [kServiceUuid]),
      );

  static Future<void> stopScan() => UniversalBle.stopScan();

  Future<void> connect() async {
    _subs.add(device.connectionStream.listen((c) {
      _connected.add(c);
      if (!c) _poll?.cancel();
    }));
    await device.connect();

    final services = await device.discoverServices();
    final svc = services.firstWhere((s) => _normUuid(s.uuid) == kServiceUuid);
    final rx = svc.characteristics.firstWhere((c) => _normUuid(c.uuid) == kNotifyUuid);
    _tx = svc.characteristics.firstWhere((c) => _normUuid(c.uuid) == kWriteUuid);

    _subs.add(rx.onValueReceived.listen(_onChunk));
    await rx.notifications.subscribe();
  }

  void _onChunk(List<int> chunk) {
    for (final f in _assembler.add(chunk)) {
      _frames.add(f);
      if (f[2] != 0) continue; // non-OK status
      switch (f[1]) {
        case cmdBasicInfo:
          final info = BasicInfo.parse(f);
          lastBasicInfo = info;
          _basic.add(info);
        case cmdCellVoltages:
          _cells.add(parseCellVoltages(f));
      }
    }
  }

  /// Write a frame in 20-byte chunks, without response (as the stock app does).
  Future<void> _write(List<int> frame) async {
    final tx = _tx;
    if (tx == null) throw StateError('Not connected');
    for (var i = 0; i < frame.length; i += 20) {
      final end = i + 20 < frame.length ? i + 20 : frame.length;
      await tx.write(frame.sublist(i, end), withResponse: false);
    }
  }

  /// Send [frame] and wait for the response whose command byte is [expect]
  /// (defaults to the request's command byte). Requests are serialized.
  Future<Uint8List> request(
    List<int> frame, {
    int? expect,
    Duration timeout = const Duration(seconds: 2),
  }) {
    final want = expect ?? frame[2];
    final result = _queue.then((_) async {
      final response = frames.firstWhere((f) => f[1] == want).timeout(timeout);
      await _write(frame);
      final f = await response;
      if (f[2] != 0) throw StateError('BMS returned status ${f[2]} for 0x${want.toRadixString(16)}');
      return f;
    });
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Same cadence as the stock app: alternate 0x03 / 0x04 every second.
  void startPolling({Duration interval = const Duration(seconds: 1)}) {
    var i = 0;
    _poll?.cancel();
    _poll = Timer.periodic(interval, (_) {
      request(readFrame((i++).isEven ? cmdBasicInfo : cmdCellVoltages)).ignore();
    });
  }

  void stopPolling() => _poll?.cancel();

  Future<BasicInfo> readBasicInfo() async => BasicInfo.parse(await request(readFrame(cmdBasicInfo)));

  Future<List<double>> readCellVoltages() async =>
      parseCellVoltages(await request(readFrame(cmdCellVoltages)));

  Future<String> readHardwareVersion() async =>
      parseHardwareVersion(await request(readFrame(cmdHardwareVersion)));

  Future<Map<String, int>> readProtectionCounts() async =>
      parseProtectionCounts(await request(readFrame(cmdProtectionCounts)));

  Future<Map<int, int>> readParams(int index, int count) async =>
      parseParams(await request(readParamsFrame(index, count)));

  /// Read legacy registers inside factory mode, always exiting afterwards.
  Future<Map<int, int>> readRegisters(List<int> regs) async {
    await request(enterFactoryFrame());
    try {
      return {for (final r in regs) r: parseRegister(await request(readFrame(r)))};
    } finally {
      await request(exitFactoryFrame()).catchError((_) => Uint8List(0));
    }
  }

  /// Gather everything useful for judging remaining battery life.
  /// Optional reads that the BMS doesn't support are left null / empty.
  Future<BatteryHealth> readHealth() async {
    // Some boards ignore the first command after notifications are enabled, so
    // a read right after connecting can time out: retry once, then fall back
    // to the last polled reply.
    BasicInfo info;
    try {
      info = await readBasicInfo();
    } on TimeoutException {
      try {
        info = await readBasicInfo();
      } on TimeoutException {
        final last = lastBasicInfo;
        if (last == null) rethrow;
        info = last;
      }
    }

    String? hw;
    try {
      hw = await readHardwareVersion();
    } catch (_) {}

    Map<String, int> counts = const {};
    try {
      counts = await readProtectionCounts();
    } catch (_) {}

    double? design, full;
    try {
      if (info.newProtocol) {
        design = (await readParams(paramNominalCapacity, 1))[paramNominalCapacity]! / 100;
        full = (await readParams(paramFullChargeCapacity, 1))[paramFullChargeCapacity]! / 100;
      } else {
        final r = await readRegisters([regDesignCapacity, regCycleCapacity]);
        design = r[regDesignCapacity]! / 100;
        full = r[regCycleCapacity]! / 100;
      }
    } catch (_) {
      design ??= info.nominalAh;
    }

    return BatteryHealth(
      cycles: info.cycles,
      productionDate: info.productionDate,
      hardwareVersion: hw,
      softwareVersion: info.softwareVersion,
      designCapacityAh: design,
      fullChargeCapacityAh: full,
      protectionCounts: counts,
    );
  }

  Future<void> disconnect() async {
    _poll?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _tx = null;
    await device.disconnect();
  }
}
