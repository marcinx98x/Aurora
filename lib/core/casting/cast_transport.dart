import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'remote_transport.dart';
import 'streaming_device.dart';

/// Google Cast via Android MethodChannel (`aurora/cast`).
class CastTransport implements RemoteTransport {
  static const _methods = MethodChannel('aurora/cast');
  static const _devicesChannel = EventChannel('aurora/cast/devices');
  static const _statusChannel = EventChannel('aurora/cast/status');
  static const _commandsChannel = EventChannel('aurora/cast/commands');

  final _devicesCtrl =
      StreamController<List<StreamingDevice>>.broadcast();
  final _statusCtrl =
      StreamController<RemotePlaybackSnapshot>.broadcast();
  final _commandsCtrl = StreamController<String>.broadcast();

  StreamSubscription? _devicesSub;
  StreamSubscription? _statusSub;
  StreamSubscription? _commandsSub;
  bool _discovering = false;

  /// TV custom-namespace commands: `next` / `previous`.
  Stream<String> get commands => _commandsCtrl.stream;

  @override
  StreamingDeviceType get type => StreamingDeviceType.cast;

  @override
  Stream<List<StreamingDevice>> get devices => _devicesCtrl.stream;

  @override
  Stream<RemotePlaybackSnapshot> get status => _statusCtrl.stream;

  @override
  Future<void> startDiscovery() async {
    if (_discovering) return;
    _discovering = true;
    try {
      _devicesSub ??= _devicesChannel.receiveBroadcastStream().listen(
        (raw) {
          final list = (raw as List?) ?? const [];
          final devices = list
              .whereType<Map>()
              .map((m) => StreamingDevice(
                    id: '${m['id']}',
                    name: '${m['name'] ?? 'Cast device'}',
                    type: StreamingDeviceType.cast,
                    subtitle:
                        m['model'] != null ? '${m['model']}' : 'Chromecast',
                    extras: {
                      if (m['id'] != null) 'routeId': '${m['id']}',
                    },
                  ))
              .toList(growable: false);
          _devicesCtrl.add(devices);
        },
        onError: (e) => debugPrint('[cast] devices stream: $e'),
      );
      _statusSub ??= _statusChannel.receiveBroadcastStream().listen(
        (raw) {
          if (raw is! Map) return;
          _statusCtrl.add(RemotePlaybackSnapshot(
            position: Duration(
                milliseconds: (raw['positionMs'] as num?)?.toInt() ?? 0),
            duration: Duration(
                milliseconds: (raw['durationMs'] as num?)?.toInt() ?? 0),
            isPlaying: raw['isPlaying'] == true,
            isLoading: raw['isLoading'] == true,
            ended: raw['ended'] == true,
            error: raw['error'] as String?,
          ));
        },
        onError: (e) => debugPrint('[cast] status stream: $e'),
      );
      _commandsSub ??= _commandsChannel.receiveBroadcastStream().listen(
        (raw) {
          if (raw is! Map) return;
          final action = raw['action'] as String?;
          if (action != null && action.isNotEmpty) {
            _commandsCtrl.add(action);
          }
        },
        onError: (e) => debugPrint('[cast] commands stream: $e'),
      );
      await _methods.invokeMethod('startDiscovery');
    } on MissingPluginException {
      debugPrint('[cast] plugin missing (non-Android?)');
      _devicesCtrl.add(const []);
    } catch (e) {
      debugPrint('[cast] startDiscovery: $e');
      _devicesCtrl.add(const []);
    }
  }

  @override
  Future<void> stopDiscovery() async {
    _discovering = false;
    try {
      await _methods.invokeMethod('stopDiscovery');
    } catch (_) {}
  }

  @override
  Future<void> connect(StreamingDevice device) async {
    await _methods.invokeMethod('connect', {'deviceId': device.id});
  }

  @override
  Future<void> load({
    required String streamUrl,
    required String title,
    required String artist,
    String? artworkUrl,
    Duration position = Duration.zero,
    Duration duration = Duration.zero,
    String contentType = 'audio/mp4',
    Map<String, dynamic>? customData,
  }) async {
    await _methods.invokeMethod('load', {
      'url': streamUrl,
      'title': title,
      'artist': artist,
      'artworkUrl': artworkUrl,
      'positionMs': position.inMilliseconds,
      'durationMs': duration.inMilliseconds,
      'contentType': contentType,
      if (customData != null) 'customData': customData,
    });
  }

  @override
  Future<void> play() => _methods.invokeMethod('play');

  @override
  Future<void> pause() => _methods.invokeMethod('pause');

  @override
  Future<void> seek(Duration position) =>
      _methods.invokeMethod('seek', {'positionMs': position.inMilliseconds});

  @override
  Future<void> setVolume(double volume) =>
      _methods.invokeMethod('setVolume', {'volume': volume.clamp(0.0, 1.0)});

  @override
  Future<void> stop() async {
    try {
      await _methods.invokeMethod('stop');
    } catch (_) {}
  }

  @override
  Future<void> disconnect() async {
    try {
      await _methods.invokeMethod('disconnect');
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    await stopDiscovery();
    await disconnect();
    await _devicesSub?.cancel();
    await _statusSub?.cancel();
    await _commandsSub?.cancel();
    await _devicesCtrl.close();
    await _statusCtrl.close();
    await _commandsCtrl.close();
  }
}
