import 'dart:io';

import 'package:flutter/material.dart';

import '../core/bonding_mode.dart';
import '../core/dispatch_settings.dart';
import '../core/link.dart';
import '../core/link_metric.dart';
import '../core/network_interface_repository.dart';
import '../core/policy.dart';
import '../core/proxy_event.dart';
import '../platform/network_naming_service.dart';
import '../policy/link_supervisor.dart';
import '../probes/captive_portal_probe.dart';
import '../transport/transport.dart';
import '../ui/dispatch_ui.dart';
import 'dispatch_controller.dart';
import 'flow_inspector.dart';
import 'pair_share_section.dart';

/// Top-level dashboard.
///
/// Layout philosophy: keep the on/off state and overall health visible at all
/// times in a fixed power card, and hide everything else behind clear,
/// friendly tabs so users who don't know networking jargon can still get to
/// the controls they need. Stable widget identity per tab (via
/// [IndexedStack]) also dodges the accessibility-tree thrash that the old
/// monolithic [ListView] produced.
class DispatchHomeScreen extends StatefulWidget {
  final DispatchController controller;

  const DispatchHomeScreen({required this.controller, super.key});

  @override
  State<DispatchHomeScreen> createState() => _DispatchHomeScreenState();
}

class _DispatchHomeScreenState extends State<DispatchHomeScreen> {
  /// Selected tab index. We keep this in state so an [IndexedStack] can keep
  /// every page mounted; switching tabs becomes a single repaint rather than
  /// a destructive widget tear-down (which is what was causing the
  /// `ui::AXTree error: 63` semantics crash).
  int _tab = 0;

  DispatchController get controller {
    return widget.controller;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? child) {
        return Scaffold(
          backgroundColor: DispatchColors.surface,
          body: SafeArea(
            child: Column(
              children: <Widget>[
                _AppHeader(controller: controller),
                _PowerCard(controller: controller),
                _Banners(controller: controller),
                _TabBar(
                  index: _tab,
                  onChanged: (int next) {
                    setState(() => _tab = next);
                  },
                ),
                Expanded(
                  child: IndexedStack(
                    index: _tab,
                    sizing: StackFit.expand,
                    children: <Widget>[
                      _NetworksPage(controller: controller),
                      _ModePage(controller: controller),
                      _PairPage(controller: controller),
                      _ActivityPage(controller: controller),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
//  Header & power card
// ─────────────────────────────────────────────────────────────────────────

/// Slim top bar with the app brand on the left and a settings gear on the
/// right. We render our own bar instead of [AppBar] because the macOS window
/// hides the system titlebar, so the brand needs to live inside the canvas.
class _AppHeader extends StatelessWidget {
  final DispatchController controller;

  const _AppHeader({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 10),
      child: Row(
        children: <Widget>[
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: DispatchColors.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(7),
            ),
            child: const Icon(
              Icons.hub_rounded,
              color: DispatchColors.accent,
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Arcane Dispatch',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          IconButton(
            tooltip: 'App settings',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.settings_outlined, size: 20),
            onPressed: () => _showSettingsDialog(context, controller),
          ),
        ],
      ),
    );
  }
}

/// Big always-visible power card. Shows the on/off state, live throughput,
/// and a one-line summary of how many networks are currently helping.
///
/// This is the only screen real estate that *never* changes tabs — keeping
/// the on/off button anchored at the top means a user can always toggle the
/// connection without having to hunt for the right page.
class _PowerCard extends StatelessWidget {
  final DispatchController controller;

  const _PowerCard({required this.controller});

  @override
  Widget build(BuildContext context) {
    bool running = controller.isRunning;
    double bpsIn = 0;
    double bpsOut = 0;
    int activeLinks = 0;
    for (Link link in controller.settings.policy.links) {
      LinkMetric? m = controller.linkMetrics[link.id];
      if (m == null) continue;
      if (m.bpsIn != null) {
        bpsIn += m.bpsIn!;
        activeLinks++;
      }
      if (m.bpsOut != null) {
        bpsOut += m.bpsOut!;
      }
    }
    int totalLinks = controller.settings.links.length;
    Color accent = running ? DispatchColors.ok : DispatchColors.muted;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: DispatchColors.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DispatchColors.border),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              _PowerButton(
                running: running,
                onPressed: running
                    ? controller.stopProxy
                    : (totalLinks == 0 ? null : controller.startProxy),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      running ? 'Connected' : 'Off',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: accent,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _statusLine(totalLinks, activeLinks, running),
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 2,
                    ),
                  ],
                ),
              ),
              // Tappable text label that mirrors the button's word so
              // existing tests / accessibility tools can still `find.text('Start')`
              // and trigger the connect action directly from the label.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: running
                    ? controller.stopProxy
                    : (totalLinks == 0 ? null : controller.startProxy),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Text(
                    running ? 'Stop' : 'Start',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: DispatchColors.muted,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              DispatchBadge(
                label: running ? 'Running' : 'Stopped',
                color: running ? DispatchColors.ok : DispatchColors.muted,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: _ThroughputCell(
                  icon: Icons.south_rounded,
                  label: 'Download',
                  bps: bpsIn,
                  color: DispatchColors.ok,
                ),
              ),
              Container(
                width: 1,
                height: 28,
                color: DispatchColors.border,
              ),
              Expanded(
                child: _ThroughputCell(
                  icon: Icons.north_rounded,
                  label: 'Upload',
                  bps: bpsOut,
                  color: DispatchColors.accent,
                ),
              ),
            ],
          ),
          if (controller.errorText != null) ...<Widget>[
            const SizedBox(height: 10),
            _InlineErrorRow(message: controller.errorText!),
          ],
        ],
      ),
    );
  }

  String _statusLine(int total, int active, bool running) {
    if (total == 0) {
      return 'Add a network on the Networks tab to get started.';
    }
    if (!running) {
      return total == 1
          ? '1 network ready. Tap to connect.'
          : '$total networks ready. Tap to connect.';
    }
    if (active == 0) {
      return 'Connected, waiting for traffic…';
    }
    return active == 1
        ? '1 network carrying traffic'
        : '$active networks carrying traffic';
  }
}

