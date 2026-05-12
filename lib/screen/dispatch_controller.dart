import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../core/bonding_mode.dart';
import '../core/dispatch_settings.dart';
import '../core/flow_stat.dart';
import '../core/link.dart';
import '../core/link_metric.dart';
import '../core/network_interface_repository.dart';
import '../core/policy.dart';
import '../core/proxy_event.dart';
import '../platform/network_naming_service.dart';
import '../platform/startup_service.dart';
import '../policy/link_supervisor.dart';
import '../probes/captive_portal_probe.dart';
import '../probes/link_metric_store.dart';
import '../probes/link_probe_service.dart';
import '../protocol/protocol_ladder.dart';
import '../transport/socks_transport.dart';
import '../transport/transport.dart';
import '../transport/tunnel_transport.dart';

/// Factory signature used to build a fresh [Transport] instance whenever the
/// controller is constructed or the active [TransportKind] changes.
///
/// Receives the *current* settings so the factory can pre-populate transport
/// configuration (listen host/port for SOCKS, etc.). The factory must always
/// return a transport whose [Transport.kind] equals [kind] — otherwise the
/// controller and the persisted settings will desync.
typedef TransportFactory = Transport Function(
  TransportKind kind,
  DispatchSettings settings,
);

/// Controller that owns the active [Transport], the persisted
/// [DispatchSettings], and the live runtime view-model the UI subscribes to.
///
/// Phase 1 always wires a [SocksTransport]. The [TransportKind.tunnel] branch
/// also returns a SOCKS transport so the UI can mount even before the
/// Network Extension is real (Phase 5 swaps in the actual `TunnelTransport`).
///
/// The controller keeps the legacy "set listen host / port / selected
/// targets" API so the existing `home_screen` keeps working unchanged, then
/// layers new accessors (`linkMetrics`, `flows`, `transportKind`,
/// `setLinks`, `setPolicy`, `setTransportKind`) for the upcoming dashboard.
class DispatchController extends ChangeNotifier {
  final NetworkInterfaceRepository repository;
  final Box settingsBox;
  final TransportFactory _transportFactory;
  final LinkProbeService probeService;
  final LinkMetricStore metricStore;
  final LinkSupervisor supervisor;

  /// Resolves raw BSD interface names into SSIDs and hardware-port names
  /// ("Wi-Fi", "USB 10/100/1000 LAN", "iPhone USB"). Exposed read-only so
  /// the UI can listen for SSID changes and rebuild captioned cards.
  final NetworkNamingService namingService;

  Transport _transport;
  DispatchSettings settings;
  List<NetworkInterfaceSnapshot> interfaces = <NetworkInterfaceSnapshot>[];
  List<ProxyEvent> events = <ProxyEvent>[];

  /// Latest metric sample per [Link.id]. Sourced from [probeService] and the
  /// active [Transport]'s metric stream; the controller merges both so the
  /// UI sees a single map.
  Map<String, LinkMetric> linkMetrics = <String, LinkMetric>{};

  /// Most recent supervisor verdict — per-link health + kill-switch state.
  /// `null` until the first probe tick lands.
  LinkHealthEvent? lastHealthEvent;

  /// Sliding window of recent flows for the inspector. Newest first; capped
  /// at 64 entries to keep the activity panel snappy on cold boot.
  List<FlowStat> flows = <FlowStat>[];

  /// Active protocol per link, populated by the negotiation loop or by a
  /// manual UI override. Empty until the first negotiation completes;
  /// transient — the choice gets refreshed every session start.
  Map<String, LinkProtocol> linkProtocols = <String, LinkProtocol>{};

  /// Latest captive-portal verdict per link id. Populated by the per-link
  /// [CaptivePortalDetector] when `policy.captivePortalAssist` is on.
  /// Keys without an entry are treated as "unknown" — the UI shows a
  /// neutral chip.
  Map<String, CaptivePortalProbeResult> captiveStates =
      <String, CaptivePortalProbeResult>{};

