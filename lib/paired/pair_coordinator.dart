import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/link.dart';
import '../crypto/noise.dart';
import 'pair_beacon.dart';
import 'pair_session.dart';
import 'tcp_pair_channel.dart';

/// High-level driver for Pair & Share that the UI talks to.
///
/// Wraps the lower-level [PairDiscovery] / [PairSession] / [TcpPairChannel]
/// pieces so the UI can call simple "host" / "join" / "stop" methods
/// without knowing about Noise, TCP framing, or Bonjour.
///
/// State model:
/// ```
///   off ──host()──> hosting ──join arrives──> verifying ──approve──> attached
///       ──discover()──> browsing
///       ──join(beacon)──> dialing ──recv──> verifying ──approve──> attached
/// ```
///
/// All transitions are exposed via [ChangeNotifier] so the UI can repaint
/// without subscribing to N separate streams.
///
/// The coordinator is intentionally **decoupled from the controller** so
/// the existing widget test (which doesn't touch pairing) is unaffected.
/// `DispatchController.pairCoordinator` lazily constructs one on first
/// access; tests that don't need pairing never trigger the wiring.
class PairCoordinator extends ChangeNotifier {
  /// Pluggable discovery surface. Production injects a
  /// [PairedMethodChannelDiscovery] (Bonjour bridge); the loopback
  /// implementation is used in dev / tests.
  final PairDiscovery? _discovery;

  /// Local Noise identity for the *device*. Memoized — every handshake
  /// runs against the same long-lived static keypair.
  final Future<NoiseKeypair> _identity;

  /// Human-readable name for this Mac. Surfaced on the peer's "verify"
  /// screen so they know whose handshake they're confirming.
  final String _deviceName;

  /// Stable device id. Used as the dedupe key in [PairBeacon] and as the
  /// id of the resulting paired [Link] so a single peer doesn't pile up
  /// multiple paired entries across pair/unpair cycles.
  final String _deviceId;

  /// Hook the UI uses to read the live peer list. Updated by the
  /// discovery stream subscription.
  final Map<String, PairBeacon> _peers = <String, PairBeacon>{};
  StreamSubscription<PairBeaconEvent>? _discoverySub;

  /// `true` while we're listening for incoming joiners on the local
  /// rendezvous port and advertising via [PairDiscovery.publish].
  bool _hosting = false;
  ServerSocket? _server;
  StreamSubscription<Socket>? _serverSub;

  /// Set during an in-flight handshake on either side. The UI reads
  /// this to render the "confirm these 6 digits match" modal.
  PairHandshake? _pending;

  /// Last error surfaced to the UI. Cleared on the next successful
  /// transition. Friendly text — safe to drop into a banner.
  String? _errorText;

  PairCoordinator({
    required PairDiscovery? discovery,
    required Future<NoiseKeypair> identity,
    required String deviceName,
    required String deviceId,
  })  : _discovery = discovery,
        _identity = identity,
        _deviceName = deviceName,
        _deviceId = deviceId;

  /// All peers currently visible on the local network. Empty when the
  /// discovery has not been started, or when the platform layer has no
  /// Bonjour bridge wired up (e.g. non-macOS hosts).
  List<PairBeacon> get peers {
    return List<PairBeacon>.unmodifiable(_peers.values);
  }

  bool get isHosting => _hosting;
  PairHandshake? get pendingHandshake => _pending;
  String? get errorText => _errorText;

  /// Begin browsing for peers. Idempotent; safe to call from `initState`.
  Future<void> startDiscovery() async {
    if (_discoverySub != null) return;
    PairDiscovery? d = _discovery;
    if (d == null) return;
    _discoverySub = d.watch().listen(_onDiscoveryEvent);
    notifyListeners();
  }

  /// Stop browsing. The peer cache is preserved so the UI doesn't blink.
  Future<void> stopDiscovery() async {
    await _discoverySub?.cancel();
    _discoverySub = null;
    notifyListeners();
  }

  void _onDiscoveryEvent(PairBeaconEvent event) {
    if (event.type == PairBeaconEventType.found) {
      _peers[event.beacon.deviceId] = event.beacon;
    } else {
      _peers.remove(event.beacon.deviceId);
    }
    notifyListeners();
  }

