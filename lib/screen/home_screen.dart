import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

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
    // Sum every link's cumulative bytes-used-this-cycle so the user sees a
    // single carrier-style "Total used" number. We deliberately walk the
    // controller's link list (not the snapshot map's keys) so links the
    // user turned off still get counted — they were charged real bytes.
    int totalBytesUsed = 0;
    for (Link link in controller.settings.policy.links) {
      totalBytesUsed += controller.dataUsedBytesByLink[link.id] ?? 0;
    }
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
          if (totalBytesUsed > 0) ...<Widget>[
            const SizedBox(height: 10),
            _TotalUsedRow(totalBytes: totalBytesUsed),
          ],
          if (controller.errorText != null) ...<Widget>[
            const SizedBox(height: 10),
            _InlineErrorRow(message: controller.errorText!),
          ],
        ],
      ),
    );
  }

  String _statusLine(int total, int active, bool running) {
    // Auto-adopt now fills the list for the user, so the "you need to
    // add a network" copy from the manual-flow era is no longer
    // accurate. We instead describe what Dispatch is currently doing
    // with whatever networks the OS exposes.
    if (total == 0) {
      return 'Looking for networks…';
    }
    if (!running) {
      return total == 1
          ? '1 network available. Tap to combine.'
          : '$total networks available. Tap to combine.';
    }
    if (active == 0) {
      return 'On — waiting for the first network to carry traffic…';
    }
    if (active == 1) {
      // With only one link actually moving bytes we can't truly
      // "combine" anything, so be honest about it.
      return total > 1
          ? 'On — 1 of $total networks carrying traffic'
          : 'On — carrying traffic on 1 network';
    }
    return 'On — auto-combining $active networks';
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

/// Compact "Total used" pill that sits below the Download/Upload cells on
/// [_PowerCard]. Surfaces the carrier-style billing-cycle bytes counter so
/// users with metered links can spot expensive months at a glance.
class _TotalUsedRow extends StatelessWidget {
  final int totalBytes;

  const _TotalUsedRow({required this.totalBytes});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: DispatchColors.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: DispatchColors.border),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const Icon(
            Icons.data_usage_rounded,
            size: 14,
            color: DispatchColors.muted,
          ),
          const SizedBox(width: 6),
          Text(
            'Total used this cycle',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: DispatchColors.muted,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _friendlyBytes(totalBytes),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
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
            'Hit the big power button to reconnect, or turn it off in the gear-icon settings.',
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
// Goal: open the app, see every network your Mac knows about — same list
// System Settings → Network shows — and at a glance know which ones
// Dispatch is combining right now and which are sitting available for
// when you plug them in. Designed to mirror Speedify's network panel.
//
// Groups (top to bottom):
//
//   * In use now — saved network services with a live link, currently
//     carrying or standing by. Each card is the existing `_NetworkCard`
//     with full priority / cap / data controls.
//
//   * Available — saved services Dispatch knows about (iPhone USB,
//     USB-Ethernet adapters, Bluetooth PAN, …) but whose hardware port
//     isn't currently up. Plug in / pair the device and Dispatch picks
//     it up automatically.
//
//   * Off — services the user has turned off (priority = never). Kept
//     visible so it's easy to flip them back on.
//
// No "Add" button. No IP addresses. No BSD device names in the primary
// view. The DispatchController's `_autoAdoptInterfaces` keeps the
// adopted-link list in lockstep with what the OS reports.

// ─────────────────────────────────────────────────────────────────────────
//  Hub-and-spoke bond graphic
// ─────────────────────────────────────────────────────────────────────────
//
// The eye-catching hero at the top of the Networks tab. It shows the
// Mac at the center with one spoke per known network radiating outward,
// each spoke colored by health and animated when traffic is flowing.
//
// Why a custom paint instead of a Stack of Containers:
//   * One animation controller drives every spoke's flow particles —
//     much cheaper than per-spoke `AnimatedBuilder`s and avoids the
//     widget tree churn that breaks AccessibilityBridge on macOS.
//   * Exact geometry (cos/sin endpoints, angled labels) is way easier
//     in a painter than in Flex/Stack arithmetic.
//   * Endpoints fall on a perfect circle regardless of the parent
//     constraints, so the layout reads as "the Mac talking to N
//     networks" instead of an arbitrary grid.

/// Snapshot of what one spoke should look like in [_BondGraphic].
/// Built fresh on every controller change — these are immutable view
/// models, not long-lived state.
class _SpokeSpec {
  /// Friendly display name (`Wi-Fi — Hometown`, `iPhone USB`, …).
  final String name;

  /// Glyph for the endpoint circle.
  final IconData icon;

  /// Overall health bucket. Drives spoke color, endpoint fill, and
  /// whether flow dots are drawn.
  final _SpokeHealth health;

  /// 0…1 intensity used to scale the flow animation: higher = more,
  /// brighter particles. We clamp at 50 Mbps so a single fast link
  /// doesn't drown out the others visually.
  final double trafficIntensity;

  /// True when the link is moving inbound traffic right now. Drives the
  /// download-direction (toward-hub) particle flow.
  final bool downloading;

  /// True when the link is moving outbound traffic right now. Drives the
  /// upload-direction (away-from-hub) particle flow.
  final bool uploading;

  const _SpokeSpec({
    required this.name,
    required this.icon,
    required this.health,
    required this.trafficIntensity,
    required this.downloading,
    required this.uploading,
  });
}

/// Health buckets for [_SpokeSpec.health]. Order matches drawing
/// priority — `active` spokes paint last so they sit on top.
enum _SpokeHealth {
  /// Healthy and currently carrying traffic. Green.
  active,

  /// Healthy and reachable but not the one moving bytes right now.
  /// Green-dim (no flow particles).
  standby,

  /// Configured but the OS hardware port isn't up (cable unplugged,
  /// Wi-Fi off, hotspot lost). Grey-dashed.
  disconnected,

  /// The link is reachable but has no internet / failed captive portal
  /// / failing the supervisor probe. Red — the user can see at a glance
  /// which one to fix.
  broken,

  /// User explicitly turned this network off (priority = never). Grey,
  /// no flow.
  off,

  /// We don't have enough info yet (supervisor hasn't reported). Soft
  /// grey, no flow.
  unknown,
}

/// Live hub-and-spoke visualization of every network Dispatch knows
/// about. Designed to live at the top of [_NetworksPage] so the user
/// always has an at-a-glance "what's connected, what's broken, what's
/// flowing" view.
class _BondGraphic extends StatefulWidget {
  final DispatchController controller;
  const _BondGraphic({required this.controller});

  @override
  State<_BondGraphic> createState() => _BondGraphicState();
}

class _BondGraphicState extends State<_BondGraphic>
    with SingleTickerProviderStateMixin {
  /// One repeating controller drives the flow-particle animation for
  /// every spoke. 2.4 s per cycle reads as "purposeful flow" without
  /// being distracting.
  late final AnimationController _flow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat();

  @override
  void dispose() {
    _flow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    List<_SpokeSpec> spokes = _buildSpokes(widget.controller);
    if (spokes.isEmpty) {
      // No networks at all — show a friendly placeholder instead of an
      // empty circle. Same height so the layout doesn't jump as
      // services arrive.
      return SizedBox(
        height: 220,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const <Widget>[
              Icon(Icons.travel_explore_rounded,
                  size: 40, color: DispatchColors.muted),
              SizedBox(height: 8),
              Text('Looking for networks…',
                  style: TextStyle(
                      color: DispatchColors.muted,
                      fontWeight: FontWeight.w600)),
              SizedBox(height: 4),
              Text(
                'Connect a Wi-Fi, plug in Ethernet, or pair your phone.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: DispatchColors.muted, fontSize: 11),
              ),
            ],
          ),
        ),
      );
    }
    bool running = widget.controller.isRunning;
    // Total bps across every link — drives the center data/s readout.
    // We sum bpsIn + bpsOut so the hub shows aggregate device
    // throughput, matching how Speedify's headline number reads. NaN
    // / negative samples coerce to 0 to keep the formatter happy.
    double totalBps = 0;
    for (Link link in widget.controller.settings.policy.links) {
      LinkMetric? m = widget.controller.linkMetrics[link.id];
      if (m == null) continue;
      double inV = (m.bpsIn ?? 0);
      double outV = (m.bpsOut ?? 0);
      if (inV.isFinite && inV > 0) totalBps += inV;
      if (outV.isFinite && outV > 0) totalBps += outV;
    }
    return SizedBox(
      height: 240,
      child: AnimatedBuilder(
        animation: _flow,
        builder: (BuildContext _, Widget? _) {
          return CustomPaint(
            painter: _BondPainter(
              spokes: spokes,
              t: _flow.value,
              running: running,
              totalBps: totalBps,
              textDirection: Directionality.of(context),
            ),
            child: const SizedBox.expand(),
          );
        },
      ),
    );
  }

  /// Build a spoke spec for every adopted [Link] in priority order.
  /// We deliberately include `LinkPriority.never` so the user can see
  /// the networks they've blocked sitting on the wheel (greyed out),
  /// confirming the blacklist is honored.
  List<_SpokeSpec> _buildSpokes(DispatchController c) {
    Map<String, NamedInterface> names = c.namingService.byBsd;
    Map<String, String> ipToBsd = _buildIpToBsd(c.interfaces);
    List<_SpokeSpec> out = <_SpokeSpec>[];
    for (Link link in c.settings.policy.links) {
      LinkMetric? m = c.linkMetrics[link.id];
      LinkStatus? sup = c.lastHealthEvent?.statuses[link.id];
      CaptivePortalProbeResult? cap = c.captiveStates[link.id];
      bool present = _isInterfacePresent(link, c);
      double bpsIn = m?.bpsIn ?? 0;
      double bpsOut = m?.bpsOut ?? 0;
      double bps = bpsIn + bpsOut;
      // 1.0 == "this link alone is pushing 50 Mbps" — enough that the
      // flow particles look saturated without making smaller links
      // invisible.
      double intensity = (bps / 50e6).clamp(0.0, 1.0);
      _SpokeHealth health = _classifyHealth(
        link: link,
        supervisorStatus: sup,
        captiveState: cap,
        interfacePresent: present,
        carrying: bps > 0,
      );
      out.add(_SpokeSpec(
        name: _friendlyLinkName(link, names, ipToBsd: ipToBsd),
        icon: _iconForLinkName(link, names, ipToBsd: ipToBsd),
        health: health,
        trafficIntensity: intensity,
        downloading: bpsIn > 0,
        uploading: bpsOut > 0,
      ));
    }
    return out;
  }

  /// Translate the raw probe / supervisor signals into one of the
  /// six [_SpokeHealth] buckets the painter understands. Mirrors the
  /// `_statusLineFor` state machine that drives the per-card text so
  /// the graphic and the cards always agree.
  static _SpokeHealth _classifyHealth({
    required Link link,
    required LinkStatus? supervisorStatus,
    required CaptivePortalProbeResult? captiveState,
    required bool interfacePresent,
    required bool carrying,
  }) {
    if (link.priority == LinkPriority.never) return _SpokeHealth.off;
    if (!interfacePresent && link.kind == LinkKind.local) {
      return _SpokeHealth.disconnected;
    }
    if (captiveState == CaptivePortalProbeResult.captive) {
      return _SpokeHealth.broken;
    }
    switch (supervisorStatus) {
      case LinkStatus.healthy:
        return carrying ? _SpokeHealth.active : _SpokeHealth.standby;
      case LinkStatus.degraded:
        return _SpokeHealth.standby;
      case LinkStatus.unhealthy:
        return _SpokeHealth.broken;
      case LinkStatus.disabled:
        return _SpokeHealth.off;
      case LinkStatus.unknown:
      case null:
        return _SpokeHealth.unknown;
    }
  }
}

