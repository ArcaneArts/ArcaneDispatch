import 'dart:async';
import 'dart:io';

import '../core/link.dart';
import '../core/link_metric.dart';
import '../core/network_interface_repository.dart';
import 'link_probe.dart';

/// Resolves a link's preferred source [InternetAddress] from its persisted
/// `sourceAddress` (literal) or `interfaceName` (looked up against the live
/// interface snapshot list). Returns `null` when neither is set or the
/// interface can't be found.
InternetAddress? resolveLinkSource(
  Link link,
  List<NetworkInterfaceSnapshot> interfaces,
) {
  if (link.sourceAddress != null && link.sourceAddress!.isNotEmpty) {
    InternetAddress? parsed = InternetAddress.tryParse(link.sourceAddress!);
    if (parsed != null) {
      return parsed;
    }
  }
  if (link.interfaceName != null) {
    for (NetworkInterfaceSnapshot iface in interfaces) {
      if (iface.name == link.interfaceName) {
        for (InternetAddress addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4) {
            return addr;
          }
        }
        if (iface.addresses.isNotEmpty) {
          return iface.addresses.first;
        }
      }
    }
  }
  return null;
}

/// Factory used by [LinkProbeService] to construct a [LinkProbe]. Lets tests
/// inject fakes without forking the service.
typedef LinkProbeFactory = LinkProbe Function({
  required Link link,
  required InternetAddress? Function() resolveSource,
  LinkProbeConfig config,
});

/// Manages the lifecycle of one [LinkProbe] per eligible [Link].
///
/// The service is the single subscriber to the union of all per-link probe
/// streams; it fans the merged stream out as a single [Stream<LinkMetric>]
/// that [DispatchController] consumes. Two reasons we centralize:
///
/// 1. The controller doesn't need to know how many probes exist — it sees
///    `linkId -> LinkMetric` updates.
/// 2. We can rate-limit, throttle, or pause probes globally (e.g. when the
///    laptop sleeps) without changing call sites.
///
/// Lifecycle:
///
/// * `updateLinks(...)` is called every time policy.links changes. The service
///   reconciles: add probes for new links, remove probes for deleted links,
///   restart probes whose source-resolution-relevant fields changed.
/// * `updateInterfaces(...)` is called when the interface snapshot list is
///   refreshed; probes pick up the new source address on the next tick.
/// * `stop()` tears down everything.
class LinkProbeService {
  final LinkProbeConfig defaultConfig;
  final LinkProbeFactory _factory;
  final StreamController<LinkMetric> _output =
      StreamController<LinkMetric>.broadcast();

  final Map<String, _ProbeEntry> _entries = <String, _ProbeEntry>{};
  List<NetworkInterfaceSnapshot> _interfaces = <NetworkInterfaceSnapshot>[];
  bool _stopped = false;

  LinkProbeService({
    this.defaultConfig = const LinkProbeConfig(),
    LinkProbeFactory? probeFactory,
  }) : _factory = probeFactory ?? _defaultFactory;

  /// Merged stream of all per-link metrics. Each event carries a [LinkMetric]
  /// stamped with the originating `linkId`.
  Stream<LinkMetric> get metrics {
    return _output.stream;
  }

  /// Most recent metric per link, useful for cold UI bootstrap. Returns a new
  /// map snapshot so callers can store / diff freely.
  Map<String, LinkMetric> snapshot() {
    Map<String, LinkMetric> result = <String, LinkMetric>{};
    _entries.forEach((String id, _ProbeEntry entry) {
      LinkMetric? last = entry.probe.latest;
      if (last != null) {
        result[id] = last;
      }
    });
    return result;
  }

