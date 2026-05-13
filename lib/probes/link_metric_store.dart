import 'dart:async';
import 'dart:convert';

import 'package:hive/hive.dart';

import '../core/link_metric.dart';

/// In-memory ring buffer of [LinkMetric] samples per link, with optional
/// periodic snapshot to Hive so a cold app launch doesn't show empty graphs.
///
/// Design:
/// * Stores up to [windowSize] samples per `linkId` (default 60, matches the
///   60 s @ 1 Hz sparkline target in the plan).
/// * On every `record(metric)`, also stamps the latest map.
/// * Every [snapshotInterval] (5 s by default), serializes the latest sample
///   per link to Hive under [snapshotKey] as JSON. Cold load reads it back
///   into the ring head so the UI has *something* to render immediately.
class LinkMetricStore {
  /// Maximum samples per link in memory. Older samples get evicted FIFO.
  final int windowSize;

  /// How often we persist the latest-per-link snapshot to Hive.
  final Duration snapshotInterval;

  /// Hive box used for persistence. `null` disables snapshotting (useful in
  /// tests).
  final Box? storage;

  /// Hive key for the snapshot blob. We store a single JSON value so we can
  /// atomically replace it without orphaning per-link rows.
  final String snapshotKey;

  /// Optional clock injection so tests can advance "now" deterministically.
  final DateTime Function() now;

  final Map<String, List<LinkMetric>> _buffers = <String, List<LinkMetric>>{};
  final Map<String, LinkMetric> _latest = <String, LinkMetric>{};
  final StreamController<LinkMetric> _stream =
      StreamController<LinkMetric>.broadcast();
  Timer? _snapshotTimer;
  bool _disposed = false;

  LinkMetricStore({
    this.windowSize = 60,
    this.snapshotInterval = const Duration(seconds: 5),
    this.storage,
    this.snapshotKey = 'link_metrics_snapshot_v1',
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  /// Replayable stream of every recorded metric. Subscribers see ongoing
  /// records only; for the historical window, call [historyFor].
  Stream<LinkMetric> get metrics {
    return _stream.stream;
  }

  /// Read the persisted snapshot from [storage] (if any) and seed the in-memory
  /// latest-per-link map. Returns the seeded map so the caller can use it
  /// without a second lookup.
  Map<String, LinkMetric> warmStart() {
    Map<String, LinkMetric> result = <String, LinkMetric>{};
    if (storage == null) {
      return result;
    }
    Object? raw = storage!.get(snapshotKey);
    if (raw is! String || raw.isEmpty) {
      return result;
    }
    try {
      Object? decoded = jsonDecode(raw);
      if (decoded is Map) {
        decoded.forEach((Object? id, Object? value) {
          if (id is String && value is Map) {
            try {
              LinkMetric m = LinkMetric.fromJson(value.cast<String, Object?>());
              result[id] = m;
              _latest[id] = m;
              _buffers.putIfAbsent(id, () => <LinkMetric>[]).add(m);
            } catch (_) {
              // Skip malformed entry; the next live sample will rehydrate it.
            }
          }
        });
      }
    } catch (_) {
      // Corrupt blob — start fresh.
    }
    return result;
  }

  /// Begin the periodic snapshot timer. Idempotent. No-op when [storage] is
  /// null (tests).
  void startSnapshots() {
    if (storage == null || _snapshotTimer != null || _disposed) {
      return;
    }
    _snapshotTimer = Timer.periodic(snapshotInterval, (Timer _) {
      flush();
    });
  }

  /// Record a new metric. Updates the ring buffer, the latest-per-link map,
  /// and emits on [metrics].
  void record(LinkMetric metric) {
    if (_disposed) {
      return;
    }
    List<LinkMetric> buffer = _buffers.putIfAbsent(
      metric.linkId,
      () => <LinkMetric>[],
    );
    buffer.add(metric);
    while (buffer.length > windowSize) {
      buffer.removeAt(0);
    }
    _latest[metric.linkId] = metric;
    if (!_stream.isClosed) {
      _stream.add(metric);
    }
  }

  /// Latest sample seen for [linkId], or `null` if none.
  LinkMetric? latestFor(String linkId) {
    return _latest[linkId];
  }

  /// Latest sample per link, as an immutable copy.
  Map<String, LinkMetric> latestSnapshot() {
    return Map<String, LinkMetric>.unmodifiable(_latest);
  }

  /// Historical window for [linkId] in chronological order (oldest first).
  /// Returns an empty list when no samples have been recorded yet.
  List<LinkMetric> historyFor(String linkId) {
    List<LinkMetric>? buffer = _buffers[linkId];
    if (buffer == null) {
      return const <LinkMetric>[];
    }
    return List<LinkMetric>.unmodifiable(buffer);
  }

  /// Drop the buffer for a link (e.g. when the user removes it).
  void dropLink(String linkId) {
    _buffers.remove(linkId);
    _latest.remove(linkId);
  }

  /// Immediately persist the latest snapshot. Called periodically by the
  /// snapshot timer, but also exposed so the app can flush on shutdown.
  Future<void> flush() async {
    if (storage == null || _disposed) {
      return;
    }
    Map<String, Object?> payload = <String, Object?>{
      for (MapEntry<String, LinkMetric> e in _latest.entries)
        e.key: e.value.toJson(),
    };
    await storage!.put(snapshotKey, jsonEncode(payload));
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _snapshotTimer?.cancel();
    _snapshotTimer = null;
    await flush().catchError((Object _) {});
    if (!_stream.isClosed) {
      await _stream.close();
    }
  }
}