/// Custom painter for [_BondGraphic]. Draws the central hub, every
/// spoke line, the endpoint badges, the labels, and the flowing
/// particles for active spokes — all driven by a single animation
/// controller via [t].
class _BondPainter extends CustomPainter {
  final List<_SpokeSpec> spokes;
  final double t; // 0..1, repeats every cycle
  final bool running;
  final double totalBps;
  final TextDirection textDirection;

  _BondPainter({
    required this.spokes,
    required this.t,
    required this.running,
    required this.totalBps,
    required this.textDirection,
  });

  @override
  void paint(Canvas canvas, Size size) {
    Offset center = Offset(size.width / 2, size.height / 2 - 4);
    // Leave room around the rim for labels.
    double maxR = math.min(size.width, size.height) / 2 - 48;
    double endpointR = 18;
    double hubR = 24;

    int n = spokes.length;
    for (int i = 0; i < n; i++) {
      // Start at top (-90°), distribute evenly clockwise.
      double angle = -math.pi / 2 + (2 * math.pi * i / n);
      Offset endpoint =
          center + Offset(math.cos(angle), math.sin(angle)) * maxR;
      _SpokeSpec spoke = spokes[i];
      Color spokeColor = _colorFor(spoke.health);

      _drawSpoke(canvas, center, endpoint, spoke, spokeColor);
      _drawFlowParticles(canvas, center, endpoint, spoke, spokeColor);
      _drawEndpoint(canvas, endpoint, endpointR, spoke, spokeColor);
      _drawLabel(canvas, center, endpoint, endpointR, spoke);
    }

    _drawHub(canvas, center, hubR);
  }

  void _drawSpoke(
      Canvas canvas, Offset center, Offset endpoint, _SpokeSpec spoke, Color color) {
    Paint paint = Paint()
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    // Disconnected / off / broken: dashed line for "not flowing".
    bool dashed = spoke.health == _SpokeHealth.disconnected ||
        spoke.health == _SpokeHealth.off ||
        spoke.health == _SpokeHealth.unknown;
    if (dashed) {
      paint.color = color.withValues(alpha: 0.35);
      _drawDashedLine(canvas, center, endpoint, paint, 6, 5);
    } else {
      paint.color = color.withValues(alpha: 0.45);
      canvas.drawLine(center, endpoint, paint);
    }
  }

  /// Particles traveling along the spoke. Two flow regimes:
  ///   * **Idle pulse** — when the link is healthy/active but no
  ///     traffic is moving right now, we still send a single soft
  ///     particle down the wire so the user can tell the tether is
  ///     alive. Speedify does the same — a 'breathing' indicator that
  ///     reads as 'wired up, ready'.
  ///   * **Loaded stream** — when there *is* throughput, particle
  ///     count, brightness, radius, and trail glow all scale with
  ///     [_SpokeSpec.trafficIntensity] so the visual codes "this is
  ///     where the bytes are coming from".
  /// Direction: download goes endpoint→hub, upload goes hub→endpoint.
  /// Bidirectional spokes alternate particle phases so you can see
  /// both directions on the same wire.
  void _drawFlowParticles(
      Canvas canvas,
      Offset center,
      Offset endpoint,
      _SpokeSpec spoke,
      Color color) {
    if (!running) return;
    // Idle pulse only applies to healthy spokes — broken/off/unknown
    // stay quiet.
    bool eligible = spoke.health == _SpokeHealth.active ||
        spoke.health == _SpokeHealth.standby;
    if (!eligible) return;

    bool loaded = spoke.downloading || spoke.uploading;
    int particles = loaded ? (3 + (spoke.trafficIntensity * 5)).round() : 1;
    Paint paint = Paint()..color = color;
    for (int p = 0; p < particles; p++) {
      double phase = (t + p / particles) % 1.0;
      // Direction:
      //   * idle pulse: always endpoint→hub (so the user reads "data
      //     coming in")
      //   * download-only: endpoint→hub
      //   * upload-only: hub→endpoint
      //   * bidirectional: alternate per particle
      bool reverse;
      if (!loaded) {
        reverse = false;
      } else if (spoke.uploading && !spoke.downloading) {
        reverse = true;
      } else if (spoke.downloading && !spoke.uploading) {
        reverse = false;
      } else {
        reverse = p.isEven;
      }
      double frac = reverse ? phase : (1.0 - phase);
      Offset pos = Offset.lerp(center, endpoint, frac)!;
      // Bigger, brighter dots when traffic is real.
      double radius = loaded ? (3.0 + spoke.trafficIntensity * 2.4) : 2.0;
      // Sin-shaped fade so particles ease into/out of the endpoints.
      double alphaT = math.sin(frac * math.pi).clamp(0.0, 1.0);
      double baseAlpha = loaded ? 0.65 : 0.30;
      double topAlpha = loaded ? 0.95 : 0.55;
      // Glow halo behind loaded particles — gives the 'data stream'
      // virtual feel without needing per-frame shader work.
      if (loaded) {
        Paint halo = Paint()
          ..color = color.withValues(alpha: 0.18 + 0.18 * alphaT)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
        canvas.drawCircle(pos, radius + 2.2, halo);
      }
      paint.color = color.withValues(alpha: baseAlpha + (topAlpha - baseAlpha) * alphaT);
      canvas.drawCircle(pos, radius, paint);
    }
  }

  void _drawEndpoint(
      Canvas canvas, Offset endpoint, double radius, _SpokeSpec spoke, Color color) {
    Paint fill = Paint()..color = _surfaceFor(spoke.health);
    Paint border = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(endpoint, radius, fill);
    canvas.drawCircle(endpoint, radius, border);
    // Glow for active spokes — telegraphs "this one's working."
    if (spoke.health == _SpokeHealth.active) {
      Paint glow = Paint()
        ..color = color.withValues(alpha: 0.18)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
      canvas.drawCircle(endpoint, radius + 3, glow);
    }
    // Icon inside the badge.
    TextPainter tp = TextPainter(
      textDirection: textDirection,
      text: TextSpan(
        text: String.fromCharCode(spoke.icon.codePoint),
        style: TextStyle(
          fontFamily: spoke.icon.fontFamily,
          package: spoke.icon.fontPackage,
          fontSize: 18,
          color: spoke.health == _SpokeHealth.off ||
                  spoke.health == _SpokeHealth.unknown
              ? DispatchColors.muted
              : color,
        ),
      ),
    )..layout();
    tp.paint(canvas, endpoint - Offset(tp.width / 2, tp.height / 2));
  }

