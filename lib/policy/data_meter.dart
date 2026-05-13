import 'dart:async';
import 'dart:convert';

import 'package:hive/hive.dart';

import '../core/link.dart';

/// Persisted per-link byte counter with monthly rollover.
///
/// Speedify exposes per-link data caps with a configurable "billing cycle
/// anchor" (typically a day-of-month). We mirror that semantics: each [Link]
/// optionally has a [Link.dataCapBytes] and a [Link.billingCycleAnchor] (ISO-
/// 8601 day or numeric day-of-month). The meter maintains a separate
/// `dataUsedBytes` counter and resets it when the anchor's monthly boundary
/// crosses.
///
/// Storage layout (under Hive box passed to the constructor):
/// ```
/// data_meter_v1/<linkId> -> {
///   'used': <int bytes used since last reset>,
///   'cycleStart': <ISO-8601 UTC date of the active cycle's start>,
/// }
/// ```
///
/// Why a separate Hive entry instead of writing back to the `Link` JSON: hot
/// counters get bumped every few KB of traffic. Encoding the entire `Link`
/// graph that often would thrash the disk. The counter file is intentionally
/// small and append-friendly.
class DataMeter {
  static const String _hiveKeyPrefix = 'data_meter_v1/';

  final Box _storage;
  final DateTime Function() _now;
  final Map<String, _MeterState> _state = <String, _MeterState>{};
  bool _disposed = false;

  DataMeter({required Box storage, DateTime Function() now = _systemNow})
    : _storage = storage,
      _now = now;

  /// Hot-path counter increment. `linkId` keys into the meter; the counter
  /// is persisted lazily (see [flush]) to keep per-byte overhead negligible.
  void recordBytes(Link link, int bytes) {
    if (_disposed || bytes <= 0) {
      return;
    }
    _MeterState s = _ensureState(link);
    s.used += bytes;
    s.dirty = true;
  }

  /// Current usage for [link] this cycle. Reads from in-memory state and
  /// falls back to the Hive snapshot if the meter hasn't seen this link yet.
  int usedFor(Link link) {
    return _ensureState(link).used;
  }

  /// True when [link] has a cap configured AND the meter shows usage at or
  /// above the cap. The policy engine reads this to surface
  /// `IneligibilityReason.dataCapExhausted` without re-parsing JSON.
  bool isExhausted(Link link) {
    if (link.dataCapBytes == null) {
      return false;
    }
    return usedFor(link) >= link.dataCapBytes!;
  }

  /// Convenience: returns a flat `linkId -> bytes used this cycle` view for
  /// [PolicyEngine.evaluate]'s `dataUsedOverride` parameter.
  Map<String, int> snapshot() {
    Map<String, int> result = <String, int>{};
    _state.forEach((String id, _MeterState s) {
      result[id] = s.used;
    });
    return result;
  }

  /// Persist any dirty counters. Safe to call from a periodic timer; the
  /// engine should also call it before exiting so the latest values survive a
  /// crash.
  Future<void> flush() async {
    if (_disposed) {
      return;
    }
    List<Future<void>> writes = <Future<void>>[];
    _state.forEach((String id, _MeterState s) {
      if (!s.dirty) {
        return;
      }
      writes.add(
        _storage.put(
          _hiveKeyPrefix + id,
          jsonEncode(<String, Object>{
            'used': s.used,
            'cycleStart': s.cycleStart.toUtc().toIso8601String(),
          }),
        ),
      );
      s.dirty = false;
    });
    if (writes.isNotEmpty) {
      await Future.wait(writes);
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    await flush();
    _disposed = true;
  }

  /// Force-reset the counter for [link]. Mostly for tests and the future
  /// "Reset this month's usage" UI button.
  void reset(Link link) {
    _ensureState(link)
      ..used = 0
      ..cycleStart = _resolveCycleStart(link, _now())
      ..dirty = true;
  }

  _MeterState _ensureState(Link link) {
    _MeterState? existing = _state[link.id];
    DateTime now = _now();
    if (existing == null) {
      _MeterState bootstrap = _readSnapshot(link, now);
      _state[link.id] = bootstrap;
      return _maybeRollover(link, bootstrap, now);
    }
    return _maybeRollover(link, existing, now);
  }

  _MeterState _readSnapshot(Link link, DateTime now) {
    Object? raw = _storage.get(_hiveKeyPrefix + link.id);
    if (raw is String && raw.isNotEmpty) {
      try {
        Object? decoded = jsonDecode(raw);
        if (decoded is Map) {
          Object? used = decoded['used'];
          Object? cycle = decoded['cycleStart'];
          int usedInt = used is int ? used : (used is num ? used.toInt() : 0);
          DateTime cycleStart = cycle is String
              ? (DateTime.tryParse(cycle)?.toUtc() ??
                    _resolveCycleStart(link, now))
              : _resolveCycleStart(link, now);
          return _MeterState(
            used: usedInt >= 0 ? usedInt : 0,
            cycleStart: cycleStart,
          );
        }
      } catch (_) {
        // Corrupt entry: fall through to a fresh cycle.
      }
    }
    return _MeterState(used: 0, cycleStart: _resolveCycleStart(link, now));
  }

  _MeterState _maybeRollover(Link link, _MeterState state, DateTime now) {
    DateTime expectedStart = _resolveCycleStart(link, now);
    if (expectedStart.isAfter(state.cycleStart)) {
      state.used = 0;
      state.cycleStart = expectedStart;
      state.dirty = true;
    }
    return state;
  }

  /// Compute the cycle start for [link] relative to [now].
  ///
  /// The anchor can be:
  /// * A day-of-month number (e.g. "1", "15") → start = most recent occurrence
  ///   of that day at 00:00 UTC.
  /// * An ISO-8601 date (e.g. "2026-01-15") → use the day part as a recurring
  ///   monthly anchor (matches Speedify's setup screen).
  /// * `null` or unparseable → fall back to the 1st of the current UTC month.
  DateTime _resolveCycleStart(Link link, DateTime now) {
    DateTime utc = now.toUtc();
    int? day = _parseAnchorDay(link.billingCycleAnchor);
    int anchor = day ?? 1;
    int targetMonth = utc.month;
    int targetYear = utc.year;
    if (utc.day < anchor) {
      // We haven't crossed into the current cycle yet; the cycle started in
      // the previous month.
      targetMonth -= 1;
      if (targetMonth == 0) {
        targetMonth = 12;
        targetYear -= 1;
      }
    }
    int clampedDay = anchor;
    int monthMaxDay = _daysInMonth(targetYear, targetMonth);
    if (clampedDay > monthMaxDay) {
      clampedDay = monthMaxDay;
    }
    return DateTime.utc(targetYear, targetMonth, clampedDay);
  }

  static int? _parseAnchorDay(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    int? direct = int.tryParse(raw);
    if (direct != null && direct >= 1 && direct <= 31) {
      return direct;
    }
    DateTime? parsed = DateTime.tryParse(raw);
    if (parsed != null) {
      return parsed.day;
    }
    return null;
  }

  static int _daysInMonth(int year, int month) {
    // Last day of month = day 0 of next month.
    DateTime first = DateTime.utc(year, month + 1, 1);
    DateTime last = first.subtract(const Duration(days: 1));
    return last.day;
  }

  static DateTime _systemNow() {
    return DateTime.now();
  }
}

class _MeterState {
  int used;
  DateTime cycleStart;
  bool dirty = false;

  _MeterState({required this.used, required this.cycleStart});
}