  /// Captive-portal probe target. Tests override this via the [target]
  /// constructor arg; production always uses [appleCaptiveProbeUri].
  final Uri _captiveTarget;

  /// Captive-portal probe function. Hooked by tests so the wiring path can
  /// be exercised without real HTTP.
  final CaptivePortalProbeFn _captiveProbe;

  /// Active detector per link id. Wires up on demand when
  /// `policy.captivePortalAssist` is true and tears down when it flips off
  /// or the link is removed.
  final Map<String, CaptivePortalDetector> _captiveDetectors =
      <String, CaptivePortalDetector>{};

  /// Subscription handles so we can cancel cleanly on detector teardown
  /// without losing the in-flight state for other links.
  final Map<String, StreamSubscription<CaptivePortalState>>
      _captiveSubscriptions =
      <String, StreamSubscription<CaptivePortalState>>{};

  bool loadingInterfaces = false;
  String? errorText;

  StreamSubscription<TransportStatus>? _statusSubscription;
  StreamSubscription<ProxyEvent>? _eventSubscription;
  StreamSubscription<FlowStat>? _flowSubscription;
  StreamSubscription<LinkMetric>? _metricSubscription;
  StreamSubscription<LinkMetric>? _probeMetricSubscription;
  StreamSubscription<LinkHealthEvent>? _supervisorSubscription;

  /// Internal constructor used by the public factory.
  ///
  /// All wiring (stream subscriptions, transport handoff) lives in the body
  /// so we don't end up with subtle initialization-order bugs across the
  /// initializer list.
  DispatchController._({
    required this.repository,
    required this.settingsBox,
    required TransportFactory transportFactory,
    required this.settings,
    required Transport transport,
    required this.probeService,
    required this.metricStore,
    required this.supervisor,
    required this.namingService,
    required Uri captiveTarget,
    required CaptivePortalProbeFn captiveProbe,
  })  : _transportFactory = transportFactory,
        _transport = transport,
        _captiveTarget = captiveTarget,
        _captiveProbe = captiveProbe {
    _wireTransport();
    _wireProbes();
    _wireSupervisor();
    _wireNamingService();
    _reconcileCaptiveDetectors();
  }

  /// Public factory. Resolves defaults (transport factory, settings, initial
  /// transport, probe service, metric store, supervisor) exactly once, then
  /// hands them to the private constructor.
  factory DispatchController({
    required NetworkInterfaceRepository repository,
    required Box settingsBox,
    TransportFactory? transportFactory,
    LinkProbeService? probeService,
    LinkMetricStore? metricStore,
    LinkSupervisor? supervisor,
    NetworkNamingService? namingService,
    Uri? captiveTarget,
    CaptivePortalProbeFn? captiveProbe,
  }) {
    TransportFactory factory =
        transportFactory ?? _defaultTransportFactory(repository, settingsBox);
    DispatchSettings settings = DispatchSettings.load(settingsBox);
    Transport transport = factory(settings.transportKind, settings);
    LinkProbeService probes = probeService ?? LinkProbeService();
    LinkMetricStore store =
        metricStore ?? LinkMetricStore(storage: settingsBox);
    LinkSupervisor health = supervisor ?? LinkSupervisor();
    NetworkNamingService naming = namingService ?? NetworkNamingService();
    return DispatchController._(
      repository: repository,
      settingsBox: settingsBox,
      transportFactory: factory,
      settings: settings,
      transport: transport,
      probeService: probes,
      metricStore: store,
      supervisor: health,
      namingService: naming,
      captiveTarget: captiveTarget ?? appleCaptiveProbeUri,
      captiveProbe: captiveProbe ?? httpCaptivePortalProbe,
    );
  }

  /// The currently active transport backend. Exposed read-only so UIs can
  /// show which engine is running.
  Transport get transport {
    return _transport;
  }

  TransportKind get transportKind {
    return _transport.kind;
  }