  void _drawHub(Canvas canvas, Offset center, double radius) {
    // Hub fill: green when at least one spoke is active and we're
    // running, neutral panel otherwise.
    bool anyActive = running &&
        spokes.any((_SpokeSpec s) => s.health == _SpokeHealth.active);
    Color fill = anyActive ? DispatchColors.ok : DispatchColors.panel;
    Color stroke =
        anyActive ? DispatchColors.ok : DispatchColors.border;
    Paint p = Paint()..color = fill;
    Paint border = Paint()
      ..color = stroke
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(center, radius, p);
    canvas.drawCircle(center, radius, border);
    // Subtle ring when running, for "alive" affordance.
    if (anyActive) {
      Paint ring = Paint()
        ..color = DispatchColors.ok.withValues(alpha: 0.18)
        ..strokeWidth = 4
        ..style = PaintingStyle.stroke;
      canvas.drawCircle(center, radius + 4, ring);
    }
    // Mac glyph at the very top of the hub. We make room for the
    // data/s readout *below* the glyph (within the hub circle) when
    // running, otherwise the glyph centers like before.
    IconData icon = anyActive
        ? Icons.laptop_mac_rounded
        : Icons.laptop_mac_outlined;
    bool showRate = running;
    double iconYOffset = showRate ? -8 : 0; // shift glyph up if rate shown
    TextPainter tp = TextPainter(
      textDirection: textDirection,
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontSize: showRate ? 18 : 24,
          color: anyActive ? Colors.white : DispatchColors.muted,
        ),
      ),
    )..layout();
    tp.paint(
      canvas,
      Offset(center.dx - tp.width / 2,
          center.dy + iconYOffset - tp.height / 2),
    );

    // Total data/s readout — sits below the laptop glyph inside the
    // hub circle so the user always sees "the device is currently
    // moving X right now" without flicking to another tab. Hidden
    // when the tunnel isn't running because the number would be
    // misleadingly zero.
    if (showRate) {
      String text = _formatRate(totalBps);
      Color textColor = anyActive ? Colors.white : DispatchColors.muted;
      TextPainter rate = TextPainter(
        textDirection: textDirection,
        textAlign: TextAlign.center,
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: textColor,
          ),
        ),
      )..layout();
      rate.paint(
        canvas,
        Offset(center.dx - rate.width / 2, center.dy + 4),
      );
    }
  }

  /// Format bytes/sec into a compact 'X.X Mb/s' / 'X.X Kb/s' string for
  /// the hub readout. Uses bits (Speedify-style) — most users read
  /// network throughput in bits, not bytes. Range:
  ///   * <  1 Kb/s   : '0 b/s'   (avoid the 'now' flicker on idle)
  ///   * <  1 Mb/s   : 'XXX Kb/s'
  ///   * <  1 Gb/s   : 'XX.X Mb/s'
  ///   * >= 1 Gb/s   : 'X.XX Gb/s'
  String _formatRate(double bps) {
    double bits = bps * 8;
    if (bits < 1e3) return '0 b/s';
    if (bits < 1e6) return '${(bits / 1e3).toStringAsFixed(0)} Kb/s';
    if (bits < 1e9) return '${(bits / 1e6).toStringAsFixed(1)} Mb/s';
    return '${(bits / 1e9).toStringAsFixed(2)} Gb/s';
  }

  /// Label sits just outside the endpoint, on the same side as the
  /// endpoint relative to the hub (above for top spokes, below for
  /// bottom spokes, etc.). Truncates long names so adjacent labels
  /// don't visually collide.
  void _drawLabel(Canvas canvas, Offset center, Offset endpoint,
      double endpointRadius, _SpokeSpec spoke) {
    // Pick where the label sits relative to the endpoint based on which
    // quadrant the spoke is in. Top-half spokes get labels above their
    // endpoint, bottom-half below.
    bool above = endpoint.dy < center.dy;
    String shown = spoke.name.length > 22
        ? '${spoke.name.substring(0, 21)}…'
        : spoke.name;
    Color color = spoke.health == _SpokeHealth.off ||
            spoke.health == _SpokeHealth.unknown
        ? DispatchColors.muted
        : DispatchColors.ink;
    TextPainter tp = TextPainter(
      textDirection: textDirection,
      textAlign: TextAlign.center,
      maxLines: 1,
      ellipsis: '…',
      text: TextSpan(
        text: shown,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    )..layout(maxWidth: 110);
    Offset labelPos;
    if (above) {
      labelPos = Offset(
        endpoint.dx - tp.width / 2,
        endpoint.dy - endpointRadius - 2 - tp.height,
      );
    } else {
      labelPos = Offset(
        endpoint.dx - tp.width / 2,
        endpoint.dy + endpointRadius + 2,
      );
    }
    tp.paint(canvas, labelPos);
  }

  void _drawDashedLine(
      Canvas canvas, Offset a, Offset b, Paint paint, double dashLen, double gap) {
    double dx = b.dx - a.dx;
    double dy = b.dy - a.dy;
    double len = math.sqrt(dx * dx + dy * dy);
    if (len == 0) return;
    double ux = dx / len;
    double uy = dy / len;
    double pos = 0;
    while (pos < len) {
      double end = math.min(pos + dashLen, len);
      Offset p1 = Offset(a.dx + ux * pos, a.dy + uy * pos);
      Offset p2 = Offset(a.dx + ux * end, a.dy + uy * end);
      canvas.drawLine(p1, p2, paint);
      pos = end + gap;
    }
  }

  Color _colorFor(_SpokeHealth h) {
    switch (h) {
      case _SpokeHealth.active:
        return DispatchColors.ok;
      case _SpokeHealth.standby:
        return DispatchColors.ok;
      case _SpokeHealth.broken:
        return DispatchColors.danger;
      case _SpokeHealth.disconnected:
      case _SpokeHealth.off:
      case _SpokeHealth.unknown:
        return DispatchColors.muted;
    }
  }

  /// Endpoint disc fill: a slightly translucent version of the panel
  /// color so the icon sits on a contrast plate even on darker
  /// backgrounds.
  Color _surfaceFor(_SpokeHealth h) {
    if (h == _SpokeHealth.active) {
      return DispatchColors.ok.withValues(alpha: 0.18);
    }
    if (h == _SpokeHealth.broken) {
      return DispatchColors.danger.withValues(alpha: 0.12);
    }
    return DispatchColors.surface;
  }

  @override
  bool shouldRepaint(covariant _BondPainter old) {
    return old.t != t ||
        old.running != running ||
        (old.totalBps - totalBps).abs() > 1e4 || // ~10 Kb/s sensitivity
        old.spokes.length != spokes.length ||
        !_specListEqual(old.spokes, spokes);
  }

  static bool _specListEqual(List<_SpokeSpec> a, List<_SpokeSpec> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      _SpokeSpec x = a[i];
      _SpokeSpec y = b[i];
      if (x.name != y.name ||
          x.health != y.health ||
          x.downloading != y.downloading ||
          x.uploading != y.uploading ||
          (x.trafficIntensity - y.trafficIntensity).abs() > 0.05) {
        return false;
      }
    }
    return true;
  }
}

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
    List<KnownNetworkService> allServices =
        c.namingService.services.where((KnownNetworkService s) {
      return s.isUserFacing;
    }).toList();

    // Map services to links: prefer matching by BSD device name (the
    // most stable identifier across reboots). Paired links have no BSD
    // name and bubble up as orphans.
    Map<String, Link> linkByBsd = <String, Link>{};
    for (Link link in links) {
      String? iface = link.interfaceName?.toLowerCase();
      if (iface == null || iface.isEmpty) continue;
      linkByBsd[iface] = link;
    }

    // Track which links we've shown via a known service so the orphan
    // bucket can render only the remaining ones (paired links, plus
    // local links whose service hasn't been resolved yet).
    Set<String> usedLinkIds = <String>{};

    // Bucket each known service into one of three groups.
    List<_ServiceRow> inUse = <_ServiceRow>[];
    List<_ServiceRow> available = <_ServiceRow>[];
    List<_ServiceRow> off = <_ServiceRow>[];

    for (KnownNetworkService svc in allServices) {
      String? bsd = svc.bsdName?.toLowerCase();
      Link? matched = bsd == null ? null : linkByBsd[bsd];
      if (matched != null) usedLinkIds.add(matched.id);
      _ServiceRow row = _ServiceRow(service: svc, link: matched);
      if (matched != null && matched.priority == LinkPriority.never) {
        off.add(row);
      } else if (svc.isCurrentlyAvailable) {
        inUse.add(row);
      } else {
        available.add(row);
      }
    }

    // Pick up any links that didn't match a known service: paired links,
    // and the rare case where a Link is in the policy but the naming
    // service hasn't surfaced the corresponding hardware port yet.
    List<Link> orphanLinks = <Link>[];
    for (Link link in links) {
      if (usedLinkIds.contains(link.id)) continue;
      orphanLinks.add(link);
    }
    for (Link link in orphanLinks) {
      _ServiceRow row = _ServiceRow(service: null, link: link);
      if (link.priority == LinkPriority.never) {
        off.add(row);
      } else {
        // Paired link or unresolved local — treat as "In use now" so it
        // shows immediately. The user already knows about it; we don't
        // want to hide it under "Available".
        inUse.add(row);
      }
    }

    // Synthesize an entry for connection kinds the user might expect to
    // be considered but that don't currently exist on the system. macOS
    // only creates a `Bluetooth PAN` service after a tether-capable device
    // is paired, so the user has no way to discover that Dispatch *will*
    // use Bluetooth tethering until they pair something. We show a hint
    // card so they know to pair their phone for cellular fallback.
    bool hasBluetoothEntry =
        allServices.any((KnownNetworkService s) =>
            s.kind == NamedInterfaceKind.bluetoothTether);
    bool hasCellularEntry =
        allServices.any((KnownNetworkService s) =>
            s.kind == NamedInterfaceKind.cellularTether);
    if (!hasBluetoothEntry && !hasCellularEntry) {
      // No phone is currently considered at all — surface a single hint
      // explaining how to enable it. (When at least one cellular tether
      // is saved, the user already knows; no need to nag.)
      available.add(_ServiceRow(
        service: const KnownNetworkService(
          serviceName: 'Phone tether (Bluetooth or USB)',
          hardwarePort: 'Bluetooth PAN',
          kind: NamedInterfaceKind.bluetoothTether,
        ),
        link: null,
      ));
    }

    bool servicesLoaded = c.namingService.services.isNotEmpty;
    bool everythingEmpty =
        inUse.isEmpty && available.isEmpty && off.isEmpty;

    if (c.loadingInterfaces && everythingEmpty && !servicesLoaded) {
      return const Center(
          child: Padding(
        padding: EdgeInsets.all(48),
        child: CircularProgressIndicator(),
      ));
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
      children: <Widget>[
        // Hub-and-spoke graphic up top — the user's at-a-glance "what's
        // connected, what's broken, what's flowing" view. Lives above
        // the textual section label so it's the first thing the eye
        // lands on when opening the Networks tab.
        _BondGraphic(controller: c),
        _SectionLabel(
          icon: Icons.dns_rounded,
          title: 'Your networks',
          subtitle: everythingEmpty
              ? 'Looking for networks… plug in Ethernet or join a Wi-Fi to begin.'
              : (inUse.length <= 1
                  ? 'Dispatch combines every network with Internet access. Tap a card to expand limits, or flip a switch to turn one off.'
                  : 'Dispatch is combining ${inUse.length} networks. Tap a card to set role, speed, or data caps.'),
        ),
        if (everythingEmpty)
          const _EmptyHint(
            icon: Icons.lan_outlined,
            text:
                'Once a network appears (Wi-Fi, Ethernet, iPhone USB, cellular hotspot, Bluetooth PAN…) it shows up here automatically and joins the bond. There\'s no Add button on purpose.',
          )
        else ...<Widget>[
          if (inUse.isNotEmpty)
            _NetworkGroupLabel(
              icon: Icons.bolt_rounded,
              title: 'In use now',
              count: inUse.length,
              color: DispatchColors.ok,
            ),
          for (_ServiceRow row in inUse) _renderRow(c, row),
          if (available.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            _NetworkGroupLabel(
              icon: Icons.power_off_rounded,
              title: 'Available — connect to use',
              count: available.length,
              color: DispatchColors.muted,
            ),
          ],
          for (_ServiceRow row in available) _renderRow(c, row),
          if (off.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            _NetworkGroupLabel(
              icon: Icons.do_not_disturb_alt_rounded,
              title: 'Off',
              count: off.length,
              color: DispatchColors.muted,
            ),
          ],
          for (_ServiceRow row in off) _renderRow(c, row),
        ],
      ],
    );
  }

  Widget _renderRow(DispatchController c, _ServiceRow row) {
    if (row.link != null) {
      return _NetworkCard(
        key: ValueKey<String>('net_${row.link!.id}'),
        controller: c,
        link: row.link!,
        knownService: row.service,
      );
    }
    return _DisconnectedServiceCard(
      key: ValueKey<String>('svc_${row.service!.serviceName}'),
      service: row.service!,
    );
  }
}

