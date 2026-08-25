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


if __name__ == "__main__":
    unittest.main()