  bool get isRunning {
    return _transport.status.isRunning;
  }

  String get proxyEndpoint {
    return _transport.status.endpoint ??
        '${settings.listenHost}:${settings.listenPort}';
  }

  Future<void> initialize() async {
    // Re-hydrate the latest metric snapshot from the previous run so the UI
    // has something to render before the first probe tick lands.
    Map<String, LinkMetric> seeded = metricStore.warmStart();
    if (seeded.isNotEmpty) {
      linkMetrics = <String, LinkMetric>{...linkMetrics, ...seeded};
    }
    metricStore.startSnapshots();
    // Kick off SSID/hardware-port resolution so the UI swaps `en0` for
    // "Home Wi-Fi" as soon as the OS replies. Tests inject a fetcher
    // so this is a no-op outside production.
    namingService.start();
    await refreshInterfaces();
    probeService.updateLinks(settings.links);
    if (settings.startProxyOnLaunch && settings.links.isNotEmpty) {
      await startProxy();
    }
  }

  Future<void> refreshInterfaces() async {
    loadingInterfaces = true;
    errorText = null;
    notifyListeners();
    try {
      interfaces = await repository.listUsableInterfaces();
      probeService.updateInterfaces(interfaces);
      // Whenever the interface list changes (cable plug/unplug, Wi-Fi
      // roam) it's almost certainly accompanied by SSID changes too.
      // Trigger an out-of-band refresh so the cards reflect the new
      // state without waiting for the next periodic tick.
      unawaited(namingService.refresh());
    } catch (error) {
      errorText = 'Failed to read network interfaces: $error';
    } finally {
      loadingInterfaces = false;
      notifyListeners();
    }
  }

  /// Historical metric samples for [linkId] in chronological order (oldest
  /// first). Returns an empty list when no probe has run yet. Used by the
  /// sparkline UI.
  List<LinkMetric> metricHistory(String linkId) {
    return metricStore.historyFor(linkId);
  }

  Future<void> setListenHost(String host) async {
    settings = settings.copyWith(listenHost: host.trim());
    await settings.save(settingsBox);
    notifyListeners();
  }

  Future<void> setListenPort(String value) async {
    int? port = int.tryParse(value.trim());
    if (port == null || port < 1 || port > 65535) {
      errorText = 'Port must be between 1 and 65535.';
      notifyListeners();
      return;
    }
    settings = settings.copyWith(listenPort: port);
    await settings.save(settingsBox);
    errorText = null;
    notifyListeners();
  }

  Future<void> setLaunchAtStartup(bool value) async {
    settings = settings.copyWith(launchAtStartup: value);
    await settings.save(settingsBox);
    if (value) {
      await StartupService.instance.enable();
    } else {
      await StartupService.instance.disable();
    }
    notifyListeners();
  }

  Future<void> setStartProxyOnLaunch(bool value) async {
    settings = settings.copyWith(startProxyOnLaunch: value);
    await settings.save(settingsBox);
    notifyListeners();
  }

  Future<void> setHideOnBlur(bool value) async {
    settings = settings.copyWith(hideOnBlur: value);
    await settings.save(settingsBox);
    notifyListeners();
  }

  /// Legacy API kept for the current checkbox/chip UI. Each [target] is a
  /// `<interface-or-ip>[/weight]` string; the call rebuilds the [Link] list
  /// underneath so the new Policy graph stays in sync.
  Future<void> setTargetSelected(String target, bool selected) async {
    Set<String> next = settings.selectedTargets.toSet();
    if (selected) {
      next.add(target);
    } else {
      next.remove(target);
    }
    List<String> ordered = next.toList()..sort();
    settings = settings.copyWithSelectedTargets(ordered);
    await settings.save(settingsBox);
    probeService.updateLinks(settings.links);
    notifyListeners();
  }

