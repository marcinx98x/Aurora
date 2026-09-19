import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../db/local_store.dart';
import '../../domain/entities/lyric_line.dart';
import '../../domain/entities/track.dart';

/// Fetch lyrics for Cast customData (synced + plain). Best-effort — never throws.
Future<Map<String, dynamic>> lyricsCustomDataFor(
  Track track,
  LocalStore store,
) async {
  try {
    final cached = store.lyrics(track.id);
    if (cached != null && cached['matchVersion'] == 3) {
      return _toCustomData(cached);
    }
    final dio = Dio(BaseOptions(
      baseUrl: AppConfig.apiBase,
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 12),
      headers: AppConfig.apiSecretKey.isNotEmpty
          ? {'x-api-key': AppConfig.apiSecretKey}
          : null,
    ));
    final res = await dio.get('/lyrics', queryParameters: {
      'title': track.title,
      'artist': track.artist,
      'duration': track.duration.inSeconds,
    });
    final data = Map<String, dynamic>.from(res.data as Map);
    if (data['found'] == true && data['matchVersion'] == 3) {
      await store.saveLyrics(track.id, data);
    }
    return _toCustomData(data);
  } catch (e) {
    debugPrint('[cast-lyrics] $e');
    return {
      'title': track.title,
      'artist': track.artist,
      'artworkUrl': track.artworkUrl,
      'synced': <Map<String, dynamic>>[],
      'plain': '',
    };
  }
}

Map<String, dynamic> _toCustomData(Map<dynamic, dynamic> data) {
  final synced = ((data['synced'] as List?) ?? [])
      .whereType<Map>()
      .map((e) => {
            'time': (e['time'] as num?)?.toDouble() ?? 0.0,
            'text': '${e['text'] ?? ''}',
          })
      .toList(growable: false);
  return {
    'synced': synced,
    'plain': (data['plain'] as String?) ?? '',
  };
}

/// Serialize [LyricsResult] when already loaded in-memory.
Map<String, dynamic> lyricsResultToCustomData(LyricsResult r) => {
      'synced': r.synced
          .map((l) => {'time': l.time, 'text': l.text})
          .toList(growable: false),
      'plain': r.plain,
    };
