import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../core/policy.dart';

/// Status enum mirroring `TunnelStatus` on the Swift side
/// (`macos/Runner/TunnelManager.swift`). Keep in lock-step or status callbacks
/// will silently fall through to [TunnelStatusKind.unknown].
enum TunnelStatusKind {
  /// We have no read on the tunnel state — the channel hasn't replied yet, or
  /// the platform is not macOS so the bridge isn't available.
  unknown,

  /// The System Extension is not installed / not approved. The UI should
  /// prompt the user to install via [TunnelChannel.installExtension] before
  /// any start attempt.
  extensionMissing,

  /// Extension is installed but the tunnel is not running.
  stopped,

  /// `startVPNTunnel` was called but the kernel has not reported `connected`
  /// yet (or the extension is reasserting after a Wi-Fi handoff).
  starting,

  /// Tunnel is up and traffic is flowing.
  connected,

  /// `stopVPNTunnel` was called but the kernel has not reported
  /// `disconnected` yet.
  stopping,

  /// Start/connect attempt failed. [TunnelStatus.lastError] holds the most
  /// recent failure reason from the platform.
  failed,
}

/// Snapshot returned by [TunnelChannel.status]. Plain data — the channel
/// rebuilds these on every call so there's no aliasing risk.
class TunnelStatus {
  final TunnelStatusKind kind;

  /// Free-form last-error string (e.g. "Permission denied", "No system
  /// extension found"). `null` when the tunnel hasn't failed since launch.
  final String? lastError;

  /// Bundle identifier of the extension the manager is targeting. Echoed back
  /// purely so the UI can show "Installing art.arcane.ArcaneDispatch.tunnel"
  /// during a sysext approval flow.
  final String extensionBundleId;

  const TunnelStatus({
    required this.kind,
    required this.extensionBundleId,
    this.lastError,
  });

  factory TunnelStatus.unknown() {
    return const TunnelStatus(
      kind: TunnelStatusKind.unknown,
      extensionBundleId: '',
    );
  }

  /// Decode a platform reply (a `Map<Object?, Object?>` as it comes off the
  /// channel) into a typed [TunnelStatus].
  factory TunnelStatus.fromPlatform(Map<Object?, Object?> raw) {
    String? kindRaw = raw['kind'] as String?;
    TunnelStatusKind kind = TunnelStatusKind.values.firstWhere(
      (TunnelStatusKind k) => k.name == kindRaw,
      orElse: () => TunnelStatusKind.unknown,
    );
    return TunnelStatus(
      kind: kind,
      lastError: raw['lastError'] as String?,
      extensionBundleId: (raw['extensionBundleId'] as String?) ?? '',
    );
  }

  bool get isRunning {
    return kind == TunnelStatusKind.connected ||
        kind == TunnelStatusKind.starting;
  }
}

/// Outcome of [TunnelChannel.installExtension]. The Swift side returns either
/// `true` (already activated), a map with `pending: true` (awaiting user
/// approval), or a [PlatformException].
class TunnelInstallResult {
  /// True iff the extension is activated and ready to start. When false the
  /// UI should keep the "Install" CTA visible and tell the user to approve in
  /// System Settings → Privacy & Security.
  final bool activated;

  /// True when the extension was submitted but is waiting on user approval.
  final bool pending;

  /// Optional error string when activation failed outright.
  final String? errorMessage;

  const TunnelInstallResult({
    required this.activated,
    required this.pending,
    this.errorMessage,
  });

  factory TunnelInstallResult.ok() {
    return const TunnelInstallResult(activated: true, pending: false);
  }

  factory TunnelInstallResult.pending() {
    return const TunnelInstallResult(activated: false, pending: true);
  }

  factory TunnelInstallResult.error(String message) {
    return TunnelInstallResult(
      activated: false,
      pending: false,
      errorMessage: message,
    );
  }
}

