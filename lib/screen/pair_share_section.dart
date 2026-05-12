import 'package:flutter/material.dart';

import '../core/link.dart';
import '../paired/pair_beacon.dart';
import '../paired/pair_coordinator.dart';
import '../ui/dispatch_ui.dart';
import 'dispatch_controller.dart';

/// Pair & Share section for the home screen.
///
/// Surfaces three things to the user:
///
///   1. Currently-paired peers (each a [LinkKind.paired] entry in the
///      policy) so they know what's already bonded.
///   2. A discover panel listing peers visible on the LAN with a
///      one-tap **Connect** button.
///   3. A **Host** button that flips this device into share-mode and
///      waits for an incoming joiner.
///
/// The discovery / handshake / verify-code work is owned by
/// [PairCoordinator]; this widget is purely presentational.
class PairShareSection extends StatefulWidget {
  final DispatchController controller;

  const PairShareSection({required this.controller, super.key});

  @override
  State<PairShareSection> createState() => _PairShareSectionState();
}

class _PairShareSectionState extends State<PairShareSection> {
  PairCoordinator? get _coord {
    return widget.controller.pairCoordinator;
  }

  @override
  void initState() {
    super.initState();
    // Touching the lazy getter wires up discovery. Done in initState so a
    // user who opens the Pair tab once doesn't have to hit a refresh
    // button before seeing peers.
    PairCoordinator? c = _coord;
    if (c != null) {
      // Fire-and-forget: the coordinator notifies the controller, which
      // re-renders this widget when peers come online.
      Future<void>.microtask(c.startDiscovery);
    }
  }

  @override
  void dispose() {
    // Leave discovery running so the next tab visit doesn't pay a
    // re-bind cost. The coordinator itself is owned by the controller
    // and will be disposed when the app closes.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    PairCoordinator? coord = _coord;
    List<Link> paired = widget.controller.settings.policy.links
        .where((Link l) => l.kind == LinkKind.paired)
        .toList(growable: false);

    // Build the discoverable-peer list. Filter out anyone we've already
    // paired with so the row doesn't try to re-pair an existing peer.
    Set<String> pairedFps = <String>{
      for (Link l in paired)
        if (l.pairedFingerprint != null && l.pairedFingerprint!.isNotEmpty)
          l.pairedFingerprint!.toLowerCase(),
    };
    List<PairBeacon> peers = coord == null
        ? <PairBeacon>[]
        : coord.peers
            .where((PairBeacon b) =>
                !pairedFps.contains(b.fingerprint.toLowerCase()))
            .toList(growable: false);

    // The "confirm 6-digit code" modal is a Material dialog driven by
    // the coordinator's pendingHandshake — we surface it inline as a
    // tile so it remains visible even if the user dismisses a snackbar.
    PairHandshake? pending = coord?.pendingHandshake;

    return DispatchSection(
      title: 'Pair & Share',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (coord == null)
            const _DisabledNotice()
          else ...<Widget>[
            _StatusRow(coord: coord),
            if (coord.errorText != null) _ErrorRow(message: coord.errorText!),
            if (pending != null)
              _VerifyTile(
                handshake: pending,
                onApprove: () => widget.controller.approvePendingPairing(),
                onCancel: () => coord.cancelPendingHandshake(),
              ),
            const _BodyDivider(),
            _DiscoverList(
              peers: peers,
              isDiscovering: coord.pendingHandshake == null,
              onConnect: (PairBeacon b) => coord.joinPeer(b),
            ),
            const _BodyDivider(),
            _HostControls(coord: coord),
          ],
          if (paired.isNotEmpty) ...<Widget>[
            const _BodyDivider(),
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Text(
                'Already paired',
                style:
                    TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
              ),
            ),
            ...paired.map((Link l) => _PairedRow(
                  controller: widget.controller,
                  link: l,
                )),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Status / hosting / discover sub-widgets
// ─────────────────────────────────────────────────────────────────────────

class _StatusRow extends StatelessWidget {
  final PairCoordinator coord;
  const _StatusRow({required this.coord});

  @override
  Widget build(BuildContext context) {
    String headline;
    String subtitle;
    Color color;
    IconData icon;
    if (coord.isHosting) {
      headline = 'Hosting';
      subtitle =
          'Other Macs running Arcane Dispatch can see this one and join.';
      color = DispatchColors.ok;
      icon = Icons.podcasts_rounded;
    } else if (coord.peers.isEmpty) {
      headline = 'Looking for peers…';
      subtitle =
          'Make sure both Macs are on the same Wi-Fi or Ethernet, and that the other one is hosting.';
      color = DispatchColors.muted;
      icon = Icons.search_rounded;
    } else {
      headline = '${coord.peers.length} peer${coord.peers.length == 1 ? '' : 's'} nearby';
      subtitle = 'Tap a peer below to combine their networks with yours.';
      color = DispatchColors.accent;
      icon = Icons.devices_other_rounded;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Row(
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 16),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(headline,
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                        color: color)),
                Text(subtitle,
                    style: const TextStyle(
                        fontSize: 11,
                        color: DispatchColors.muted,
                        height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorRow extends StatelessWidget {
  final String message;
  const _ErrorRow({required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: DispatchColors.danger.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: DispatchColors.danger.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: <Widget>[
            const Icon(Icons.error_outline,
                color: DispatchColors.danger, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message,
                  style: const TextStyle(
                      fontSize: 12, color: DispatchColors.danger)),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiscoverList extends StatelessWidget {
  final List<PairBeacon> peers;
  final bool isDiscovering;
  final void Function(PairBeacon) onConnect;

  const _DiscoverList({
    required this.peers,
    required this.isDiscovering,
    required this.onConnect,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.search_rounded,
                  size: 14, color: DispatchColors.muted),
              const SizedBox(width: 6),
              Text('Discover peers',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 6),
          if (peers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                isDiscovering
                    ? 'No peers visible yet. Have the other Mac open the Pair tab and tap Host.'
                    : 'Discovery paused while a handshake is in progress.',
                style: const TextStyle(
                    fontSize: 12, color: DispatchColors.muted),
              ),
            )
          else
            for (PairBeacon b in peers)
              _DiscoverRow(beacon: b, onConnect: () => onConnect(b)),
        ],
      ),
    );
  }
}

class _DiscoverRow extends StatelessWidget {
  final PairBeacon beacon;
  final VoidCallback onConnect;
  const _DiscoverRow({required this.beacon, required this.onConnect});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          const Icon(Icons.devices_other_rounded,
              size: 16, color: DispatchColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  beacon.deviceName.isNotEmpty
                      ? beacon.deviceName
                      : 'Unknown Mac',
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 13),
                ),
                Text(
                  // Surface fingerprint short prefix so the user can
                  // sanity-check that they're connecting to the device
                  // they expect (matches the verify-code modal).
                  beacon.fingerprint.isNotEmpty
                      ? 'fp ${beacon.fingerprint.length > 8 ? beacon.fingerprint.substring(0, 8) : beacon.fingerprint}'
                      : '—',
                  style: const TextStyle(
                      fontSize: 11, color: DispatchColors.muted),
                ),
              ],
            ),
          ),
          ElevatedButton(
            onPressed: onConnect,
            style: ElevatedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8)),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }
}

class _HostControls extends StatelessWidget {
  final PairCoordinator coord;
  const _HostControls({required this.coord});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: Row(
        children: <Widget>[
          const Icon(Icons.podcasts_rounded,
              size: 14, color: DispatchColors.muted),
          const SizedBox(width: 6),
          Text('Host on this Mac',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const Spacer(),
          if (coord.isHosting)
            OutlinedButton(
              onPressed: coord.stopHosting,
              child: const Text('Stop hosting'),
            )
          else
            ElevatedButton.icon(
              icon: const Icon(Icons.podcasts_rounded, size: 14),
              label: const Text('Host a session'),
              onPressed: coord.startHosting,
            ),
        ],
      ),
    );
  }
}

