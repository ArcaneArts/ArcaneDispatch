// Round-trip test for FlowStatsReader against canned ring-buffer bytes that
// mirror what FlowStatsPublisher.swift would write. Validates header parsing,
// record decoding (offsets), wrap-around handling, and the "skip backlog on
// first open" semantics.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:arcane_dispatch/bridge/flow_stats_reader.dart';
import 'package:arcane_dispatch/core/flow_stat.dart';

// Constants must match the production reader/writer.
const int _headerSize = 32;
const int _recordSize = 256;
const int _capacity = 8; // small so we can exercise wrap-around fast

void main() {
  late Directory tempDir;
  late File ringFile;
  late RandomAccessFile raf;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('flow_stats_test_');
    ringFile = File('${tempDir.path}/flow_stats.bin');
    // Pre-allocate.
    int totalSize = _headerSize + _capacity * _recordSize;
    Uint8List zeros = Uint8List(totalSize);
    await ringFile.writeAsBytes(zeros, flush: true);
    raf = await ringFile.open(mode: FileMode.append);
    await raf.close();
    raf = await ringFile.open(mode: FileMode.write);
    await raf.close();
    raf = await ringFile.open(mode: FileMode.writeOnlyAppend);
    await raf.close();
    // Re-open in read/write mode for actual content writes.
    raf = await ringFile.open(mode: FileMode.write);
    await raf.writeFrom(Uint8List(totalSize));
    await raf.close();
    raf = await ringFile.open(mode: FileMode.write);
    await raf.writeFrom(Uint8List(totalSize));
    await raf.close();
  });

  tearDown(() async {
    try {
      await raf.close();
    } catch (_) {}
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('reader rejects file without ADFS magic', () async {
    // Header is all zeros (from setUp) — no magic, no version.
    FlowStatsReader reader = FlowStatsReader(pathOverride: ringFile.path);
    List<FlowStat> seen = <FlowStat>[];
    reader.flows.listen(seen.add);
    await reader.start();
    // Write some records anyway and bump writeIndex; reader should ignore.
    await _writeHeader(ringFile, capacity: _capacity, writeIndex: 0,
        clobberMagic: true);
    await _writeRecord(ringFile,
        slot: 0,
        kind: 1,
        family: 2,
        proto: 6,
        flowId: 1,
        linkId: 'en0',
        remoteAddress: '1.2.3.4',
        remotePort: 443,
        bytesOut: 100,
        bytesIn: 200);
    await _setWriteIndex(ringFile, 1);
    await _waitFor(() => seen.isNotEmpty, timeout: const Duration(milliseconds: 600));
    expect(seen, isEmpty);
    await reader.dispose();
  });

  test('round-trips a single TCP flow record', () async {
    await _writeHeader(ringFile, capacity: _capacity, writeIndex: 0);
    FlowStatsReader reader = FlowStatsReader(
      pathOverride: ringFile.path,
      pollInterval: const Duration(milliseconds: 50),
    );
    List<FlowStat> seen = <FlowStat>[];
    StreamSubscription<FlowStat> sub = reader.flows.listen(seen.add);
    await reader.start();
    // Give the reader one tick to capture writeIndex=0 as its baseline so
    // anything we write below is treated as fresh.
    await Future<void>.delayed(const Duration(milliseconds: 120));

    await _writeRecord(
      ringFile,
      slot: 0,
      kind: 1,
      family: 2,
      proto: 6,
      flowId: 0x1122334455667788,
      localPort: 51234,
      remotePort: 443,
      bytesOut: 1024,
      bytesIn: 4096,
      linkId: 'en0',
      localAddress: '10.0.0.5',
      remoteAddress: '93.184.216.34',
      timestamp: 1_700_000_000.5,
    );
    await _setWriteIndex(ringFile, 1);

    await _waitFor(() => seen.isNotEmpty,
        timeout: const Duration(seconds: 2));
    expect(seen, hasLength(1));
    FlowStat stat = seen.single;
    expect(stat.flowId, '2/1234605616436508552');
    expect(stat.linkId, 'en0');
    expect(stat.remoteAddress, '93.184.216.34');
    expect(stat.remotePort, 443);
    expect(stat.protocol, 6);
    expect(stat.bytesIn, 4096);
    expect(stat.bytesOut, 1024);
    expect(stat.isOpen, isTrue); // kind=1 (created) leaves closedAt null
    expect(stat.openedAt.toUtc().millisecondsSinceEpoch,
        (1_700_000_000.5 * 1000).round());

    await sub.cancel();
    await reader.dispose();
  });

  test('isRealtime flag tags FlowStat.trafficClass = "realtime"', () async {
    await _writeHeader(ringFile, capacity: _capacity, writeIndex: 0);
    FlowStatsReader reader = FlowStatsReader(
      pathOverride: ringFile.path,
      pollInterval: const Duration(milliseconds: 50),
    );
    List<FlowStat> seen = <FlowStat>[];
    reader.flows.listen(seen.add);
    await reader.start();
    await Future<void>.delayed(const Duration(milliseconds: 120));

    await _writeRecord(ringFile,
        slot: 0,
        kind: 1,
        family: 2,
        proto: 17,
        flowId: 42,
        remotePort: 3478, // STUN
        bytesOut: 10,
        bytesIn: 12,
        linkId: 'en0',
        remoteAddress: '162.159.130.50',
        timestamp: 1_700_000_020.0,
        isRealtime: true);
    await _writeRecord(ringFile,
        slot: 1,
        kind: 1,
        family: 2,
        proto: 6,
        flowId: 43,
        remotePort: 80,
        bytesOut: 64,
        bytesIn: 64,
        linkId: 'en0',
        remoteAddress: '10.0.0.42',
        timestamp: 1_700_000_021.0,
        isRealtime: false);
    await _setWriteIndex(ringFile, 2);

    await _waitFor(() => seen.length >= 2,
        timeout: const Duration(seconds: 2));
    FlowStat rt = seen.firstWhere((s) => s.flowId.endsWith('/42'));
    FlowStat bulk = seen.firstWhere((s) => s.flowId.endsWith('/43'));
    expect(rt.trafficClass, 'realtime');
    expect(bulk.trafficClass, isNull);
    await reader.dispose();
  });

  test('decodes closed flows (kind=3) with closedAt populated', () async {
    await _writeHeader(ringFile, capacity: _capacity, writeIndex: 0);
    FlowStatsReader reader = FlowStatsReader(
      pathOverride: ringFile.path,
      pollInterval: const Duration(milliseconds: 50),
    );
    List<FlowStat> seen = <FlowStat>[];
    reader.flows.listen(seen.add);
    await reader.start();
    await Future<void>.delayed(const Duration(milliseconds: 120));

    await _writeRecord(ringFile,
        slot: 0,
        kind: 3, // closed
        family: 2,
        proto: 17, // UDP
        flowId: 7,
        remotePort: 53,
        bytesOut: 80,
        bytesIn: 120,
        linkId: 'en1',
        localAddress: '10.0.0.6',
        remoteAddress: '1.1.1.1',
        timestamp: 1_700_000_010.0);
    await _setWriteIndex(ringFile, 1);

    await _waitFor(() => seen.isNotEmpty,
        timeout: const Duration(seconds: 2));
    expect(seen.single.protocol, 17);
    expect(seen.single.isOpen, isFalse);
    expect(seen.single.closedAt, isNotNull);
    await reader.dispose();
  });

  test('wraps around the ring buffer when writeIndex exceeds capacity',
      () async {
    await _writeHeader(ringFile, capacity: _capacity, writeIndex: 0);
    FlowStatsReader reader = FlowStatsReader(
      pathOverride: ringFile.path,
      pollInterval: const Duration(milliseconds: 50),
    );
    List<FlowStat> seen = <FlowStat>[];
    reader.flows.listen(seen.add);
    await reader.start();
    await Future<void>.delayed(const Duration(milliseconds: 120));

    // Write 12 records into 8 slots — last 8 should win.
    for (int i = 0; i < 12; i++) {
      int slot = i % _capacity;
      await _writeRecord(ringFile,
          slot: slot,
          kind: 2, // bytes
          family: 2,
          proto: 6,
          flowId: i + 1,
          remotePort: 8000 + i,
          bytesOut: (i + 1) * 10,
          bytesIn: (i + 1) * 20,
          linkId: 'en0',
          remoteAddress: '10.0.0.${i + 1}',
          timestamp: 1_700_000_000.0 + i);
    }
    await _setWriteIndex(ringFile, 12);

    await _waitFor(() => seen.length >= 8,
        timeout: const Duration(seconds: 2));
    // Exactly 8 because anything older is overwritten.
    expect(seen.length, 8);
    // Last-written wins: flowIds 5..12 (because writes 1..12 cycle through
    // slots 0..7 twice; the second pass overwrites slots 0..3 with 9..12 and
    // leaves slots 4..7 holding writes 5..8).
    Set<int> flowIds = seen.map((FlowStat s) => int.parse(s.flowId.split('/').last)).toSet();
    expect(flowIds, <int>{5, 6, 7, 8, 9, 10, 11, 12});
    await reader.dispose();
  });

  test('skips half-written slots with NaN timestamp', () async {
    await _writeHeader(ringFile, capacity: _capacity, writeIndex: 0);
    FlowStatsReader reader = FlowStatsReader(
      pathOverride: ringFile.path,
      pollInterval: const Duration(milliseconds: 50),
    );
    List<FlowStat> seen = <FlowStat>[];
    reader.flows.listen(seen.add);
    await reader.start();
    await Future<void>.delayed(const Duration(milliseconds: 120));

    // Slot 0 is NaN-stamped, slot 1 is well-formed.
    await _writeRecord(ringFile,
        slot: 0,
        kind: 1,
        family: 2,
        proto: 6,
        flowId: 100,
        remotePort: 443,
        bytesOut: 0,
        bytesIn: 0,
        linkId: 'en0',
        remoteAddress: '10.0.0.10',
        timestamp: double.nan);
    await _writeRecord(ringFile,
        slot: 1,
        kind: 1,
        family: 2,
        proto: 6,
        flowId: 101,
        remotePort: 443,
        bytesOut: 0,
        bytesIn: 0,
        linkId: 'en0',
        remoteAddress: '10.0.0.11',
        timestamp: 1_700_000_000.0);
    await _setWriteIndex(ringFile, 2);

    await _waitFor(() => seen.isNotEmpty,
        timeout: const Duration(seconds: 2));
    expect(seen, hasLength(1));
    expect(seen.single.remoteAddress, '10.0.0.11');
    await reader.dispose();
  });
}

// --- writer helpers (single producer, no concurrency) ---------------------

Future<void> _writeHeader(
  File file, {
  required int capacity,
  required int writeIndex,
  bool clobberMagic = false,
}) async {
  Uint8List header = Uint8List(_headerSize);
  ByteData bd = ByteData.sublistView(header);
  if (!clobberMagic) {
    header[0] = 0x41;
    header[1] = 0x44;
    header[2] = 0x46;
    header[3] = 0x53;
  } else {
    // Anything that isn't "ADFS" — reader must reject.
    header[0] = 0x00;
    header[1] = 0x00;
    header[2] = 0x00;
    header[3] = 0x00;
  }
  bd.setUint16(4, 2, Endian.little); // version
  bd.setUint16(6, _recordSize, Endian.little);
  bd.setUint32(8, capacity, Endian.little);
  bd.setUint64(16, writeIndex, Endian.little);
  RandomAccessFile raf = await file.open(mode: FileMode.append);
  try {
    await raf.setPosition(0);
    await raf.writeFrom(header);
    await raf.flush();
  } finally {
    await raf.close();
  }
}

Future<void> _setWriteIndex(File file, int writeIndex) async {
  Uint8List bytes = Uint8List(8);
  ByteData.sublistView(bytes).setUint64(0, writeIndex, Endian.little);
  RandomAccessFile raf = await file.open(mode: FileMode.append);
  try {
    await raf.setPosition(16);
    await raf.writeFrom(bytes);
    await raf.flush();
  } finally {
    await raf.close();
  }
}

Future<void> _writeRecord(
  File file, {
  required int slot,
  required int kind,
  required int family,
  required int proto,
  required int flowId,
  required int remotePort,
  required int bytesOut,
  required int bytesIn,
  required String linkId,
  required String remoteAddress,
  String localAddress = '',
  int localPort = 0,
  double timestamp = 1_700_000_000.0,
  bool isRealtime = false,
}) async {
  Uint8List rec = Uint8List(_recordSize);
  ByteData bd = ByteData.sublistView(rec);
  bd.setFloat64(0, timestamp, Endian.little);
  rec[8] = kind & 0xff;
  rec[9] = family & 0xff;
  rec[10] = proto & 0xff;
  // linkIdLen filled by _writeBoundedString below.
  bd.setUint64(12, flowId, Endian.little);
  bd.setUint16(20, localPort, Endian.little);
  bd.setUint16(22, remotePort, Endian.little);
  bd.setUint64(24, bytesOut, Endian.little);
  bd.setUint64(32, bytesIn, Endian.little);
  _writeBoundedString(rec, linkId, lenAt: 11, dataAt: 40, maxLen: 48);
  _writeBoundedString(rec, localAddress, lenAt: 88, dataAt: 89, maxLen: 79);
  _writeBoundedString(rec, remoteAddress, lenAt: 168, dataAt: 169, maxLen: 79);
  rec[248] = isRealtime ? 1 : 0;
  int offset = _headerSize + slot * _recordSize;
  RandomAccessFile raf = await file.open(mode: FileMode.append);
  try {
    await raf.setPosition(offset);
    await raf.writeFrom(rec);
    await raf.flush();
  } finally {
    await raf.close();
  }
}

void _writeBoundedString(
  Uint8List bytes,
  String s, {
  required int lenAt,
  required int dataAt,
  required int maxLen,
}) {
  List<int> data = s.codeUnits;
  if (data.length > maxLen) {
    data = data.sublist(0, maxLen);
  }
  bytes[lenAt] = data.length & 0xff;
  for (int i = 0; i < data.length; i++) {
    bytes[dataAt + i] = data[i] & 0xff;
  }
}

Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 1),
}) async {
  DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