/// Dart-side wrapper around the `dispatch_tunnel` [MethodChannel].
///
/// Stateless on its own — every public method maps 1:1 to a Swift
/// `MethodCall`. Callers should hold a single instance per app since
/// constructing a new `MethodChannel` is fine but the platform handler is
/// global.
///
/// All methods throw `PlatformException` on platform-level failures and a
/// `TunnelUnavailableException` when the channel isn't reachable (e.g. on
/// non-macOS hosts during widget tests).
class TunnelChannel {
  /// Channel name shared with `macos/Runner/TunnelManager.swift`. Don't
  /// hard-code in client code — read via [TunnelChannel.channelName] so a
  /// rename only edits one place.
  static const String channelName = 'dispatch_tunnel';

  final MethodChannel _channel;

  TunnelChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// Submit the System Extension activation request. Idempotent: if the
  /// extension is already running, the platform returns `true` and we
  /// resolve to [TunnelInstallResult.ok].
  Future<TunnelInstallResult> installExtension() async {
    try {
      Object? response = await _channel.invokeMethod<Object?>('installExtension');
      if (response is bool && response) {
        return TunnelInstallResult.ok();
      }
      if (response is Map && response['pending'] == true) {
        return TunnelInstallResult.pending();
      }
      return TunnelInstallResult.error(
        'Unexpected installExtension response: $response',
      );
    } on PlatformException catch (e) {
      return TunnelInstallResult.error(e.message ?? e.code);
    } on MissingPluginException {
      throw TunnelUnavailableException();
    }
  }

  /// Bring the tunnel up. When [policy] is non-null we push the latest
  /// snapshot to the App Group container first so the extension reads the
  /// freshest links list on `startTunnel`.
  Future<void> startTunnel({Policy? policy}) async {
    Map<String, Object?> args = <String, Object?>{};
    if (policy != null) {
      args['policyJson'] = jsonEncode(policy.toJson());
    }
    try {
      await _channel.invokeMethod<Object?>('startTunnel', args);
    } on MissingPluginException {
      throw TunnelUnavailableException();
    }
  }

  Future<void> stopTunnel() async {
    try {
      await _channel.invokeMethod<Object?>('stopTunnel');
    } on MissingPluginException {
      throw TunnelUnavailableException();
    }
  }

  /// Write [policy] to the App Group container and ask the running extension
  /// to reload it. Safe to call when the tunnel isn't running — the policy
  /// will be picked up on the next `startTunnel` anyway.
  Future<void> reloadPolicy(Policy policy) async {
    try {
      await _channel.invokeMethod<Object?>('reloadPolicy', <String, Object?>{
        'policyJson': jsonEncode(policy.toJson()),
      });
    } on MissingPluginException {
      throw TunnelUnavailableException();
    }
  }

  /// Persist the policy without restarting or messaging the extension. Useful
  /// when the user toggles a link from the UI while the tunnel is stopped;
  /// the next start uses the fresh JSON.
  Future<bool> writePolicy(Policy policy) async {
    try {
      Object? response = await _channel.invokeMethod<Object?>(
        'writePolicy',
        <String, Object?>{'policyJson': jsonEncode(policy.toJson())},
      );
      return response == true;
    } on MissingPluginException {
      throw TunnelUnavailableException();
    }
  }

  Future<TunnelStatus> status() async {
    try {
      Object? response = await _channel.invokeMethod<Object?>('status');
      if (response is Map) {
        return TunnelStatus.fromPlatform(response.cast<Object?, Object?>());
      }
      return TunnelStatus.unknown();
    } on MissingPluginException {
      throw TunnelUnavailableException();
    }
  }

  /// Absolute filesystem path to the `flow_stats.bin` ring buffer the
  /// extension writes inside the App Group container. Returns null when the
  /// container isn't reachable (entitlement misconfig). Used by
  /// [FlowStatsReader] to mmap the shared file.
  Future<String?> flowStatsPath() async {
    try {
      Object? response = await _channel.invokeMethod<Object?>('flowStatsPath');
      if (response is String) {
        return response;
      }
      return null;
    } on MissingPluginException {
      throw TunnelUnavailableException();
    }
  }