/// The fat round power button on the left of [_PowerCard].
class _PowerButton extends StatelessWidget {
  final bool running;
  final VoidCallback? onPressed;

  const _PowerButton({required this.running, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    Color fill = running ? DispatchColors.ok : DispatchColors.panel;
    Color border = running ? DispatchColors.ok : DispatchColors.border;
    Color icon = running ? Colors.white : DispatchColors.muted;
    bool enabled = onPressed != null;
    return Semantics(
      label: running ? 'Disconnect' : 'Connect',
      button: true,
      enabled: enabled,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: enabled ? fill : fill.withValues(alpha: 0.6),
              shape: BoxShape.circle,
              border: Border.all(color: border, width: 2),
              boxShadow: <BoxShadow>[
                if (running)
                  BoxShadow(
                    color: DispatchColors.ok.withValues(alpha: 0.35),
                    blurRadius: 18,
                    spreadRadius: 1,
                  ),
              ],
            ),
            child: Icon(Icons.power_settings_new_rounded,
                size: 30, color: icon),
          ),
        ),
      ),
    );
  }
}

/// A column showing one direction of throughput.
class _ThroughputCell extends StatelessWidget {
  final IconData icon;
  final String label;
  final double bps;
  final Color color;

  const _ThroughputCell({
    required this.icon,
    required this.label,
    required this.bps,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(label,
                  style: const TextStyle(
                      fontSize: 11,
                      color: DispatchColors.muted,
                      fontWeight: FontWeight.w600)),
              Text(_friendlyBps(bps),
                  style: TextStyle(
                      fontSize: 15,
                      color: color,
                      fontWeight: FontWeight.w800)),
            ],
          ),
        ],
      ),
    );
  }
}

class _InlineErrorRow extends StatelessWidget {
  final String message;
  const _InlineErrorRow({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: DispatchColors.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: DispatchColors.danger.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.error_outline, color: DispatchColors.danger, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                style: const TextStyle(color: DispatchColors.danger, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

/// Static, soft-color banners surfaced above the tabs when something needs
/// the user's attention (kill switch, no healthy links, captive portal…).
class _Banners extends StatelessWidget {
  final DispatchController controller;
  const _Banners({required this.controller});

  @override
  Widget build(BuildContext context) {
    List<Widget> banners = <Widget>[];

    if (controller.lastHealthEvent != null) {
      LinkHealthEvent ev = controller.lastHealthEvent!;
      bool anyHealthy = ev.statuses.values.any((LinkStatus s) => s == LinkStatus.healthy);
      bool anyEnabled = ev.statuses.values.any((LinkStatus s) => s != LinkStatus.disabled);
      if (anyEnabled && !anyHealthy) {
        banners.add(_SoftBanner(
          color: DispatchColors.warn,
          icon: Icons.warning_amber_rounded,
          title: 'No network is healthy',
          body:
              'Latency, loss, or jitter is too high on every selected network. '
              'Traffic may be slow or paused.',
        ));
      }
    }

    Set<String> captiveIds = controller.captiveStates.entries
        .where((MapEntry<String, CaptivePortalProbeResult> e) =>
            e.value == CaptivePortalProbeResult.captive)
        .map((MapEntry<String, CaptivePortalProbeResult> e) => e.key)
        .toSet();
    if (captiveIds.isNotEmpty) {
      banners.add(_SoftBanner(
        color: DispatchColors.warn,
        icon: Icons.wifi_off_rounded,
        title: 'Captive portal detected',
        body: 'Sign in to ${captiveIds.length == 1 ? "your network" : "${captiveIds.length} networks"} '
            'in a browser. Dispatch will resume routing automatically once they reach the Internet.',
      ));
    }

    if (controller.settings.policy.killSwitch && !controller.isRunning) {
      banners.add(_SoftBanner(
        color: DispatchColors.danger,
        icon: Icons.lock_outline,
        title: 'Kill switch is on',
        body: 'Apps using Dispatch can\'t reach the Internet while disconnected. '
            'Hit the big power button to reconnect, or turn off kill switch in Mode.',
      ));
    }

    if (banners.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (Widget b in banners) Padding(padding: const EdgeInsets.only(bottom: 6), child: b),
        ],
      ),
    );
  }
}

class _SoftBanner extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String title;
  final String body;

  const _SoftBanner({
    required this.color,
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title,
                    style: TextStyle(
                        color: color,
                        fontSize: 13,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(body,
                    style: const TextStyle(
                        color: DispatchColors.muted, fontSize: 12, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Segmented tab bar — bigger touch targets and word labels so non-technical
/// users can tell at a glance what each page does.
class _TabBar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onChanged;

  const _TabBar({required this.index, required this.onChanged});

  static const List<_TabEntry> _tabs = <_TabEntry>[
    _TabEntry('Networks', Icons.wifi_rounded),
    _TabEntry('Mode', Icons.tune_rounded),
    _TabEntry('Pair', Icons.qr_code_2_rounded),
    _TabEntry('Activity', Icons.timeline_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: DispatchColors.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DispatchColors.border),
      ),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < _tabs.length; i++)
            Expanded(
              child: _TabButton(
                entry: _tabs[i],
                selected: i == index,
                onTap: () => onChanged(i),
              ),
            ),
        ],
      ),
    );
  }
}

class _TabEntry {
  final String label;
  final IconData icon;
  const _TabEntry(this.label, this.icon);
}

class _TabButton extends StatelessWidget {
  final _TabEntry entry;
  final bool selected;
  final VoidCallback onTap;

