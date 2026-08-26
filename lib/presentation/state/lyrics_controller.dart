import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/config/app_config.dart';
import '../../domain/entities/lyric_line.dart';
import 'player_controller.dart';
import 'providers.dart';

LyricsResult _parse(Map<dynamic, dynamic> data) {
  final synced = ((data['synced'] as List?) ?? [])
      .map((e) => LyricLine(
            (e['time'] as num).toDouble(),
            e['text'] as String,
          ))
      .toList();
  return LyricsResult(
    synced: synced,
    plain: (data['plain'] as String?) ?? '',
    found: data['found'] == true || synced.isNotEmpty,
    timingReliable: data['timingReliable'] != false,
    timingIssue: data['timingIssue'] as String?,
    suggestedOffset: (data['suggestedOffset'] as num?)?.toDouble(),
  );
}

final _dio = Dio(BaseOptions(
  baseUrl: AppConfig.apiBase,
  connectTimeout: const Duration(seconds: 8),
  receiveTimeout: const Duration(seconds: 15),
  headers: AppConfig.apiSecretKey.isNotEmpty
      ? {'x-api-key': AppConfig.apiSecretKey}
      : null,
));

String _offsetKey(String trackId) => 'lyrics_offset_$trackId';

/// Per-track manual correction in milliseconds. Positive values delay lyrics.
final lyricsOffsetProvider = StateProvider.autoDispose.family<int, String>(
  (ref, trackId) =>
      ref.read(localStoreProvider).number(_offsetKey(trackId)) ?? 0,
);

Future<void> setLyricsOffset(WidgetRef ref, String trackId, int millis) async {
  final value = millis.clamp(-120000, 120000);
  ref.read(lyricsOffsetProvider(trackId).notifier).state = value;
  await ref.read(localStoreProvider).setNumber(_offsetKey(trackId), value);
}

/// Lyrics for the current track. Uses offline-saved lyrics first (downloaded
/// alongside the track), then falls back to the lrclib resolver.
final lyricsProvider = FutureProvider.autoDispose<LyricsResult>((ref) async {
  final track = ref.watch(playerControllerProvider.select((s) => s.current));
  if (track == null) return const LyricsResult();

  // Offline cache (saved when the track was downloaded).
  final cached = ref.read(localStoreProvider).lyrics(track.id);
  // Older cache entries were produced before the server validated title,
  // artist and duration, so they may belong to another song.
  if (cached?['matchVersion'] == 3) return _parse(cached!);

  final res = await _dio.get('/lyrics', queryParameters: {
    'title': track.title,
    'artist': track.artist,
    'duration': track.duration.inSeconds,
  });
  final data = Map<String, dynamic>.from(res.data as Map);
  if (data['found'] == true && data['matchVersion'] == 3) {
    await ref.read(localStoreProvider).saveLyrics(track.id, data);
  }
  return _parse(data);
});
