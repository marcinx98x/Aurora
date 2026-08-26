import 'package:flutter_test/flutter_test.dart';
import 'package:aurora_music/core/utils/formatters.dart';
import 'package:aurora_music/domain/entities/lyric_line.dart';

void main() {
  group('Fmt.duration', () {
    test('formats minutes:seconds', () {
      expect(Fmt.duration(const Duration(seconds: 215)), '3:35');
    });
    test('formats hours:minutes:seconds', () {
      expect(Fmt.duration(const Duration(seconds: 3725)), '1:02:05');
    });
  });

  group('Fmt.compact', () {
    test('millions', () => expect(Fmt.compact(12300000), '12.3M'));
    test('thousands', () => expect(Fmt.compact(4200), '4.2K'));
  });

  group('LyricsResult.activeIndexAt', () {
    const lyrics = LyricsResult(
      found: true,
      synced: [
        LyricLine(48.0, 'First line'),
        LyricLine(55.5, 'Second line'),
        LyricLine(62.0, 'Third line'),
      ],
    );

    test('has no active line during spoken intro', () {
      expect(lyrics.activeIndexAt(0), -1);
      expect(lyrics.activeIndexAt(47.99), -1);
    });

    test('activates lines at their timestamp', () {
      expect(lyrics.activeIndexAt(48), 0);
      expect(lyrics.activeIndexAt(60), 1);
      expect(lyrics.activeIndexAt(62), 2);
    });

    test('returns to intro state after a backwards seek', () {
      expect(lyrics.activeIndexAt(70), 2);
      expect(lyrics.activeIndexAt(20), -1);
    });

    test('applies a positive per-track delay', () {
      expect(lyrics.activeIndexAt(50, offsetSeconds: 5), -1);
      expect(lyrics.activeIndexAt(53, offsetSeconds: 5), 0);
      expect(lyrics.activeIndexAt(61, offsetSeconds: 5), 1);
    });
  });
}