  const _TabButton({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    Color fg = selected ? DispatchColors.ink : DispatchColors.muted;
    Color bg = selected ? Colors.white : Colors.transparent;
    return Semantics(
      label: entry.label,
      button: true,
      selected: selected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(8),
              boxShadow: selected
                  ? <BoxShadow>[
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 6,
                        offset: const Offset(0, 1),
                      ),
                    ]
                  : null,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(entry.icon, size: 18, color: fg),
                const SizedBox(height: 2),
                Text(entry.label,
                    style: TextStyle(
                        fontSize: 11,
                        color: fg,
                        fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =====================================================================
// NETWORKS PAGE
// =====================================================================
//
// Goal: a non-technical user opens the app, sees every network on their
// machine, can flip them on/off with one tap, and drag a slider to say
// "use this one most" / "only as a backup". No interface names, no IP
// addresses, no weight integers in the primary view.

class _NetworksPage extends StatefulWidget {
  final DispatchController controller;
  const _NetworksPage({required this.controller});

  @override
  State<_NetworksPage> createState() => _NetworksPageState();
}

class _NetworksPageState extends State<_NetworksPage> {
  @override
  Widget build(BuildContext context) {
    DispatchController c = widget.controller;
    List<Link> links = c.settings.policy.links;

    if (c.loadingInterfaces) {
      return const Center(
          child: Padding(
        padding: EdgeInsets.all(48),
        child: CircularProgressIndicator(),
      ));
    }

    // Discover unselected interfaces so the user can add them.
    // [names] is the live snapshot of friendly per-interface metadata
    // (SSIDs, hardware port labels). When the user is on macOS this lets
    // us show "Home Wi-Fi" / "iPhone USB" / "USB 10/100/1000 LAN" instead
    // of `en0` / `en7` / `en12`. On non-macOS hosts (and during tests)
    // the map is empty and we fall back to the existing heuristic.
    Map<String, NamedInterface> names = c.namingService.byBsd;
    Set<String> selectedTargets = c.settings.selectedTargets.toSet();
    List<_AvailableNetwork> available = <_AvailableNetwork>[];
    for (NetworkInterfaceSnapshot snap in c.interfaces) {
      // Hide interfaces the OS classifies as plumbing — loopback,
      // virtual tunnels, bridges, AirDrop — so the picker only shows
      // links a normal user would recognize. If the resolver hasn't
      // seen this device yet (`named == null`) we fall back to showing
      // it so the UI never blanks on a slow first refresh.
      NamedInterface? named = names[snap.name.toLowerCase()];
      if (named != null && !named.isUserFacing) {
        continue;
      }
      for (InternetAddress addr in snap.validAddresses) {
        bool isPicked = selectedTargets.contains(snap.name) ||
            selectedTargets.contains(addr.address) ||
            selectedTargets.any((String t) =>
                t.startsWith('${snap.name}/') ||
                t.startsWith('${addr.address}/'));
        if (!isPicked) {
          available.add(_AvailableNetwork(
              interface: snap,
              address: addr,
              kindLabel: _friendlyKindFor(snap.name, names)));
        }
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
      children: <Widget>[
        _SectionLabel(
          icon: Icons.dns_rounded,
          title: 'Your networks',
          subtitle: links.isEmpty
              ? 'No networks added yet — pick one below to begin.'
              : 'Tap a card to expand limits & details. Drag priority to rank them.',
        ),
        if (links.isEmpty)
          _EmptyHint(
            icon: Icons.lan_outlined,
            text:
                'Add one or more networks below to combine them. Wi-Fi + Ethernet, or Wi-Fi + Cellular, are the most common pairs.',
          )
        else
          for (Link link in links)
            _NetworkCard(
              key: ValueKey<String>('net_${link.id}'),
              controller: c,
              link: link,
            ),
        const SizedBox(height: 14),
        _SectionLabel(
          icon: Icons.add_link_rounded,
          title: 'Available to add',
          subtitle: available.isEmpty
              ? 'Every network on this machine is already in use.'
              : 'These networks are connected but not yet helping. Tap to add.',
        ),
        if (available.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12, horizontal: 4),
            child: Text(
              'Plug in Ethernet, connect to another Wi-Fi, or tether your phone to add more.',
              style: TextStyle(fontSize: 12, color: DispatchColors.muted),
            ),
          )
        else
          for (_AvailableNetwork an in available) _AddNetworkRow(controller: c, network: an),
      ],
    );
  }
}

class _AvailableNetwork {
  final NetworkInterfaceSnapshot interface;
  final InternetAddress address;
  final String kindLabel;

  const _AvailableNetwork({
    required this.interface,
    required this.address,
    required this.kindLabel,
  });
}

/// Section header row — icon + title + subtitle.
class _SectionLabel extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _SectionLabel({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: DispatchColors.accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 14, color: DispatchColors.accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w800)),
                Text(subtitle,
                    style: const TextStyle(
                        fontSize: 12, color: DispatchColors.muted, height: 1.3)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Friendly-language hint card shown when the user has zero networks.
class _EmptyHint extends StatelessWidget {
  final IconData icon;
  final String text;
  const _EmptyHint({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: DispatchColors.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DispatchColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: DispatchColors.muted, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    fontSize: 13, color: DispatchColors.ink, height: 1.4)),
          ),
        ],
      ),
    );
  }
}

/// One network the user has chosen to use. Collapsible: top row shows
/// power/name/status, tap to reveal priority chips + slider + caps.
class _NetworkCard extends StatefulWidget {
  final DispatchController controller;
  final Link link;

  const _NetworkCard({super.key, required this.controller, required this.link});

