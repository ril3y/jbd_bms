import 'package:flutter_test/flutter_test.dart';
import 'package:jbd_bms/jbd_bms.dart';

final t0 = DateTime(2026, 1, 1, 12);

BmsSample s(int sec, double current, {int soc = 50, int cycles = 10, int prot = 0, double? cmin, double? cmax}) =>
    BmsSample(
      time: t0.add(Duration(seconds: sec)),
      voltage: 40,
      current: current,
      soc: soc,
      remainingAh: 50,
      cycles: cycles,
      protectionMask: prot,
      minCellV: cmin,
      maxCellV: cmax,
      maxTempC: 25,
    );

void main() {
  group('SessionTracker', () {
    test('a 1 h 20 A discharge followed by rest closes one session', () {
      final tr = SessionTracker();
      final closed = <PowerSession>[];
      for (var i = 0; i <= 3600; i += 10) {
        closed.addAll([tr.add(s(i, -20, soc: 80 - i ~/ 180))].whereType<PowerSession>());
      }
      for (var i = 3610; i <= 3610 + 180; i += 10) {
        closed.addAll([tr.add(s(i, 0))].whereType<PowerSession>());
      }
      expect(closed, hasLength(1));
      final x = closed.single;
      expect(x.kind, SessionKind.discharge);
      expect(x.ah, closeTo(20, 0.1));
      expect(x.wh, closeTo(800, 5));
      expect(x.startSoc, 80);
      expect(x.peakCurrentA, 20);
      expect(x.duration, const Duration(hours: 1));
    });

    test('reversal closes the session and opens the opposite one', () {
      final tr = SessionTracker();
      for (var i = 0; i <= 600; i += 10) {
        tr.add(s(i, -10));
      }
      final closed = tr.add(s(610, 15));
      expect(closed?.kind, SessionKind.discharge);
      expect(tr.current?.kind, SessionKind.charge);
    });

    test('blips under a minute are ignored', () {
      final tr = SessionTracker();
      tr.add(s(0, -30));
      tr.add(s(20, -30));
      expect(tr.flush(), isNull);
    });

    test('a long gap ends the session without integrating across it', () {
      final tr = SessionTracker();
      for (var i = 0; i <= 600; i += 10) {
        tr.add(s(i, -10));
      }
      final closed = tr.add(s(600 + 3600, -10));
      expect(closed, isNotNull);
      expect(closed!.ah, closeTo(10 * 600 / 3600, 0.01));
    });

    test('tracks worst cell spread', () {
      final tr = SessionTracker();
      tr.add(s(0, -10, cmin: 3.30, cmax: 3.31));
      tr.add(s(60, -10, cmin: 3.20, cmax: 3.26));
      tr.add(s(120, -10, cmin: 3.25, cmax: 3.27));
      expect(tr.flush()!.maxSpreadMv, closeTo(60, 1e-6));
    });
  });

  group('EventDetector', () {
    test('cycle increments and protection flags', () {
      final d = EventDetector();
      expect(d.onSample(s(0, 0, cycles: 10)), isEmpty);
      final e = d.onSample(s(10, 0, cycles: 11, prot: 1 << 1));
      expect(e.map((x) => x.kind), [BmsEventKind.cycle, BmsEventKind.protectionActive]);
      expect(e[1].label, 'Cell under-voltage');
      final c = d.onSample(s(20, 0, cycles: 11));
      expect(c.single.kind, BmsEventKind.protectionCleared);
    });

    test('protection counter deltas become events; seeded totals are not re-reported', () {
      BatteryHealth h(Map<String, int> c) => BatteryHealth(
            cycles: 1,
            productionDate: null,
            hardwareVersion: null,
            softwareVersion: '1.0',
            designCapacityAh: 100,
            fullChargeCapacityAh: 100,
            protectionCounts: c,
          );
      final d = EventDetector(protectionCounts: {'Short circuit': 2});
      expect(d.onHealth(h({'Short circuit': 2})), isEmpty);
      final e = d.onHealth(h({'Short circuit': 4, 'Cell under-voltage': 1}));
      expect(e.map((x) => '${x.label}:${x.count}'), ['Short circuit:2', 'Cell under-voltage:1']);
    });
  });

  test('JSON round-trips', () {
    final sample = s(5, -3.5, cmin: 3.2, cmax: 3.3, prot: 4);
    expect(BmsSample.fromJson(sample.toJson()).toJson(), sample.toJson());
    final tr = SessionTracker()..add(s(0, 5))..add(s(120, 5));
    final sess = tr.flush()!;
    expect(PowerSession.fromJson(sess.toJson()).toJson(), sess.toJson());
    final ev = BmsEvent(t0, BmsEventKind.cycle, 'Cycle 3 completed');
    expect(BmsEvent.fromJson(ev.toJson()).toJson(), ev.toJson());
  });
}
