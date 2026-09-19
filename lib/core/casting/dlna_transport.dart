import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'remote_transport.dart';
import 'streaming_device.dart';

/// SSDP discovery + AVTransport SOAP control for DLNA renderers.
class DlnaTransport implements RemoteTransport {
  static const _ssdpAddr = '239.255.255.250';
  static const _ssdpPort = 1900;
  static const _searchTarget =
      'urn:schemas-upnp-org:service:AVTransport:1';

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 4),
    receiveTimeout: const Duration(seconds: 8),
  ));

  final _devicesCtrl =
      StreamController<List<StreamingDevice>>.broadcast();
  final _statusCtrl =
      StreamController<RemotePlaybackSnapshot>.broadcast();

  final Map<String, _DlnaRenderer> _known = {};
  StreamingDevice? _active;
  Timer? _pollTimer;
  Timer? _discoverTimer;
  bool _discovering = false;
  double _volume = 1.0;

  @override
  StreamingDeviceType get type => StreamingDeviceType.dlna;

  @override
  Stream<List<StreamingDevice>> get devices => _devicesCtrl.stream;

  @override
  Stream<RemotePlaybackSnapshot> get status => _statusCtrl.stream;

  @override
  Future<void> startDiscovery() async {
    if (_discovering) return;
    _discovering = true;
    await _scan();
    _discoverTimer =
        Timer.periodic(const Duration(seconds: 12), (_) => _scan());
  }

  @override
  Future<void> stopDiscovery() async {
    _discovering = false;
    _discoverTimer?.cancel();
    _discoverTimer = null;
  }

  Future<void> _scan() async {
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      socket.multicastHops = 4;
      final msg = 'M-SEARCH * HTTP/1.1\r\n'
          'HOST: $_ssdpAddr:$_ssdpPort\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 2\r\n'
          'ST: $_searchTarget\r\n'
          '\r\n';
      final bytes = utf8.encode(msg);
      final dest = InternetAddress(_ssdpAddr);
      for (var i = 0; i < 3; i++) {
        socket.send(bytes, dest, _ssdpPort);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }

      final locations = <String>{};
      final sub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = socket.receive();
        if (dg == null) return;
        final text = utf8.decode(dg.data, allowMalformed: true);
        final loc = _header(text, 'LOCATION') ?? _header(text, 'Location');
        if (loc != null && loc.isNotEmpty) locations.add(loc.trim());
      });

      await Future<void>.delayed(const Duration(seconds: 3));
      await sub.cancel();
      socket.close();

      for (final loc in locations) {
        await _resolveDevice(loc);
      }
      _emitDevices();
    } catch (e) {
      debugPrint('[dlna] scan: $e');
      _emitDevices();
    }
  }

  String? _header(String response, String name) {
    final re = RegExp('^$name:\\s*(.+)\\s*\$',
        caseSensitive: false, multiLine: true);
    return re.firstMatch(response)?.group(1);
  }

  Future<void> _resolveDevice(String location) async {
    try {
      final res = await _dio.get<String>(location);
      final body = res.data ?? '';
      if (body.isEmpty) return;
      final friendly = _xmlTag(body, 'friendlyName') ?? 'DLNA device';
      final udn = _xmlTag(body, 'UDN') ?? location;
      final base = Uri.parse(location);
      String? controlUrl;
      String? renderingControlUrl;
      final serviceBlocks =
          RegExp(r'<service>([\s\S]*?)</service>', caseSensitive: false)
              .allMatches(body);
      for (final m in serviceBlocks) {
        final block = m.group(1) ?? '';
        final type = _xmlTag(block, 'serviceType') ?? '';
        final path = _xmlTag(block, 'controlURL') ?? '';
        if (path.isEmpty) continue;
        final absolute = path.startsWith('http')
            ? path
            : base.resolve(path).toString();
        if (type.contains('AVTransport')) {
          controlUrl = absolute;
        } else if (type.contains('RenderingControl')) {
          renderingControlUrl = absolute;
        }
      }
      if (controlUrl == null) return;
      _known[udn] = _DlnaRenderer(
        id: udn,
        name: friendly,
        location: location,
        avTransportUrl: controlUrl,
        renderingControlUrl: renderingControlUrl,
      );
    } catch (e) {
      debugPrint('[dlna] resolve $location: $e');
    }
  }

  void _emitDevices() {
    final list = _known.values
        .map((r) => StreamingDevice(
              id: r.id,
              name: r.name,
              type: StreamingDeviceType.dlna,
              subtitle: 'DLNA / UPnP',
              extras: {
                'avTransportUrl': r.avTransportUrl,
                if (r.renderingControlUrl != null)
                  'renderingControlUrl': r.renderingControlUrl!,
                'location': r.location,
              },
            ))
        .toList(growable: false);
    _devicesCtrl.add(list);
  }

  @override
  Future<void> connect(StreamingDevice device) async {
    _active = device;
    _pollTimer?.cancel();
    _pollTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _pollStatus());
  }

  String get _avUrl =>
      _active?.extras['avTransportUrl'] ??
      (_known[_active?.id]?.avTransportUrl ?? '');

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
    final url = _avUrl;
    if (url.isEmpty) throw StateError('No DLNA AVTransport URL');
    final didl = _didl(streamUrl, title, artist, artworkUrl, contentType);
    await _soap(url, 'SetAVTransportURI', {
      'InstanceID': '0',
      'CurrentURI': streamUrl,
      'CurrentURIMetaData': didl,
    });
    if (position > Duration.zero) {
      await seek(position);
    }
    await play();
    _statusCtrl.add(RemotePlaybackSnapshot(
      position: position,
      duration: duration,
      isPlaying: true,
    ));
  }

  String _didl(
    String url,
    String title,
    String artist,
    String? art,
    String mime,
  ) {
    final artTag = art != null && art.isNotEmpty
        ? '<upnp:albumArtURI>${_xmlEsc(art)}</upnp:albumArtURI>'
        : '';
    return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="0" parentID="-1" restricted="1">'
        '<dc:title>${_xmlEsc(title)}</dc:title>'
        '<upnp:artist>${_xmlEsc(artist)}</upnp:artist>'
        '$artTag'
        '<upnp:class>object.item.audioItem.musicTrack</upnp:class>'
        '<res protocolInfo="http-get:*:$mime:*">${_xmlEsc(url)}</res>'
        '</item></DIDL-Lite>';
  }

  String _xmlEsc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  @override
  Future<void> play() async {
    final url = _avUrl;
    if (url.isEmpty) return;
    await _soap(url, 'Play', {'InstanceID': '0', 'Speed': '1'});
    _statusCtrl.add(const RemotePlaybackSnapshot(isPlaying: true));
  }

  @override
  Future<void> pause() async {
    final url = _avUrl;
    if (url.isEmpty) return;
    try {
      await _soap(url, 'Pause', {'InstanceID': '0'});
    } catch (_) {
      await _soap(url, 'Stop', {'InstanceID': '0'});
    }
    _statusCtrl.add(const RemotePlaybackSnapshot(isPlaying: false));
  }

  @override
  Future<void> seek(Duration position) async {
    final url = _avUrl;
    if (url.isEmpty) return;
    final t = _formatRelTime(position);
    try {
      await _soap(url, 'Seek', {
        'InstanceID': '0',
        'Unit': 'REL_TIME',
        'Target': t,
      });
    } catch (e) {
      debugPrint('[dlna] seek unsupported: $e');
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    final rc = _active?.extras['renderingControlUrl'] ??
        _known[_active?.id]?.renderingControlUrl;
    if (rc == null || rc.isEmpty) return;
    try {
      await _soap(rc, 'SetVolume', {
        'InstanceID': '0',
        'Channel': 'Master',
        'DesiredVolume': '${(_volume * 100).round()}',
      }, serviceType: 'urn:schemas-upnp-org:service:RenderingControl:1');
    } catch (e) {
      debugPrint('[dlna] setVolume: $e');
    }
  }

  @override
  Future<void> stop() async {
    final url = _avUrl;
    if (url.isEmpty) return;
    try {
      await _soap(url, 'Stop', {'InstanceID': '0'});
    } catch (_) {}
    _statusCtrl.add(const RemotePlaybackSnapshot(isPlaying: false));
  }

  @override
  Future<void> disconnect() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    await stop();
    _active = null;
  }

  Future<void> _pollStatus() async {
    final url = _avUrl;
    if (url.isEmpty) return;
    try {
      final body = await _soap(url, 'GetPositionInfo', {'InstanceID': '0'});
      final rel = _xmlTag(body, 'RelTime') ?? '0:00:00';
      final dur = _xmlTag(body, 'TrackDuration') ?? '0:00:00';
      final transport =
          await _soap(url, 'GetTransportInfo', {'InstanceID': '0'});
      final state = _xmlTag(transport, 'CurrentTransportState') ?? '';
      _statusCtrl.add(RemotePlaybackSnapshot(
        position: _parseRelTime(rel),
        duration: _parseRelTime(dur),
        isPlaying: state.toUpperCase() == 'PLAYING',
      ));
    } catch (_) {}
  }

  Future<String> _soap(
    String controlUrl,
    String action,
    Map<String, String> args, {
    String serviceType = 'urn:schemas-upnp-org:service:AVTransport:1',
  }) async {
    final argsXml = args.entries
        .map((e) => '<${e.key}>${_xmlEsc(e.value)}</${e.key}>')
        .join();
    final envelope =
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body>'
        '<u:$action xmlns:u="$serviceType">'
        '$argsXml'
        '</u:$action>'
        '</s:Body></s:Envelope>';
    final res = await _dio.post<String>(
      controlUrl,
      data: envelope,
      options: Options(headers: {
        'Content-Type': 'text/xml; charset="utf-8"',
        'SOAPACTION': '"$serviceType#$action"',
      }),
    );
    final code = res.statusCode ?? 0;
    if (code >= 400) {
      throw HttpException('DLNA $action failed: $code');
    }
    return res.data ?? '';
  }

  String? _xmlTag(String xml, String tag) {
    final re = RegExp('<$tag[^>]*>([^<]*)</$tag>', caseSensitive: false);
    return re.firstMatch(xml)?.group(1);
  }

  String _formatRelTime(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  Duration _parseRelTime(String t) {
    final parts = t.trim().split(':');
    if (parts.length < 3) return Duration.zero;
    final h = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;
    final sec = double.tryParse(parts[2]) ?? 0;
    return Duration(
      hours: h,
      minutes: m,
      milliseconds: (sec * 1000).round(),
    );
  }

  @override
  Future<void> dispose() async {
    await stopDiscovery();
    await disconnect();
    await _devicesCtrl.close();
    await _statusCtrl.close();
  }
}

class _DlnaRenderer {
  final String id;
  final String name;
  final String location;
  final String avTransportUrl;
  final String? renderingControlUrl;

  _DlnaRenderer({
    required this.id,
    required this.name,
    required this.location,
    required this.avTransportUrl,
    this.renderingControlUrl,
  });
}
