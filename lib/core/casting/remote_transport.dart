import 'streaming_device.dart';

/// Minimal remote playback surface. Queue stays in Dart.
abstract class RemoteTransport {
  StreamingDeviceType get type;

  Stream<List<StreamingDevice>> get devices;

  Stream<RemotePlaybackSnapshot> get status;

  Future<void> startDiscovery();

  Future<void> stopDiscovery();

  Future<void> connect(StreamingDevice device);

  Future<void> load({
    required String streamUrl,
    required String title,
    required String artist,
    String? artworkUrl,
    Duration position = Duration.zero,
    Duration duration = Duration.zero,
    String contentType = 'audio/mp4',
  });

  Future<void> play();

  Future<void> pause();

  Future<void> seek(Duration position);

  Future<void> setVolume(double volume);

  Future<void> stop();

  Future<void> disconnect();

  Future<void> dispose();
}