  /// New typed API for Phase 2+ to manage links directly.
  Future<void> setLinks(List<Link> links) async {
    settings = settings.copyWith(
      links: links,
      policy: settings.policy.copyWith(links: links),
    );
    await settings.save(settingsBox);
    probeService.updateLinks(links);
    _reconcileCaptiveDetectors();
    Policy view = _effectivePolicy();
    supervisor.updatePolicy(view);
    if (isRunning) {
      await _transport.updatePolicy(view);
    }
    notifyListeners();
  }

  /// Replace a single link's [LinkPriority]. Other fields are preserved. The
  /// PolicyEngine consumes the change immediately on the next `start` / running
  /// `updatePolicy`, so promoting a link from Secondary -> Primary takes
  /// effect at the next connection.
  Future<void> setLinkPriority(String linkId, LinkPriority priority) async {
    await _mutateLink(linkId, (Link link) {
      return link.copyWith(priority: priority);
    });
  }

  /// Update the per-link Mbps cap. Pass `null` to clear the cap. The transport
  /// rebuilds its [TokenBucket] for this link on the next policy apply.
  ///
  /// [megabitsPerSec] is in user-facing Mbps; we convert to bytes/sec
  /// internally so the same units land in `Link.speedCapBps`.
  Future<void> setLinkSpeedCapMbps(String linkId, double? megabitsPerSec) async {
    int? bps;
    if (megabitsPerSec != null && megabitsPerSec > 0) {
      // 1 Mbit = 125_000 bytes/sec.
      bps = (megabitsPerSec * 125000).round();
    }
    await _mutateLink(linkId, (Link link) {
      return link.copyWith(speedCapBps: bps);
    });
  }

  /// Update the per-link monthly data cap. Pass `null` to clear the cap.
  /// [gigabytes] is converted to bytes (×1_000_000_000) for storage.
  Future<void> setLinkDataCapGb(String linkId, double? gigabytes) async {
    int? bytes;
    if (gigabytes != null && gigabytes > 0) {
      bytes = (gigabytes * 1000000000).round();
    }
    await _mutateLink(linkId, (Link link) {
      return link.copyWith(dataCapBytes: bytes);
    });
  }

  /// Helper that finds [linkId] in the current settings, applies [transform],
  /// and writes the result back via [setLinks]. No-op when the link is not
  /// present, so callers don't need to special-case races against a delete.
  Future<void> _mutateLink(String linkId, Link Function(Link) transform) async {
    List<Link> next = <Link>[];
    bool found = false;
    for (Link link in settings.links) {
      if (link.id == linkId) {
        next.add(transform(link));
        found = true;
      } else {
        next.add(link);
      }
    }
    if (!found) {
      return;
    }
    await setLinks(next);
  }

  /// New typed API to replace the [Policy] wholesale (e.g. mode change, kill
  /// switch toggle). Keeps the link list in sync to avoid drift.
  Future<void> setPolicy(Policy policy) async {
    Policy reconciled = policy.copyWith(links: settings.links);
    settings = settings.copyWith(policy: reconciled);
    await settings.save(settingsBox);
    probeService.updateLinks(reconciled.links);
    _reconcileCaptiveDetectors();
    Policy view = _effectivePolicy();
    supervisor.updatePolicy(view);
    if (isRunning) {
      await _transport.updatePolicy(view);
    }
    notifyListeners();
  }

  /// Focused setter for the kill-switch flag. Equivalent to
  /// `setPolicy(policy.copyWith(killSwitch: value))` but typed for the UI.
  ///
  /// Turning the switch off while it's actively engaging will clear any
  /// pending kill-switch state on the next supervisor tick, since the
  /// supervisor's `killSwitchActive` is gated on `policy.killSwitch`.
  Future<void> setKillSwitch(bool value) async {
    if (settings.policy.killSwitch == value) {
      return;
    }
    await setPolicy(settings.policy.copyWith(killSwitch: value));
  }

