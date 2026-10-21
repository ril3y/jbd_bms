// History building blocks. JBD boards keep no event log or charge history,
// only lifetime totals (cycle count, protection counters). These classes let
// an app build its own history from live samples. Pure Dart, storage-agnostic.

import 'client.dart';
import 'protocol.dart';

/// One point-in-time reading, compact enough to log every few seconds.
class BmsSample {
  final DateTime time;
  final double voltage;
  final double current;
  final int soc;
  final double remainingAh;
  final int cycles;
  final double? maxTempC;
  final double? minCellV;
  final double? maxCellV;
  final int protectionMask;

  const BmsSample({
    required this.time,
    required this.voltage,
    required this.current,
    required this.soc,
    required this.remainingAh,
    required this.cycles,
    this.maxTempC,
    this.minCellV,
    this.maxCellV,
    this.protectionMask = 0,
  });

  factory BmsSample.from(BasicInfo info, {List<double>? cells, DateTime? time}) => BmsSample(
        time: time ?? DateTime.now(),
        voltage: info.voltage,
        current: info.current,
        soc: info.soc,
        remainingAh: info.remainingAh,
        cycles: info.cycles,
        maxTempC: info.temperaturesC.isEmpty ? null : info.temperaturesC.reduce((a, b) => a > b ? a : b),
        minCellV: cells == null || cells.isEmpty ? null : cells.reduce((a, b) => a < b ? a : b),
        maxCellV: cells == null || cells.isEmpty ? null : cells.reduce((a, b) => a > b ? a : b),
        protectionMask: info.protectionMask,
      );

  double get powerW => voltage * current;

  /// Cell spread (max - min) in mV, if cell data was available.
  double? get spreadMv => minCellV == null || maxCellV == null ? null : (maxCellV! - minCellV!) * 1000;

  Map<String, dynamic> toJson() => {
        't': time.millisecondsSinceEpoch,
        'v': voltage,
        'i': current,
        'soc': soc,
        'ah': remainingAh,
        'cyc': cycles,
        if (maxTempC != null) 'tmax': maxTempC,
        if (minCellV != null) 'cmin': minCellV,
        if (maxCellV != null) 'cmax': maxCellV,
        if (protectionMask != 0) 'prot': protectionMask,
      };

  factory BmsSample.fromJson(Map<String, dynamic> j) => BmsSample(
        time: DateTime.fromMillisecondsSinceEpoch(j['t'] as int),
        voltage: (j['v'] as num).toDouble(),
        current: (j['i'] as num).toDouble(),
        soc: j['soc'] as int,
        remainingAh: (j['ah'] as num).toDouble(),
        cycles: j['cyc'] as int,
        maxTempC: (j['tmax'] as num?)?.toDouble(),
        minCellV: (j['cmin'] as num?)?.toDouble(),
        maxCellV: (j['cmax'] as num?)?.toDouble(),
        protectionMask: (j['prot'] as int?) ?? 0,
      );
}

enum SessionKind { charge, discharge }

/// A continuous charge or discharge period.
class PowerSession {
  final SessionKind kind;
  final DateTime start;
  final DateTime end;
  final int startSoc;
  final int endSoc;
  final double ah; // always positive
  final double wh; // always positive
  final double peakCurrentA; // always positive
  final double? maxTempC;
  final double? maxSpreadMv;
  final double? minCellV;
  final double? maxCellV;

  const PowerSession({
    required this.kind,
    required this.start,
    required this.end,
    required this.startSoc,
    required this.endSoc,
    required this.ah,
    required this.wh,
    required this.peakCurrentA,
    this.maxTempC,
    this.maxSpreadMv,
    this.minCellV,
    this.maxCellV,
  });