  /// Reconcile the live link set. Synchronously decides which probes to add /
  /// remove / replace; spins up new probes asynchronously.
  void updateLinks(List<Link> links) {
    if (_stopped) {
      return;
    }
    Set<String> nextIds = <String>{
      for (Link link in links)
        if (_isProbable(link)) link.id,
    };
    // Remove probes whose link is gone or no longer probable.
    List<String> toRemove = _entries.keys
        .where((String id) => !nextIds.contains(id))
        .toList();
    for (String id in toRemove) {
      _removeEntry(id);
    }
    for (Link link in links) {
      if (!_isProbable(link)) {
        continue;
      }
      _ProbeEntry? existing = _entries[link.id];
      if (existing == null) {
        _spawn(link);
      } else if (_needsRespawn(existing.link, link)) {
        _removeEntry(link.id);
        _spawn(link);
      } else {
        existing.link = link;
      }
    }
  }

  /// Update the cached interface snapshots used for source-IP resolution.
  /// Cheap; just stores the list. Probes look it up at tick time.
  void updateInterfaces(List<NetworkInterfaceSnapshot> interfaces) {
    _interfaces = List<NetworkInterfaceSnapshot>.unmodifiable(interfaces);
  }

  /// Synchronously cancel every probe's periodic timer. Use this from a
  /// synchronous dispose path (e.g. `ChangeNotifier.dispose`) so the Flutter
  /// test binding doesn't trip its pending-timer assertion before the async
  /// [stop] coroutine has a chance to run.
  void cancelTimers() {
    for (_ProbeEntry entry in _entries.values) {
      entry.probe.cancelTimer();
    }
  }

  Future<void> stop() async {
    if (_stopped) {
      return;
    }
    _stopped = true;
    cancelTimers();
    List<Future<void>> closing = <Future<void>>[];
    for (_ProbeEntry entry in _entries.values) {
      closing.add(entry.dispose());
    }
    _entries.clear();
    await Future.wait(closing);
    if (!_output.isClosed) {
      await _output.close();
    }
  }

  bool _isProbable(Link link) {
    if (link.priority == LinkPriority.never) {
      return false;
    }
    return link.interfaceName != null || link.sourceAddress != null;
  }

  bool _needsRespawn(Link oldLink, Link newLink) {
    // The probe binds its source on every tick by calling resolveSource(), so
    // changes in the live interface snapshot are picked up for free. The only
    // identity-impacting fields are these:
    return oldLink.interfaceName != newLink.interfaceName ||
        oldLink.sourceAddress != newLink.sourceAddress;
  }

  void _spawn(Link link) {
    LinkProbe probe = _factory(
      link: link,
      resolveSource: () => resolveLinkSource(link, _interfaces),
      config: defaultConfig,
    );
    StreamSubscription<LinkMetric> sub = probe.stream.listen(
      (LinkMetric metric) {
        if (!_output.isClosed) {
          _output.add(metric);
        }
      },
    );
    _entries[link.id] = _ProbeEntry(link: link, probe: probe, subscription: sub);
    probe.start();
  }

  void _removeEntry(String id) {
    _ProbeEntry? entry = _entries.remove(id);
    if (entry != null) {
      // Stop the periodic timer synchronously so it can't fire one more time
      // after the link is gone (which would otherwise leak a stale metric
      // into the merged stream). The remaining teardown — subscription
      // cancel, socket close — is allowed to run asynchronously.
      entry.probe.cancelTimer();
      unawaited(entry.dispose());
    }
  }

  static LinkProbe _defaultFactory({
    required Link link,
    required InternetAddress? Function() resolveSource,
    LinkProbeConfig config = const LinkProbeConfig(),
  }) {
    return LinkProbe(
      link: link,
      resolveSource: resolveSource,
      config: config,
    );
  }
}

class _ProbeEntry {
  Link link;
  final LinkProbe probe;
  final StreamSubscription<LinkMetric> subscription;

  _ProbeEntry({
    required this.link,
    required this.probe,
    required this.subscription,
  });

  Future<void> dispose() async {
    await subscription.cancel();
    await probe.stop();
  }
}
