import 'package:flutter/material.dart';

import '../core/flow_stat.dart';
import '../ui/dispatch_ui.dart';
import 'dispatch_controller.dart';

/// Live per-flow table for the home screen.
///
/// Renders the controller's [DispatchController.flows] sliding window with
/// one row per active or recent flow:
///
/// ```
/// [link pill] remote-host:port       in: 1.2 MB    out: 134 KB  • 12 s
/// ```
///
/// The widget is intentionally read-only — no taps, no menus, no expand. The
/// goal is "watch your tunnel work at a glance". A future detail panel will
/// be a separate screen.
///
/// The section auto-hides while the controller has no flows so the home
/// screen stays tidy when only the SOCKS transport is active (SOCKS doesn't
/// publish [FlowStat]s yet — Phase 7 will fill them in).
class FlowInspectorSection extends StatelessWidget {
  final DispatchController controller;

  const FlowInspectorSection({required this.controller, super.key});

  @override
  Widget build(BuildContext context) {
    List<FlowStat> flows = controller.flows;
    if (flows.isEmpty) {
      return const SizedBox.shrink();
    }
    return DispatchSection(
      title: 'Live flows',
      trailing: Text(
        '${flows.length} flow${flows.length == 1 ? '' : 's'}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int i = 0; i < flows.length; i++) ...<Widget>[
              if (i > 0) const Divider(height: 8, color: DispatchColors.border),
              _FlowRow(flow: flows[i]),
            ],
          ],
        ),
      ),
    );
  }
}

class _FlowRow extends StatelessWidget {
  final FlowStat flow;

  const _FlowRow({required this.flow});

  @override
  Widget build(BuildContext context) {
    bool rt = flow.trafficClass == 'realtime';
    // Stable per-link color — the same hash → HSL the link card uses, so a
    // flow row reads the same color as its sourcing link sparkline at a
    // glance. Closed flows fade to muted to make active rows stand out.
    Color linkColor = flow.linkId.isEmpty
        ? DispatchColors.muted
        : (flow.isOpen
            ? DispatchColors.linkColorFor(flow.linkId)
            : DispatchColors.muted);
    return Row(
      children: <Widget>[
        // Thin vertical stripe in the link color so a row's source link is
        // visible without reading the badge text.
        Container(
          width: 3,
          height: 28,
          decoration: BoxDecoration(
            color: linkColor,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        DispatchBadge(
          label: flow.linkId.isEmpty ? '—' : flow.linkId,
          color: linkColor,
        ),
        if (rt) ...<Widget>[
          const SizedBox(width: 6),
          const DispatchBadge(
            label: 'RT',
            color: DispatchColors.accent,
          ),
        ],
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                _formatRemote(flow),
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: DispatchColors.ink,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                _formatMeta(flow),
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        // Byte counters render right-aligned in a fixed-width font so they
        // line up across rows even when one row has '1.2 MB' and another has
        // '134 KB'.
        Text(
          _formatBytes(flow),
          textAlign: TextAlign.right,
          style: const TextStyle(
            fontSize: 11,
            fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
            color: DispatchColors.ink,
          ),
        ),
      ],
    );
  }

  /// "host:port" when the SOCKS layer has resolved a name, otherwise just the
  /// IP literal. Protocol annotation is appended for non-TCP flows so a
  /// glance can spot UDP video.
  String _formatRemote(FlowStat flow) {
    String head = flow.remoteHost?.isNotEmpty == true
        ? '${flow.remoteHost}:${flow.remotePort}'
        : '${flow.remoteAddress}:${flow.remotePort}';
    if (flow.protocol != 6 && flow.protocol != 17) {
      head = '$head  • proto=${flow.protocol}';
    } else if (flow.protocol == 17) {
      head = '$head  • UDP';
    }
    // Non-realtime traffic classes are appended inline; the realtime case
    // is surfaced via the dedicated `RT` badge above.
    if (flow.trafficClass != null &&
        flow.trafficClass!.isNotEmpty &&
        flow.trafficClass != 'realtime') {
      head = '$head  • ${flow.trafficClass}';
    }
    return head;
  }

  String _formatMeta(FlowStat flow) {
    Duration age = flow.duration;
    return flow.isOpen
        ? 'open • ${_formatDuration(age)}'
        : 'closed • ${_formatDuration(age)}';
  }

  String _formatBytes(FlowStat flow) {
    return '↑ ${_humanizeBytes(flow.bytesOut)}    ↓ ${_humanizeBytes(flow.bytesIn)}';
  }

  static String _humanizeBytes(int bytes) {
    if (bytes <= 0) {
      return '0 B';
    }
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      double kb = bytes / 1024.0;
      return '${kb.toStringAsFixed(kb >= 10 ? 0 : 1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      double mb = bytes / (1024.0 * 1024.0);
      return '${mb.toStringAsFixed(mb >= 10 ? 0 : 1)} MB';
    }
    double gb = bytes / (1024.0 * 1024.0 * 1024.0);
    return '${gb.toStringAsFixed(gb >= 10 ? 0 : 1)} GB';
  }

  static String _formatDuration(Duration d) {
    if (d.inSeconds < 60) {
      return '${d.inSeconds}s';
    }
    if (d.inMinutes < 60) {
      return '${d.inMinutes}m ${d.inSeconds % 60}s';
    }
    return '${d.inHours}h ${d.inMinutes % 60}m';
  }
}