  Duration get duration => end.difference(start);
  double get averageCurrentA => duration.inSeconds == 0 ? 0 : ah / (duration.inSeconds / 3600);

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'start': start.millisecondsSinceEpoch,
        'end': end.millisecondsSinceEpoch,
        'soc0': startSoc,
        'soc1': endSoc,
        'ah': ah,
        'wh': wh,
        'peak': peakCurrentA,
        if (maxTempC != null) 'tmax': maxTempC,
        if (maxSpreadMv != null) 'spread': maxSpreadMv,
        if (minCellV != null) 'cmin': minCellV,
        if (maxCellV != null) 'cmax': maxCellV,
      };

  factory PowerSession.fromJson(Map<String, dynamic> j) => PowerSession(
        kind: SessionKind.values.byName(j['kind'] as String),
        start: DateTime.fromMillisecondsSinceEpoch(j['start'] as int),
        end: DateTime.fromMillisecondsSinceEpoch(j['end'] as int),
        startSoc: j['soc0'] as int,
        endSoc: j['soc1'] as int,
        ah: (j['ah'] as num).toDouble(),
        wh: (j['wh'] as num).toDouble(),
        peakCurrentA: (j['peak'] as num).toDouble(),
        maxTempC: (j['tmax'] as num?)?.toDouble(),
        maxSpreadMv: (j['spread'] as num?)?.toDouble(),
        minCellV: (j['cmin'] as num?)?.toDouble(),
        maxCellV: (j['cmax'] as num?)?.toDouble(),
      );
}

/// Turns a stream of samples into charge/discharge sessions.
///
/// A session starts when |current| exceeds [threshold] in one direction and
/// ends after the current has been below it (or reversed) for [settle], or
/// when samples stop arriving for longer than [maxGap].
class SessionTracker {
  final double threshold;
  final Duration settle;
  final Duration maxGap;

  SessionTracker({
    this.threshold = 0.5,
    this.settle = const Duration(minutes: 2),
    this.maxGap = const Duration(minutes: 5),
  });

  _Open? _open;
  BmsSample? _last;

  /// The in-progress session, if any (not yet closed).
  PowerSession? get current => _open?.toSession();

  /// Feed a sample; returns a session if one just closed.
  PowerSession? add(BmsSample s) {
    final last = _last;
    _last = s;
    PowerSession? closed;

    if (last != null && s.time.difference(last.time) > maxGap) {
      closed = _close();
    }

    final kind = s.current >= threshold
        ? SessionKind.charge
        : s.current <= -threshold
            ? SessionKind.discharge
            : null;

    final open = _open;
    if (open != null) {
      if (last != null && s.time.difference(last.time) <= maxGap) open.integrate(last, s);
      if (kind == open.kind) {
        open.quietSince = null;
        open.extend(s);
      } else {
        open.quietSince ??= s.time;
        if (kind != null || s.time.difference(open.quietSince!) >= settle) {
          closed = _close() ?? closed;
          if (kind != null) _open = _Open(kind, s);
        }
      }
    } else if (kind != null) {
      _open = _Open(kind, s);
    }
    return closed;
  }

  /// Close any open session now (e.g. on disconnect).
  PowerSession? flush() => _close();

  PowerSession? _close() {
    final o = _open;
    _open = null;
    // Ignore blips: under 1 minute or under 0.05 Ah
    final s = o?.toSession();
    if (s == null || s.duration < const Duration(minutes: 1) || s.ah < 0.05) return null;
    return s;
  }
}

class _Open {
  final SessionKind kind;
  final DateTime start;
  final int startSoc;
  DateTime end;
  int endSoc;
  double ah = 0, wh = 0, peak = 0;
  double? maxTemp, maxSpread, minCell, maxCell;
  DateTime? quietSince;

  _Open(this.kind, BmsSample s)
      : start = s.time,
        end = s.time,
        startSoc = s.soc,
        endSoc = s.soc {
    extend(s);
  }

  void extend(BmsSample s) {
    end = s.time;
    endSoc = s.soc;
    final i = s.current.abs();
    if (i > peak) peak = i;
    if (s.maxTempC != null && (maxTemp == null || s.maxTempC! > maxTemp!)) maxTemp = s.maxTempC;
    final sp = s.spreadMv;
    if (sp != null && (maxSpread == null || sp > maxSpread!)) maxSpread = sp;
    if (s.minCellV != null && (minCell == null || s.minCellV! < minCell!)) minCell = s.minCellV;
    if (s.maxCellV != null && (maxCell == null || s.maxCellV! > maxCell!)) maxCell = s.maxCellV;
  }

