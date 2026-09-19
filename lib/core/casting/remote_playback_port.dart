import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/track.dart';
import 'streaming_device.dart';

/// Thin port so [PlayerController] never imports devices_controller.
abstract class RemotePlaybackPort {
  bool get isActive;

  Stream<RemotePlaybackSnapshot> get snapshots;

  Future<void> play();

  Future<void> pause();

  Future<void> seek(Duration position);

  Future<void> setVolume(double volume);

  Future<void> loadTrack(
    Track track,
    Uri streamUri, {
    Duration position = Duration.zero,
    Duration duration = Duration.zero,
  });
}

class InactiveRemotePlaybackPort implements RemotePlaybackPort {
  const InactiveRemotePlaybackPort();

  @override
  bool get isActive => false;

  @override
  Stream<RemotePlaybackSnapshot> get snapshots => const Stream.empty();

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> loadTrack(
    Track track,
    Uri streamUri, {
    Duration position = Duration.zero,
    Duration duration = Duration.zero,
  }) async {}
}

/// Overridden by DevicesController when a remote device is selected.
final remotePlaybackPortProvider =
    StateProvider<RemotePlaybackPort>((ref) => const InactiveRemotePlaybackPort());