  /// Focused setter for the active bonding mode (Speed / Redundant /
  /// Streaming / Local). Equivalent to
  /// `setPolicy(policy.copyWith(mode: value))` but typed for the UI.
  ///
  /// The transport's underlying `BondedSession` (when wired) honors mode
  /// changes mid-stream without dropping in-flight frames — see
  /// `BondedSession.setMode` and the Phase 10 loopback test
  /// `setMode at runtime swaps strategies without dropping the stream`.
  Future<void> setBondingMode(BondingMode value) async {
    if (settings.policy.mode == value) {
      return;
    }
    await setPolicy(settings.policy.copyWith(mode: value));
  }

  /// Toggle the streaming/QoS prioritization. When enabled, the tunnel's
  /// classifier tags Zoom/WebRTC/SNI-matched flows and the bonded session
  /// routes them through its real-time lane. When disabled all flows ride
  /// the bulk scheduler regardless of port/SNI.
  ///
  /// The toggle is part of `policy.streamingDetection` so the extension
  /// (which actually does the classifying) sees the change as soon as the
  /// next policy.json write lands.
  Future<void> setStreamingDetection(bool value) async {
    if (settings.policy.streamingDetection == value) {
      return;
    }
    await setPolicy(settings.policy.copyWith(streamingDetection: value));
  }

  /// Manual per-link protocol override. Used by the Phase 11 chip UI to
  /// pin a link to UDP / TCP / TLS regardless of the auto-ladder's
  /// current verdict. Passing `null` clears the override and falls back
  /// to whatever the negotiation loop last picked.
  ///
  /// The state is transient (not persisted) because operational
  /// conditions change frequently — pinning a link forever would defeat
  /// the auto-failover machinery. The UI surfaces this via a chip on
  /// each link card.
  void setLinkProtocol(String linkId, LinkProtocol? protocol) {
    if (protocol == null) {
      if (!linkProtocols.containsKey(linkId)) return;
      linkProtocols = <String, LinkProtocol>{...linkProtocols}
        ..remove(linkId);
    } else {
      if (linkProtocols[linkId] == protocol) return;
      linkProtocols = <String, LinkProtocol>{
        ...linkProtocols,
        linkId: protocol,
      };
    }
    notifyListeners();
  }

  /// Merge a freshly-paired peer into the policy as a [LinkKind.paired]
  /// link. Idempotent — calling twice with the same link replaces the
  /// prior entry rather than duplicating it.
  Future<void> attachPairedLink(Link link) async {
    if (link.kind != LinkKind.paired) {
      throw ArgumentError('attachPairedLink requires LinkKind.paired');
    }
    List<Link> next = <Link>[];
    bool replaced = false;
    for (Link existing in settings.policy.links) {
      if (existing.id == link.id) {
        next.add(link);
        replaced = true;
      } else {
        next.add(existing);
      }
    }
    if (!replaced) {
      next.add(link);
    }
    await setLinks(next);
  }

  /// Remove a previously-paired peer. No-op if the linkId is not paired
  /// or doesn't exist.
  Future<void> detachPairedLink(String linkId) async {
    List<Link> next = settings.policy.links
        .where((Link l) => !(l.id == linkId && l.kind == LinkKind.paired))
        .toList(growable: false);
    if (next.length == settings.policy.links.length) {
      return;
    }
    await setLinks(next);
  }

  /// Toggle the captive-portal assist subsystem. When enabled, each link
  /// runs a recurring HTTP probe and links that come back captive are
  /// demoted to `Backup` priority in the effective policy view (the on-disk
  /// link config keeps its user-chosen priority unchanged).
  Future<void> setCaptivePortalAssist(bool value) async {
    if (settings.policy.captivePortalAssist == value) {
      return;
    }
    await setPolicy(settings.policy.copyWith(captivePortalAssist: value));
    _reconcileCaptiveDetectors();
  }

