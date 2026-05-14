import 'dart:io';
import 'package:flutter/material.dart';

import '../core/dispatch_settings.dart';
import '../core/link.dart';
import '../core/link_metric.dart';
import '../core/network_interface_repository.dart';
import '../core/policy.dart';
import '../platform/network_naming_service.dart';
import '../policy/link_supervisor.dart';
import '../probes/captive_portal_probe.dart';
import '../transport/transport.dart';
import '../ui/dispatch_ui.dart';
import 'dispatch_controller.dart';

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
                Expanded(child: _NetworksPage(controller: controller)),
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
    TransportStatus transportStatus = controller.transport.status;
    bool running = transportStatus.isRunning;
    bool busy = transportStatus.isBusy;
    double bpsIn = 0;
    double bpsOut = 0;
    int activeLinks = 0;
    for (Link link in controller.settings.policy.links) {
      LinkMetric? m = controller.linkMetrics[link.id];
      if (m == null) continue;
      double inBps = m.bpsIn ?? 0;
      double outBps = m.bpsOut ?? 0;
      if (inBps > 0 || outBps > 0) {
        activeLinks++;
      }
      if (m.bpsIn != null) {
        bpsIn += m.bpsIn!;
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
    String actionLabel = running ? 'Stop' : 'Start';
    if (transportStatus.state == TransportState.starting) {
      actionLabel = 'Starting';
    } else if (transportStatus.state == TransportState.stopping) {
      actionLabel = 'Stopping';
    }
    String badgeLabel = running ? 'Running' : 'Stopped';
    Color badgeColor = running ? DispatchColors.ok : DispatchColors.muted;
    if (transportStatus.state == TransportState.starting) {
      badgeLabel = 'Starting';
      badgeColor = DispatchColors.warn;
    } else if (transportStatus.state == TransportState.stopping) {
      badgeLabel = 'Stopping';
      badgeColor = DispatchColors.warn;
    } else if (transportStatus.state == TransportState.failed) {
      badgeLabel = 'Failed';
      badgeColor = DispatchColors.danger;
    }
    Color accent = running ? DispatchColors.ok : DispatchColors.muted;
    if (transportStatus.state == TransportState.starting ||
        transportStatus.state == TransportState.stopping) {
      accent = DispatchColors.warn;
    } else if (transportStatus.state == TransportState.failed) {
      accent = DispatchColors.danger;
    }
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
                busy: busy,
                onPressed: busy
                    ? null
                    : (running ? controller.stopProxy : controller.startProxy),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      _powerTitle(activeLinks, transportStatus),
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
                    : (busy ? null : controller.startProxy),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 4,
                  ),
                  child: Text(
                    actionLabel,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: DispatchColors.muted,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              DispatchBadge(label: badgeLabel, color: badgeColor),
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
              Container(width: 1, height: 28, color: DispatchColors.border),
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
    TransportStatus transportStatus = controller.transport.status;
    if (transportStatus.state == TransportState.starting) {
      return 'Starting the system tunnel…';
    }
    if (transportStatus.state == TransportState.stopping) {
      return 'Stopping the system tunnel…';
    }
    if (transportStatus.state == TransportState.failed) {
      return 'Start failed. The reason is shown below.';
    }
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
      return 'On — waiting for a network with working internet';
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

  String _powerTitle(int active, TransportStatus status) {
    if (status.state == TransportState.starting) return 'Starting';
    if (status.state == TransportState.stopping) return 'Stopping';
    if (status.state == TransportState.failed) return 'Needs attention';
    if (!status.isRunning) return 'Off';
    if (active == 0) return 'Waiting';
    return 'On';
  }
}

/// The fat round power button on the left of [_PowerCard].
class _PowerButton extends StatelessWidget {
  final bool running;
  final bool busy;
  final VoidCallback? onPressed;

  const _PowerButton({
    required this.running,
    required this.busy,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    Color fill = running || busy ? DispatchColors.ok : DispatchColors.panel;
    Color border = running || busy ? DispatchColors.ok : DispatchColors.border;
    Color icon = running || busy ? Colors.white : DispatchColors.muted;
    bool enabled = onPressed != null;
    String semanticLabel = running ? 'Disconnect' : 'Connect';
    if (busy) {
      semanticLabel = 'Connecting';
    }
    return Semantics(
      label: semanticLabel,
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
            child: Icon(
              Icons.power_settings_new_rounded,
              size: 30,
              color: icon,
            ),
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
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  color: DispatchColors.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                _friendlyBps(bps),
                style: TextStyle(
                  fontSize: 15,
                  color: color,
                  fontWeight: FontWeight.w800,
                ),
              ),
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
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
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
        border: Border.all(
          color: DispatchColors.danger.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.error_outline,
            color: DispatchColors.danger,
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: DispatchColors.danger,
                fontSize: 12,
              ),
            ),
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
      bool anyHealthy = ev.statuses.values.any(
        (LinkStatus s) => s == LinkStatus.healthy,
      );
      bool anyEnabled = ev.statuses.values.any(
        (LinkStatus s) => s != LinkStatus.disabled,
      );
      if (anyEnabled && !anyHealthy) {
        banners.add(
          _SoftBanner(
            color: DispatchColors.warn,
            icon: Icons.warning_amber_rounded,
            title: 'No network is healthy',
            body:
                'Latency, loss, or jitter is too high on every selected network. '
                'Traffic may be slow or paused.',
          ),
        );
      }
    }

    Set<String> captiveIds = controller.captiveStates.entries
        .where(
          (MapEntry<String, CaptivePortalProbeResult> e) =>
              e.value == CaptivePortalProbeResult.captive,
        )
        .map((MapEntry<String, CaptivePortalProbeResult> e) => e.key)
        .toSet();
    if (captiveIds.isNotEmpty) {
      banners.add(
        _SoftBanner(
          color: DispatchColors.warn,
          icon: Icons.wifi_off_rounded,
          title: 'Captive portal detected',
          body:
              'Sign in to ${captiveIds.length == 1 ? "your network" : "${captiveIds.length} networks"} '
              'in a browser. Dispatch will resume routing automatically once they reach the Internet.',
        ),
      );
    }

    if (controller.settings.policy.killSwitch && !controller.isRunning) {
      banners.add(
        _SoftBanner(
          color: DispatchColors.danger,
          icon: Icons.lock_outline,
          title: 'Kill switch is on',
          body:
              'Apps using Dispatch can\'t reach the Internet while disconnected. '
              'Hit the big power button to reconnect, or turn it off in the gear-icon settings.',
        ),
      );
    }

    _TetherIssue? tetherIssue = _findTetherIssue(controller);
    if (tetherIssue != null) {
      banners.add(
        _SoftBanner(
          color: DispatchColors.warn,
          icon: tetherIssue.icon,
          title: tetherIssue.title,
          body: tetherIssue.body,
        ),
      );
    }

    if (banners.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (Widget b in banners)
            Padding(padding: const EdgeInsets.only(bottom: 6), child: b),
        ],
      ),
    );
  }

  static _TetherIssue? _findTetherIssue(DispatchController controller) {
    Map<String, Link> linksByBsd = <String, Link>{};
    for (Link link in controller.settings.policy.links) {
      String? bsd = link.interfaceName?.toLowerCase();
      if (bsd != null && bsd.isNotEmpty) {
        linksByBsd[bsd] = link;
      }
    }

    for (KnownNetworkService service in controller.namingService.services) {
      if (!_isTetherKind(service.kind)) {
        continue;
      }
      if (!service.isCurrentlyAvailable || service.disabled) {
        continue;
      }
      String? bsd = service.bsdName?.toLowerCase();
      Link? link = bsd == null ? null : linksByBsd[bsd];
      if (link == null) {
        return _TetherIssue.forService(service, hasLink: false);
      }
      CaptivePortalProbeResult? captive = controller.captiveStates[link.id];
      LinkStatus? status = controller.lastHealthEvent?.statuses[link.id];
      bool badProbe =
          captive == CaptivePortalProbeResult.error ||
          captive == CaptivePortalProbeResult.captive;
      bool badHealth = status == LinkStatus.unhealthy;
      if (badProbe || badHealth) {
        return _TetherIssue.forService(service, hasLink: true);
      }
    }
    return null;
  }

  static bool _isTetherKind(NamedInterfaceKind kind) {
    return kind == NamedInterfaceKind.cellularTether ||
        kind == NamedInterfaceKind.bluetoothTether;
  }
}

