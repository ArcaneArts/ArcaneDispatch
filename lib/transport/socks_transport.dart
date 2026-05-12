import 'dart:async';
import 'dart:io';

import 'package:hive/hive.dart';

import '../core/flow_stat.dart';
import '../core/link.dart';
import '../core/link_metric.dart';
import '../core/network_interface_repository.dart';
import '../core/policy.dart';
import '../core/proxy_event.dart';
import '../core/socks_proxy_server.dart';
import '../core/weighted_address.dart';
import '../policy/byte_accountant.dart';
import '../policy/data_meter.dart';
import '../policy/policy_engine.dart';
import '../policy/token_bucket.dart';
import 'transport.dart';

/// Settings the controller passes to the SOCKS transport when starting it.
///
/// We keep these here (instead of inside [Policy]) because they only make
/// sense for the legacy SOCKS engine. Once the tunnel transport ships, the
/// `listenHost`/`listenPort` pair is a no-op for tunnel mode.
class SocksTransportConfig {
  final String listenHost;
  final int listenPort;

  const SocksTransportConfig({
    this.listenHost = '127.0.0.1',
    this.listenPort = 1080,
  });
}

/// Adapter that exposes the existing [SocksProxyServer] through the new
/// [Transport] interface.
///
/// Phase 1 keeps the behavior 100 % identical to the original
/// `DispatchController` / `SocksProxyServer` pair. The only changes are:
///
/// * Policy is consumed as a typed [Policy] (with [Link]s) instead of a list
///   of `<target>[/weight]` strings.
/// * Flow events are surfaced through [flows] in addition to the legacy
///   event stream, so the new dashboard (Phase 15) can consume them.
///
/// Phase 3 layers a per-link [TokenBucket] (speed cap throttle) and a Hive-
/// backed [DataMeter] (monthly data cap) on top of the same engine. Both are
/// wired through the SOCKS server's [SocksProxyServer.accountant] hook, so
/// every byte that crosses the proxy in either direction is throttled and
/// metered against the link whose source IP carried it.
///
/// Tests inject a fake inner engine via [serverFactory]; the factory receives
/// the bound `ProxyEventSink` and the bound `ByteAccountant`, so fakes can
/// drive the accountant directly when convenient.
class SocksTransport implements Transport {
  final SocksProxyServer Function(
    ProxyEventSink onEvent,
    ByteAccountant accountant,
  ) _serverFactory;
  final WeightedAddressResolver _resolver;
  final NetworkInterfaceRepository _repository;
  final PolicyEngine _engine;
  final SocksTransportConfig config;

  /// Persistent storage for the [DataMeter]. Optional: when omitted the
  /// transport tracks usage in-memory only (useful for tests). In production
  /// this points at the same Hive box the controller uses for settings, so
  /// counters survive restarts.
  final Box? _meterStorage;

  late final SocksProxyServer _server;
  late final DataMeter _dataMeter;

  /// Per-link token buckets keyed by [Link.id]. Rebuilt on every [start] /
  /// [updatePolicy] so cap changes take effect at the next connection.
  final Map<String, TokenBucket> _buckets = <String, TokenBucket>{};

  final LatestStream<TransportStatus> _state = LatestStream<TransportStatus>(
    TransportStatus(state: TransportState.stopped),
  );
  final StreamController<LinkMetric> _metrics =
      StreamController<LinkMetric>.broadcast();
  final StreamController<FlowStat> _flows = StreamController<FlowStat>.broadcast();
  final StreamController<ProxyEvent> _events =
      StreamController<ProxyEvent>.broadcast();

  /// Tracks the live [FlowStat] per remote socket so we can emit close events
  /// with accurate timestamps. Populated when the underlying server reports a
  /// `connectionOpened` event.
  final Map<String, FlowStat> _openFlows = <String, FlowStat>{};

  /// Resolves `linkId -> Link` for the live policy so we can stamp flows with
  /// the right link metadata.
  Map<String, Link> _linksById = const <String, Link>{};

