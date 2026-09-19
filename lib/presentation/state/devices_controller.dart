import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/casting/aurora_connect.dart';
import '../../core/casting/cast_transport.dart';
import '../../core/casting/dlna_transport.dart';
import '../../core/casting/remote_transport.dart';
import '../../core/casting/streaming_device.dart';
import '../../core/config/app_config.dart';
import '../../domain/entities/track.dart';
import 'output_controller.dart';
import 'player_controller.dart';

@immutable
class DevicesState {
  final StreamingDevice active;
  final List<StreamingDevice> castDevices;
  final List<StreamingDevice> dlnaDevices;
  final List<StreamingDevice> auroraDevices;
  final bool discovering;
  final String? error;
  final bool isReceiverControlled;
  final String? controllerName;
  final RemotePlaybackSnapshot? remoteSnapshot;

  const DevicesState({
    this.active = StreamingDevice.local,
    this.castDevices = const [],
    this.dlnaDevices = const [],
    this.auroraDevices = const [],
    this.discovering = false,
    this.error,
    this.isReceiverControlled = false,
    this.controllerName,
    this.remoteSnapshot,
  });

  bool get isRemote => active.type != StreamingDeviceType.local;

  DevicesState copyWith({
    StreamingDevice? active,
    List<StreamingDevice>? castDevices,
    List<StreamingDevice>? dlnaDevices,
    List<StreamingDevice>? auroraDevices,
    bool? discovering,
    String? error,
    bool clearError = false,
    bool? isReceiverControlled,
    String? controllerName,
    bool clearController = false,
    RemotePlaybackSnapshot? remoteSnapshot,
    bool clearRemote = false,
  }) =>
      DevicesState(
        active: active ?? this.active,
        castDevices: castDevices ?? this.castDevices,
        dlnaDevices: dlnaDevices ?? this.dlnaDevices,
        auroraDevices: auroraDevices ?? this.auroraDevices,
        discovering: discovering ?? this.discovering,
        error: clearError ? null : (error ?? this.error),
        isReceiverControlled:
            isReceiverControlled ?? this.isReceiverControlled,
        controllerName: clearController
            ? null
            : (controllerName ?? this.controllerName),
        remoteSnapshot:
            clearRemote ? null : (remoteSnapshot ?? this.remoteSnapshot),
      );
}

class DevicesController extends Notifier<DevicesState> {
  late final CastTransport _cast;
  late final DlnaTransport _dlna;
  late final AuroraConnectTransport _aurora;
  late final AuroraConnectReceiver _receiver;

  StreamSubscription? _castDevSub;
  StreamSubscription? _dlnaDevSub;
  StreamSubscription? _auroraDevSub;
  StreamSubscription? _statusSub;

  RemoteTransport? _activeTransport;
  Timer? _receiverStateTimer;

  @override
  DevicesState build() {
    _cast = CastTransport();
    _dlna = DlnaTransport();
    _aurora = AuroraConnectTransport();
    _receiver = AuroraConnectReceiver();

    ref.onDispose(() {
      unawaited(_teardown());
    });

    // Start receiver + discovery after first frame so MethodChannels are ready.
    Future.microtask(() async {
      await _startReceiver();
      await refreshDiscovery();
    });

    return const DevicesState();
  }

  bool get isRemoteActive => state.isRemote;