  /// Begin hosting. Binds a TCP rendezvous socket, publishes a
  /// [PairBeacon] via the discovery surface (so other Macs on the LAN
  /// see us), and awaits the first incoming joiner.
  ///
  /// [preferredPort] is the *rendezvous* port — the same value goes
  /// into the published [PairBeacon.port]. Defaults to 0, letting the
  /// OS pick a free port.
  ///
  /// On the first incoming connection [PairSession.host] runs, and the
  /// resulting handshake is parked in [pendingHandshake] for the user
  /// to confirm via [approvePendingHandshake] / [cancelPendingHandshake].
  Future<void> startHosting({int preferredPort = 0}) async {
    if (_hosting) return;
    try {
      _errorText = null;
      ServerSocket s = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        preferredPort,
      );
      _server = s;
      _serverSub = s.listen(_onIncoming, onError: (Object e) {
        _errorText = 'Hosting error: $e';
        notifyListeners();
      });
      _hosting = true;
      notifyListeners();
      PairDiscovery? d = _discovery;
      if (d != null) {
        PairBeacon self = PairBeacon(
          deviceId: _deviceId,
          deviceName: _deviceName,
          host: _localBindHost(s.address),
          port: s.port,
          fingerprint: await _selfFingerprint(),
        );
        await d.publish(self);
      }
    } catch (e) {
      _errorText = 'Could not start hosting: $e';
      _hosting = false;
      _server = null;
      _serverSub = null;
      notifyListeners();
    }
  }

  /// Stop hosting. Tears down the rendezvous socket and unpublishes
  /// from discovery. Any in-flight handshake is cancelled.
  Future<void> stopHosting() async {
    if (!_hosting) return;
    _hosting = false;
    await _serverSub?.cancel();
    _serverSub = null;
    await _server?.close();
    _server = null;
    PairDiscovery? d = _discovery;
    if (d != null) await d.unpublish();
    PairHandshake? p = _pending;
    if (p != null && p.role == PairRole.host) {
      _pending = null;
      await p.channel.close();
    }
    notifyListeners();
  }

  Future<void> _onIncoming(Socket socket) async {
    if (_pending != null) {
      // We only accept one joiner at a time. Drop subsequent connects.
      await socket.close();
      return;
    }
    NoiseKeypair me = await _identity;
    TcpPairChannel ch = TcpPairChannel.accept(socket);
    String endpoint =
        '${_localBindHost(_server?.address ?? InternetAddress.anyIPv4)}:${_server?.port ?? 0}';
    try {
      PairOutcome outcome = await PairSession.host(
        channel: ch,
        me: me,
        hostName: _deviceName,
        endpoint: endpoint,
        hostDeviceId: _deviceId,
      );
      _pending = PairHandshake(
        role: PairRole.host,
        outcome: outcome,
        channel: ch,
      );
      notifyListeners();
    } catch (e) {
      _errorText = 'Pairing handshake failed: $e';
      await ch.close();
      notifyListeners();
    }
  }

  /// Initiate a join against a discovered peer. Opens a TCP connection
  /// to `beacon.host:beacon.port`, runs the Noise handshake, and parks
  /// the result in [pendingHandshake] for the user to confirm.
  ///
  /// Throws nothing — errors are surfaced through [errorText] so the UI
  /// can render them in-place rather than crashing.
  Future<void> joinPeer(
    PairBeacon beacon, {
    Uint8List? remoteStatic,
  }) async {
    if (_pending != null) return;
    try {
      _errorText = null;
      NoiseKeypair me = await _identity;
      TcpPairChannel ch = await TcpPairChannel.connect(beacon.host, beacon.port);
      // Beacon fingerprint is 16 hex chars (truncated SHA-256). For
      // production this is supplied by the platform bridge along with
      // the remote static public key. If the caller didn't supply one,
      // we accept the beacon's fingerprint at face value and let the
      // post-handshake verify-code modal be the user-facing check.
      Uint8List rs = remoteStatic ?? Uint8List(32);
      PairOutcome outcome = await PairSession.join(
        channel: ch,
        me: me,
        beacon: beacon,
        remoteStatic: rs,
      );
      _pending = PairHandshake(
        role: PairRole.join,
        outcome: outcome,
        channel: ch,
      );
      notifyListeners();
    } catch (e) {
      _errorText = 'Could not connect to ${beacon.deviceName}: $e';
      notifyListeners();
    }
  }

  /// Approve the in-flight handshake. Returns the freshly-built
  /// paired [Link] so the caller can attach it via the controller's
  /// `attachPairedLink`.
  Future<Link?> approvePendingHandshake() async {
    PairHandshake? p = _pending;
    if (p == null) return null;
    _pending = null;
    // Don't close the channel — the [NoiseTransport] returned from the
    // handshake will continue to ship sealed packets over it.
    notifyListeners();
    return p.outcome.link;
  }

  /// Reject the in-flight handshake. Closes the channel and re-arms
  /// hosting if we were the host.
  Future<void> cancelPendingHandshake() async {
    PairHandshake? p = _pending;
    if (p == null) return;
    _pending = null;
    _errorText = 'Pairing cancelled.';
    await p.channel.close();
    notifyListeners();
  }

  /// SHA-256(public-key) truncated to 16 hex chars — same shape used
  /// across [PairBeacon.fingerprint] and [Link.pairedFingerprint].
  Future<String> _selfFingerprint() async {
    NoiseKeypair me = await _identity;
    return PairSession.fingerprintOf(me.public);
  }

  /// Pick a presentable host string for our advertised beacon. Anywhere
  /// we bound to 0.0.0.0 we report the most likely externally-reachable
  /// LAN IP — the discovery side will hand the responder the address
  /// they actually saw the beacon arrive on, so this is purely cosmetic
  /// (for the host's own "Hosting on …" line).
  static String _localBindHost(InternetAddress addr) {
    if (addr.isLoopback) return addr.address;
    if (addr.address == '0.0.0.0' || addr.address == '::') {
      return 'this device';
    }
    return addr.address;
  }

  @override
  void dispose() {
    unawaited(stopDiscovery());
    unawaited(stopHosting());
    unawaited(_discovery?.dispose());
    super.dispose();
  }
}

/// Which side of an in-flight handshake we're driving.
enum PairRole { host, join }

/// Held in [PairCoordinator.pendingHandshake] while the user is
/// inspecting the verify code. The UI calls [PairCoordinator.approvePendingHandshake]
/// to commit, or [PairCoordinator.cancelPendingHandshake] to drop the channel.
class PairHandshake {
  final PairRole role;
  final PairOutcome outcome;
  final PairChannel channel;

  const PairHandshake({
    required this.role,
    required this.outcome,
    required this.channel,
  });

  /// 6-digit code derived from the Noise transcript hash. Same value
  /// on both sides when the handshake wasn't tampered with.
  String get verifyCode => outcome.verifyCode;

  /// Peer's fingerprint (first 16 hex of SHA-256 of static public key).
  String get peerFingerprint => outcome.peerFingerprint;

  /// Friendly label for the peer (their device name).
  String get peerLabel => outcome.link.label;
}