  @override
  State<_NetworkCard> createState() => _NetworkCardState();
}

class _NetworkCardState extends State<_NetworkCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    Link link = widget.link;
    DispatchController c = widget.controller;
    LinkMetric? metric = c.linkMetrics[link.id];
    Color tint = DispatchColors.linkColorFor(link.id);
    bool included = link.priority != LinkPriority.never;
    Map<String, NamedInterface> names = c.namingService.byBsd;
    // Reverse-resolve IP-only links back to their BSD device so SSID
    // lookups still succeed. Cheap (<10 entries on a typical Mac) so we
    // rebuild on every paint rather than caching.
    Map<String, String> ipToBsd = _buildIpToBsd(c.interfaces);
    String friendlyName =
        _friendlyLinkName(link, names, ipToBsd: ipToBsd);
    IconData kindIcon =
        _iconForLinkName(link, names, ipToBsd: ipToBsd);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: DispatchColors.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _expanded ? tint.withValues(alpha: 0.6) : DispatchColors.border,
          width: _expanded ? 1.5 : 1,
        ),
      ),
      child: Column(
        children: <Widget>[
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              child: Row(
                children: <Widget>[
                  _NetworkIcon(icon: kindIcon, color: tint, dim: !included),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                friendlyName,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: included
                                      ? DispatchColors.ink
                                      : DispatchColors.muted,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            _PriorityBadge(priority: link.priority),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _statusLineFor(metric, link),
                          style: const TextStyle(
                              fontSize: 12,
                              color: DispatchColors.muted,
                              height: 1.3),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 2,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Switch(
                    value: included,
                    activeThumbColor: tint,
                    onChanged: (bool on) async {
                      LinkPriority next =
                          on ? LinkPriority.primary : LinkPriority.never;
                      await c.setLinkPriority(link.id, next);
                    },
                  ),
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: DispatchColors.muted,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
              child: _NetworkCardBody(
                controller: c,
                link: link,
                tint: tint,
              ),
            ),
        ],
      ),
    );
  }

  String _statusLineFor(LinkMetric? m, Link link) {
    if (m == null || m.rttMs == null) {
      if (link.priority == LinkPriority.never) {
        return 'Turned off — not used by Dispatch.';
      }
      return 'Standing by.';
    }
    List<String> parts = <String>[];
    double? rtt = m.rttMs;
    if (rtt != null) parts.add('${rtt.toStringAsFixed(0)} ms');
    double? loss = m.loss;
    if (loss != null && loss > 0.001) {
      parts.add('${(loss * 100).toStringAsFixed(1)}% loss');
    }
    double? bpsOut = m.bpsOut;
    if (bpsOut != null && bpsOut > 0) {
      parts.add('Up ${_friendlyBps(bpsOut)}');
    }
    double? bpsIn = m.bpsIn;
    if (bpsIn != null && bpsIn > 0) {
      parts.add('Down ${_friendlyBps(bpsIn)}');
    }
    if (parts.isEmpty) return 'Healthy';
    return parts.join('  •  ');
  }
}

class _NetworkIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  final bool dim;

  const _NetworkIcon({
    required this.icon,
    required this.color,
    required this.dim,
  });

  @override
  Widget build(BuildContext context) {
    Color bg = (dim ? DispatchColors.muted : color).withValues(alpha: 0.12);
    Color fg = dim ? DispatchColors.muted : color;
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Icon(icon, color: fg, size: 22),
    );
  }
}

class _PriorityBadge extends StatelessWidget {
  final LinkPriority priority;
  const _PriorityBadge({required this.priority});

  @override
  Widget build(BuildContext context) {
    String label;
    Color color;
    switch (priority) {
      case LinkPriority.primary:
        label = 'Primary';
        color = DispatchColors.ok;
        break;
      case LinkPriority.secondary:
        label = 'Secondary';
        color = DispatchColors.accent;
        break;
      case LinkPriority.backup:
        label = 'Backup';
        color = DispatchColors.warn;
        break;
      case LinkPriority.never:
        label = 'Off';
        color = DispatchColors.muted;
        break;
    }
    return DispatchBadge(label: label, color: color);
  }
}

/// The drawer that opens when a [_NetworkCard] is tapped. Surfaces the
/// rest of the per-link knobs the plan documents: priority chips, Mbps
/// cap slider, monthly data cap, and a remove button.
class _NetworkCardBody extends StatelessWidget {
  final DispatchController controller;
  final Link link;
  final Color tint;

  const _NetworkCardBody({
    required this.controller,
    required this.link,
    required this.tint,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const _BodyDivider(),
        const _BodyLabel(
            label: 'Role',
            help:
                'Primary is used first. Secondary kicks in when bonding helps. Backup only takes over on outage.'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          children: <Widget>[
            for (LinkPriority p in <LinkPriority>[
              LinkPriority.primary,
              LinkPriority.secondary,
              LinkPriority.backup,
            ])
              _ChoiceChip(
                label: _priorityLabel(p),
                selected: link.priority == p,
                color: tint,
                onTap: () => controller.setLinkPriority(link.id, p),
              ),
          ],
        ),
        const SizedBox(height: 14),
        const _BodyDivider(),
        const _BodyLabel(
            label: 'Speed limit',
            help:
                'Cap how fast Dispatch can push traffic over this network. Useful for cellular plans.'),
        _SpeedCapSlider(controller: controller, link: link, tint: tint),
        const SizedBox(height: 14),
        const _BodyDivider(),
        const _BodyLabel(
            label: 'Monthly data cap',
            help:
                'Pause this network once it carries this many GB this month. Reset on the 1st.'),
        _DataCapRow(controller: controller, link: link, tint: tint),
        if (link.kind == LinkKind.paired) ...<Widget>[
          const SizedBox(height: 14),
          const _BodyDivider(),
          Row(
            children: <Widget>[
              const Icon(Icons.qr_code_2_rounded,
                  size: 16, color: DispatchColors.muted),
              const SizedBox(width: 6),
              const Text('Paired from another device',
                  style: TextStyle(
                      fontSize: 12, color: DispatchColors.muted)),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.link_off_rounded, size: 14),
                label: const Text('Forget pair'),
                onPressed: () => controller.detachPairedLink(link.id),
                style: TextButton.styleFrom(
                    foregroundColor: DispatchColors.danger),
              ),
            ],
          ),
        ] else ...<Widget>[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('Remove from list'),
              style: TextButton.styleFrom(
                  foregroundColor: DispatchColors.danger),
              onPressed: () async {
                String target = link.toLegacyTarget();
                await controller.setTargetSelected(target, false);
              },
            ),
          ),
        ],
      ],
    );
  }

  String _priorityLabel(LinkPriority p) {
    switch (p) {
      case LinkPriority.primary:
        return 'Use first';
      case LinkPriority.secondary:
        return 'Add for speed';
      case LinkPriority.backup:
        return 'Backup only';
      case LinkPriority.never:
        return 'Off';
    }
  }
}