  /// Tell the extension which Speed Server to talk to. The endpoint is a
  /// `host:port` literal (e.g. `relay.example.com:4430`) and the bearer
  /// `token` is the value `dispatch-speed-server adduser` printed.
  ///
  /// We round-trip through the App Group container so the extension can
  /// pick up changes without a tunnel restart — see Phase 8.12 of the
  /// master plan and the matching Swift handler in
  /// `macos/Runner/TunnelManager.swift`.
  ///
  /// `endpoint` empty + `token` empty clears the configuration and falls
  /// back to local mode (Phase 16).
  Future<bool> setServer({required String endpoint, required String token}) async {
    try {
      Object? response = await _channel.invokeMethod<Object?>(
        'setServer',
        <String, Object?>{
          'endpoint': endpoint,
          'token': token,
        },
      );
      return response == true;
    } on MissingPluginException {
      throw TunnelUnavailableException();
    }
  }

  /// Read the currently-configured Speed Server (if any). Returned map has
  /// `endpoint` (string) and a `tokenSet` (bool) — we deliberately do not
  /// surface the bearer token to the UI to minimise the chance of it ending
  /// up in screenshots or log scrapes.
  Future<TunnelServerConfig> getServer() async {
    try {
      Object? response = await _channel.invokeMethod<Object?>('getServer');
      if (response is Map) {
        return TunnelServerConfig.fromPlatform(response.cast<Object?, Object?>());
      }
      return TunnelServerConfig.empty();
    } on MissingPluginException {
      throw TunnelUnavailableException();
    }
  }

  /// Returns this client's persistent Noise IK public key as base64. The
  /// Swift side generates + persists a fresh keypair on first call via
  /// Keychain so subsequent launches keep the same identity (matches the
  /// Phase 9.11 spec). Returns null when the platform channel isn't
  /// available (non-macOS hosts during tests).
  Future<String?> getClientPublicKey() async {
    try {
      Object? response = await _channel.invokeMethod<Object?>('getClientPublicKey');
      if (response is String) {
        return response;
      }
      return null;
    } on MissingPluginException {
      throw TunnelUnavailableException();
    }
  }

  /// Persist the responder's static public key (the operator paste-blob
  /// next to the Speed Server URL). Pass an empty string to clear. The
  /// extension reads this on `startTunnel` to seed the Noise IK
  /// initiator state. Returns true on success.
  Future<bool> setResponderPublicKey(String publicKeyBase64) async {
    try {
      Object? response = await _channel.invokeMethod<Object?>(
        'setResponderPublicKey',
        <String, Object?>{'publicKey': publicKeyBase64},
      );
      return response == true;
    } on MissingPluginException {
      throw TunnelUnavailableException();
    }
  }
}

/// Thrown when the platform side of the tunnel bridge isn't reachable — e.g.
/// on Linux/Windows builds or during widget tests on a host with no native
/// channel. The UI should fall back to SOCKS or show "tunnel not available"
/// rather than crash.
class TunnelUnavailableException implements Exception {
  TunnelUnavailableException();

  @override
  String toString() {
    return 'Tunnel bridge is not available on this platform.';
  }
}

/// View of the persisted Speed Server config. The Swift side never echoes
/// the bearer token back over the channel — only a `tokenSet` flag — so
/// the UI can render "configured ✓" without ever holding the secret.
class TunnelServerConfig {
  /// `host:port` literal of the configured relay. Empty string means
  /// "no server configured", in which case the tunnel runs in local mode.
  final String endpoint;

  /// True iff a non-empty bearer token is stored alongside the endpoint.
  final bool tokenSet;

  const TunnelServerConfig({required this.endpoint, required this.tokenSet});

  factory TunnelServerConfig.empty() {
    return const TunnelServerConfig(endpoint: '', tokenSet: false);
  }

  factory TunnelServerConfig.fromPlatform(Map<Object?, Object?> raw) {
    return TunnelServerConfig(
      endpoint: (raw['endpoint'] as String?) ?? '',
      tokenSet: raw['tokenSet'] == true,
    );
  }

  /// Convenience helper for the UI: are we ready to use the bonded
  /// transport, or should we keep the user on local mode?
  bool get isConfigured => endpoint.isNotEmpty && tokenSet;
}