  /// Returns the policy with captive links forcibly downgraded to
  /// `LinkPriority.backup`. Used wherever the controller pushes a policy to
  /// a downstream component (supervisor, transport). The on-disk policy is
  /// never rewritten — demotions only affect runtime routing.
  Policy _effectivePolicy() {
    if (!settings.policy.captivePortalAssist || captiveStates.isEmpty) {
      return settings.policy;
    }
    bool anyDemotion = false;
    List<Link> next = <Link>[];
    for (Link link in settings.policy.links) {
      CaptivePortalProbeResult? state = captiveStates[link.id];
      if (state == CaptivePortalProbeResult.captive &&
          link.priority != LinkPriority.backup &&
          link.priority != LinkPriority.never) {
        anyDemotion = true;
        next.add(link.copyWith(priority: LinkPriority.backup));
      } else {
        next.add(link);
      }
    }
    if (!anyDemotion) {
      return settings.policy;
    }
    return settings.policy.copyWith(links: next);
  }

  /// Reconciles the set of running [CaptivePortalDetector] instances against
  /// the current policy. Idempotent — calling repeatedly with no change is
  /// a no-op. Tears down detectors for removed links and spins up detectors
  /// for new ones (provided assist is enabled).
  void _reconcileCaptiveDetectors() {
    bool assist = settings.policy.captivePortalAssist;
    Set<String> wantedIds = assist
        ? settings.policy.links
            .map((Link l) => l.id)
            .where((String id) => id.isNotEmpty)
            .toSet()
        : <String>{};
    // Tear down detectors that should no longer exist.
    List<String> toRemove = <String>[];
    for (String existing in _captiveDetectors.keys) {
      if (!wantedIds.contains(existing)) {
        toRemove.add(existing);
      }
    }
    for (String id in toRemove) {
      _captiveSubscriptions.remove(id)?.cancel();
      _captiveDetectors.remove(id)?.cancelTimer();
      captiveStates = <String, CaptivePortalProbeResult>{...captiveStates}
        ..remove(id);
    }
    // Spin up detectors for newly-eligible links.
    for (Link link in settings.policy.links) {
      if (!assist) break;
      if (_captiveDetectors.containsKey(link.id)) continue;
      CaptivePortalDetector det = CaptivePortalDetector(
        link: link,
        resolveSource: () => resolveLinkSource(link, interfaces),
        probe: _captiveProbe,
        target: _captiveTarget,
      );
      _captiveDetectors[link.id] = det;
      _captiveSubscriptions[link.id] = det.stream.listen(
        (CaptivePortalState s) => _handleCaptiveState(link.id, s),
      );
      det.start();
    }
    if (toRemove.isNotEmpty) {
      notifyListeners();
    }
  }

  void _handleCaptiveState(String linkId, CaptivePortalState s) {
    CaptivePortalProbeResult? effective = s.effective;
    if (effective == null) return;
    CaptivePortalProbeResult? prior = captiveStates[linkId];
    if (prior == effective) return;
    captiveStates = <String, CaptivePortalProbeResult>{
      ...captiveStates,
      linkId: effective,
    };
    // Re-publish the (possibly demoted) policy to downstream subsystems
    // so the supervisor and a running transport pick up the change at
    // once. Both calls are no-ops when nothing actually changed.
    Policy view = _effectivePolicy();
    supervisor.updatePolicy(view);
    if (isRunning) {
      unawaited(_transport.updatePolicy(view));
    }
    notifyListeners();
  }


  /// Switch to a different transport backend. The current backend is stopped
  /// and disposed; the new one takes over the streams and persisted settings.
  Future<void> setTransportKind(TransportKind kind) async {
    if (kind == _transport.kind) {
      return;
    }
    await stopProxy();
    await _detachTransport();
    settings = settings.copyWith(transportKind: kind);
    await settings.save(settingsBox);
    _transport = _transportFactory(kind, settings);
    _wireTransport();
    notifyListeners();
  }