  /// Trapezoid integration of the part of [a]→[b] flowing in this session's direction.
  void integrate(BmsSample a, BmsSample b) {
    final hours = b.time.difference(a.time).inMicroseconds / Duration.microsecondsPerHour;
    final sign = kind == SessionKind.charge ? 1 : -1;
    final i = ((a.current + b.current) / 2 * sign).clamp(0, double.infinity);
    ah += i * hours;
    wh += i * hours * (a.voltage + b.voltage) / 2;
  }

  PowerSession toSession() => PowerSession(
        kind: kind,
        start: start,
        end: end,
        startSoc: startSoc,
        endSoc: endSoc,
        ah: ah,
        wh: wh,
        peakCurrentA: peak,
        maxTempC: maxTemp,
        maxSpreadMv: maxSpread,
        minCellV: minCell,
        maxCellV: maxCell,
      );
}

enum BmsEventKind {
  /// The BMS cycle counter went up.
  cycle,

  /// A lifetime protection counter went up since the last read.
  protectionCount,

  /// A protection flag appeared in live data.
  protectionActive,

  /// A previously active protection flag cleared.
  protectionCleared,
}

/// Something notable, timestamped when CellScope (or another app) observed it.
class BmsEvent {
  final DateTime time;
  final BmsEventKind kind;
  final String label;
  final int count;

  const BmsEvent(this.time, this.kind, this.label, [this.count = 1]);

  Map<String, dynamic> toJson() => {'t': time.millisecondsSinceEpoch, 'kind': kind.name, 'label': label, 'n': count};

  factory BmsEvent.fromJson(Map<String, dynamic> j) => BmsEvent(
        DateTime.fromMillisecondsSinceEpoch(j['t'] as int),
        BmsEventKind.values.byName(j['kind'] as String),
        j['label'] as String,
        (j['n'] as int?) ?? 1,
      );
}

/// Detects events by comparing successive readings.
class EventDetector {
  int? _cycles;
  int _mask = 0;
  Map<String, int>? _counts;

  /// Seed with previously saved totals so restarts don't re-report old events.
  // Named params can't be private, so initializing formals don't apply.
  EventDetector({int? cycles, Map<String, int>? protectionCounts})
      // ignore: prefer_initializing_formals
      : _cycles = cycles,
        _counts = protectionCounts;

  List<BmsEvent> onSample(BmsSample s) {
    final out = <BmsEvent>[];
    final prev = _cycles;
    if (prev != null && s.cycles > prev) {
      out.add(BmsEvent(s.time, BmsEventKind.cycle, 'Cycle ${s.cycles} completed', s.cycles - prev));
    }
    _cycles = s.cycles;

    final raised = s.protectionMask & ~_mask;
    final cleared = _mask & ~s.protectionMask;
    for (var bit = 0; bit < 16; bit++) {
      final label = bit < kProtectionLabels.length ? kProtectionLabels[bit] : 'Protection bit $bit';
      if (raised & (1 << bit) != 0) out.add(BmsEvent(s.time, BmsEventKind.protectionActive, label));
      if (cleared & (1 << bit) != 0) out.add(BmsEvent(s.time, BmsEventKind.protectionCleared, label));
    }
    _mask = s.protectionMask;
    return out;
  }

  /// Compare lifetime protection counters with the previous read.
  List<BmsEvent> onHealth(BatteryHealth h, {DateTime? time}) {
    final now = time ?? DateTime.now();
    final out = <BmsEvent>[];
    final prev = _counts;
    if (prev != null) {
      for (final e in h.protectionCounts.entries) {
        final delta = e.value - (prev[e.key] ?? 0);
        if (delta > 0) out.add(BmsEvent(now, BmsEventKind.protectionCount, e.key, delta));
      }
    }
    if (h.protectionCounts.isNotEmpty) _counts = Map.of(h.protectionCounts);
    return out;
  }
}
