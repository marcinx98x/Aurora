import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/casting/aurora_connect.dart';
import '../../core/casting/dlna_transport.dart';
import '../../core/casting/remote_playback_port.dart';
import '../../core/casting/remote_transport.dart';
import '../../core/casting/streaming_device.dart';
import '../../core/config/app_config.dart';
import '../../domain/entities/track.dart';
import 'output_controller.dart';
import 'player_controller.dart';

@immutable
class DevicesState {
  final StreamingDevice active;
  final List<StreamingDevice> dlnaDevices;
  final List<StreamingDevice> auroraDevices;
  final bool discovering;
  final String? error;
  final bool isReceiverControlled;
  final String? controllerName;
  final RemotePlaybackSnapshot? remoteSnapshot;

  const DevicesState({
    this.active = StreamingDevice.local,
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
  late final DlnaTransport _dlna;
  late final AuroraConnectTransport _aurora;
  late final AuroraConnectReceiver _receiver;

  StreamSubscription? _dlnaDevSub;
  StreamSubscription? _auroraDevSub;
  StreamSubscription? _statusSub;
  bool _handlingRemoteEnd = false;

  RemoteTransport? _activeTransport;
  Timer? _receiverStateTimer;
  Timer? _receiverStartTimer;
  bool _receiverStarted = false;
  bool _receiverKickoffScheduled = false;

  @override
  DevicesState build() {
    _dlna = DlnaTransport();
    _aurora = AuroraConnectTransport();
    _receiver = AuroraConnectReceiver();

    ref.onDispose(() {
      unawaited(_teardown());
    });

    // Cold start: no discovery, no receiver, no NSD.
    return const DevicesState();
  }

  bool get isRemoteActive => state.isRemote;

  /// Called from the Devices sheet. Discovery only — never from main.
  Future<void> refreshDiscovery() async {
    state = state.copyWith(discovering: true, clearError: true);
    _dlnaDevSub ??= _dlna.devices.listen((list) {
      state = state.copyWith(dlnaDevices: list);
    });
    _auroraDevSub ??= _aurora.devices.listen((list) {
      final port = _receiver.port;
      final filtered = list.where((d) {
        if (port == null) return true;
        return d.extras['port'] != '$port';
      }).toList(growable: false);
      state = state.copyWith(auroraDevices: filtered);
    });

    await Future.wait([
      _dlna.startDiscovery(),
      _aurora.startDiscovery(),
    ]);
    state = state.copyWith(discovering: false);
  }

  /// Delayed receiver start after the first Devices sheet open (≥2s).
  void ensureReceiverStarted() {
    if (_receiverStarted || _receiverKickoffScheduled) return;
    if (!Platform.isAndroid) return;
    _receiverKickoffScheduled = true;
    _receiverStartTimer?.cancel();
    _receiverStartTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_startReceiver());
    });
  }

  Future<void> _startReceiver() async {
    if (_receiverStarted) return;
    if (!Platform.isAndroid) return;
    _receiver.onCommand = _onReceiverCommand;
    try {
      await _receiver.start(serviceName: 'Aurora ${Platform.localHostname}');
      _receiverStarted = true;
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
      _receiverKickoffScheduled = false;
    }
  }

  void _bindPort() {
    ref.read(remotePlaybackPortProvider.notifier).state =
        _DevicesRemotePort(this);
  }

  void _clearPort() {
    ref.read(remotePlaybackPortProvider.notifier).state =
        const InactiveRemotePlaybackPort();
  }

  Future<void> selectDevice(StreamingDevice device) async {
    if (device == state.active) return;

    final player = ref.read(playerControllerProvider.notifier);
    final ps = ref.read(playerControllerProvider);

    if (device.type == StreamingDeviceType.local) {
      await _returnToLocal(resume: true);
      return;
    }

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
            'Server must be reachable on the same Wi-Fi (DLNA cannot use localhost)',
      );
      if (device.type == StreamingDeviceType.dlna) {
        return;
      }
    }

    try {
      await player.pauseForRemoteHandoff();
      await _activeTransport?.disconnect();
      _statusSub?.cancel();

      final transport = switch (device.type) {
        StreamingDeviceType.dlna => _dlna,
        StreamingDeviceType.aurora => _aurora,
        StreamingDeviceType.local => null,
      };
      if (transport == null) return;

      await transport.connect(device);
      _activeTransport = transport;
      _bindPort();
      _statusSub = transport.status.listen((snap) {
        state = state.copyWith(remoteSnapshot: snap);
        player.applyRemoteSnapshot(snap);
        if (snap.error != null) {
          state = state.copyWith(error: snap.error);
        }
        if (snap.ended) {
          unawaited(_onRemoteTrackEnded());
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

  Future<void> _onRemoteTrackEnded() async {
    if (_handlingRemoteEnd || !state.isRemote) return;
    _handlingRemoteEnd = true;
    try {
      await ref.read(playerControllerProvider.notifier).next();
    } finally {
      _handlingRemoteEnd = false;
    }
  }

  Future<void> _returnToLocal({required bool resume}) async {
    final pos = state.remoteSnapshot?.position;
    try {
      await _activeTransport?.stop();
      await _activeTransport?.disconnect();
    } catch (_) {}
    _statusSub?.cancel();
    _statusSub = null;
    _activeTransport = null;
    _clearPort();
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

  Future<void> remoteLoadTrack(
    Track track,
    Uri streamUri, {
    Duration position = Duration.zero,
    Duration duration = Duration.zero,
  }) async {
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
    _receiverStartTimer?.cancel();
    _receiverStateTimer?.cancel();
    _clearPort();
    await _statusSub?.cancel();
    await _dlnaDevSub?.cancel();
    await _auroraDevSub?.cancel();
    await _receiver.stop();
    await _dlna.dispose();
    await _aurora.dispose();
  }
}

/// Bridges DevicesController into the player-facing port (no import cycle).
class _DevicesRemotePort implements RemotePlaybackPort {
  _DevicesRemotePort(this._c);

  final DevicesController _c;

  @override
  bool get isActive => true;

  @override
  Stream<RemotePlaybackSnapshot> get snapshots {
    final t = _c._activeTransport;
    if (t == null) return const Stream.empty();
    return t.status;
  }

  @override
  Future<void> play() => _c.remotePlay();

  @override
  Future<void> pause() => _c.remotePause();

  @override
  Future<void> seek(Duration position) => _c.remoteSeek(position);

  @override
  Future<void> setVolume(double volume) => _c.remoteSetVolume(volume);

  @override
  Future<void> loadTrack(
    Track track,
    Uri streamUri, {
    Duration position = Duration.zero,
    Duration duration = Duration.zero,
  }) =>
      _c.remoteLoadTrack(track, streamUri,
          position: position, duration: duration);
}

final devicesControllerProvider =
    NotifierProvider<DevicesController, DevicesState>(DevicesController.new);

/// Chip label prefers active streaming target, else system output kind.
final devicesChipLabelProvider =
    Provider<({String label, StreamingDeviceType type})>((ref) {
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