  /// Resolves `local-address -> linkId` for fast flow attribution. Filled in
  /// from the resolved addresses passed to the inner server on start.
  Map<String, String> _linkIdByLocalAddress = const <String, String>{};

  /// Live snapshot of per-link metrics, used by the [PolicyEngine] when it
  /// decides which links are eligible. Updated from the outside via
  /// [applyMetrics]; defaults to an empty map so the engine still runs (it
  /// just won't apply RTT/loss gates).
  Map<String, LinkMetric> _currentMetrics = const <String, LinkMetric>{};

  /// Latest policy the transport was started with. Kept so [applyMetrics] can
  /// re-evaluate against the same set of links without forcing the controller
  /// to round-trip the whole policy on every probe tick.
  Policy? _currentPolicy;

  /// Last [PolicyDecision] applied to the running [SocksProxyServer]. Surfaced
  /// to tests and (eventually) the dashboard so users can see which links the
  /// engine activated and why others were dropped.
  PolicyDecision? _lastDecision;

  /// Per-link, per-direction byte accumulators used to derive throughput
  /// metrics. Reset on every tick of [_throughputTimer]; the diff between
  /// reads is what we publish as `bpsIn` / `bpsOut`.
  ///
  /// Keyed by [Link.id]. Missing entries are implicit zero — we don't
  /// allocate per-link state until bytes actually flow.
  final Map<String, int> _bytesInWindow = <String, int>{};
  final Map<String, int> _bytesOutWindow = <String, int>{};

  /// Periodic timer that drains the byte accumulators into [_metrics] as a
  /// `LinkMetric(bpsIn, bpsOut)` sample once per [_throughputInterval]. The
  /// controller listens on `metrics`, merges the throughput sample with
  /// probe samples (RTT/jitter/loss), and surfaces both to the UI.
  ///
  /// Lives for the lifetime of the transport; cancelled in [dispose].
  Timer? _throughputTimer;

  /// How often we publish a throughput sample. 1 Hz matches the EWMA
  /// window the UI labels as "live" and stays cheap on battery.
  static const Duration _throughputInterval = Duration(seconds: 1);

  bool _disposed = false;

  SocksTransport({
    required NetworkInterfaceRepository repository,
    SocksProxyServer Function(
      ProxyEventSink onEvent,
      ByteAccountant accountant,
    )? serverFactory,
    WeightedAddressResolver resolver = const WeightedAddressResolver(),
    PolicyEngine engine = const PolicyEngine(),
    this.config = const SocksTransportConfig(),
    Box? meterStorage,
    DataMeter? dataMeter,
  })  : _repository = repository,
        _serverFactory = serverFactory ??
            ((ProxyEventSink onEvent, ByteAccountant accountant) =>
                SocksProxyServer(onEvent: onEvent, accountant: accountant)),
        _resolver = resolver,
        _engine = engine,
        _meterStorage = meterStorage {
    _dataMeter = dataMeter ??
        (_meterStorage != null
            ? DataMeter(storage: _meterStorage)
            : _InMemoryDataMeter());
    _server = _serverFactory(_handleServerEvent, _accountant);
  }

  /// Visible for tests: the wrapped SOCKS engine. Lets tests inspect the
  /// bound port and connection accounting without re-exposing internals.
  SocksProxyServer get innerServer {
    return _server;
  }

  @override
  TransportKind get kind {
    return TransportKind.socks;
  }

  @override
  TransportStatus get status {
    return _state.value;
  }

  @override
  Stream<TransportStatus> get states {
    return _state.stream;
  }

  @override
  Stream<LinkMetric> get metrics {
    return _metrics.stream;
  }

  @override
  Stream<FlowStat> get flows {
    return _flows.stream;
  }

  @override
  Stream<ProxyEvent> get events {
    return _events.stream;
  }