/// One row in the network list. Either:
///   * `service != null && link != null` — adopted network the OS knows
///     about. Standard `_NetworkCard`.
///   * `service != null && link == null` — saved service whose hardware
///     port isn't currently up (iPhone unplugged, USB adapter detached).
///     Renders a `_DisconnectedServiceCard`.
///   * `service == null && link != null` — orphan link (paired, or a
///     local link whose service hasn't been resolved yet).
class _ServiceRow {
  final KnownNetworkService? service;
  final Link? link;
  const _ServiceRow({required this.service, required this.link});
}

/// Group-divider label shown between groups in the Networks list.
/// Visually distinct from `_SectionLabel` — smaller, no description, and
/// shows a count chip so the user can tell at a glance how many
/// networks are in each bucket.
class _NetworkGroupLabel extends StatelessWidget {
  final IconData icon;
  final String title;
  final int count;
  final Color color;

  const _NetworkGroupLabel({
    required this.icon,
    required this.title,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 12, 2, 8),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Slim card shown for known network services that aren't currently up
/// (iPhone USB without an iPhone, USB-Ethernet adapter not plugged in,
/// Bluetooth PAN with no paired tether device). Communicates "Dispatch
/// knows about this and will combine it the moment it connects."
class _DisconnectedServiceCard extends StatelessWidget {
  final KnownNetworkService service;
  const _DisconnectedServiceCard({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    String name = service.displayName;
    IconData icon = _iconForKind(service.kind);
    String hint = _hintForKind(service.kind);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: DispatchColors.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DispatchColors.border),
      ),
      child: Row(
        children: <Widget>[
          _NetworkIcon(icon: icon, color: DispatchColors.muted, dim: true),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        name,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: DispatchColors.muted,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const DispatchBadge(
                      label: 'Disconnected',
                      color: DispatchColors.muted,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  hint,
                  style: const TextStyle(
                    fontSize: 12,
                    color: DispatchColors.muted,
                    height: 1.3,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static IconData _iconForKind(NamedInterfaceKind k) {
    switch (k) {
      case NamedInterfaceKind.wifi:
        return Icons.wifi_rounded;
      case NamedInterfaceKind.ethernet:
        return Icons.settings_ethernet_rounded;
      case NamedInterfaceKind.cellularTether:
        return Icons.smartphone_rounded;
      case NamedInterfaceKind.bluetoothTether:
        return Icons.bluetooth_rounded;
      case NamedInterfaceKind.thunderbolt:
        return Icons.bolt_rounded;
      case NamedInterfaceKind.bridge:
      case NamedInterfaceKind.virtualTunnel:
      case NamedInterfaceKind.loopback:
      case NamedInterfaceKind.other:
        return Icons.cable_rounded;
    }
  }

  static String _hintForKind(NamedInterfaceKind k) {
    switch (k) {
      case NamedInterfaceKind.wifi:
        return 'Join a Wi-Fi network and Dispatch will start combining it.';
      case NamedInterfaceKind.cellularTether:
        return 'Plug in your iPhone (USB) or enable Personal Hotspot — Dispatch will use it for cellular fallback automatically.';
      case NamedInterfaceKind.bluetoothTether:
        return 'Pair an iPhone or Android tether device — Dispatch will combine it the moment it connects.';
      case NamedInterfaceKind.ethernet:
        return 'Plug in this adapter and Dispatch will start combining it.';
      case NamedInterfaceKind.thunderbolt:
        return 'Connect the Thunderbolt cable and Dispatch will join it to the bond.';
      case NamedInterfaceKind.bridge:
      case NamedInterfaceKind.virtualTunnel:
      case NamedInterfaceKind.loopback:
      case NamedInterfaceKind.other:
        return 'Saved network — Dispatch will use it when it becomes available.';
    }
  }
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

  /// When the saved-services list resolved this link to a named macOS
  /// network service, we pass it through so the card can use the
  /// authoritative service name (`iPhone USB`, `Bluetooth PAN`, the
  /// current Wi-Fi SSID, …) without re-deriving it from the legacy IP /
  /// BSD fallback path.
  final KnownNetworkService? knownService;

  const _NetworkCard({
    super.key,
    required this.controller,
    required this.link,
    this.knownService,
  });

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
    KnownNetworkService? svc = widget.knownService;
    String friendlyName = svc != null
        ? svc.displayName
        : _friendlyLinkName(link, names, ipToBsd: ipToBsd);
    IconData kindIcon = svc != null
        ? _DisconnectedServiceCard._iconForKind(svc.kind)
        : _iconForLinkName(link, names, ipToBsd: ipToBsd);
    LinkStatus? supervisorStatus =
        c.lastHealthEvent?.statuses[link.id];
    CaptivePortalProbeResult? captiveState = c.captiveStates[link.id];
    bool interfacePresent = _isInterfacePresent(link, c);

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
                          _statusLineFor(
                            metric,
                            link,
                            supervisorStatus: supervisorStatus,
                            captiveState: captiveState,
                            interfacePresent: interfacePresent,
                          ),
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
}

/// Plain-English subtitle describing what this link is doing right
/// now. We deliberately avoid raw RTT / loss numbers in the primary
/// network card — the Activity tab carries the full breakdown with
/// charts, but the at-a-glance card should answer "is this network
/// helping me right now?" in one line.
///
/// State precedence (first match wins):
///   1. Link is turned off (priority = never).
///   2. Interface is gone (cable unplugged, Wi-Fi off, hotspot lost).
///   3. Captive portal detected — user must sign in.
///   4. Supervisor verdict — healthy / degraded / unhealthy / unknown.
///
/// Lifted out of `_NetworkCardState` so the Activity tab can reuse it
/// verbatim and keep the two views perfectly in sync.
String _statusLineFor(
  LinkMetric? m,
  Link link, {
  LinkStatus? supervisorStatus,
  CaptivePortalProbeResult? captiveState,
  bool interfacePresent = true,
}) {
  if (link.priority == LinkPriority.never) {
    return 'Off — Dispatch isn\'t using this network';
  }
  if (!interfacePresent && link.kind == LinkKind.local) {
    return 'Disconnected — will rejoin when reconnected';
  }
  if (captiveState == CaptivePortalProbeResult.captive) {
    return 'Sign-in required — opening a browser to this network will fix it';
  }
  switch (supervisorStatus) {
    case LinkStatus.healthy:
      double? bpsIn = m?.bpsIn;
      double? bpsOut = m?.bpsOut;
      bool carryingIn = bpsIn != null && bpsIn > 0;
      bool carryingOut = bpsOut != null && bpsOut > 0;
      if (carryingIn && carryingOut) {
        return 'Carrying traffic  •  ↓ ${_friendlyBps(bpsIn)}  ↑ ${_friendlyBps(bpsOut)}';
      }
      if (carryingIn) {
        return 'Carrying traffic  •  ↓ ${_friendlyBps(bpsIn)}';
      }
      if (carryingOut) {
        return 'Carrying traffic  •  ↑ ${_friendlyBps(bpsOut)}';
      }
      return 'Healthy, standing by';
    case LinkStatus.degraded:
      return 'Reachable — held in reserve';
    case LinkStatus.unhealthy:
      return 'No Internet — Dispatch is routing around it';
    case LinkStatus.disabled:
      return 'Off — Dispatch isn\'t using this network';
    case LinkStatus.unknown:
    case null:
      if (m == null || m.rttMs == null) return 'Checking…';
      return 'Healthy, standing by';
  }
}

/// Compact (label, color) tuple for the per-link status pill rendered on
/// the Activity tab. Same state machine as [_statusLineFor] but boiled
/// down to one word + one color so it fits inside a [DispatchBadge].
class _StatusBadgeInfo {
  final String label;
  final Color color;
  const _StatusBadgeInfo(this.label, this.color);
}

_StatusBadgeInfo _statusBadgeFor(
  LinkMetric? m,
  Link link, {
  LinkStatus? supervisorStatus,
  CaptivePortalProbeResult? captiveState,
  bool interfacePresent = true,
}) {
  if (link.priority == LinkPriority.never) {
    return const _StatusBadgeInfo('Off', DispatchColors.muted);
  }
  if (!interfacePresent && link.kind == LinkKind.local) {
    return const _StatusBadgeInfo('Disconnected', DispatchColors.muted);
  }
  if (captiveState == CaptivePortalProbeResult.captive) {
    return const _StatusBadgeInfo('Sign-in needed', DispatchColors.warn);
  }
  switch (supervisorStatus) {
    case LinkStatus.healthy:
      double? bpsIn = m?.bpsIn;
      double? bpsOut = m?.bpsOut;
      bool carrying =
          (bpsIn != null && bpsIn > 0) || (bpsOut != null && bpsOut > 0);
      return _StatusBadgeInfo(
        carrying ? 'Carrying traffic' : 'Healthy',
        DispatchColors.ok,
      );
    case LinkStatus.degraded:
      return const _StatusBadgeInfo('Reserve', DispatchColors.warn);
    case LinkStatus.unhealthy:
      return const _StatusBadgeInfo('No internet', DispatchColors.danger);
    case LinkStatus.disabled:
      return const _StatusBadgeInfo('Off', DispatchColors.muted);
    case LinkStatus.unknown:
    case null:
      if (m == null || m.rttMs == null) {
        return const _StatusBadgeInfo('Checking…', DispatchColors.muted);
      }
      return const _StatusBadgeInfo('Healthy', DispatchColors.ok);
  }
}

/// True iff [link] is anchored to an interface that's currently in the
/// controller's live snapshot. Paired links return true unconditionally
/// (they're virtual). Links without an [Link.interfaceName] anchor also
/// return true — there's nothing to verify against, so we assume yes.
bool _isInterfacePresent(Link link, DispatchController c) {
  if (link.kind == LinkKind.paired) return true;
  String? iface = link.interfaceName?.toLowerCase();
  if (iface == null || iface.isEmpty) {
    String? src = link.sourceAddress;
    if (src == null || src.isEmpty) return true;
    for (NetworkInterfaceSnapshot snap in c.interfaces) {
      for (InternetAddress addr in snap.validAddresses) {
        if (addr.address == src) return true;
      }
    }
    return false;
  }
  for (NetworkInterfaceSnapshot snap in c.interfaces) {
    if (snap.name.toLowerCase() == iface) return true;
  }
  return false;
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
        label = 'Preferred';
        color = DispatchColors.warn;
        break;
      case LinkPriority.secondary:
        label = 'Auto';
        color = DispatchColors.ok;
        break;
      case LinkPriority.backup:
        label = 'Backup';
        color = DispatchColors.accent;
        break;
      case LinkPriority.never:
        label = 'Blocked';
        color = DispatchColors.danger;
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
            label: 'How Dispatch should treat this network',
            help:
                'Preferred = always include. Auto = use when it helps. Backup = only on outage. Blocked = never touch this network.'),
        const SizedBox(height: 6),
        // Four explicit verbs replace the old three-chip "Role" row plus
        // the separate "Turn off this network" button. The user wanted
        // explicit Blacklist (Blocked) and Whitelist (Preferred) actions
        // — exposing them as peer chips makes the intent obvious and
        // keeps every option one tap away.
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (LinkPriority p in <LinkPriority>[
              LinkPriority.primary,
              LinkPriority.secondary,
              LinkPriority.backup,
              LinkPriority.never,
            ])
              _PriorityChip(
                priority: p,
                selected: link.priority == p,
                tint: tint,
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
        // Surface the live usage from the data meter right under the cap
        // control so the user sees both "what's the limit" and "where am
        // I right now" in one place.
        if ((controller.dataUsedBytesByLink[link.id] ?? 0) > 0) ...<Widget>[
          const SizedBox(height: 8),
          _PerLinkUsageRow(
            bytes: controller.dataUsedBytesByLink[link.id]!,
            capBytes: link.dataCapBytes,
          ),
        ],
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
        ],
        // The standalone "Turn off this network" button used to live here.
        // It's gone because the Blocked chip in the priority row above is
        // the same action with clearer terminology, and a peer of the
        // other three priorities. Two ways of doing the same thing was
        // confusing.
      ],
    );
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

/// Priority chip with explicit verb + icon for each [LinkPriority]:
///   * `primary`   → "Preferred" with a star (whitelist semantics)
///   * `secondary` → "Auto"      with a check  (default-ish bucket)
///   * `backup`    → "Backup"    with a shield (only-on-outage)
///   * `never`     → "Blocked"   with a block  (blacklist semantics)
///
/// The Blocked chip pulls its own danger-color border even when not
/// selected so users can scan the row and immediately spot the "off"
/// option without having to read all four labels. When selected, every
/// chip uses its own semantic color, not the link's [tint], because the
/// chip's meaning (block / prefer / auto / backup) is more important
/// than which network it belongs to.
class _PriorityChip extends StatelessWidget {
  final LinkPriority priority;
  final bool selected;
  final Color tint;
  final VoidCallback onTap;

  const _PriorityChip({
    required this.priority,
    required this.selected,
    required this.tint,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    _PriorityChipSpec spec = _specFor(priority, tint);
    Color border = selected
        ? spec.color
        : (priority == LinkPriority.never
            ? DispatchColors.danger.withValues(alpha: 0.45)
            : DispatchColors.border);
    Color fill = selected ? spec.color.withValues(alpha: 0.16) : Colors.transparent;
    Color fg = selected ? spec.color : DispatchColors.ink;
    return Material(
      color: Colors.transparent,
      child: Tooltip(
        message: spec.help,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: border, width: selected ? 1.4 : 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(spec.icon, size: 13, color: fg),
                const SizedBox(width: 5),
                Text(spec.label,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: fg)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static _PriorityChipSpec _specFor(LinkPriority p, Color tint) {
    switch (p) {
      case LinkPriority.primary:
        // "Preferred" = whitelist. Star + warn-color so it pops as
        // intentional even when other chips are selected.
        return _PriorityChipSpec(
          label: 'Preferred',
          icon: Icons.star_rounded,
          color: DispatchColors.warn,
          help: 'Whitelist — always include this network in the bond.',
        );
      case LinkPriority.secondary:
        return _PriorityChipSpec(
          label: 'Auto',
          icon: Icons.auto_awesome_rounded,
          color: tint,
          help: 'Use this network whenever Dispatch thinks it will help.',
        );
      case LinkPriority.backup:
        return _PriorityChipSpec(
          label: 'Backup',
          icon: Icons.shield_outlined,
          color: DispatchColors.accent,
          help: 'Only take over if the other networks fail.',
        );
      case LinkPriority.never:
        // "Blocked" = blacklist. Block icon + danger color, both inside
        // and outside the chip, so the action reads as destructive.
        return _PriorityChipSpec(
          label: 'Blocked',
          icon: Icons.block_rounded,
          color: DispatchColors.danger,
          help: 'Blacklist — never route any traffic through this network.',
        );
    }
  }
}

class _PriorityChipSpec {
  final String label;
  final IconData icon;
  final Color color;
  final String help;
  const _PriorityChipSpec({
    required this.label,
    required this.icon,
    required this.color,
    required this.help,
  });
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
/// 1. The paired-device tag for [LinkKind.paired].
/// 2. The SSID / hardware-port from the OS naming snapshot.
/// 3. A custom user-supplied [Link.label] (only if it isn't an
///    IP literal or raw BSD device name leaked in by the legacy
///    `selected_targets` migration).
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
  if (link.kind == LinkKind.paired) {
    if (_looksLikeRawId(link.label)) {
      return 'Paired device';
    }
    return link.label.isNotEmpty ? link.label : 'Paired device';
  }
  String bsd = _resolveBsdFor(link, ipToBsd);
  NamedInterface? named = names[bsd];
  if (named != null) {
    String display = named.displayName;
    if (display.isNotEmpty) return display;
  }
  // Custom user-applied label takes precedence over the kind heuristic,
  // but only if it isn't a raw IP / BSD identifier left over from the
  // pre-v1 `selected_targets` migration (where `label` got set to the
  // IP literal). Without this filter we'd happily show `192.168.1.45`
  // as the network name forever.
  if (link.label.isNotEmpty && !_looksLikeRawId(link.label)) {
    return link.label;
  }
  return _friendlyKindFor(bsd, names);
}

/// True iff [s] looks like a BSD device (`en0`, `pdp_ip0`, `utun3`) or
/// an IP literal (v4 dotted-quad or v6 colon-separated). Used to filter
/// out labels stored on legacy [Link]s so the UI can re-derive a real
/// human name from the live naming map instead.
bool _looksLikeRawId(String s) {
  if (s.isEmpty) return false;
  if (RegExp(r'^en\d+$').hasMatch(s)) return true;
  if (RegExp(r'^pdp_ip\d+$').hasMatch(s)) return true;
  if (RegExp(r'^(?:utun|ipsec|tun|tap|awdl|bridge|llw|ppp)\d+$')
      .hasMatch(s)) {
    return true;
  }
  // IPv4 dotted-quad.
  if (RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}(?:/\d+)?$').hasMatch(s)) return true;
  // IPv6 — at least two colons + only hex/colon/period/percent chars.
  if (s.contains(':') &&
      RegExp(r'^[0-9a-fA-F:%.]+$').hasMatch(s) &&
      ':'.allMatches(s).length >= 2) {
    return true;
  }
  return false;
}

/// Friendly fallback label for an arbitrary BSD interface name when the
/// naming map either hasn't loaded or didn't classify the device. Used
/// by [_friendlyLinkName] as a last resort so the UI never displays the
/// raw `en0` / `pdp_ip0` slug.
String _friendlyKindFor(String rawName, Map<String, NamedInterface> names) {
  String name = rawName.toLowerCase();
  NamedInterface? named = names[name];
  if (named != null) {
    String display = named.displayName;
    // Skip displayName when it just echoes the BSD device — that's
    // [NamedInterface.displayName]'s last-resort fallback, which is
    // exactly the slug we're trying to hide.
    if (display.isNotEmpty && display.toLowerCase() != name) {
      return display;
    }
    // Use the kind label ("Wi-Fi", "Ethernet", "Cellular", …) instead
    // of leaking the BSD name.
    if (named.kindLabel.isNotEmpty &&
        named.kindLabel.toLowerCase() != name) {
      return named.kindLabel;
    }
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
  if (name.isEmpty) return 'Network';
  // Generic catch-all when everything above fails. Better than leaking
  // the raw slug to the user — they don't know what `en12` means.
  return 'Network';
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

/// Format a cumulative byte count for display ("12.4 GB", "812 MB"…).
///
/// Uses decimal units (KB = 1000 bytes) because that matches what carriers
/// print on monthly bills — the data-cap UI compares against the same scale.
String _friendlyBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1000) return '$bytes B';
  if (bytes < 1e6) return '${(bytes / 1e3).toStringAsFixed(1)} KB';
  if (bytes < 1e9) return '${(bytes / 1e6).toStringAsFixed(1)} MB';
  if (bytes < 1e12) return '${(bytes / 1e9).toStringAsFixed(2)} GB';
  return '${(bytes / 1e12).toStringAsFixed(2)} TB';
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
              'Combine networks across Macs. Tap Host on one, then tap Connect on the other. Both devices need to be on the same Wi-Fi or Ethernet to see each other.',
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
// Watch each network breathe in real time. The top section is a card
// per enabled network with its friendly name (SSID / hardware port),
// status pill, current readings (download / upload / ping / loss) and
// a 60-sample bandwidth chart that shows both directions on the same
// Y axis. The bottom section keeps the proxy event log for debugging.
//
// The flow inspector that used to live here is gone because it only
// worked in Tunnel mode and most users start in SOCKS — so the tab was
// effectively empty for them. Per-network charts and live numbers are
// what the user wanted to see ("Wi-Fi names, connection status, charts
// of bandwidth usage"), so that's now the centerpiece.

class _ActivityPage extends StatelessWidget {
  final DispatchController controller;
  const _ActivityPage({required this.controller});

  @override
  Widget build(BuildContext context) {
    List<Link> tracked = controller.settings.policy.links
        .where((Link l) => l.priority != LinkPriority.never)
        .toList(growable: false);
    Map<String, NamedInterface> names = controller.namingService.byBsd;
    Map<String, String> ipToBsd = _buildIpToBsd(controller.interfaces);

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
      children: <Widget>[
        const _SectionLabel(
          icon: Icons.timeline_rounded,
          title: 'Live activity',
          subtitle:
              'Each network breathing in real time. The chart shows the last minute of traffic — green is download, blue is upload.',
        ),
        if (tracked.isEmpty)
          const _EmptyHint(
            icon: Icons.timeline_rounded,
            text:
                'No networks turned on yet. Once a Wi-Fi, Ethernet, or hotspot comes online (and you leave its switch on in the Networks tab) its live chart shows up here.',
          )
        else
          for (Link link in tracked)
            _LinkActivityCard(
              key: ValueKey<String>('activity_${link.id}'),
              controller: controller,
              link: link,
              names: names,
              ipToBsd: ipToBsd,
            ),
        const SizedBox(height: 8),
        const _SectionLabel(
          icon: Icons.event_note_rounded,
          title: 'Recent events',
          subtitle:
              'Connection-level log from the proxy. Handy when something looks off; safe to ignore otherwise.',
        ),
        _EventsList(controller: controller),
      ],
    );
  }
}

/// One row on the Activity tab: friendly name + status pill, the four
/// live readings, and a dual-line bandwidth chart over the last ~60
/// samples. Reads everything off the controller; rebuilds whenever the
/// controller notifies (which it does on every metric).
class _LinkActivityCard extends StatelessWidget {
  final DispatchController controller;
  final Link link;
  final Map<String, NamedInterface> names;
  final Map<String, String> ipToBsd;

  const _LinkActivityCard({
    super.key,
    required this.controller,
    required this.link,
    required this.names,
    required this.ipToBsd,
  });

  @override
  Widget build(BuildContext context) {
    LinkMetric? metric = controller.linkMetrics[link.id];
    List<LinkMetric> history = controller.metricHistory(link.id);
    LinkStatus? supervisor = controller.lastHealthEvent?.statuses[link.id];
    CaptivePortalProbeResult? captive = controller.captiveStates[link.id];
    bool present = _isInterfacePresent(link, controller);
    String name = _friendlyLinkName(link, names, ipToBsd: ipToBsd);
    IconData icon = _iconForLinkName(link, names, ipToBsd: ipToBsd);
    Color tint = DispatchColors.linkColorFor(link.id);
    _StatusBadgeInfo status = _statusBadgeFor(
      metric,
      link,
      supervisorStatus: supervisor,
      captiveState: captive,
      interfacePresent: present,
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: DispatchColors.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DispatchColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              _NetworkIcon(icon: icon, color: tint, dim: false),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      name,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w700),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 1),
                    Text(
                      _statusLineFor(
                        metric,
                        link,
                        supervisorStatus: supervisor,
                        captiveState: captive,
                        interfacePresent: present,
                      ),
                      style: const TextStyle(
                          fontSize: 11,
                          color: DispatchColors.muted,
                          height: 1.3),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              DispatchBadge(label: status.label, color: status.color),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: _ReadingCell(
                  label: 'Down',
                  value: _friendlyBps(metric?.bpsIn ?? 0),
                  color: DispatchColors.ok,
                  icon: Icons.south_rounded,
                ),
              ),
              Expanded(
                child: _ReadingCell(
                  label: 'Up',
                  value: _friendlyBps(metric?.bpsOut ?? 0),
                  color: DispatchColors.accent,
                  icon: Icons.north_rounded,
                ),
              ),
              Expanded(
                child: _ReadingCell(
                  label: 'Ping',
                  value: metric?.rttMs == null
                      ? '—'
                      : '${metric!.rttMs!.toStringAsFixed(0)} ms',
                  color: _rttColor(metric?.rttMs),
                  icon: Icons.timer_outlined,
                ),
              ),
              Expanded(
                child: _ReadingCell(
                  label: 'Loss',
                  value: _formatLoss(metric?.loss),
                  color: _lossColor(metric?.loss),
                  icon: Icons.broken_image_outlined,
                ),
              ),
            ],
          ),
          // Per-network billing-cycle bytes counter. We render it inline so
          // metered users can spot which interface is eating the cap
          // without leaving the Activity tab.
          if ((controller.dataUsedBytesByLink[link.id] ?? 0) > 0) ...<Widget>[
            const SizedBox(height: 8),
            _PerLinkUsageRow(
              bytes: controller.dataUsedBytesByLink[link.id]!,
              capBytes: link.dataCapBytes,
            ),
          ],
          const SizedBox(height: 10),
          _DualThroughputChart(history: history),
        ],
      ),
    );
  }
}

/// One of the four live readings (Down / Up / Ping / Loss) above the
/// bandwidth chart. Tabular figures so digits don't jitter as values
/// change.
class _ReadingCell extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData icon;

  const _ReadingCell({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 4),
            Text(
              label.toUpperCase(),
              style: const TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w800,
                color: DispatchColors.muted,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w800,
            color: color,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

Color _rttColor(double? rtt) {
  if (rtt == null) return DispatchColors.muted;
  if (rtt < 60) return DispatchColors.ok;
  if (rtt < 150) return DispatchColors.warn;
  return DispatchColors.danger;
}

Color _lossColor(double? loss) {
  if (loss == null) return DispatchColors.muted;
  if (loss < 0.005) return DispatchColors.ok;
  if (loss < 0.02) return DispatchColors.warn;
  return DispatchColors.danger;
}

String _formatLoss(double? loss) {
  if (loss == null) return '—';
  double pct = loss * 100;
  if (pct < 0.1) return '0%';
  if (pct < 1) return '${pct.toStringAsFixed(2)}%';
  return '${pct.toStringAsFixed(1)}%';
}

/// Dual-line bandwidth chart over the last ~60 [LinkMetric] samples.
/// Download (`bpsIn`) draws in [DispatchColors.ok] and upload (`bpsOut`)
/// in [DispatchColors.accent]. Both lines share a single Y axis so the
/// user can compare them at a glance.
///
/// Falls back to an "Idle — no traffic yet" hint when every sample has
/// null/zero throughput (e.g. proxy hasn't started or this network
/// hasn't been used yet).
class _DualThroughputChart extends StatelessWidget {
  final List<LinkMetric> history;
  const _DualThroughputChart({required this.history});

  /// Fixed chart height. Sized so the line has room to breathe but the
  /// card stays compact enough to fit two/three side-by-side links in
  /// a typical menu-bar-style window.
  static const double _height = 72;

  @override
  Widget build(BuildContext context) {
    bool hasTraffic = false;
    for (LinkMetric m in history) {
      if ((m.bpsIn ?? 0) > 0 || (m.bpsOut ?? 0) > 0) {
        hasTraffic = true;
        break;
      }
    }

    return Container(
      height: _height,
      decoration: BoxDecoration(
        color: DispatchColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: DispatchColors.border, width: 0.5),
      ),
      child: Stack(
        children: <Widget>[
          if (hasTraffic)
            Positioned.fill(
              child: CustomPaint(
                painter: _DualThroughputPainter(history: history),
              ),
            )
          else
            const Center(
              child: Text(
                'Idle — no traffic yet',
                style: TextStyle(
                  fontSize: 11,
                  color: DispatchColors.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          Positioned(
            left: 8,
            top: 4,
            child: Row(
              children: const <Widget>[
                _LegendDot(color: DispatchColors.ok),
                SizedBox(width: 4),
                Text(
                  'Down',
                  style: TextStyle(
                    fontSize: 10,
                    color: DispatchColors.muted,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(width: 10),
                _LegendDot(color: DispatchColors.accent),
                SizedBox(width: 4),
                Text(
                  'Up',
                  style: TextStyle(
                    fontSize: 10,
                    color: DispatchColors.muted,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  const _LegendDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// Per-link "Used: 12.4 GB" row that sits between the live readings and
/// the bandwidth chart. When the link has a [Link.dataCapBytes] cap it
/// also draws a thin progress fill so the user sees how close they are
/// to the ceiling at a glance.
class _PerLinkUsageRow extends StatelessWidget {
  final int bytes;
  final int? capBytes;
  const _PerLinkUsageRow({required this.bytes, this.capBytes});

  @override
  Widget build(BuildContext context) {
    String trailing = capBytes == null
        ? _friendlyBytes(bytes)
        : '${_friendlyBytes(bytes)} of ${_friendlyBytes(capBytes!)}';
    double? progress;
    Color barColor = DispatchColors.muted;
    if (capBytes != null && capBytes! > 0) {
      double pct = bytes / capBytes!;
      progress = pct.clamp(0.0, 1.0);
      // Same thresholds the policy engine uses for `dataCapExhausted`
      // warnings: 80% caution, 95% emergency.
      if (pct >= 0.95) {
        barColor = DispatchColors.danger;
      } else if (pct >= 0.80) {
        barColor = DispatchColors.warn;
      } else {
        barColor = DispatchColors.ok;
      }
    }
    return Row(
      children: <Widget>[
        const Icon(
          Icons.data_usage_rounded,
          size: 13,
          color: DispatchColors.muted,
        ),
        const SizedBox(width: 5),
        const Text(
          'Used',
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: DispatchColors.muted,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(width: 8),
        if (progress != null)
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                height: 4,
                child: LinearProgressIndicator(
                  value: progress,
                  backgroundColor: DispatchColors.border,
                  valueColor: AlwaysStoppedAnimation<Color>(barColor),
                ),
              ),
            ),
          )
        else
          const Spacer(),
        const SizedBox(width: 8),
        Text(
          trailing,
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _DualThroughputPainter extends CustomPainter {
  final List<LinkMetric> history;
  _DualThroughputPainter({required this.history});

  @override
  void paint(Canvas canvas, Size size) {
    if (history.isEmpty || size.width <= 0 || size.height <= 0) {
      return;
    }

    // Share the Y axis between both lines so a 12 Mbps download and a
    // 0.5 Mbps upload render at visibly different heights instead of
    // both filling the canvas.
    double maxV = 0;
    for (LinkMetric m in history) {
      if (m.bpsIn != null && m.bpsIn! > maxV) maxV = m.bpsIn!;
      if (m.bpsOut != null && m.bpsOut! > maxV) maxV = m.bpsOut!;
    }
    if (maxV <= 0) return;
    // 15% headroom so the line doesn't kiss the top edge.
    maxV *= 1.15;

    // Leave ~16 px at the top for the legend overlay so the line doesn't
    // overlap the labels.
    double top = 16;
    double h = size.height - top - 2;
    if (h <= 0) return;

    _drawLine(
      canvas,
      size,
      history,
      (LinkMetric m) => m.bpsIn,
      DispatchColors.ok,
      maxV,
      top,
      h,
    );
    _drawLine(
      canvas,
      size,
      history,
      (LinkMetric m) => m.bpsOut,
      DispatchColors.accent,
      maxV,
      top,
      h,
    );
  }

  void _drawLine(
    Canvas canvas,
    Size size,
    List<LinkMetric> samples,
    double? Function(LinkMetric) read,
    Color color,
    double maxV,
    double top,
    double h,
  ) {
    Paint stroke = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    Paint fill = Paint()
      ..color = color.withValues(alpha: 0.10)
      ..style = PaintingStyle.fill;

    Path linePath = Path();
    Path fillPath = Path();
    bool penDown = false;
    double? lastX;
    int n = samples.length;
    for (int i = 0; i < n; i++) {
      double? v = read(samples[i]);
      double x = n == 1 ? size.width / 2 : (i / (n - 1)) * size.width;
      if (v == null) {
        penDown = false;
        continue;
      }
      double normalized = (v / maxV).clamp(0.0, 1.0);
      double y = top + h - normalized * h;
      if (!penDown) {
        linePath.moveTo(x, y);
        fillPath.moveTo(x, top + h);
        fillPath.lineTo(x, y);
        penDown = true;
      } else {
        linePath.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
      lastX = x;
    }
    if (lastX != null) {
      fillPath.lineTo(lastX, top + h);
      fillPath.close();
    }
    canvas.drawPath(fillPath, fill);
    canvas.drawPath(linePath, stroke);
  }

  @override
  bool shouldRepaint(covariant _DualThroughputPainter old) {
    return old.history != history;
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
    _EventTrafficLight light = _classify(event);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _TrafficLightDot(color: light.color, pulsing: light.pulsing),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(light.headline,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: light.color,
                    )),
                if (light.detail.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(light.detail,
                        style: const TextStyle(
                            fontSize: 11.5, color: DispatchColors.muted)),
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

  /// Map an event to one of four traffic-light states. The mapping is
  /// deliberately blunt — users want to scan the column at a glance and
  /// know "things are happening / something's wrong / all good / quiet."
  ///
  /// Colors:
  ///   * **Grey** — informational / idle / closed (no action needed)
  ///   * **Yellow** — in-flight transition: starting, awaiting, retrying
  ///   * **Green** — successful state achieved: connected, started, opened
  ///   * **Red** — failure that needs attention
  ///
  /// Yellow events get a soft pulse to telegraph "still working on it."
  static _EventTrafficLight _classify(ProxyEvent e) {
    String msg = e.message.trim();
    String low = msg.toLowerCase();
    switch (e.type) {
      case ProxyEventType.error:
        return _EventTrafficLight(
          color: DispatchColors.danger,
          headline: _headlineForError(low, msg),
          detail: msg,
          pulsing: false,
        );
      case ProxyEventType.warning:
        return _EventTrafficLight(
          color: DispatchColors.warn,
          headline: _headlineForWarn(low, msg),
          detail: msg,
          pulsing: false,
        );
      case ProxyEventType.connectionOpened:
        return _EventTrafficLight(
          color: DispatchColors.ok,
          headline: 'Connection opened',
          detail: msg,
          pulsing: false,
        );
      case ProxyEventType.connectionClosed:
        return _EventTrafficLight(
          color: DispatchColors.muted,
          headline: 'Connection closed',
          detail: msg,
          pulsing: false,
        );
      case ProxyEventType.info:
        if (_looksLikeStarting(low)) {
          return _EventTrafficLight(
            color: DispatchColors.warn,
            headline: _headlineForStarting(low, msg),
            detail: msg,
            pulsing: true,
          );
        }
        if (_looksLikeStopped(low)) {
          return _EventTrafficLight(
            color: DispatchColors.muted,
            headline: 'Stopped',
            detail: msg,
            pulsing: false,
          );
        }
        if (_looksLikeRunning(low)) {
          return _EventTrafficLight(
            color: DispatchColors.ok,
            headline: 'Running',
            detail: msg,
            pulsing: false,
          );
        }
        return _EventTrafficLight(
          color: DispatchColors.muted,
          headline: msg.isEmpty ? 'Info' : _firstSentence(msg),
          detail: msg,
          pulsing: false,
        );
    }
  }

  static bool _looksLikeStarting(String low) {
    return low.contains('starting') ||
        low.contains('awaiting') ||
        low.contains('requested') ||
        low.contains('connecting') ||
        low.contains('installing') ||
        low.contains('loading') ||
        low.contains('pending');
  }

  static bool _looksLikeRunning(String low) {
    return low.contains('connected') ||
        low.contains('started') ||
        low.contains('running') ||
        low.contains('established') ||
        low.contains('ready');
  }

  static bool _looksLikeStopped(String low) {
    return low.contains('stopped') ||
        low.contains('closed') ||
        low.contains('disconnected');
  }

  static String _headlineForStarting(String low, String msg) {
    if (low.contains('tunnel')) return 'Starting tunnel…';
    if (low.contains('proxy') || low.contains('socks')) return 'Starting proxy…';
    if (low.contains('pair')) return 'Pairing…';
    if (low.contains('connecting')) return 'Connecting…';
    return _firstSentence(msg);
  }

  static String _headlineForWarn(String low, String msg) {
    if (low.contains('captive') || low.contains('sign-in') ||
        low.contains('sign in') || low.contains('login')) {
      return 'Sign-in required';
    }
    if (low.contains('approval') || low.contains('allow') ||
        low.contains('permission')) {
      return 'Action needed';
    }
    if (low.contains('timeout') || low.contains('timed out')) {
      return 'Timed out';
    }
    return _firstSentence(msg);
  }

  static String _headlineForError(String low, String msg) {
    if (low.contains('failed to start') || low.contains('start failed')) {
      return 'Failed to start';
    }
    if (low.contains('failed to') || low.contains('failed:')) {
      return 'Operation failed';
    }
    return _firstSentence(msg);
  }

  /// First sentence of [msg], or up to 60 chars when there's no obvious
  /// break, so the headline stays compact regardless of message length.
  static String _firstSentence(String msg) {
    if (msg.isEmpty) return 'Event';
    int dot = msg.indexOf(RegExp(r'[.!?\n]'));
    String first = dot > 0 ? msg.substring(0, dot) : msg;
    if (first.length > 60) {
      return '${first.substring(0, 60)}\u2026';
    }
    return first;
  }
}

/// One classified row used by [_EventRow.build]. Keeps the build method
/// declarative and lets us test the mapping in isolation if we ever want
/// to.
class _EventTrafficLight {
  final Color color;
  final String headline;
  final String detail;
  final bool pulsing;
  const _EventTrafficLight({
    required this.color,
    required this.headline,
    required this.detail,
    required this.pulsing,
  });
}

/// Solid 10-px traffic-light dot with an optional soft pulse for
/// in-flight states. Cheaper than a Lottie or AnimatedBuilder spinner
/// and reads as "still working on it" just from the gentle alpha
/// oscillation.
class _TrafficLightDot extends StatefulWidget {
  final Color color;
  final bool pulsing;
  const _TrafficLightDot({required this.color, required this.pulsing});

  @override
  State<_TrafficLightDot> createState() => _TrafficLightDotState();
}

class _TrafficLightDotState extends State<_TrafficLightDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.pulsing) {
      return Container(
        width: 11,
        height: 11,
        margin: const EdgeInsets.only(top: 3),
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: widget.color.withValues(alpha: 0.35),
              blurRadius: 6,
              spreadRadius: 0,
            ),
          ],
        ),
      );
    }
    return AnimatedBuilder(
      animation: _pulse,
      builder: (BuildContext _, Widget? _) {
        double t = (_pulse.value * 0.5) + 0.5;
        return Container(
          width: 11,
          height: 11,
          margin: const EdgeInsets.only(top: 3),
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: t),
            shape: BoxShape.circle,
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: widget.color.withValues(alpha: 0.45 * t),
                blurRadius: 8,
                spreadRadius: 1,
              ),
            ],
          ),
        );
      },
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
    Policy policy = settings.policy;
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
              // Behaviour toggles that previously lived on the Mode tab.
              // They're advanced enough that most users won't touch them
              // (sensible defaults already match the user's intent:
              // combine for speed, prefer low-latency for realtime, auto
              // sign-in handling on, kill switch off), but the gear icon
              // is exactly where power users expect to find them.
              _SettingsLabel('Safety & quality',
                  'Defaults work for most people; tweak only if you know you need to.'),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Help me sign in to coffee-shop Wi-Fi'),
                subtitle: const Text(
                    'When a network bounces you to a login page, Dispatch pauses it until you sign in.',
                    style: TextStyle(fontSize: 11)),
                value: policy.captivePortalAssist,
                onChanged: (bool v) => controller.setCaptivePortalAssist(v),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Prioritize video and voice'),
                subtitle: const Text(
                    'Dispatch sends calls and screen-shares down the lowest-latency network automatically.',
                    style: TextStyle(fontSize: 11)),
                value: policy.streamingDetection,
                onChanged: (bool v) => controller.setStreamingDetection(v),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Block internet when Dispatch is off'),
                subtitle: const Text(
                    'Strict mode: when Dispatch isn\'t running, your apps lose internet too. Useful on untrusted networks.',
                    style: TextStyle(fontSize: 11)),
                value: policy.killSwitch,
                onChanged: (bool v) => controller.setKillSwitch(v),
              ),
              const SizedBox(height: 12),
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
              _SettingsLabel('How traffic leaves your Mac',
                  'System-wide is the default — every app on your Mac flows through the bond, no per-app setup. The proxy mode is an opt-in fallback for cases where the system extension can\'t be installed (e.g. a build without a Developer ID team).'),
              SegmentedButton<TransportKind>(
                segments: const <ButtonSegment<TransportKind>>[
                  ButtonSegment<TransportKind>(
                      value: TransportKind.tunnel,
                      label: Text('System-wide')),
                  ButtonSegment<TransportKind>(
                      value: TransportKind.socks,
                      label: Text('Proxy (SOCKS)')),
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