class _BodyDivider extends StatelessWidget {
  const _BodyDivider();
  @override
  Widget build(BuildContext context) =>
      const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Divider(height: 1));
}

class _BodyLabel extends StatelessWidget {
  final String label;
  final String help;
  const _BodyLabel({required this.label, required this.help});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label,
            style:
                const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text(help,
            style: const TextStyle(
                fontSize: 11, color: DispatchColors.muted, height: 1.35)),
      ],
    );
  }
}

class _ChoiceChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color color;
  const _ChoiceChip({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? color.withValues(alpha: 0.16) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: selected ? color : DispatchColors.border,
                width: selected ? 1.4 : 1),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: selected ? color : DispatchColors.ink)),
        ),
      ),
    );
  }
}

/// Slider whose right thumb-label tells the user the speed cap in Mbps.
/// Goes 0 → 200 in 5 Mbps steps; 0 means "no limit".
class _SpeedCapSlider extends StatefulWidget {
  final DispatchController controller;
  final Link link;
  final Color tint;
  const _SpeedCapSlider({
    required this.controller,
    required this.link,
    required this.tint,
  });

  @override
  State<_SpeedCapSlider> createState() => _SpeedCapSliderState();
}

class _SpeedCapSliderState extends State<_SpeedCapSlider> {
  late double _val;

  @override
  void initState() {
    super.initState();
    _val = (widget.link.speedCapBps ?? 0) / 125000.0; // bytes/s -> Mbps
  }

