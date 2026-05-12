import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/flow_stat.dart';
import 'tunnel_channel.dart';

/// Reads the `flow_stats.bin` ring buffer the macOS Network Extension writes
/// inside the App Group container and converts each record to a [FlowStat]
/// the [DispatchController] / UI consumes.
///
/// Lock-step with `macos/ArcaneDispatchTunnel/Engine/FlowStatsPublisher.swift`.
/// Any change to the on-disk format must bump [formatVersion] on both sides
/// at once.
///
/// Threading model: this class polls the file on a `Timer.periodic` so we
/// don't need a dedicated isolate. The poll only allocates when the writer
/// has produced new records, so idle CPU is effectively zero.
class FlowStatsReader {
  /// Channel used once on first poll to resolve the absolute path of
  /// `flow_stats.bin`. Cached after the first successful lookup so the
  /// channel isn't called every tick.
  final TunnelChannel channel;

  /// Path override for tests — when non-null, [channel.flowStatsPath] is
  /// skipped and reads go straight to this file. Production callers pass
  /// null and let the channel resolve the path.
  final String? pathOverride;

  /// How often to look for new records once the file is open. 250 ms gives a
  /// snappy live-flow UI without burning CPU on an idle tunnel.
  final Duration pollInterval;

  // --- format constants (must match FlowStatsPublisher.swift) -------------
  static const List<int> _magic = <int>[0x41, 0x44, 0x46, 0x53]; // "ADFS"
  static const int _formatVersion = 2;
  static const int _headerSize = 32;
  static const int _recordSize = 256;

  // record field offsets (within a 256-byte slot)
  static const int _offTimestamp = 0; // f64
  static const int _offKind = 8;
  static const int _offFamily = 9;
  static const int _offProtocol = 10;
  static const int _offLinkIdLen = 11;
  static const int _offFlowId = 12; // u64
  static const int _offLocalPort = 20; // u16
  static const int _offRemotePort = 22; // u16
  static const int _offBytesOut = 24; // u64
  static const int _offBytesIn = 32; // u64
  static const int _offLinkIdData = 40; // 48 bytes
  static const int _offLocalAddrLen = 88;
  static const int _offLocalAddrData = 89; // 79 bytes
  static const int _offRemoteAddrLen = 168;
  static const int _offRemoteAddrData = 169; // 79 bytes
  static const int _offIsRealtime = 248; // u8 flag (format v2+)
  // 249..255 padding

  String? _path;
  RandomAccessFile? _file;
  int? _capacity;
  int _lastReadIndex = 0;
  bool _initialized = false;
  bool _disposed = false;
  Timer? _timer;
  final StreamController<FlowStat> _flows = StreamController<FlowStat>.broadcast();

  FlowStatsReader({
    TunnelChannel? channel,
    this.pathOverride,
    this.pollInterval = const Duration(milliseconds: 250),
  }) : channel = channel ?? TunnelChannel();

  /// Stream of [FlowStat] updates. Hot — events that arrive before the first
  /// listener are dropped, like every other broadcast stream in the project.
  Stream<FlowStat> get flows {
    return _flows.stream;
  }

  /// Start polling. Idempotent; safe to call after `stop()`.
  Future<void> start() async {
    if (_disposed) {
      throw StateError('FlowStatsReader has been disposed.');
    }
    _timer?.cancel();
    // First tick happens immediately so the UI isn't blank for ~250 ms.
    unawaited(_tick());
    _timer = Timer.periodic(pollInterval, (Timer _) => unawaited(_tick()));
  }

  /// Stop polling and release the file handle. Safe to call without a prior
  /// `start()`.
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    try {
      await _file?.close();
    } finally {
      _file = null;
      _initialized = false;
      _capacity = null;
      _lastReadIndex = 0;
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await stop();
    await _flows.close();
  }

  // -----------------------------------------------------------------------

  Future<void> _tick() async {
    if (_disposed) {
      return;
    }
    try {
      await _ensureOpen();
      if (_file == null || _capacity == null) {
        return;
      }
      await _drainNewRecords();
    } catch (_) {
      // Swallow — the next tick retries. Reporting every transient hiccup
      // (file recreated, header torn during init, etc.) would be noisy.
    }
  }

  Future<void> _ensureOpen() async {
    if (_file != null && _initialized) {
      return;
    }
    String? path = _path ?? pathOverride;
    if (path == null) {
      try {
        path = await channel.flowStatsPath();
      } on TunnelUnavailableException {
        return;
      }
    }
    if (path == null || path.isEmpty) {
      return;
    }
    File f = File(path);
    if (!await f.exists()) {
      // The extension hasn't written the file yet; come back next tick.
      return;
    }
    RandomAccessFile raf = await f.open();
    _path = path;
    _file = raf;
    if (!await _readAndValidateHeader()) {
      await raf.close();
      _file = null;
      return;
    }
    // First-time open: skip past whatever's already in the buffer so we only
    // surface events that arrive after we start listening. Otherwise the UI
    // would replay every flow event since the extension started.
    _lastReadIndex = await _readWriteIndex() ?? 0;
    _initialized = true;
  }

  Future<bool> _readAndValidateHeader() async {
    RandomAccessFile? raf = _file;
    if (raf == null) {
      return false;
    }
    await raf.setPosition(0);
    Uint8List header = await raf.read(_headerSize);
    if (header.length != _headerSize) {
      return false;
    }
    for (int i = 0; i < _magic.length; i++) {
      if (header[i] != _magic[i]) {
        return false;
      }
    }
    int version = header[4] | (header[5] << 8);
    if (version != _formatVersion) {
      return false;
    }
    int recordSize = header[6] | (header[7] << 8);
    if (recordSize != _recordSize) {
      return false;
    }
    int capacity =
        header[8] | (header[9] << 8) | (header[10] << 16) | (header[11] << 24);
    if (capacity == 0) {
      return false;
    }
    _capacity = capacity;
    return true;
  }

