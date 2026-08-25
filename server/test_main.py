import os
import tempfile
import unittest

from fastapi import HTTPException

import main


class PromoteDownloadTest(unittest.TestCase):
    def test_ignores_partial_downloads(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            partial = os.path.join(work, "track.m4a.part")
            target = os.path.join(work, "cached.mp4")
            with open(partial, "wb") as file:
                file.write(b"incomplete")

            self.assertIsNone(main._promote_download(work, target))
            self.assertFalse(os.path.exists(target))

    def test_atomically_promotes_completed_media(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            completed = os.path.join(work, "track.m4a")
            target = os.path.join(work, "cached.mp4")
            with open(completed, "wb") as file:
                file.write(b"complete audio")

            self.assertEqual(main._promote_download(work, target), target)
            with open(target, "rb") as file:
                self.assertEqual(file.read(), b"complete audio")
            self.assertFalse(os.path.exists(completed))


class ParseRangeTest(unittest.TestCase):
    def test_parses_normal_open_and_suffix_ranges(self) -> None:
        self.assertEqual(main._parse_range("bytes=2-5", 10), (2, 5))
        self.assertEqual(main._parse_range("bytes=7-", 10), (7, 9))
        self.assertEqual(main._parse_range("bytes=-3", 10), (7, 9))

    def test_rejects_unsatisfiable_ranges(self) -> None:
        for value in ("bytes=10-", "bytes=8-2", "bytes=-0", "not-a-range"):
            with self.subTest(value=value), self.assertRaises(HTTPException) as caught:
                main._parse_range(value, 10)
            self.assertEqual(caught.exception.status_code, 416)
            self.assertEqual(caught.exception.headers, {"Content-Range": "bytes */10"})


class LyricsMatchTest(unittest.TestCase):
    def setUp(self) -> None:
        self.identities = main._lyric_identities(
            "Adele - Hello (Official Video)", "AdeleVEVO"
        )

    def test_selects_identity_match_instead_of_first_synced_result(self) -> None:
        wrong = {
            "id": 1,
            "trackName": "Hello",
            "artistName": "Lionel Richie",
            "duration": 241,
            "syncedLyrics": "[00:01.00]Wrong song",
        }
        correct = {
            "id": 2,
            "trackName": "Hello",
            "artistName": "Adele",
            "duration": 295,
            "plainLyrics": "Correct song",
        }

        selected = main._select_lyric_hit(
            [wrong, correct], self.identities, duration=295
        )

        self.assertIs(selected, correct)

    def test_rejects_wrong_version_by_duration(self) -> None:
        live_version = {
            "trackName": "Hello",
            "artistName": "Adele",
            "duration": 360,
            "syncedLyrics": "[00:01.00]Live version",
        }

        self.assertIsNone(main._select_lyric_hit(
            [live_version], self.identities, duration=295
        ))

    def test_accepts_topic_channel_artist(self) -> None:
        identities = main._lyric_identities(
            "Blinding Lights", "The Weeknd - Topic"
        )
        hit = {
            "trackName": "Blinding Lights",
            "artistName": "The Weeknd",
            "duration": 200,
            "syncedLyrics": "[00:01.00]Yeah",
        }

        self.assertIs(main._select_lyric_hit([hit], identities, 200), hit)


if __name__ == "__main__":
    unittest.main()