  Future<void> _startReceiver() async {
    if (!Platform.isAndroid) return;
    _receiver.onCommand = _onReceiverCommand;
    try {
      final name = await _deviceName();
      await _receiver.start(serviceName: name);
      _receiverStateTimer?.cancel();
      _receiverStateTimer =
          Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (!state.isReceiverControlled) return;
        final ps = ref.read(playerControllerProvider);
        _receiver.broadcastState(RemotePlaybackSnapshot(
          position: ps.position,
          duration: ps.total,
          isPlaying: ps.isPlaying,
          isLoading: ps.isLoading,
        ));
      });
    } catch (e) {
      debugPrint('[devices] receiver start: $e');
    }
  }

  Future<String> _deviceName() async {
    try {
      // Reuse media channel for a friendly label if needed later.
      return 'Aurora ${Platform.localHostname}';
    } catch (_) {
      return 'Aurora';
    }
  }

  Future<void> refreshDiscovery() async {
    state = state.copyWith(discovering: true, clearError: true);
    _castDevSub ??= _cast.devices.listen((list) {
      state = state.copyWith(castDevices: list);
    });
    _dlnaDevSub ??= _dlna.devices.listen((list) {
      state = state.copyWith(dlnaDevices: list);
    });
    _auroraDevSub ??= _aurora.devices.listen((list) {
      // Hide ourselves if we somehow appear.
      final port = _receiver.port;
      final filtered = list.where((d) {
        if (port == null) return true;
        return d.extras['port'] != '$port';
      }).toList(growable: false);
      state = state.copyWith(auroraDevices: filtered);
    });

    await Future.wait([
      _cast.startDiscovery(),
      _dlna.startDiscovery(),
      _aurora.startDiscovery(),
    ]);
    state = state.copyWith(discovering: false);
  }

  Future<void> selectDevice(StreamingDevice device) async {
    if (device == state.active) return;

    final player = ref.read(playerControllerProvider.notifier);
    final ps = ref.read(playerControllerProvider);

    if (device.type == StreamingDeviceType.local) {
      await _returnToLocal(resume: true);
      return;
    }

    // Remote targets need a LAN-reachable stream URL.
    final track = ps.current;
    if (track == null) {
      state = state.copyWith(error: 'Nothing is playing');
      return;
    }
    if (track.localPath != null &&
        !RegExp(r'^[A-Za-z0-9_-]{6,64}$').hasMatch(track.id)) {
      state = state.copyWith(
        error: 'Local files can only play on this phone',
      );
      return;
    }
    if (_apiBaseLooksLocalOnly()) {
      state = state.copyWith(
        error:
            'Server must be reachable on the same Wi‑Fi (Cast/DLNA cannot use localhost)',
      );
      // Still allow Aurora Connect (peer fetches same URL — same constraint),
      // but warn loudly. Abort Cast/DLNA when clearly unreachable.
      if (device.type == StreamingDeviceType.cast ||
          device.type == StreamingDeviceType.dlna) {
        return;
      }
    }

    try {
      await player.pauseForRemoteHandoff();
      await _activeTransport?.disconnect();
      _statusSub?.cancel();

      final transport = switch (device.type) {
        StreamingDeviceType.cast => _cast,
        StreamingDeviceType.dlna => _dlna,
        StreamingDeviceType.aurora => _aurora,
        StreamingDeviceType.local => null,
      };
      if (transport == null) return;

      await transport.connect(device);
      _activeTransport = transport;
      _statusSub = transport.status.listen((snap) {
        state = state.copyWith(remoteSnapshot: snap);
        player.applyRemoteSnapshot(snap);
        if (snap.error != null) {
          state = state.copyWith(error: snap.error);
        }
      });

      final uri = await player.resolveStreamUriForRemote(track);
      await transport.load(
        streamUrl: uri.toString(),
        title: track.title,
        artist: track.artist,
        artworkUrl: track.artworkUrl.isNotEmpty ? track.artworkUrl : null,
        position: ps.position,
        duration: ps.total,
      );

      state = state.copyWith(
        active: device,
        clearError: true,
        remoteSnapshot: RemotePlaybackSnapshot(
          position: ps.position,
          duration: ps.total,
          isPlaying: true,
        ),
      );
    } catch (e) {
      debugPrint('[devices] select failed: $e');
      state = state.copyWith(error: 'Could not connect: $e');
      await _returnToLocal(resume: true);
    }
  }

  bool _apiBaseLooksLocalOnly() {
    final base = AppConfig.apiBase.toLowerCase();
    return base.contains('127.0.0.1') ||
        base.contains('localhost') ||
        base.contains('10.0.2.2');
  }

  Future<void> _returnToLocal({required bool resume}) async {
    Duration? pos = state.remoteSnapshot?.position;
    try {
      await _activeTransport?.stop();
      await _activeTransport?.disconnect();
    } catch (_) {}
    _statusSub?.cancel();
    _statusSub = null;
    _activeTransport = null;
    state = state.copyWith(
      active: StreamingDevice.local,
      clearRemote: true,
      clearError: true,
    );
    if (resume) {
      await ref
          .read(playerControllerProvider.notifier)
          .resumeAfterRemoteHandoff(position: pos);
    }
  }

  Future<void> remotePlay() async => _activeTransport?.play();

  Future<void> remotePause() async => _activeTransport?.pause();

  Future<void> remoteSeek(Duration position) async =>
      _activeTransport?.seek(position);

  Future<void> remoteSetVolume(double v) async =>
      _activeTransport?.setVolume(v);

  Future<void> remoteLoadTrack(Track track, Uri streamUri,
      {Duration position = Duration.zero, Duration duration = Duration.zero}) async {
    final t = _activeTransport;
    if (t == null) return;
    await t.load(
      streamUrl: streamUri.toString(),
      title: track.title,
      artist: track.artist,
      artworkUrl: track.artworkUrl.isNotEmpty ? track.artworkUrl : null,
      position: position,
      duration: duration,
    );
  }

  void _onReceiverCommand(Map<String, dynamic> msg) {
    final type = msg['type'] as String? ?? '';
    final player = ref.read(playerControllerProvider.notifier);
    switch (type) {
      case 'hello':
        state = state.copyWith(
          isReceiverControlled: true,
          controllerName: msg['name'] as String? ?? 'Another Aurora',
        );
        break;
      case 'load':
        state = state.copyWith(
          isReceiverControlled: true,
          controllerName: state.controllerName ?? 'Another Aurora',
        );
        unawaited(player.playAsReceiver(
          title: msg['title'] as String? ?? 'Unknown',
          artist: msg['artist'] as String? ?? '',
          artworkUrl: msg['artworkUrl'] as String? ?? '',
          streamUrl: msg['streamUrl'] as String? ?? '',
          positionMs: (msg['positionMs'] as num?)?.toInt() ?? 0,
          durationMs: (msg['durationMs'] as num?)?.toInt() ?? 0,
        ));
        break;
      case 'play':
        unawaited(player.receiverPlay());
        break;
      case 'pause':
        unawaited(player.receiverPause());
        break;
      case 'seek':
        final ms = (msg['positionMs'] as num?)?.toInt() ?? 0;
        unawaited(player.receiverSeek(Duration(milliseconds: ms)));
        break;
      case 'volume':
        final v = (msg['volume'] as num?)?.toDouble() ?? 1.0;
        unawaited(player.setVolume(v));
        break;
      case 'stop':
        unawaited(player.receiverPause());
        state = state.copyWith(
          isReceiverControlled: false,
          clearController: true,
        );
        break;
    }
  }

  Future<void> stopBeingControlled() async {
    state = state.copyWith(
      isReceiverControlled: false,
      clearController: true,
    );
    await ref.read(playerControllerProvider.notifier).receiverPause();
  }

  Future<void> _teardown() async {
    _receiverStateTimer?.cancel();
    await _statusSub?.cancel();
    await _castDevSub?.cancel();
    await _dlnaDevSub?.cancel();
    await _auroraDevSub?.cancel();
    await _receiver.stop();
    await _cast.dispose();
    await _dlna.dispose();
    await _aurora.dispose();
  }
}

final devicesControllerProvider =
    NotifierProvider<DevicesController, DevicesState>(DevicesController.new);

/// Chip label prefers active streaming target, else system output kind.
final devicesChipLabelProvider = Provider<({String label, StreamingDeviceType type})>((ref) {
  final devices = ref.watch(devicesControllerProvider);
  if (devices.isRemote) {
    return (label: devices.active.name, type: devices.active.type);
  }
  final out = ref.watch(outputDeviceProvider).valueOrNull;
  return (
    label: out?.label ?? 'Device Speakers',
    type: StreamingDeviceType.local,
  );
});