class _TetherIssue {
  final IconData icon;
  final String title;
  final String body;

  const _TetherIssue({
    required this.icon,
    required this.title,
    required this.body,
  });

  factory _TetherIssue.forService(
    KnownNetworkService service, {
    required bool hasLink,
  }) {
    bool cellular = service.kind == NamedInterfaceKind.cellularTether;
    return _TetherIssue(
      icon: cellular ? Icons.smartphone_rounded : Icons.bluetooth_rounded,
      title: cellular
          ? 'iPhone tether is plugged in, but not online'
          : 'Bluetooth tether is connected, but not online',
      body: cellular
          ? _cellularBody(service, hasLink)
          : _bluetoothBody(service, hasLink),
    );
  }

  static String _cellularBody(KnownNetworkService service, bool hasLink) {
    String prefix = hasLink
        ? '${service.displayName} exists, but the internet probe failed.'
        : '${service.displayName} is visible to macOS, but it has no usable IP address yet.';
    return '$prefix On the iPhone: unlock it, tap Trust if asked, then open Settings > Personal Hotspot and turn Allow Others to Join on.';
  }

  static String _bluetoothBody(KnownNetworkService service, bool hasLink) {
    String prefix = hasLink
        ? '${service.displayName} exists, but the internet probe failed.'
        : '${service.displayName} is visible to macOS, but it has no usable IP address yet.';
    return '$prefix Turn on internet sharing or Personal Hotspot on the phone.';
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
                Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: const TextStyle(
                    color: DispatchColors.muted,
                    fontSize: 12,
                    height: 1.35,
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
//     isn't currently up. Plug in the device and Dispatch picks
//     it up automatically.
//
//   * Off — services the user has turned off (priority = never). Kept
//     visible so it's easy to flip them back on.
//
// No "Add" button. No IP addresses. No BSD device names in the primary
// view. The DispatchController's `_autoAdoptInterfaces` keeps the
// adopted-link list in lockstep with what the OS reports.

class _NetworkSummarySpec {
  final String name;
  final IconData icon;
  final _NetworkSummaryHealth health;
  final double bps;

  const _NetworkSummarySpec({
    required this.name,
    required this.icon,
    required this.health,
    required this.bps,
  });
}

enum _NetworkSummaryHealth { active, ready, problem, blocked, offline, pending }

class _BondGraphic extends StatelessWidget {
  final DispatchController controller;

  const _BondGraphic({required this.controller});

  @override
  Widget build(BuildContext context) {
    List<_NetworkSummarySpec> summaries = _buildSummaries(controller);
    double totalBps = _totalBps(controller);
    int active = 0;
    int problem = 0;
    int blocked = 0;
    for (_NetworkSummarySpec summary in summaries) {
      if (summary.health == _NetworkSummaryHealth.active) active++;
      if (summary.health == _NetworkSummaryHealth.problem) problem++;
      if (summary.health == _NetworkSummaryHealth.blocked) blocked++;
    }
    String endpoint =
        controller.settings.policy.serverUrl ??
        DispatchSettings.defaultRelayUrl;
    String relayHelp = _relayHelpText(controller, active);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
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
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: DispatchColors.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.cloud_sync_rounded,
                  color: DispatchColors.accent,
                  size: 19,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        const Text(
                          'SLC relay',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(width: 8),
                        DispatchBadge(
                          label: _relayBadgeLabel(controller, active),
                          color: _relayBadgeColor(controller, active),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      endpoint,
                      style: const TextStyle(
                        fontSize: 12,
                        color: DispatchColors.muted,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      relayHelp,
                      style: const TextStyle(
                        fontSize: 11,
                        color: DispatchColors.muted,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              _MiniStat(
                label: 'Live',
                value: controller.isRunning ? _friendlyBps(totalBps) : 'Off',
                color: controller.isRunning
                    ? DispatchColors.ok
                    : DispatchColors.muted,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: _MiniStat(
                  label: 'Active',
                  value: '$active',
                  color: active > 0 ? DispatchColors.ok : DispatchColors.muted,
                ),
              ),
              Expanded(
                child: _MiniStat(
                  label: 'Issues',
                  value: '$problem',
                  color: problem > 0
                      ? DispatchColors.danger
                      : DispatchColors.muted,
                ),
              ),
              Expanded(
                child: _MiniStat(
                  label: 'Blocked',
                  value: '$blocked',
                  color: blocked > 0
                      ? DispatchColors.warn
                      : DispatchColors.muted,
                ),
              ),
            ],
          ),
          if (summaries.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (_NetworkSummarySpec summary in summaries.take(4))
                  _NetworkSummaryChip(summary: summary),
                if (summaries.length > 4)
                  _MoreNetworksChip(count: summaries.length - 4),
              ],
            ),
          ] else ...<Widget>[
            const SizedBox(height: 10),
            const Text(
              'Waiting for Wi-Fi, Ethernet, or tethered internet.',
              style: TextStyle(
                fontSize: 12,
                color: DispatchColors.muted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  static List<_NetworkSummarySpec> _buildSummaries(DispatchController c) {
    Map<String, NamedInterface> names = c.namingService.byBsd;
    Map<String, String> ipToBsd = _buildIpToBsd(c.interfaces);
    List<_NetworkSummarySpec> out = <_NetworkSummarySpec>[];
    for (Link link in c.settings.policy.links) {
      LinkMetric? metric = c.linkMetrics[link.id];
      LinkStatus? status = c.lastHealthEvent?.statuses[link.id];
      CaptivePortalProbeResult? captive = c.captiveStates[link.id];
      bool present = _isInterfacePresent(link, c);
      double bps = (metric?.bpsIn ?? 0) + (metric?.bpsOut ?? 0);
      out.add(
        _NetworkSummarySpec(
          name: _friendlyLinkName(link, names, ipToBsd: ipToBsd),
          icon: _iconForLinkName(link, names, ipToBsd: ipToBsd),
          health: _healthFor(
            link: link,
            status: status,
            captive: captive,
            present: present,
            carrying: bps > 0,
          ),
          bps: bps,
        ),
      );
    }
    return out;
  }

  static _NetworkSummaryHealth _healthFor({
    required Link link,
    required LinkStatus? status,
    required CaptivePortalProbeResult? captive,
    required bool present,
    required bool carrying,
  }) {
    if (link.priority == LinkPriority.never) {
      return _NetworkSummaryHealth.blocked;
    }
    if (!present) return _NetworkSummaryHealth.offline;
    if (captive == CaptivePortalProbeResult.captive ||
        captive == CaptivePortalProbeResult.error ||
        status == LinkStatus.unhealthy) {
      return _NetworkSummaryHealth.problem;
    }
    if (carrying) return _NetworkSummaryHealth.active;
    if (status == LinkStatus.healthy || status == LinkStatus.degraded) {
      return _NetworkSummaryHealth.ready;
    }
    return _NetworkSummaryHealth.pending;
  }

  static double _totalBps(DispatchController c) {
    double total = 0;
    for (Link link in c.settings.policy.links) {
      LinkMetric? metric = c.linkMetrics[link.id];
      double inbound = metric?.bpsIn ?? 0;
      double outbound = metric?.bpsOut ?? 0;
      if (inbound.isFinite && inbound > 0) total += inbound;
      if (outbound.isFinite && outbound > 0) total += outbound;
    }
    return total;
  }

  static String _relayBadgeLabel(DispatchController c, int active) {
    if (!c.isRunning) return 'Ready';
    if (active == 0) return 'Waiting';
    return 'Routing';
  }

  static String _relayHelpText(DispatchController c, int active) {
    if (c.transportKind != TransportKind.tunnel) {
      return 'Per-app proxy mode is active.';
    }
    if (c.isRunning && active == 0) {
      return 'Reachable relay is not enough. Server egress must show tun:true.';
    }
    return 'System internet requires relay TUN/NAT on the server.';
  }

  static Color _relayBadgeColor(DispatchController c, int active) {
    if (!c.isRunning) return DispatchColors.muted;
    if (active == 0) return DispatchColors.warn;
    return DispatchColors.ok;
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _MiniStat({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            color: DispatchColors.muted,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            color: color,
            fontWeight: FontWeight.w800,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _NetworkSummaryChip extends StatelessWidget {
  final _NetworkSummarySpec summary;

  const _NetworkSummaryChip({required this.summary});

  @override
  Widget build(BuildContext context) {
    Color color = _healthColor(summary.health);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(summary.icon, size: 14, color: color),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              summary.name,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            _chipValue(summary),
            style: TextStyle(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  static String _chipValue(_NetworkSummarySpec summary) {
    if (summary.health == _NetworkSummaryHealth.active) {
      return _friendlyBps(summary.bps);
    }
    if (summary.health == _NetworkSummaryHealth.ready) return 'Ready';
    if (summary.health == _NetworkSummaryHealth.problem) return 'Issue';
    if (summary.health == _NetworkSummaryHealth.blocked) return 'Blocked';
    if (summary.health == _NetworkSummaryHealth.offline) return 'Offline';
    return 'Checking';
  }

  static Color _healthColor(_NetworkSummaryHealth health) {
    if (health == _NetworkSummaryHealth.active) return DispatchColors.ok;
    if (health == _NetworkSummaryHealth.ready) return DispatchColors.ok;
    if (health == _NetworkSummaryHealth.problem) return DispatchColors.danger;
    if (health == _NetworkSummaryHealth.blocked) return DispatchColors.warn;
    return DispatchColors.muted;
  }
}

class _MoreNetworksChip extends StatelessWidget {
  final int count;

  const _MoreNetworksChip({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        color: DispatchColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: DispatchColors.border),
      ),
      child: Text(
        '+$count more',
        style: const TextStyle(
          fontSize: 12,
          color: DispatchColors.muted,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
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
    List<KnownNetworkService> allServices = c.namingService.services.where((
      KnownNetworkService s,
    ) {
      return s.isUserFacing;
    }).toList();

    // Map services to links: prefer matching by BSD device name (the
    // most stable identifier across reboots).
    Map<String, Link> linkByBsd = <String, Link>{};
    for (Link link in links) {
      String? iface = link.interfaceName?.toLowerCase();
      if (iface == null || iface.isEmpty) continue;
      linkByBsd[iface] = link;
    }

    // The pool model: only currently-reachable adapters show up here.
    // - Connected service           -> "In use now" (or "Off" if blocked).
    // - Saved-but-disconnected      -> hidden (no more "Available" bucket).
    // - Out-of-range saved Wi-Fi    -> hidden.
    List<_ServiceRow> inUse = <_ServiceRow>[];
    List<_ServiceRow> off = <_ServiceRow>[];

    for (KnownNetworkService svc in allServices) {
      // Hide disconnected adapters entirely. If the OS isn't routing
      // packets through it right this second, it's not in the pool.
      if (!svc.isCurrentlyAvailable) continue;
      String? bsd = svc.bsdName?.toLowerCase();
      Link? matched = bsd == null ? null : linkByBsd[bsd];
      _ServiceRow row = _ServiceRow(service: svc, link: matched);
      if (matched != null && matched.priority == LinkPriority.never) {
        off.add(row);
      } else {
        inUse.add(row);
      }
    }

    bool servicesLoaded = c.namingService.services.isNotEmpty;
    bool everythingEmpty = inUse.isEmpty && off.isEmpty;

    if (c.loadingInterfaces && everythingEmpty && !servicesLoaded) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(48),
          child: CircularProgressIndicator(),
        ),
      );
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
          title: 'Network pool',
          subtitle: everythingEmpty
              ? 'Looking for networks… plug in Ethernet, join a Wi-Fi, or attach an iPhone tether.'
              : (inUse.length <= 1
                    ? 'Dispatch pulls from every network with internet access. Bad networks get flagged red and are skipped automatically.'
                    : 'Dispatch is pooling ${inUse.length} networks. Bad ones get flagged red and skipped. Tap any card to set priority or block it.'),
        ),
        if (everythingEmpty)
          const _EmptyHint(
            icon: Icons.lan_outlined,
            text:
                'Once a network has internet access (Wi-Fi, Ethernet, iPhone USB, cellular hotspot, Bluetooth PAN…) it joins the pool automatically. There\'s no Add button on purpose.',
          )
        else ...<Widget>[
          if (inUse.isNotEmpty)
            _NetworkGroupLabel(
              icon: Icons.bolt_rounded,
              title: 'In the pool',
              count: inUse.length,
              color: DispatchColors.ok,
            ),
          for (_ServiceRow row in inUse) _renderRow(c, row),
          if (off.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            _NetworkGroupLabel(
              icon: Icons.do_not_disturb_alt_rounded,
              title: 'Blocked',
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
/// Bluetooth PAN with no active tether device). Communicates "Dispatch
/// knows about this and will combine it the moment it connects."
class _DisconnectedServiceCard extends StatelessWidget {
  final KnownNetworkService service;
  const _DisconnectedServiceCard({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    String name = service.displayName;
    IconData icon = _iconForKind(service.kind);
    String hint = _hintForKind(service.kind);
    String badge = _badgeFor(service);
    Color badgeColor = _badgeColorFor(service);

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
                    DispatchBadge(label: badge, color: badgeColor),
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
        return 'Connect to Wi-Fi and Dispatch will start combining it.';
      case NamedInterfaceKind.cellularTether:
        return 'If the phone is plugged in, unlock it, tap Trust if prompted, then turn on Personal Hotspot.';
      case NamedInterfaceKind.bluetoothTether:
        return 'Enable internet sharing or Personal Hotspot on the phone; Bluetooth alone is not enough.';
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

  static String _badgeFor(KnownNetworkService service) {
    if (service.disabled) return 'Off in macOS';
    if (service.isCurrentlyAvailable &&
        service.kind == NamedInterfaceKind.cellularTether) {
      return 'No tether internet';
    }
    if (service.isCurrentlyAvailable &&
        service.kind == NamedInterfaceKind.bluetoothTether) {
      return 'No tether internet';
    }
    if (service.isCurrentlyAvailable) return 'No usable IP';
    return 'Disconnected';
  }

  static Color _badgeColorFor(KnownNetworkService service) {
    if (service.disabled) return DispatchColors.muted;
    if (service.isCurrentlyAvailable) return DispatchColors.warn;
    return DispatchColors.muted;
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
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: DispatchColors.muted,
                    height: 1.3,
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
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 13,
                color: DispatchColors.ink,
                height: 1.4,
              ),
            ),
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
    LinkStatus? supervisorStatus = c.lastHealthEvent?.statuses[link.id];
    CaptivePortalProbeResult? captiveState = c.captiveStates[link.id];
    bool interfacePresent = _isInterfacePresent(link, c);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: DispatchColors.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _expanded
              ? tint.withValues(alpha: 0.6)
              : DispatchColors.border,
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
                            kind: svc?.kind,
                          ),
                          style: const TextStyle(
                            fontSize: 12,
                            color: DispatchColors.muted,
                            height: 1.3,
                          ),
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
                      LinkPriority next = on
                          ? LinkPriority.primary
                          : LinkPriority.never;
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
              child: _NetworkCardBody(controller: c, link: link, tint: tint),
            ),
        ],
      ),
    );
  }
}

/// Plain-English subtitle describing what this link is doing right
/// now. We deliberately avoid raw RTT / loss numbers in the primary
/// network card. The at-a-glance card should answer "is this network helping
/// me right now?" in one line.
///
/// State precedence (first match wins):
///   1. Link is turned off (priority = never).
///   2. Interface is gone (cable unplugged, Wi-Fi off, hotspot lost).
///   3. Captive portal detected — user must sign in.
///   4. Supervisor verdict — healthy / degraded / unhealthy / unknown.
///
String _statusLineFor(
  LinkMetric? m,
  Link link, {
  LinkStatus? supervisorStatus,
  CaptivePortalProbeResult? captiveState,
  bool interfacePresent = true,
  NamedInterfaceKind? kind,
}) {
  if (link.priority == LinkPriority.never) {
    return 'Off — Dispatch isn\'t using this network';
  }
  if (!interfacePresent) {
    return 'Disconnected — will rejoin when reconnected';
  }
  if (captiveState == CaptivePortalProbeResult.captive) {
    if (kind == NamedInterfaceKind.cellularTether) {
      return 'Personal Hotspot needs attention — unlock iPhone and allow tethering';
    }
    if (kind == NamedInterfaceKind.bluetoothTether) {
      return 'Bluetooth tether needs attention — enable internet sharing on the phone';
    }
    return 'Sign-in required — opening a browser to this network will fix it';
  }
  // "connected to the access point but can't reach the open internet."
  // The link probe may still report low RTT (the AP itself answers TCP
  // SYNs locally) which would otherwise mislead the supervisor into
  // calling the link healthy. The captive probe's authoritative "no
  // internet" verdict overrides that here.
  if (captiveState == CaptivePortalProbeResult.error) {
    if (kind == NamedInterfaceKind.cellularTether) {
      return 'iPhone USB is connected, but Personal Hotspot is not offering internet';
    }
    if (kind == NamedInterfaceKind.bluetoothTether) {
      return 'Bluetooth is connected, but the phone is not offering internet';
    }
    if (kind == NamedInterfaceKind.ethernet ||
        kind == NamedInterfaceKind.thunderbolt) {
      return 'Connected, but this adapter cannot reach the internet';
    }
    return 'No internet — connected to Wi-Fi but can\'t reach the web';
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
      return 'Poor signal — Dispatch is routing around it';
    case LinkStatus.disabled:
      return 'Off — Dispatch isn\'t using this network';
    case LinkStatus.unknown:
    case null:
      if (m == null || m.rttMs == null) {
        if (kind == NamedInterfaceKind.cellularTether) {
          return 'Checking iPhone tether — Personal Hotspot must be on';
        }
        return 'Checking…';
      }
      return 'Healthy, standing by';
  }
}

/// True iff [link] is anchored to an interface that's currently in the
/// controller's live snapshot. Links without an [Link.interfaceName] anchor
/// also return true because there is nothing stable to verify against.
bool _isInterfacePresent(Link link, DispatchController c) {
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
              'Preferred = always include. Auto = use when it helps. Backup = only on outage. Blocked = never touch this network.',
        ),
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
              'Cap how fast Dispatch can push traffic over this network. Useful for cellular plans.',
        ),
        _SpeedCapSlider(controller: controller, link: link, tint: tint),
        const SizedBox(height: 14),
        const _BodyDivider(),
        const _BodyLabel(
          label: 'Monthly data cap',
          help:
              'Pause this network once it carries this many GB this month. Reset on the 1st.',
        ),
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
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 6),
    child: Divider(height: 1),
  );
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
        Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 2),
        Text(
          help,
          style: const TextStyle(
            fontSize: 11,
            color: DispatchColors.muted,
            height: 1.35,
          ),
        ),
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
    Color fill = selected
        ? spec.color.withValues(alpha: 0.16)
        : Colors.transparent;
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
                Text(
                  spec.label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: fg,
                  ),
                ),
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
                widget.link.id,
                finalVal == 0 ? null : finalVal,
              );
            },
          ),
        ),
        SizedBox(
          width: 70,
          child: Text(
            label,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
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
      text: gb == null ? '' : gb.toStringAsFixed(0),
    );
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
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
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
/// 1. The SSID / hardware-port from the OS naming snapshot.
/// 2. A custom user-supplied [Link.label] (only if it isn't an
///    IP literal or raw BSD device name leaked in by the legacy
///    `selected_targets` migration).
/// 3. The interface-name heuristic.
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
  if (RegExp(r'^(?:utun|ipsec|tun|tap|awdl|bridge|llw|ppp)\d+$').hasMatch(s)) {
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
    if (named.kindLabel.isNotEmpty && named.kindLabel.toLowerCase() != name) {
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

IconData _iconForInterfaceName(String raw, Map<String, NamedInterface> names) {
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

/// Per-link "Used: 12.4 GB" row that sits below the data-cap controls. When
/// the link has a [Link.dataCapBytes] cap it also draws a thin progress fill.
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

// =====================================================================
// SETTINGS DIALOG (gear icon)
// =====================================================================
//
// Everything power-users want lives here — the listen host / port,
// transport kind, start-at-login, etc. Hidden behind the gear icon so
// the main UI stays uncluttered.

Future<void> _showSettingsDialog(
  BuildContext context,
  DispatchController controller,
) {
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
              _SettingsLabel(
                'Relay',
                'Arcane Dispatch always uses the SLC relay for bonding.',
              ),
              _RelaySummary(policy: policy),
              const SizedBox(height: 12),
              // Behaviour toggles that previously lived on the Mode tab.
              // They're advanced enough that most users won't touch them
              // (sensible defaults already match the user's intent:
              // combine for speed, prefer low-latency for realtime, auto
              // sign-in handling on, kill switch off), but the gear icon
              // is exactly where power users expect to find them.
              _SettingsLabel(
                'Safety & quality',
                'Defaults work for most people; tweak only if you know you need to.',
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Help me sign in to coffee-shop Wi-Fi'),
                subtitle: const Text(
                  'When a network bounces you to a login page, Dispatch pauses it until you sign in.',
                  style: TextStyle(fontSize: 11),
                ),
                value: policy.captivePortalAssist,
                onChanged: (bool v) => controller.setCaptivePortalAssist(v),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Block internet when Dispatch is off'),
                subtitle: const Text(
                  'Strict mode: when Dispatch isn\'t running, your apps lose internet too. Useful on untrusted networks.',
                  style: TextStyle(fontSize: 11),
                ),
                value: policy.killSwitch,
                onChanged: (bool v) => controller.setKillSwitch(v),
              ),
              const SizedBox(height: 12),
              _SettingsLabel(
                'Listen port',
                'Apps connect to this port. SOCKS proxy default is 1080.',
              ),
              TextFormField(
                initialValue: settings.listenPort.toString(),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (String v) => controller.setListenPort(v),
              ),
              const SizedBox(height: 12),
              _SettingsLabel(
                'Bind address',
                'Most people leave this as 127.0.0.1 (this Mac only).',
              ),
              TextFormField(
                initialValue: settings.listenHost,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (String v) => controller.setListenHost(v),
              ),
              const SizedBox(height: 12),
              _SettingsLabel(
                'How traffic leaves your Mac',
                'System-wide is the default — every app on your Mac flows through the bond, no per-app setup. The proxy mode is an opt-in fallback for cases where the system extension can\'t be installed (e.g. a build without a Developer ID team).',
              ),
              SegmentedButton<TransportKind>(
                segments: const <ButtonSegment<TransportKind>>[
                  ButtonSegment<TransportKind>(
                    value: TransportKind.tunnel,
                    label: Text('System-wide'),
                  ),
                  ButtonSegment<TransportKind>(
                    value: TransportKind.socks,
                    label: Text('Proxy (SOCKS)'),
                  ),
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
                  style: TextStyle(fontSize: 11),
                ),
                value: settings.launchAtStartup,
                onChanged: (bool v) => controller.setLaunchAtStartup(v),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Hide menu-bar window on click-away'),
                subtitle: const Text(
                  'Recommended. Off keeps the panel pinned for debugging.',
                  style: TextStyle(fontSize: 11),
                ),
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

class _RelaySummary extends StatelessWidget {
  final Policy policy;

  const _RelaySummary({required this.policy});

  @override
  Widget build(BuildContext context) {
    String endpoint = policy.serverUrl ?? DispatchSettings.defaultRelayUrl;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: DispatchColors.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: DispatchColors.accent.withValues(alpha: 0.24),
        ),
      ),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.cloud_done_rounded,
            size: 18,
            color: DispatchColors.accent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'SLC relay locked in',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  endpoint,
                  style: const TextStyle(
                    fontSize: 12,
                    color: DispatchColors.muted,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          DispatchBadge(
            label: policy.bondedTransport ? 'Bonded' : 'Relay',
            color: DispatchColors.accent,
          ),
        ],
      ),
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
          Text(
            title,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
          ),
          Text(
            help,
            style: const TextStyle(
              fontSize: 11,
              color: DispatchColors.muted,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}