  @override
  Widget build(BuildContext context) {
    double v = _val.clamp(0, 200);
    String label = v == 0 ? 'No limit' : '${v.round()} Mbps';
    return Row(
      children: <Widget>[
        Expanded(
          child: Slider(
            value: v,
            min: 0,
            max: 200,
            divisions: 40,
            activeColor: widget.tint,
            label: label,
            onChanged: (double next) {
              setState(() => _val = next);
            },
            onChangeEnd: (double finalVal) {
              widget.controller.setLinkSpeedCapMbps(
                  widget.link.id, finalVal == 0 ? null : finalVal);
            },
          ),
        ),
        SizedBox(
          width: 70,
          child: Text(label,
              textAlign: TextAlign.right,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}

class _DataCapRow extends StatefulWidget {
  final DispatchController controller;
  final Link link;
  final Color tint;
  const _DataCapRow({
    required this.controller,
    required this.link,
    required this.tint,
  });

  @override
  State<_DataCapRow> createState() => _DataCapRowState();
}

class _DataCapRowState extends State<_DataCapRow> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    double? gb = widget.link.dataCapBytes == null
        ? null
        : widget.link.dataCapBytes! / 1e9;
    _ctrl = TextEditingController(
        text: gb == null ? '' : gb.toStringAsFixed(0));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 110,
            height: 36,
            child: TextField(
              controller: _ctrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                border: OutlineInputBorder(),
                hintText: 'No cap',
                suffixText: 'GB',
              ),
              onSubmitted: (String value) {
                double? gb = double.tryParse(value);
                widget.controller.setLinkDataCapGb(widget.link.id, gb);
              },
            ),
          ),
          const SizedBox(width: 10),
          TextButton(
            onPressed: () {
              _ctrl.text = '';
              widget.controller.setLinkDataCapGb(widget.link.id, null);
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }
}

/// One row in the "Available to add" list. Tap to push the network into the
/// policy with a sensible default (Primary, weight 1).
class _AddNetworkRow extends StatelessWidget {
  final DispatchController controller;
  final _AvailableNetwork network;

  const _AddNetworkRow({required this.controller, required this.network});

  @override
  Widget build(BuildContext context) {
    Map<String, NamedInterface> names = controller.namingService.byBsd;
    // Try to enrich the row with the macOS hardware-port name and SSID
    // when available; otherwise fall back to the heuristic [kindLabel]
    // we already computed when building the available list.
    NamedInterface? named = names[network.interface.name.toLowerCase()];
    String title;
    String subtitle;
    if (named != null && named.displayName.isNotEmpty) {
      title = named.displayName;
      // Subtitle: kind + BSD + IP, joined by middots. Skip kind when it
      // duplicates the title (e.g. SSID is "Wi-Fi").
      List<String> parts = <String>[];
      if (named.kindLabel != title) parts.add(named.kindLabel);
      parts.add(network.interface.name);
      parts.add(network.address.address);
      subtitle = parts.join(' • ');
    } else {
      title = network.kindLabel;
      subtitle = '${network.interface.name} • ${network.address.address}';
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: DispatchColors.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DispatchColors.border),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => controller.setTargetSelected(network.address.address, true),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
            child: Row(
              children: <Widget>[
                Icon(_iconForInterfaceName(network.interface.name, names),
                    size: 20, color: DispatchColors.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(title,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w700)),
                      Text(
                        subtitle,
                        style: const TextStyle(
                            fontSize: 11, color: DispatchColors.muted),
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: () =>
                      controller.setTargetSelected(network.address.address, true),
                  icon: const Icon(Icons.add_circle_outline, size: 16),
                  label: const Text('Add'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Friendly-name helpers
// ---------------------------------------------------------------------------
//
// On macOS the BSD interface name is `en0`, `en1`, `pdp_ip0`, `utun3`, …
// None of these mean anything to a normal user. These helpers map them to
// human words and icons.
//
// All helpers take a [Map<String, NamedInterface>] which is the live
// snapshot from [NetworkNamingService]. When the map carries an entry for
// the BSD name we prefer the SSID / hardware port; otherwise we fall back
// to a regex-style heuristic so a stale cache or non-macOS host still
// renders sensible labels.

/// Decide a friendly human label for a [Link]. Prefers, in order:
///
/// 1. An explicit user-applied [Link.label].
/// 2. The paired-device tag for [LinkKind.paired].
/// 3. The SSID / hardware-port from the OS naming snapshot.
/// 4. The interface-name heuristic.
///
/// [ipToBsd] is a reverse map produced by [_buildIpToBsd] — many links
/// only store the IP they were created from (no BSD name attached), so
/// this map lets us recover the device. Without it those links would
/// always fall through to the regex heuristic and miss their SSID.
String _friendlyLinkName(
  Link link,
  Map<String, NamedInterface> names, {
  Map<String, String>? ipToBsd,
}) {
  if (link.label.isNotEmpty) {
    return link.label;
  }
  if (link.kind == LinkKind.paired) {
    return 'Paired device';
  }
  String bsd = _resolveBsdFor(link, ipToBsd);
  NamedInterface? named = names[bsd];
  if (named != null) {
    String display = named.displayName;
    if (display.isNotEmpty) return display;
  }
  return _friendlyKindFor(bsd, names);
}

/// Same logic for an arbitrary interface name (used by the "available"
/// list and other call sites that don't have a full [Link]).
String _friendlyKindFor(String rawName, Map<String, NamedInterface> names) {
  String name = rawName.toLowerCase();
  NamedInterface? named = names[name];
  if (named != null) {
    String display = named.displayName;
    if (display.isNotEmpty) return display;
  }
  if (name.startsWith('en0')) return 'Wi-Fi';
  if (name.startsWith('en1') ||
      name.startsWith('en2') ||
      name.startsWith('en3') ||
      name.startsWith('en4') ||
      name.startsWith('en5')) {
    return 'Ethernet';
  }
  if (name.startsWith('pdp_ip') ||
      name.contains('cell') ||
      name.contains('rmnet')) {
    return 'Cellular';
  }
  if (name.startsWith('utun') ||
      name.startsWith('ipsec') ||
      name.startsWith('tun') ||
      name.startsWith('tap')) {
    return 'VPN tunnel';
  }
  if (name.startsWith('awdl')) return 'AirDrop link';
  if (name.startsWith('bridge')) return 'Bridge';
  if (name.startsWith('llw')) return 'Low-latency Wi-Fi';
  if (name.startsWith('lo')) return 'Loopback';
  // Fallback to the raw name with title-casing for unknowns.
  return rawName;
}

/// Decide a friendly icon for a [Link]. The naming map lets us pick the
/// right symbol for cases where the BSD name is ambiguous (e.g. an
/// iPhone-USB tether is reported as `en7` on some Macs and `en4` on
/// others, but the macOS Hardware Port name disambiguates).
///
/// [ipToBsd] is the same reverse map used by [_friendlyLinkName].
IconData _iconForLinkName(
  Link link,
  Map<String, NamedInterface> names, {
  Map<String, String>? ipToBsd,
}) {
  if (link.kind == LinkKind.paired) return Icons.qr_code_2_rounded;
  String bsd = _resolveBsdFor(link, ipToBsd);
  return _iconForInterfaceName(bsd, names);
}

/// Resolve a link to its best-known BSD device name. Prefers an explicit
/// `interfaceName` field; otherwise reverse-resolves the `sourceAddress`
/// IP through [ipToBsd] (built from the controller's live interface list).
/// Returns an empty string when neither path yields a match — the
/// downstream helpers then fall back to the heuristic.
String _resolveBsdFor(Link link, Map<String, String>? ipToBsd) {
  String? iface = link.interfaceName;
  if (iface != null && iface.isNotEmpty) return iface.toLowerCase();
  String? ip = link.sourceAddress;
  if (ip != null && ip.isNotEmpty && ipToBsd != null) {
    String? resolved = ipToBsd[ip];
    if (resolved != null && resolved.isNotEmpty) return resolved.toLowerCase();
  }
  return (iface ?? ip ?? '').toLowerCase();
}

/// Build a flat `{IP literal -> BSD device name}` map from the snapshot
/// of interfaces the controller currently knows about. Used so links
/// created with only an IP (`192.168.1.45`) can still resolve back to
/// their hardware port (`en0`) and therefore to their SSID.
Map<String, String> _buildIpToBsd(List<NetworkInterfaceSnapshot> interfaces) {
  Map<String, String> out = <String, String>{};
  for (NetworkInterfaceSnapshot snap in interfaces) {
    for (InternetAddress addr in snap.validAddresses) {
      out[addr.address] = snap.name;
    }
  }
  return out;
}

IconData _iconForInterfaceName(
    String raw, Map<String, NamedInterface> names) {
  String name = raw.toLowerCase();
  NamedInterface? named = names[name];
  if (named != null) {
    switch (named.kind) {
      case NamedInterfaceKind.wifi:
        return Icons.wifi_rounded;
      case NamedInterfaceKind.ethernet:
        return Icons.settings_ethernet_rounded;
      case NamedInterfaceKind.cellularTether:
        return Icons.signal_cellular_alt_rounded;
      case NamedInterfaceKind.bluetoothTether:
        return Icons.bluetooth_rounded;
      case NamedInterfaceKind.thunderbolt:
        return Icons.bolt_rounded;
      case NamedInterfaceKind.loopback:
        return Icons.refresh_rounded;
      case NamedInterfaceKind.virtualTunnel:
        return Icons.lock_outline;
      case NamedInterfaceKind.bridge:
        return Icons.hub_outlined;
      case NamedInterfaceKind.other:
        // fall through to heuristic below.
        break;
    }
  }
  if (name.startsWith('en0')) return Icons.wifi_rounded;
  if (name.startsWith('en')) return Icons.settings_ethernet_rounded;
  if (name.startsWith('pdp_ip') || name.contains('cell')) {
    return Icons.signal_cellular_alt_rounded;
  }
  if (name.startsWith('utun') || name.startsWith('ipsec')) {
    return Icons.lock_outline;
  }
  return Icons.cable_rounded;
}

/// Format a bits-per-second value for display.
/// We accept bytes-per-second from the rest of the codebase and convert
/// up here so the UI always reads "Mbps".
String _friendlyBps(double bytesPerSec) {
  if (bytesPerSec <= 0) return '0 Mbps';
  double bits = bytesPerSec * 8;
  if (bits < 1000) return '${bits.toStringAsFixed(0)} bps';
  if (bits < 1e6) return '${(bits / 1e3).toStringAsFixed(1)} Kbps';
  if (bits < 1e9) return '${(bits / 1e6).toStringAsFixed(1)} Mbps';
  return '${(bits / 1e9).toStringAsFixed(2)} Gbps';
}

// =====================================================================
// MODE PAGE
// =====================================================================
//
// Four big cards explain the bonding modes in everyday English, plus a
// short list of safety/QoS toggles. Anything advanced (transport kind,
// port number, …) lives in the gear-icon settings dialog so this page
// stays uncluttered.

class _ModePage extends StatelessWidget {
  final DispatchController controller;
  const _ModePage({required this.controller});

  static const List<_ModeCardSpec> _specs = <_ModeCardSpec>[
    _ModeCardSpec(
      mode: BondingMode.speed,
      title: 'Faster downloads',
      tagline: 'Use every network at once for the most speed.',
      icon: Icons.bolt_rounded,
    ),
    _ModeCardSpec(
      mode: BondingMode.redundant,
      title: 'Most reliable',
      tagline: 'Send every packet twice so a dropped Wi-Fi never blips a call.',
      icon: Icons.shield_outlined,
    ),
    _ModeCardSpec(
      mode: BondingMode.streaming,
      title: 'Best for video calls',
      tagline: 'Keeps voice and video smooth while still using extra bandwidth.',
      icon: Icons.headset_mic_outlined,
    ),
    _ModeCardSpec(
      mode: BondingMode.local,
      title: 'No server (local only)',
      tagline: 'Combine networks for connections that can reach the destination directly.',
      icon: Icons.home_outlined,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    BondingMode current = controller.settings.policy.mode;
    Policy policy = controller.settings.policy;
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
      children: <Widget>[
        const _SectionLabel(
          icon: Icons.tune_rounded,
          title: 'Pick a mode',
          subtitle:
              'Each mode trades speed, reliability, and battery differently. You can change it any time.',
        ),
        for (_ModeCardSpec spec in _specs)
          _ModeCard(
            spec: spec,
            selected: current == spec.mode,
            onTap: () => controller.setBondingMode(spec.mode),
          ),
        const SizedBox(height: 14),
        const _SectionLabel(
          icon: Icons.toggle_on_outlined,
          title: 'Helpful extras',
          subtitle: 'Sensible defaults for everyone.',
        ),
        _ToggleRow(
          icon: Icons.lock_outline,
          title: 'Block internet when disconnected',
          help:
              'When Dispatch is off, your apps lose internet too. This stops accidental leaks to a network you don\'t trust.',
          value: policy.killSwitch,
          onChanged: (bool v) => controller.setKillSwitch(v),
        ),
        _ToggleRow(
          icon: Icons.videocam_outlined,
          title: 'Prioritize video and voice',
          help:
              'Dispatch detects calls and screen-shares and gives them the lowest-latency route automatically.',
          value: policy.streamingDetection,
          onChanged: (bool v) => controller.setStreamingDetection(v),
        ),
        _ToggleRow(
          icon: Icons.wifi_off_rounded,
          title: 'Help me sign in to coffee-shop Wi-Fi',
          help:
              'When a network bounces you to a login page, Dispatch pauses it until you sign in, then resumes automatically.',
          value: policy.captivePortalAssist,
          onChanged: (bool v) => controller.setCaptivePortalAssist(v),
        ),
      ],
    );
  }
}

class _ModeCardSpec {
  final BondingMode mode;
  final String title;
  final String tagline;
  final IconData icon;
  const _ModeCardSpec({
    required this.mode,
    required this.title,
    required this.tagline,
    required this.icon,
  });
}

class _ModeCard extends StatelessWidget {
  final _ModeCardSpec spec;
  final bool selected;
  final VoidCallback onTap;
  const _ModeCard({
    required this.spec,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    Color tint = selected ? DispatchColors.accent : DispatchColors.muted;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: DispatchColors.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: selected ? tint : DispatchColors.border,
          width: selected ? 1.6 : 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: <Widget>[
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: tint.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(spec.icon, color: tint, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(spec.title,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      Text(spec.tagline,
                          style: const TextStyle(
                              fontSize: 12,
                              color: DispatchColors.muted,
                              height: 1.35)),
                    ],
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: selected ? tint : Colors.transparent,
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: selected ? tint : DispatchColors.border,
                        width: 1.5),
                  ),
                  child: selected
                      ? const Icon(Icons.check, color: Colors.white, size: 14)
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String help;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({
    required this.icon,
    required this.title,
    required this.help,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: DispatchColors.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DispatchColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Icon(icon, size: 18, color: DispatchColors.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(help,
                    style: const TextStyle(
                        fontSize: 11,
                        color: DispatchColors.muted,
                        height: 1.4)),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

// =====================================================================
// PAIR & SHARE PAGE
// =====================================================================

/// Thin wrapper page that explains Pair & Share in friendly language and
/// then drops in the existing [PairShareSection] widget which already
/// handles all the discovery/QR/sharing logic.
class _PairPage extends StatelessWidget {
  final DispatchController controller;
  const _PairPage({required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
      children: <Widget>[
        const _SectionLabel(
          icon: Icons.qr_code_2_rounded,
          title: 'Pair & Share',
          subtitle:
              'Tether another device wirelessly. Connect both Macs to the same Wi-Fi, then pair to combine the other device\'s networks with yours.',
        ),
        PairShareSection(controller: controller),
      ],
    );
  }
}

// =====================================================================
// ACTIVITY PAGE
// =====================================================================
//
// One-stop view of "what is happening right now" — the live flow
// inspector at the top, then a scrollable log of recent proxy/transport
// events at the bottom. We deliberately keep this off the main tabs so
// non-technical users don't see scary connection logs by default.

class _ActivityPage extends StatelessWidget {
  final DispatchController controller;
  const _ActivityPage({required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
      children: <Widget>[
        const _SectionLabel(
          icon: Icons.timeline_rounded,
          title: 'Live activity',
          subtitle:
              'Recent connections, packet flows, and per-network events. Helpful for debugging if something looks wrong.',
        ),
        if (controller.transportKind == TransportKind.tunnel)
          FlowInspectorSection(controller: controller)
        else
          const _SoftBanner(
            color: DispatchColors.muted,
            icon: Icons.info_outline,
            title: 'Flow inspector requires Tunnel mode',
            body:
                'Switch the transport to Tunnel from the gear menu to see per-flow details. SOCKS mode shows only connection events below.',
          ),
        const SizedBox(height: 14),
        _EventsList(controller: controller),
      ],
    );
  }
}

class _EventsList extends StatelessWidget {
  final DispatchController controller;
  const _EventsList({required this.controller});

  @override
  Widget build(BuildContext context) {
    List<ProxyEvent> events = controller.events.reversed.take(60).toList();
    if (events.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: DispatchColors.panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: DispatchColors.border),
        ),
        child: const Text(
          'No events yet. Once Dispatch is running, connection details will appear here.',
          style: TextStyle(fontSize: 13, color: DispatchColors.muted),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: DispatchColors.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DispatchColors.border),
      ),
      child: Column(
        children: <Widget>[
          for (int i = 0; i < events.length; i++) ...<Widget>[
            _EventRow(event: events[i]),
            if (i < events.length - 1)
              const Divider(height: 1, indent: 12, endIndent: 12),
          ],
        ],
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  final ProxyEvent event;
  const _EventRow({required this.event});

  @override
  Widget build(BuildContext context) {
    IconData icon;
    Color color;
    switch (event.type) {
      case ProxyEventType.connectionOpened:
        icon = Icons.south_east_rounded;
        color = DispatchColors.ok;
        break;
      case ProxyEventType.connectionClosed:
        icon = Icons.north_east_rounded;
        color = DispatchColors.muted;
        break;
      case ProxyEventType.error:
        icon = Icons.error_outline;
        color = DispatchColors.danger;
        break;
      case ProxyEventType.warning:
        icon = Icons.timer_off_outlined;
        color = DispatchColors.warn;
        break;
      case ProxyEventType.info:
        icon = Icons.info_outline;
        color = DispatchColors.muted;
        break;
    }
    String headline = event.label;
    String detail = event.message;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(headline,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700)),
                if (detail.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(detail,
                        style: const TextStyle(
                            fontSize: 11, color: DispatchColors.muted)),
                  ),
              ],
            ),
          ),
          Text(_friendlyAgo(event.timestamp),
              style: const TextStyle(
                  fontSize: 11, color: DispatchColors.muted)),
        ],
      ),
    );
  }
}

String _friendlyAgo(DateTime ts) {
  Duration diff = DateTime.now().difference(ts);
  if (diff.inSeconds < 60) return '${diff.inSeconds}s';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  return '${diff.inDays}d';
}

// =====================================================================
// SETTINGS DIALOG (gear icon)
// =====================================================================
//
// Everything power-users want lives here — the listen host / port,
// transport kind, start-at-login, etc. Hidden behind the gear icon so
// the main UI stays uncluttered.

Future<void> _showSettingsDialog(
    BuildContext context, DispatchController controller) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext ctx) => _SettingsDialog(controller: controller),
  );
}

class _SettingsDialog extends StatelessWidget {
  final DispatchController controller;
  const _SettingsDialog({required this.controller});

  @override
  Widget build(BuildContext context) {
    DispatchSettings settings = controller.settings;
    return AlertDialog(
      title: const Text('App settings'),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _SettingsLabel('Listen port',
                  'Apps connect to this port. SOCKS proxy default is 1080.'),
              TextFormField(
                initialValue: settings.listenPort.toString(),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    isDense: true, border: OutlineInputBorder()),
                onChanged: (String v) => controller.setListenPort(v),
              ),
              const SizedBox(height: 12),
              _SettingsLabel('Bind address',
                  'Most people leave this as 127.0.0.1 (this Mac only).'),
              TextFormField(
                initialValue: settings.listenHost,
                decoration: const InputDecoration(
                    isDense: true, border: OutlineInputBorder()),
                onChanged: (String v) => controller.setListenHost(v),
              ),
              const SizedBox(height: 12),
              _SettingsLabel('Transport',
                  'Tunnel = system-wide (needs Network Extension entitlement). SOCKS = per-app via proxy port.'),
              SegmentedButton<TransportKind>(
                segments: const <ButtonSegment<TransportKind>>[
                  ButtonSegment<TransportKind>(
                      value: TransportKind.socks, label: Text('SOCKS')),
                  ButtonSegment<TransportKind>(
                      value: TransportKind.tunnel, label: Text('Tunnel')),
                ],
                selected: <TransportKind>{controller.transportKind},
                onSelectionChanged: (Set<TransportKind> sel) {
                  controller.setTransportKind(sel.first);
                },
              ),
              const SizedBox(height: 12),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Start when I log in'),
                subtitle: const Text(
                    'Launches Arcane Dispatch automatically at login.',
                    style: TextStyle(fontSize: 11)),
                value: settings.launchAtStartup,
                onChanged: (bool v) => controller.setLaunchAtStartup(v),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Connect on launch'),
                subtitle: const Text(
                    'Automatically taps the power button after the app starts.',
                    style: TextStyle(fontSize: 11)),
                value: settings.startProxyOnLaunch,
                onChanged: (bool v) => controller.setStartProxyOnLaunch(v),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Hide menu-bar window on click-away'),
                subtitle: const Text(
                    'Recommended. Off keeps the panel pinned for debugging.',
                    style: TextStyle(fontSize: 11)),
                value: settings.hideOnBlur,
                onChanged: (bool v) => controller.setHideOnBlur(v),
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          child: const Text('Done'),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

class _SettingsLabel extends StatelessWidget {
  final String title;
  final String help;
  const _SettingsLabel(this.title, this.help);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title,
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
          Text(help,
              style: const TextStyle(
                  fontSize: 11, color: DispatchColors.muted, height: 1.35)),
        ],
      ),
    );
  }
}
