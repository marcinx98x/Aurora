/// One synced lyric line. [time] is seconds from track start.
class LyricLine {
  final double time;
  final String text;
  const LyricLine(this.time, this.text);
}

/// Result of a lyric lookup. [synced] is empty when only plain text exists.
class LyricsResult {
  final List<LyricLine> synced;
  final String plain;
  final bool found;
  final bool timingReliable;
  final String? timingIssue;
  final double? suggestedOffset;
  const LyricsResult({
    this.synced = const [],
    this.plain = '',
    this.found = false,
    this.timingReliable = true,
    this.timingIssue,
    this.suggestedOffset,
  });

  /// A timestamp beyond the end of the audio means this is an incompatible
  /// edit, not a simple delay. Keep its plain lyrics but disable highlighting.
  bool get isSynced =>
      synced.isNotEmpty && timingIssue != 'timestamps_outside_track';

  /// Active line at [positionSeconds], or -1 while an intro/dialogue is still
  /// playing before the first timestamp. A binary search also keeps this cheap
  /// for long lyric files and handles seeking backwards correctly.
  int activeIndexAt(double positionSeconds, {double offsetSeconds = 0}) {
    final adjustedPosition = positionSeconds - offsetSeconds;
    var low = 0;
    var high = synced.length - 1;
    var active = -1;
    while (low <= high) {
      final middle = low + ((high - low) >> 1);
      if (synced[middle].time <= adjustedPosition) {
        active = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return active;
  }
}