  @override
  Future<void> start(Policy policy) async {
    if (_disposed) {
      throw StateError('SocksTransport has been disposed.');
    }
    if (_server.isRunning) {
      return;
    }

    _state.add(TransportStatus(state: TransportState.starting));
    try {
      List<NetworkInterfaceSnapshot> interfaces =
          await _repository.listUsableInterfaces();

      // Resolve every non-Never link to an address first so the engine sees
      // the same universe of candidates the user configured. The engine then
      // applies priority/health/cap gates to pick which subset actually carries
      // traffic in this start cycle.
      Map<String, ResolvedWeightedAddress> resolvedByLinkId =
          _resolveLinksById(policy.links, interfaces);

      PolicyDecision decision = _engine.evaluate(
        policy: policy,
        metrics: _currentMetrics,
        dataUsedOverride: _dataMeter.snapshot(),
      );
      if (!decision.hasEligible) {
        throw const DispatchConfigException(
          'No links are eligible to carry traffic. Check link priorities, '
          'data caps, and probe health.',
        );
      }

      List<ResolvedWeightedAddress> resolved =
          eligibleToResolved(decision.eligible, resolvedByLinkId);
      if (resolved.isEmpty) {
        throw const DispatchConfigException(
          'No eligible link could be resolved to a local IP address.',
        );
      }

      _currentPolicy = policy;
      _lastDecision = decision;
      _linksById = <String, Link>{for (Link link in policy.links) link.id: link};
      _linkIdByLocalAddress = _buildAddressIndexFromEligible(
        decision.eligible,
        resolvedByLinkId,
      );
      _rebuildBuckets(policy.links);

      await _server.start(
        listenAddress: InternetAddress(config.listenHost),
        port: config.listenPort,
        addresses: resolved,
      );

      String endpoint = '${config.listenHost}:${_server.boundPort ?? config.listenPort}';
      _state.add(
        TransportStatus(state: TransportState.running, endpoint: endpoint),
      );
      // Begin publishing 1 Hz throughput samples. This is what feeds the
      // power-card "Download / Upload" cells and the per-link bandwidth
      // sparklines on the Activity tab.
      _startThroughputTimer();
    } catch (error) {
      _state.add(
        TransportStatus(
          state: TransportState.failed,
          errorMessage: error.toString(),
        ),
      );
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    if (!_server.isRunning) {
      _state.add(TransportStatus(state: TransportState.stopped));
      return;
    }
    _state.add(TransportStatus(state: TransportState.stopping));
    // Stop the throughput timer first so we don't leak a final partial
    // sample after the server tears down. The helper also publishes a
    // zero-sample per link so the UI reads "0 Mbps" immediately.
    _stopThroughputTimer();
    await _server.stop();
    // Persist accumulated counters before relinquishing control. Cheap when
    // nothing is dirty; safe even if [stop] is called repeatedly.
    await _dataMeter.flush();
    _state.add(TransportStatus(state: TransportState.stopped));
  }

  @override
  Future<void> updatePolicy(Policy policy) async {
    // The SOCKS engine doesn't support hot-reload of source addresses today,
    // so we restart when the link set actually changes. Other policy fields
    // (mode, killSwitch, streamingDetection) are no-ops for SOCKS in Phase 1.
    if (_server.isRunning) {
      await stop();
      await start(policy);
    } else {
      _currentPolicy = policy;
      _linksById = <String, Link>{for (Link link in policy.links) link.id: link};
      _rebuildBuckets(policy.links);
    }
  }

  /// Update the live metric snapshot that the [PolicyEngine] consults on
  /// every [start] / [updatePolicy]. Phase 3 only re-applies these on the
  /// next restart; Phase 4 wires this into failover so metric changes can
  /// trigger an in-place re-evaluation.
  void applyMetrics(Map<String, LinkMetric> metrics) {
    _currentMetrics = Map<String, LinkMetric>.unmodifiable(metrics);
  }

  @override
  Map<String, int> dataUsedSnapshot() {
    // The accountant feeds the [DataMeter] on every chunk; surface its
    // snapshot directly. Counters reset at each link's billing-cycle anchor.
    return _dataMeter.snapshot();
  }

  /// The most recent [PolicyDecision] this transport applied. `null` until
  /// the first successful [start]. Useful for dashboards that want to render
  /// "primary group active" / "primary down, on secondary" status.
  PolicyDecision? get lastDecision {
    return _lastDecision;
  }

  /// Read-only snapshot of the currently-configured links, keyed by id.
  Map<String, Link> get linksById {
    return Map<String, Link>.unmodifiable(_linksById);
  }

  /// Last [Policy] this transport was [start]ed or [updatePolicy]'d with.
  /// `null` until the first call to either. Exposed for tests and for the
  /// supervisor (Phase 4) that needs to re-evaluate without round-tripping.
  Policy? get currentPolicy {
    return _currentPolicy;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _throughputTimer?.cancel();
    _throughputTimer = null;
    await stop().catchError((Object _) {});
    for (TokenBucket bucket in _buckets.values) {
      bucket.dispose();
    }
    _buckets.clear();
    await _dataMeter.dispose();
    await _state.close();
    await _metrics.close();
    await _flows.close();
    await _events.close();
  }

  /// Per-chunk accountant invoked by [SocksProxyServer] before each chunk is
  /// written through the proxy. Looks up the link by the connection's
  /// source-IP, awaits its [TokenBucket] (throttle to the configured Mbps),
  /// then records the bytes on the [DataMeter] (data cap accounting).
  ///
  /// We intentionally don't drop traffic when a cap is exceeded — instead the
  /// policy engine (Phase 3) eventually excludes the exhausted link from the
  /// eligible set, which forces *new* flows to a different link. Existing
  /// flows continue to drain (slowly) so user-visible "rip" is minimized.
  Future<void> _accountant({
    required InternetAddress localAddress,
    required int bytes,
    required ByteDirection direction,
  }) async {
    String? linkId = _linkIdByLocalAddress[localAddress.address];
    if (linkId == null || bytes <= 0) {
      return;
    }
    // Accumulate into the live throughput window before throttling so the
    // metric stream reflects what the user *actually* used, not just what
    // got through the token bucket after rate-limiting.
    //
    // [ByteDirection.upstream] means bytes going from the local app out
    // to the remote — that's user-facing "upload". `downstream` is the
    // remote -> app direction, which the UI labels "download". Mapping
    // them onto bpsIn/bpsOut explicitly keeps that contract obvious.
    Map<String, int> window = direction == ByteDirection.downstream
        ? _bytesInWindow
        : _bytesOutWindow;
    window.update(linkId, (int v) => v + bytes, ifAbsent: () => bytes);
    TokenBucket? bucket = _buckets[linkId];
    if (bucket != null && !bucket.isUnlimited) {
      await bucket.acquire(bytes);
    }
    Link? link = _linksById[linkId];
    if (link != null) {
      _dataMeter.recordBytes(link, bytes);
    }
  }

  /// Drain the per-link byte accumulators, compute bytes-per-second over
  /// the elapsed window, and emit one [LinkMetric] per link. Called on a
  /// 1 Hz timer while the transport is running.
  ///
  /// Important: we emit a sample *for every known link*, even ones that
  /// didn't see traffic this tick. That guarantees the UI shows `0 Mbps`
  /// when a link is idle instead of stale numbers from the previous burst.
  void _tickThroughput() {
    if (_disposed) return;
    DateTime now = DateTime.now();
    // Union of every link we've ever seen plus every link in the policy.
    // The policy union is what keeps idle-but-configured links visible.
    Set<String> ids = <String>{
      ..._linksById.keys,
      ..._bytesInWindow.keys,
      ..._bytesOutWindow.keys,
    };
    for (String linkId in ids) {
      int inBytes = _bytesInWindow.remove(linkId) ?? 0;
      int outBytes = _bytesOutWindow.remove(linkId) ?? 0;
      // bytes/sec for a 1-second window is just the byte total. If we
      // ever change [_throughputInterval] we'd divide by its seconds.
      double bpsIn = inBytes.toDouble();
      double bpsOut = outBytes.toDouble();
      LinkMetric sample = LinkMetric(
        linkId: linkId,
        capturedAt: now,
        bpsIn: bpsIn,
        bpsOut: bpsOut,
      );
      if (!_metrics.isClosed) {
        _metrics.add(sample);
      }
    }
  }

  /// Start the per-second throughput emitter. Idempotent.
  void _startThroughputTimer() {
    _throughputTimer ??= Timer.periodic(
      _throughputInterval,
      (Timer _) => _tickThroughput(),
    );
  }

  /// Stop the throughput emitter and zero-out any in-flight accumulators
  /// so the next start cycle reads from a clean slate.
  void _stopThroughputTimer() {
    _throughputTimer?.cancel();
    _throughputTimer = null;
    // Emit one final all-zero sample per known link so the UI doesn't
    // freeze on the last positive reading after the user hits Stop.
    if (_metrics.isClosed) {
      _bytesInWindow.clear();
      _bytesOutWindow.clear();
      return;
    }
    DateTime now = DateTime.now();
    Set<String> ids = <String>{..._linksById.keys};
    for (String linkId in ids) {
      _metrics.add(LinkMetric(
        linkId: linkId,
        capturedAt: now,
        bpsIn: 0,
        bpsOut: 0,
      ));
    }
    _bytesInWindow.clear();
    _bytesOutWindow.clear();
  }

  /// (Re)build the per-link token buckets to match [links]'s speed caps.
  ///
  /// Existing buckets for links that disappear are disposed; uncapped links
  /// get an unlimited bucket (so the accountant short-circuits without
  /// allocating a Timer per chunk).
  void _rebuildBuckets(List<Link> links) {
    Set<String> nextIds = <String>{for (Link link in links) link.id};
    List<String> toRemove = _buckets.keys
        .where((String id) => !nextIds.contains(id))
        .toList();
    for (String id in toRemove) {
      _buckets.remove(id)?.dispose();
    }
    for (Link link in links) {
      int cap = link.speedCapBps ?? 0;
      TokenBucket? existing = _buckets[link.id];
      if (existing != null && existing.refillBytesPerSec == cap) {
        // Same cap: keep the existing bucket so in-flight `acquire` calls
        // don't suddenly throw on the disposed instance.
        continue;
      }
      existing?.dispose();
      _buckets[link.id] = TokenBucket(refillBytesPerSec: cap);
    }
  }

  /// Maps a [Policy]'s links to the legacy [RawWeightedAddress] /
  /// [ResolvedWeightedAddress] pipeline, keyed by [Link.id] so the policy
  /// engine output can be turned back into addresses without relying on
  /// list-position alignment. Never-priority links are skipped (they would
  /// be excluded by the engine anyway).
  ///
  /// Throws [DispatchConfigException] when *no* link resolves — i.e. the user
  /// didn't pick anything, or every pick fails resolution. Individual link
  /// failures bubble up as the resolver's normal exception, so we don't need
  /// to swallow them.
  Map<String, ResolvedWeightedAddress> _resolveLinksById(
    List<Link> links,
    List<NetworkInterfaceSnapshot> interfaces,
  ) {
    List<Link> eligibleForResolution = links
        .where((Link link) => link.priority != LinkPriority.never)
        .toList();
    if (eligibleForResolution.isEmpty) {
      throw const DispatchConfigException(
        'Select at least one local address before starting the proxy.',
      );
    }
    List<RawWeightedAddress> raw = eligibleForResolution
        .map((Link link) => RawWeightedAddress.parse(link.toLegacyTarget()))
        .toList();
    List<ResolvedWeightedAddress> resolved =
        _resolver.resolve(raw, interfaces);
    Map<String, ResolvedWeightedAddress> byId =
        <String, ResolvedWeightedAddress>{};
    for (int i = 0; i < eligibleForResolution.length && i < resolved.length;
        i += 1) {
      byId[eligibleForResolution[i].id] = resolved[i];
    }
    return byId;
  }

  Map<String, String> _buildAddressIndexFromEligible(
    List<EligibleLink> eligible,
    Map<String, ResolvedWeightedAddress> resolvedByLinkId,
  ) {
    Map<String, String> index = <String, String>{};
    for (EligibleLink slot in eligible) {
      ResolvedWeightedAddress? addr = resolvedByLinkId[slot.link.id];
      if (addr == null) {
        continue;
      }
      if (addr.ipv4 != null) {
        index[addr.ipv4!.address] = slot.link.id;
      }
      if (addr.ipv6 != null) {
        index[addr.ipv6!.address] = slot.link.id;
      }
    }
    return index;
  }

  void _handleServerEvent(ProxyEvent event) {
    _events.add(event);
    switch (event.type) {
      case ProxyEventType.connectionOpened:
        _onConnectionOpened(event);
        break;
      case ProxyEventType.connectionClosed:
        _onConnectionClosed(event);
        break;
      case ProxyEventType.info:
      case ProxyEventType.warning:
      case ProxyEventType.error:
        break;
    }
  }

  void _onConnectionOpened(ProxyEvent event) {
    if (event.remoteAddress == null || event.remotePort == null) {
      return;
    }
    String flowId = _flowId(event);
    String localAddress = event.localAddress?.address ?? '';
    String linkId = _linkIdByLocalAddress[localAddress] ??
        (_linksById.keys.isEmpty ? 'unknown' : _linksById.keys.first);
    FlowStat flow = FlowStat(
      flowId: flowId,
      linkId: linkId,
      remoteAddress: event.remoteAddress!.address,
      remotePort: event.remotePort!,
      openedAt: event.timestamp,
    );
    _openFlows[flowId] = flow;
    _flows.add(flow);
  }

  void _onConnectionClosed(ProxyEvent event) {
    String flowId = _flowId(event);
    FlowStat? open = _openFlows.remove(flowId);
    if (open == null) {
      return;
    }
    _flows.add(open.close(at: event.timestamp));
  }

  String _flowId(ProxyEvent event) {
    String remote = event.remoteAddress?.address ?? 'unknown';
    int port = event.remotePort ?? 0;
    return '$remote:$port@${event.timestamp.microsecondsSinceEpoch}';
  }
}

/// In-memory fallback used when no Hive box is provided to [SocksTransport].
///
/// Useful for tests and the bootstrap path before the controller has
/// finished migrating settings to the new schema. Production paths always
/// pass a real Hive [Box] so usage survives restarts and the policy engine
/// can read accurate counters across sessions.
class _InMemoryDataMeter implements DataMeter {
  final Map<String, int> _counts = <String, int>{};

  @override
  void recordBytes(Link link, int bytes) {
    if (bytes <= 0) {
      return;
    }
    _counts.update(link.id, (int current) => current + bytes, ifAbsent: () => bytes);
  }

  @override
  int usedFor(Link link) {
    return _counts[link.id] ?? 0;
  }

  @override
  bool isExhausted(Link link) {
    if (link.dataCapBytes == null) {
      return false;
    }
    return usedFor(link) >= link.dataCapBytes!;
  }

  @override
  Map<String, int> snapshot() {
    return Map<String, int>.unmodifiable(_counts);
  }

  @override
  Future<void> flush() async {
    // Nothing to flush; everything is already in memory.
  }

  @override
  Future<void> dispose() async {
    _counts.clear();
  }

  @override
  void reset(Link link) {
    _counts[link.id] = 0;
  }
}
