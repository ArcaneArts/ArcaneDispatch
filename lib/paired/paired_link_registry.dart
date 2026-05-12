import 'dart:async';
import 'dart:typed_data';

import '../bonded/bonded_session.dart' show BondedSendOnLink;
import 'paired_link_socket.dart';

/// Routes outgoing bonded frames to per-link backends.
///
/// Paired links go through their [PairedLinkSocket] (which seals via the
/// per-peer Noise transport); everything else falls back to whatever
/// transport the caller wired up — typically a UDP socket bound to the
/// physical interface or, in unit tests, an in-memory loopback.
///
/// The registry also surfaces an aggregated inbound stream tagged with
/// link id so the owning [BondedSession] can call its
/// `handleInboundOnLink(linkId, bytes)` method uniformly.
class PairedLinkRegistry {
  final Map<String, PairedLinkSocket> _sockets = <String, PairedLinkSocket>{};
  final Map<String, StreamSubscription<Uint8List>> _subs =
      <String, StreamSubscription<Uint8List>>{};
  final StreamController<PairedInboundEvent> _inbound =
      StreamController<PairedInboundEvent>.broadcast();
  bool _disposed = false;

  /// Attach [socket] for the given [linkId]. Calling twice replaces the
  /// prior binding (the old socket is left alive — caller owns its
  /// lifecycle).
  void attach(String linkId, PairedLinkSocket socket) {
    if (_disposed) {
      throw StateError('PairedLinkRegistry disposed');
    }
    StreamSubscription<Uint8List>? prior = _subs.remove(linkId);
    // Cancel without awaiting — the caller may be in a hot path.
    unawaited(prior?.cancel());
    _sockets[linkId] = socket;
    _subs[linkId] = socket.inbound.listen((Uint8List bytes) {
      _inbound.add(PairedInboundEvent(linkId: linkId, bytes: bytes));
    });
  }

  /// Drop the binding for [linkId]. Returns the previously-attached socket
  /// (if any) so the caller can close it.
  PairedLinkSocket? detach(String linkId) {
    StreamSubscription<Uint8List>? sub = _subs.remove(linkId);
    unawaited(sub?.cancel());
    return _sockets.remove(linkId);
  }

  /// Currently-bound paired link ids.
  Iterable<String> get linkIds => _sockets.keys;

  /// Look up the socket bound to [linkId] or null when no paired link
  /// owns that id.
  PairedLinkSocket? socketFor(String linkId) => _sockets[linkId];

  /// Aggregated inbound stream across every attached paired link. Each
  /// event carries the originating [linkId] so the [BondedSession] can
  /// route into its reassembler.
  Stream<PairedInboundEvent> get inbound => _inbound.stream;

  /// Wrap [fallback] so that frames addressed to a paired link id are
  /// shipped via the corresponding [PairedLinkSocket]. Frames for any
  /// other link fall through to [fallback].
  ///
  /// Errors from `PairedLinkSocket.send` are swallowed and reported via
  /// [errors] — the bonded session keeps shipping on the other links.
  BondedSendOnLink wrap(BondedSendOnLink fallback) {
    return (String linkId, Uint8List bytes) {
      PairedLinkSocket? sock = _sockets[linkId];
      if (sock == null) {
        fallback(linkId, bytes);
        return;
      }
      // Fire and forget. Failures surface via [errors].
      unawaited(_sendOrLog(linkId, sock, bytes));
    };
  }

  Future<void> _sendOrLog(
    String linkId,
    PairedLinkSocket sock,
    Uint8List bytes,
  ) async {
    try {
      await sock.send(bytes);
    } catch (e) {
      _errors.add(PairedSendError(linkId: linkId, error: e));
    }
  }

  final StreamController<PairedSendError> _errors =
      StreamController<PairedSendError>.broadcast();

  /// Async errors from per-link sends. Subscribers may surface these as
  /// UI banners; the bonded session itself doesn't need to consume them.
  Stream<PairedSendError> get errors => _errors.stream;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (StreamSubscription<Uint8List> sub in _subs.values) {
      await sub.cancel();
    }
    _subs.clear();
    _sockets.clear();
    await _inbound.close();
    await _errors.close();
  }
}

class PairedInboundEvent {
  final String linkId;
  final Uint8List bytes;
  const PairedInboundEvent({required this.linkId, required this.bytes});
}

class PairedSendError {
  final String linkId;
  final Object error;
  const PairedSendError({required this.linkId, required this.error});

  @override
  String toString() => 'PairedSendError(linkId=$linkId, error=$error)';
}