  Future<int?> _readWriteIndex() async {
    RandomAccessFile? raf = _file;
    if (raf == null) {
      return null;
    }
    await raf.setPosition(16);
    Uint8List bytes = await raf.read(8);
    if (bytes.length != 8) {
      return null;
    }
    return _readUint64LE(bytes, 0);
  }

  Future<void> _drainNewRecords() async {
    RandomAccessFile? raf = _file;
    int? capacity = _capacity;
    if (raf == null || capacity == null) {
      return;
    }
    int? writeIndex = await _readWriteIndex();
    if (writeIndex == null || writeIndex == _lastReadIndex) {
      return;
    }
    // Limit how many records we read per tick. Both directions of slack
    // matter here: a very long pause could leave thousands of records
    // behind, and we don't want to allocate a giant list in one frame.
    int maxBatch = capacity;
    int unread = writeIndex - _lastReadIndex;
    if (unread > maxBatch) {
      // We fell behind by more than one ring's worth; jump ahead.
      _lastReadIndex = writeIndex - maxBatch;
      unread = maxBatch;
    }
    int toRead = unread > maxBatch ? maxBatch : unread;
    for (int i = 0; i < toRead; i++) {
      int idx = _lastReadIndex + i;
      int slot = idx % capacity;
      int offset = _headerSize + slot * _recordSize;
      await raf.setPosition(offset);
      Uint8List rec = await raf.read(_recordSize);
      if (rec.length != _recordSize) {
        continue;
      }
      FlowStat? stat = _decodeRecord(rec);
      if (stat != null) {
        _flows.add(stat);
      }
    }
    _lastReadIndex = writeIndex;
  }

  FlowStat? _decodeRecord(Uint8List rec) {
    // Sanity-check timestamp: NaN/Inf or far-future = half-written / stale.
    double ts = _readFloat64LE(rec, _offTimestamp);
    if (ts.isNaN || ts.isInfinite || ts <= 0) {
      return null;
    }
    int kind = rec[_offKind];
    int family = rec[_offFamily];
    int proto = rec[_offProtocol];
    int linkIdLen = rec[_offLinkIdLen];
    int flowId = _readUint64LE(rec, _offFlowId);
    // localPort is intentionally not stored on FlowStat — the inspector UI
    // doesn't show it yet. We still read it so any future column addition
    // is one parser-field change away.
    // ignore: unused_local_variable
    int localPort = rec[_offLocalPort] | (rec[_offLocalPort + 1] << 8);
    int remotePort = rec[_offRemotePort] | (rec[_offRemotePort + 1] << 8);
    int bytesOut = _readUint64LE(rec, _offBytesOut);
    int bytesIn = _readUint64LE(rec, _offBytesIn);
    String linkId = _readBoundedString(rec, _offLinkIdData, linkIdLen, 48);
    int localAddrLen = rec[_offLocalAddrLen];
    String localAddr =
        _readBoundedString(rec, _offLocalAddrData, localAddrLen, 79);
    int remoteAddrLen = rec[_offRemoteAddrLen];
    String remoteAddr =
        _readBoundedString(rec, _offRemoteAddrData, remoteAddrLen, 79);
    bool isRealtime = rec[_offIsRealtime] != 0;

    // `kind`: 1=created, 2=bytes, 3=closed (see FlowEvent.Kind on the Swift
    // side). We collapse the open/bytes/close lifecycle into a single
    // [FlowStat] from the Dart side because the controller only cares about
    // the *latest* state.
    DateTime openedAt = DateTime.fromMillisecondsSinceEpoch(
      (ts * 1000).round(),
      isUtc: true,
    );
    DateTime? closedAt = kind == 3 ? openedAt : null;

    // We can't tell from the buffer alone when the flow originally opened
    // for a `bytes` event — the Swift side overwrites the slot every time —
    // so we just stamp the current event's timestamp. The controller can
    // dedupe + collapse on flowId.
    return FlowStat(
      flowId: '$family/$flowId',
      linkId: linkId,
      remoteAddress: remoteAddr.isNotEmpty ? remoteAddr : localAddr,
      remotePort: remotePort,
      openedAt: openedAt,
      protocol: proto,
      bytesIn: bytesIn,
      bytesOut: bytesOut,
      closedAt: closedAt,
      // remoteHost stays null — name resolution belongs in the UI layer.
      remoteHost: null,
      // 'realtime' tag means the extension flagged this flow for the QoS lane.
      trafficClass: isRealtime ? 'realtime' : null,
    );
  }

  static int _readUint64LE(Uint8List bytes, int offset) {
    // Build via ByteData so the JIT can vectorize, and to keep us out of
    // ambiguous-precision territory on 64-bit values (Dart int is fine here
    // but `bytes[i] << 56` would be a JS gotcha if we ever ported to web).
    ByteData bd = ByteData.sublistView(bytes, offset, offset + 8);
    return bd.getUint64(0, Endian.little);
  }

  static double _readFloat64LE(Uint8List bytes, int offset) {
    ByteData bd = ByteData.sublistView(bytes, offset, offset + 8);
    return bd.getFloat64(0, Endian.little);
  }

  static String _readBoundedString(
    Uint8List bytes,
    int offset,
    int length,
    int maxLen,
  ) {
    if (length <= 0 || length > maxLen) {
      return '';
    }
    return String.fromCharCodes(bytes.sublist(offset, offset + length));
  }
}
