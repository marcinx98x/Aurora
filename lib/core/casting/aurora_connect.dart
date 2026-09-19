import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'remote_transport.dart';
import 'streaming_device.dart';

const _nsdChannel = MethodChannel('aurora/nsd');
const _nsdDevices = EventChannel('aurora/nsd/devices');

/// Aurora Connect client: discovers peers via NSD and controls them over WS.
class AuroraConnectTransport implements RemoteTransport {
  final _devicesCtrl =
      StreamController<List<StreamingDevice>>.broadcast();
  final _statusCtrl =
      StreamController<RemotePlaybackSnapshot>.broadcast();

  StreamSubscription? _nsdSub;
  WebSocket? _socket;
  bool _discovering = false;

  @override
  StreamingDeviceType get type => StreamingDeviceType.aurora;

  @override
  Stream<List<StreamingDevice>> get devices => _devicesCtrl.stream;

  @override
  Stream<RemotePlaybackSnapshot> get status => _statusCtrl.stream;

  @override
  Future<void> startDiscovery() async {
    if (_discovering) return;
    _discovering = true;
    try {
      _nsdSub ??= _nsdDevices.receiveBroadcastStream().listen((raw) {
        final list = (raw as List?) ?? const [];
        final devices = list.whereType<Map>().map((m) {
          final host = '${m['host'] ?? ''}';
          final port = (m['port'] as num?)?.toInt() ?? 0;
          return StreamingDevice(
            id: '${m['id'] ?? '$host:$port'}',
            name: '${m['name'] ?? 'Aurora'}',
            type: StreamingDeviceType.aurora,
            subtitle: 'Aurora Connect',
            extras: {
              'host': host,
              'port': '$port',
            },
          );
        }).toList(growable: false);
        _devicesCtrl.add(devices);
      }, onError: (e) => debugPrint('[aurora] nsd: $e'));
      await _nsdChannel.invokeMethod('startDiscovery');
    } on MissingPluginException {
      _devicesCtrl.add(const []);
    } catch (e) {
      debugPrint('[aurora] startDiscovery: $e');
      _devicesCtrl.add(const []);
    }
  }

  @override
  Future<void> stopDiscovery() async {
    _discovering = false;
    try {
      await _nsdChannel.invokeMethod('stopDiscovery');
    } catch (_) {}
  }

  @override
  Future<void> connect(StreamingDevice device) async {
    await disconnect();
    final host = device.extras['host'] ?? '';
    final port = int.tryParse(device.extras['port'] ?? '') ?? 0;
    if (host.isEmpty || port == 0) {
      throw StateError('Aurora device missing host/port');
    }
    _socket = await WebSocket.connect('ws://$host:$port/aurora');
    _socket!.listen(_onMessage, onDone: () {
      _statusCtrl.add(const RemotePlaybackSnapshot(
        isPlaying: false,
        error: 'Disconnected from Aurora device',
      ));
    }, onError: (e) {
      _statusCtrl.add(RemotePlaybackSnapshot(
        isPlaying: false,
        error: '$e',
      ));
    });
    _send({'type': 'hello', 'name': 'Aurora Controller'});
  }

  void _onMessage(dynamic raw) {
    try {
      final map = jsonDecode(raw as String) as Map<String, dynamic>;
      if (map['type'] == 'state') {
        _statusCtrl.add(RemotePlaybackSnapshot(
          position: Duration(milliseconds: (map['positionMs'] as num?)?.toInt() ?? 0),
          duration: Duration(milliseconds: (map['durationMs'] as num?)?.toInt() ?? 0),
          isPlaying: map['isPlaying'] == true,
          isLoading: map['isLoading'] == true,
          error: map['error'] as String?,
        ));
      }
    } catch (e) {
      debugPrint('[aurora] bad message: $e');
    }
  }

  void _send(Map<String, dynamic> msg) {
    final s = _socket;
    if (s == null) return;
    s.add(jsonEncode(msg));
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
  }) async {
    _send({
      'type': 'load',
      'streamUrl': streamUrl,
      'title': title,
      'artist': artist,
      'artworkUrl': artworkUrl,
      'positionMs': position.inMilliseconds,
      'durationMs': duration.inMilliseconds,
      'contentType': contentType,
    });
    _statusCtrl.add(RemotePlaybackSnapshot(
      position: position,
      duration: duration,
      isPlaying: true,
      isLoading: true,
    ));
  }

  @override
  Future<void> play() async => _send({'type': 'play'});

  @override
  Future<void> pause() async => _send({'type': 'pause'});

  @override
  Future<void> seek(Duration position) async =>
      _send({'type': 'seek', 'positionMs': position.inMilliseconds});

  @override
  Future<void> setVolume(double volume) async =>
      _send({'type': 'volume', 'volume': volume.clamp(0.0, 1.0)});

  @override
  Future<void> stop() async => _send({'type': 'stop'});

  @override
  Future<void> disconnect() async {
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
  }

  @override
  Future<void> dispose() async {
    await stopDiscovery();
    await disconnect();
    await _nsdSub?.cancel();
    await _devicesCtrl.close();
    await _statusCtrl.close();
  }
}

/// LAN WebSocket receiver + NSD advertise so other Auroras can hand off.
class AuroraConnectReceiver {
  static const _nsd = MethodChannel('aurora/nsd');

  HttpServer? _server;
  final _clients = <WebSocket>{};
  int? _port;

  /// Called when a controller sends a command.
  void Function(Map<String, dynamic> msg)? onCommand;

  bool get isRunning => _server != null;
  int? get port => _port;

  Future<void> start({String serviceName = 'Aurora'}) async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _port = _server!.port;
    _server!.listen((req) async {
      if (req.uri.path == '/aurora' && WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        _clients.add(ws);
        ws.listen((data) {
          try {
            final map = jsonDecode(data as String) as Map<String, dynamic>;
            onCommand?.call(map);
          } catch (e) {
            debugPrint('[aurora-rx] bad cmd: $e');
          }
        }, onDone: () => _clients.remove(ws), onError: (_) => _clients.remove(ws));
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    });

    try {
      await _nsd.invokeMethod('advertise', {
        'name': serviceName,
        'port': _port,
      });
    } on MissingPluginException {
      debugPrint('[aurora-rx] NSD advertise unavailable');
    } catch (e) {
      debugPrint('[aurora-rx] advertise: $e');
    }
  }

  void broadcastState(RemotePlaybackSnapshot snap) {
    final payload = jsonEncode({
      'type': 'state',
      'positionMs': snap.position.inMilliseconds,
      'durationMs': snap.duration.inMilliseconds,
      'isPlaying': snap.isPlaying,
      'isLoading': snap.isLoading,
      'error': snap.error,
    });
    for (final c in List<WebSocket>.from(_clients)) {
      try {
        c.add(payload);
      } catch (_) {
        _clients.remove(c);
      }
    }
  }

  Future<void> stop() async {
    try {
      await _nsd.invokeMethod('stopAdvertise');
    } catch (_) {}
    for (final c in List<WebSocket>.from(_clients)) {
      await c.close();
    }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
    _port = null;
  }
}