  Future<void> startProxy() async {
    if (_transport.status.isRunning) {
      return;
    }
    // User-initiated start always clears any pending kill-switch resume flag.
    // The supervisor will re-engage if the link state actually warrants it.
    _stoppedByKillSwitch = false;
    errorText = null;
    notifyListeners();
    try {
      await _transport.start(settings.policy);
    } catch (error) {
      errorText = error.toString();
      addEvent(ProxyEvent(type: ProxyEventType.error, message: errorText!));
    }
    notifyListeners();
  }

  Future<void> stopProxy() async {
    // User-initiated stop wins over the supervisor — clear the flag so the
    // supervisor doesn't auto-resume on the next healthy event.
    _stoppedByKillSwitch = false;
    await _stopInternal();
  }

  /// Internal stop path used by both the user button and the kill switch.
  /// Skips the [_stoppedByKillSwitch] reset so the supervisor's stop call
  /// keeps the flag it set just before invoking this.
  Future<void> _stopInternal() async {
    if (!_transport.status.isRunning) {
      return;
    }
    await _transport.stop();
    notifyListeners();
  }

  void addEvent(ProxyEvent event) {
    events = <ProxyEvent>[event, ...events].take(80).toList();
    notifyListeners();
  }

  void _wireTransport() {
    _statusSubscription = _transport.states.listen((TransportStatus _) {
      notifyListeners();
    });
    _eventSubscription = _transport.events.listen(addEvent);
    _flowSubscription = _transport.flows.listen(_handleFlow);
    _metricSubscription = _transport.metrics.listen(_handleMetric);
  }

  void _wireProbes() {
    _probeMetricSubscription =
        probeService.metrics.listen((LinkMetric metric) {
      metricStore.record(metric);
      _handleMetric(metric);
    });
  }

  /// Push the current policy into the supervisor and subscribe to its health
  /// events. The supervisor's verdict drives the kill switch and (in Phase
  /// 4) automatic restart when the active policy group changes.
  void _wireSupervisor() {
    supervisor.updatePolicy(settings.policy);
    if (linkMetrics.isNotEmpty) {
      supervisor.updateMetrics(linkMetrics);
    }
    _supervisorSubscription =
        supervisor.events.listen(_handleHealthEvent);
  }

  /// Start polling macOS for friendly per-interface names (SSIDs, hardware
  /// port labels) and propagate refresh events to the UI by rebuilding the
  /// controller. The service is a [ChangeNotifier]; we forward its ticks
  /// through [notifyListeners] so listening widgets re-render with the
  /// freshest names without having to subscribe twice.
  ///
  /// We attach the listener here but defer [NetworkNamingService.start] to
  /// [init]. Reason: starting a periodic timer from the constructor
  /// triggers the Flutter widget-test framework's "pending timer" guard,
  /// since the timer outlives the test even when [dispose] is called
  /// asynchronously.
  void _wireNamingService() {
    namingService.addListener(_onNamingChanged);
  }

  void _onNamingChanged() {
    // The service already debounces unchanged snapshots; if we got here a
    // real change happened. Notify so the home screen swaps `en0` for the
    // current SSID, etc.
    notifyListeners();
  }

  /// Kill-switch driver. When the supervisor reports `killSwitchActive` and
  /// the transport is still running, stop it; when the switch releases AND
  /// `startProxyOnLaunch` was on (i.e. the user had asked for auto-run),
  /// resume.
  ///
  /// We never auto-restart a user-stopped transport, only one that the kill
  /// switch shut down — the [stoppedByKillSwitch] guard tracks that.
  void _handleHealthEvent(LinkHealthEvent event) {
    lastHealthEvent = event;
    // Keep the running transport's metric snapshot in sync so the next
    // updatePolicy / restart sees the latest readings without a round-trip.
    Transport active = _transport;
    if (active is SocksTransport) {
      active.applyMetrics(linkMetrics);
    }

    if (event.killSwitchActive && _transport.status.isRunning) {
      _stoppedByKillSwitch = true;
      addEvent(ProxyEvent(
        type: ProxyEventType.warning,
        message:
            'Kill switch engaged: no eligible links, stopping proxy.',
      ));
      unawaited(_stopInternal());
    } else if (!event.killSwitchActive &&
        _stoppedByKillSwitch &&
        event.decision.hasEligible) {
      _stoppedByKillSwitch = false;
      addEvent(ProxyEvent(
        type: ProxyEventType.info,
        message: 'Kill switch released: resuming proxy.',
      ));
      unawaited(startProxy());
    }
    notifyListeners();
  }

