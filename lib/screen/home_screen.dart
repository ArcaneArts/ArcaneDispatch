import 'dart:io';

import 'package:flutter/material.dart';

import '../core/network_interface_repository.dart';
import '../core/proxy_event.dart';
import '../ui/dispatch_ui.dart';
import 'dispatch_controller.dart';

class DispatchHomeScreen extends StatefulWidget {
  final DispatchController controller;

  const DispatchHomeScreen({required this.controller, super.key});

  @override
  State<DispatchHomeScreen> createState() => _DispatchHomeScreenState();
}

class _DispatchHomeScreenState extends State<DispatchHomeScreen> {
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _targetController;

  DispatchController get controller {
    return widget.controller;
  }

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController(
      text: controller.settings.listenHost,
    );
    _portController = TextEditingController(
      text: controller.settings.listenPort.toString(),
    );
    _targetController = TextEditingController();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _targetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? child) {
        return Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: ListView(
                children: <Widget>[
                  _Header(controller: controller),
                  const SizedBox(height: 12),
                  _EndpointSection(
                    controller: controller,
                    hostController: _hostController,
                    portController: _portController,
                  ),
                  const SizedBox(height: 10),
                  _InterfacesSection(
                    controller: controller,
                    targetController: _targetController,
                  ),
                  const SizedBox(height: 10),
                  _SettingsSection(controller: controller),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 220,
                    child: _EventsSection(controller: controller),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  final DispatchController controller;

  const _Header({required this.controller});

  @override
  Widget build(BuildContext context) {
    bool running = controller.isRunning;
    return Row(
      children: <Widget>[
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: running
                ? DispatchColors.ok.withValues(alpha: 0.12)
                : DispatchColors.accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            Icons.hub_outlined,
            color: running ? DispatchColors.ok : DispatchColors.accent,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Arcane Dispatch',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 2),
              Text(
                running
                    ? 'SOCKS proxy listening on ${controller.proxyEndpoint}'
                    : 'SOCKS proxy is stopped',
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        DispatchBadge(
          label: running ? 'Running' : 'Stopped',
          color: running ? DispatchColors.ok : DispatchColors.muted,
        ),
      ],
    );
  }
}

class _EndpointSection extends StatelessWidget {
  final DispatchController controller;
  final TextEditingController hostController;
  final TextEditingController portController;

  const _EndpointSection({
    required this.controller,
    required this.hostController,
    required this.portController,
  });

  @override
  Widget build(BuildContext context) {
    return DispatchSection(
      title: 'Proxy',
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: hostController,
                    enabled: !controller.isRunning,
                    decoration: const InputDecoration(labelText: 'Listen IP'),
                    onChanged: controller.setListenHost,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 96,
                  child: TextField(
                    controller: portController,
                    enabled: !controller.isRunning,
                    decoration: const InputDecoration(labelText: 'Port'),
                    keyboardType: TextInputType.number,
                    onChanged: controller.setListenPort,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: controller.isRunning
                      ? controller.stopProxy
                      : controller.startProxy,
                  icon: Icon(
                    controller.isRunning
                        ? Icons.stop_rounded
                        : Icons.play_arrow_rounded,
                    size: 18,
                  ),
                  label: Text(controller.isRunning ? 'Stop' : 'Start'),
                ),
              ],
            ),
            if (controller.errorText != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                controller.errorText!,
                style: const TextStyle(
                  color: DispatchColors.danger,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _InterfacesSection extends StatelessWidget {
  final DispatchController controller;
  final TextEditingController targetController;

  const _InterfacesSection({
    required this.controller,
    required this.targetController,
  });

  @override
  Widget build(BuildContext context) {
    return DispatchSection(
      title: 'Interfaces',
      trailing: DenseIconButton(
        icon: Icons.refresh_rounded,
        tooltip: 'Refresh interfaces',
        onPressed: controller.loadingInterfaces
            ? null
            : controller.refreshInterfaces,
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (controller.loadingInterfaces)
              const LinearProgressIndicator(minHeight: 2)
            else if (controller.interfaces.isEmpty)
              Text(
                'No usable network interfaces were found.',
                style: Theme.of(context).textTheme.bodySmall,
              )
            else
              ...controller.interfaces.map((
                NetworkInterfaceSnapshot interface,
              ) {
                return _InterfaceRow(
                  interface: interface,
                  selected: controller.settings.selectedTargets.contains(
                    interface.name,
                  ),
                  enabled: !controller.isRunning,
                  onChanged: (bool? value) {
                    controller.setTargetSelected(interface.name, value == true);
                  },
                );
              }),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: targetController,
                    enabled: !controller.isRunning,
                    decoration: const InputDecoration(
                      labelText: 'Manual IP/interface target',
                      hintText: '10.0.0.14/2',
                    ),
                    onSubmitted: (_) => _addManualTarget(),
                  ),
                ),
                const SizedBox(width: 8),
                DenseIconButton(
                  icon: Icons.add_rounded,
                  tooltip: 'Add target',
                  onPressed: controller.isRunning ? null : _addManualTarget,
                ),
              ],
            ),
            if (controller.settings.selectedTargets.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: controller.settings.selectedTargets.map((
                  String target,
                ) {
                  return InputChip(
                    label: Text(target),
                    onDeleted: controller.isRunning
                        ? null
                        : () => controller.setTargetSelected(target, false),
                    visualDensity: VisualDensity.compact,
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _addManualTarget() {
    String value = targetController.text.trim();
    if (value.isEmpty) {
      return;
    }
    targetController.clear();
    controller.setTargetSelected(value, true);
  }
}

class _InterfaceRow extends StatelessWidget {
  final NetworkInterfaceSnapshot interface;
  final bool selected;
  final bool enabled;
  final ValueChanged<bool?> onChanged;

  const _InterfaceRow({
    required this.interface,
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    String addresses = interface.addresses
        .map((InternetAddress address) => address.address)
        .join(', ');
    return CheckboxListTile(
      value: selected,
      onChanged: enabled ? onChanged : null,
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(
        interface.name,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
      ),
      subtitle: Text(addresses, overflow: TextOverflow.ellipsis),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  final DispatchController controller;

  const _SettingsSection({required this.controller});

  @override
  Widget build(BuildContext context) {
    return DispatchSection(
      title: 'Settings',
      child: Column(
        children: <Widget>[
          SwitchListTile(
            dense: true,
            title: const Text('Launch Arcane Dispatch at login'),
            value: controller.settings.launchAtStartup,
            onChanged: controller.setLaunchAtStartup,
          ),
          SwitchListTile(
            dense: true,
            title: const Text('Start proxy on app launch'),
            value: controller.settings.startProxyOnLaunch,
            onChanged: controller.setStartProxyOnLaunch,
          ),
          SwitchListTile(
            dense: true,
            title: const Text('Hide window on blur'),
            value: controller.settings.hideOnBlur,
            onChanged: controller.setHideOnBlur,
          ),
        ],
      ),
    );
  }
}

class _EventsSection extends StatelessWidget {
  final DispatchController controller;

  const _EventsSection({required this.controller});

  @override
  Widget build(BuildContext context) {
    return DispatchSection(
      title: 'Recent Activity',
      child: controller.events.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Text(
                  'No proxy activity yet.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            )
          : ListView.separated(
              padding: EdgeInsets.zero,
              itemCount: controller.events.length,
              separatorBuilder: (BuildContext context, int index) {
                return const Divider(height: 1, color: DispatchColors.border);
              },
              itemBuilder: (BuildContext context, int index) {
                ProxyEvent event = controller.events[index];
                return ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  title: Text(
                    event.message,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                  leading: DispatchBadge(
                    label: event.label,
                    color: _eventColor(event.type),
                  ),
                  subtitle: Text(
                    _formatTime(event.timestamp),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                );
              },
            ),
    );
  }

  Color _eventColor(ProxyEventType type) {
    switch (type) {
      case ProxyEventType.info:
        return DispatchColors.accent;
      case ProxyEventType.connectionOpened:
      case ProxyEventType.connectionClosed:
        return DispatchColors.ok;
      case ProxyEventType.warning:
        return Colors.orange.shade800;
      case ProxyEventType.error:
        return DispatchColors.danger;
    }
  }

  String _formatTime(DateTime time) {
    String hour = time.hour.toString().padLeft(2, '0');
    String minute = time.minute.toString().padLeft(2, '0');
    String second = time.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }
}
