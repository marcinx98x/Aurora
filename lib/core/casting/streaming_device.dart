/// A discovered or local playback target (phone, Cast, DLNA, Aurora).
enum StreamingDeviceType { local, cast, dlna, aurora }

class StreamingDevice {
  final String id;
  final String name;
  final StreamingDeviceType type;
  final bool isAvailable;
  final String? subtitle;

  /// Opaque native / protocol handle (Cast route id, DLNA control URL, …).
  final Map<String, String> extras;

  const StreamingDevice({
    required this.id,
    required this.name,
    required this.type,
    this.isAvailable = true,
    this.subtitle,
    this.extras = const {},
  });

  static const local = StreamingDevice(
    id: 'local',
    name: 'This phone',
    type: StreamingDeviceType.local,
    subtitle: 'Speaker / Bluetooth / headphones',
  );

  StreamingDevice copyWith({
    String? name,
    bool? isAvailable,
    String? subtitle,
    Map<String, String>? extras,
  }) =>
      StreamingDevice(
        id: id,
        name: name ?? this.name,
        type: type,
        isAvailable: isAvailable ?? this.isAvailable,
        subtitle: subtitle ?? this.subtitle,
        extras: extras ?? this.extras,
      );

  @override
  bool operator ==(Object other) =>
      other is StreamingDevice && other.id == id && other.type == type;

  @override
  int get hashCode => Object.hash(type, id);
}

/// Snapshot pushed by a remote transport while casting / controlling.
class RemotePlaybackSnapshot {
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final bool isLoading;
  final String? error;

  const RemotePlaybackSnapshot({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.isPlaying = false,
    this.isLoading = false,
    this.error,
  });

  RemotePlaybackSnapshot copyWith({
    Duration? position,
    Duration? duration,
    bool? isPlaying,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) =>
      RemotePlaybackSnapshot(
        position: position ?? this.position,
        duration: duration ?? this.duration,
        isPlaying: isPlaying ?? this.isPlaying,
        isLoading: isLoading ?? this.isLoading,
        error: clearError ? null : (error ?? this.error),
      );
}
