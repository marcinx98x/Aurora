import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/casting/streaming_device.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import 'glass.dart';
import '../state/devices_controller.dart';
import '../state/output_controller.dart';

/// Spotify-style devices picker: this phone, DLNA, Aurora Connect.
class DevicesSheet extends ConsumerStatefulWidget {
  const DevicesSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const DevicesSheet(),
    );
  }

  @override
  ConsumerState<DevicesSheet> createState() => _DevicesSheetState();
}

class _DevicesSheetState extends ConsumerState<DevicesSheet> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await Permission.nearbyWifiDevices.request();
      } catch (_) {}
      if (!mounted) return;
      final devices = ref.read(devicesControllerProvider.notifier);
      devices.ensureReceiverStarted();
      await devices.refreshDiscovery();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(devicesControllerProvider);
    final localOut = ref.watch(outputDeviceProvider).valueOrNull ??
        const OutputDevice(OutputKind.speaker, 'Device Speakers');

    return Glass(
      radius: const BorderRadius.vertical(top: Radii.xl),
      blur: 30,
      opacity: 0.16,
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.72,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: Sp.md),
              Container(
                width: 44,
                height: 4,
                decoration: const BoxDecoration(
                  color: AppColors.glassStroke,
                  borderRadius: Radii.rPill,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Sp.lg, Sp.lg, Sp.lg, Sp.sm),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Connect to a device',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    if (state.discovering)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      IconButton(
                        tooltip: 'Refresh',
                        onPressed: () => ref
                            .read(devicesControllerProvider.notifier)
                            .refreshDiscovery(),
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                  ],
                ),
              ),
              if (state.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Sp.lg),
                  child: Text(
                    state.error!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.orangeAccent,
                        ),
                  ),
                ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: Sp.lg),
                  children: [
                    _section(context, 'This phone'),
                    _tile(
                      context,
                      device: StreamingDevice.local.copyWith(
                        subtitle: localOut.label,
                      ),
                      selected: !state.isRemote,
                      leading: Icon(_localIcon(localOut.kind),
                          color: AppColors.accentBright),
                      onTap: () async {
                        await ref
                            .read(devicesControllerProvider.notifier)
                            .selectDevice(StreamingDevice.local);
                        if (context.mounted) Navigator.pop(context);
                      },
                      trailing: TextButton(
                        onPressed: () {
                          openOutputPicker();
                        },
                        child: const Text('Output'),
                      ),
                    ),
                    _section(context, 'Network (DLNA)'),
                    if (state.dlnaDevices.isEmpty)
                      _empty(context, 'No DLNA renderers found')
                    else
                      ...state.dlnaDevices.map((d) => _tile(
                            context,
                            device: d,
                            selected: state.active == d,
                            leading: const Icon(Icons.tv_rounded,
                                color: AppColors.accentBright),
                            onTap: () => _pick(d),
                          )),
                    _section(context, 'Aurora'),
                    if (state.auroraDevices.isEmpty)
                      _empty(context, 'No other Aurora devices on Wi-Fi')
                    else
                      ...state.auroraDevices.map((d) => _tile(
                            context,
                            device: d,
                            selected: state.active == d,
                            leading: const Icon(Icons.phone_android_rounded,
                                color: AppColors.accentBright),
                            onTap: () => _pick(d),
                          )),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pick(StreamingDevice d) async {
    await ref.read(devicesControllerProvider.notifier).selectDevice(d);
    if (mounted) Navigator.pop(context);
  }

  Widget _section(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(Sp.lg, Sp.md, Sp.lg, Sp.xs),
        child: Text(
          title,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: AppColors.textSecondary,
                letterSpacing: 0.4,
              ),
        ),
      );

  Widget _empty(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: Sp.lg, vertical: Sp.sm),
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.textSecondary,
              ),
        ),
      );

  Widget _tile(
    BuildContext context, {
    required StreamingDevice device,
    required bool selected,
    required Widget leading,
    required VoidCallback onTap,
    Widget? trailing,
  }) {
    return ListTile(
      leading: leading,
      title: Text(device.name),
      subtitle: device.subtitle != null ? Text(device.subtitle!) : null,
      trailing: trailing ??
          (selected
              ? const Icon(Icons.check_rounded, color: AppColors.accentBright)
              : null),
      onTap: onTap,
    );
  }

  IconData _localIcon(OutputKind k) => switch (k) {
        OutputKind.bluetooth => Icons.bluetooth_audio_rounded,
        OutputKind.headphones => Icons.headphones_rounded,
        OutputKind.speaker => Icons.smartphone_rounded,
      };
}

class DevicesChip extends ConsumerWidget {
  const DevicesChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chip = ref.watch(devicesChipLabelProvider);
    final controlled = ref.watch(
        devicesControllerProvider.select((s) => s.isReceiverControlled));
    final icon = switch (chip.type) {
      StreamingDeviceType.dlna => Icons.tv_rounded,
      StreamingDeviceType.aurora => Icons.phone_android_rounded,
      StreamingDeviceType.local => Icons.speaker_rounded,
    };
    return GestureDetector(
      onTap: () => DevicesSheet.show(context),
      child: Glass(
        radius: Radii.rPill,
        blur: 18,
        opacity: 0.10,
        padding: const EdgeInsets.symmetric(horizontal: Sp.md, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: AppColors.accentBright),
            const SizedBox(width: Sp.sm),
            Text(
              controlled
                  ? 'Controlled · ${chip.label}'
                  : 'Devices: ${chip.label}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: AppColors.textSecondary,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