  /// Tracks whether the most recent `stop` was driven by the kill switch.
  /// Prevents the supervisor from resurrecting a user-stopped transport.
  bool _stoppedByKillSwitch = false;

  Future<void> _detachTransport() async {
    await _statusSubscription?.cancel();
    await _eventSubscription?.cancel();
    await _flowSubscription?.cancel();
    await _metricSubscription?.cancel();
    _statusSubscription = null;
    _eventSubscription = null;
    _flowSubscription = null;
    _metricSubscription = null;
    await _transport.dispose();
  }

  void _handleFlow(FlowStat flow) {
    int idx = flows.indexWhere((FlowStat existing) {
      return existing.flowId == flow.flowId;
    });
    if (idx >= 0) {
      List<FlowStat> next = List<FlowStat>.of(flows);
      next[idx] = flow;
      flows = next;
    } else {
      flows = <FlowStat>[flow, ...flows].take(64).toList();
    }
    notifyListeners();
  }

  void _handleMetric(LinkMetric metric) {
    linkMetrics = <String, LinkMetric>{
      ...linkMetrics,
      metric.linkId: metric,
    };
    supervisor.updateMetric(metric);
    notifyListeners();
  }

  @override
  void dispose() {
    // Synchronously cancel periodic probe timers so the Flutter test binding
    // doesn't trip its pending-timer assertion in tearDown. The async parts
    // of stop() flush streams in the background.
    probeService.cancelTimers();
    for (CaptivePortalDetector detector in _captiveDetectors.values) {
      detector.cancelTimer();
    }
    unawaited(_probeMetricSubscription?.cancel());
    unawaited(_supervisorSubscription?.cancel());
    for (StreamSubscription<CaptivePortalState> sub
        in _captiveSubscriptions.values) {
      unawaited(sub.cancel());
    }
    _captiveSubscriptions.clear();
    for (CaptivePortalDetector detector in _captiveDetectors.values) {
      unawaited(detector.stop());
    }
    _captiveDetectors.clear();
    unawaited(probeService.stop());
    unawaited(metricStore.dispose());
    unawaited(supervisor.dispose());
    namingService.removeListener(_onNamingChanged);
    namingService.dispose();
    unawaited(_detachTransport());
    super.dispose();
  }

  /// Default factory used when callers don't pass their own.
  ///
  /// The factory always builds a fresh transport (we never reuse an instance
  /// across kinds), and the SOCKS transport reads its listen host/port from
  /// the persisted settings so the existing UI fields keep working.
  ///
  /// The Hive [Box] is forwarded to the SOCKS transport so per-link data
  /// caps (Phase 3 [DataMeter]) survive restarts.
  static TransportFactory _defaultTransportFactory(
    NetworkInterfaceRepository repository,
    Box meterStorage,
  ) {
    return (TransportKind kind, DispatchSettings settings) {
      switch (kind) {
        case TransportKind.socks:
          return SocksTransport(
            repository: repository,
            meterStorage: meterStorage,
            config: SocksTransportConfig(
              listenHost: settings.listenHost,
              listenPort: settings.listenPort,
            ),
          );
        case TransportKind.tunnel:
          // Phase 5: system-wide tunnel via the Network Extension. The
          // platform side (TunnelManager.swift) is wired through the
          // `dispatch_tunnel` channel; the transport handles install +
          // start + status polling. On non-macOS hosts the transport falls
          // back to a `failed` state with a friendly explanation.
          return TunnelTransport();
      }
    };
  }
}