class _VerifyTile extends StatelessWidget {
  final PairHandshake handshake;
  final Future<void> Function() onApprove;
  final Future<void> Function() onCancel;
  const _VerifyTile({
    required this.handshake,
    required this.onApprove,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    String role = handshake.role == PairRole.host
        ? 'A peer wants to share networks with this Mac'
        : 'You\'re connecting to ${handshake.peerLabel}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: DispatchColors.accent.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: DispatchColors.accent.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.verified_user_outlined,
                    color: DispatchColors.accent, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(role,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 13)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Confirm these 6 digits match the same code on the other device. If they don\'t match, somebody is intercepting the connection — tap cancel.',
              style: TextStyle(
                  fontSize: 12,
                  color: DispatchColors.muted,
                  height: 1.4),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: DispatchColors.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: DispatchColors.border),
              ),
              child: Center(
                child: Text(
                  handshake.verifyCode,
                  style: const TextStyle(
                    fontFamily: 'SF Mono',
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 6,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                TextButton(
                  style: TextButton.styleFrom(
                      foregroundColor: DispatchColors.danger),
                  onPressed: () async => onCancel(),
                  child: const Text('Cancel'),
                ),
                const Spacer(),
                ElevatedButton.icon(
                  icon: const Icon(Icons.check_rounded, size: 16),
                  label: const Text('Codes match — pair'),
                  onPressed: () async => onApprove(),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PairedRow extends StatelessWidget {
  final DispatchController controller;
  final Link link;

  const _PairedRow({required this.controller, required this.link});

  @override
  Widget build(BuildContext context) {
    String endpoint = link.pairedEndpoint ?? '—';
    String fp = link.pairedFingerprint ?? '';
    String fpShort = fp.length > 8 ? fp.substring(0, 8) : fp;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        children: <Widget>[
          const Icon(Icons.devices_other_rounded,
              color: DispatchColors.accent, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  link.label.isNotEmpty ? link.label : 'Paired peer',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700),
                ),
                Text(
                  fpShort.isEmpty ? endpoint : '$endpoint  · fp $fpShort',
                  style: const TextStyle(
                      fontSize: 11, color: DispatchColors.muted),
                ),
              ],
            ),
          ),
          DispatchBadge(
            label: _priorityLabel(link.priority),
            color: DispatchColors.muted,
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.link_off_rounded, size: 18),
            tooltip: 'Unpair',
            onPressed: () => controller.detachPairedLink(link.id),
          ),
        ],
      ),
    );
  }

  String _priorityLabel(LinkPriority p) {
    switch (p) {
      case LinkPriority.primary:
        return 'Primary';
      case LinkPriority.secondary:
        return 'Secondary';
      case LinkPriority.backup:
        return 'Backup';
      case LinkPriority.never:
        return 'Off';
    }
  }
}

class _BodyDivider extends StatelessWidget {
  const _BodyDivider();
  @override
  Widget build(BuildContext context) =>
      const Padding(padding: EdgeInsets.symmetric(vertical: 4), child: Divider(height: 1));
}

class _DisabledNotice extends StatelessWidget {
  const _DisabledNotice();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.info_outline,
              color: DispatchColors.muted, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Pair & Share isn\'t available in this build. The bonding loop '
              'still combines every network on this Mac.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
