"""Tests for release.py: python3 -m unittest discover -s scripts"""

import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import release

CHANGELOG = """# Changelog

Intro.

## [1.10.3] - 2026-10-10
### Changed
- Old entry.
"""


class ParseTest(unittest.TestCase):
    def test_sections_and_continuation_lines(self) -> None:
        sections = release.parse("a.md", "### Added\n- One\n  more.\n\n### Fixed\n- Two\n")
        self.assertEqual(sections, {"Added": ["- One\n  more."], "Fixed": ["- Two"]})

    def test_errors(self) -> None:
        for text in ["- No heading\n", "### Misc\n- x\n", "### Added\nplain text\n", "### Added\n", "### Added\n- \n", ""]:
            with self.subTest(text=text), self.assertRaises(release.FragmentError):
                release.parse("a.md", text)


class VersionTest(unittest.TestCase):
    pubspec = "name: x\nversion: 1.10.3+20\n"

    def test_bumps(self) -> None:
        added = {"Added": ["- x"]}
        changed = {"Changed": ["- x"]}
        self.assertEqual(release.bumped(self.pubspec, "auto", added), ("1.11.0", 21))
        self.assertEqual(release.bumped(self.pubspec, "auto", changed), ("1.10.4", 21))
        self.assertEqual(release.bumped(self.pubspec, "minor", changed), ("1.11.0", 21))
        self.assertEqual(release.bumped(self.pubspec, "major", changed), ("2.0.0", 21))
        with self.assertRaises(release.FragmentError):
            release.bumped(self.pubspec, "huge", changed)


class PlayNotesTest(unittest.TestCase):
    def test_plain_text(self) -> None:
        sections = {"Added": ["- Watch: **Compact** `favorites`, see\n  [docs](https://x)."]}
        self.assertEqual(release.play_notes("1.0.0", sections), "Watch: Compact favorites, see docs.\n")

    def test_cut_to_play_limit(self) -> None:
        sections = {"Changed": [f"- {'a' * 200}", f"- {'b' * 200}", f"- {'c' * 200}"]}
        notes = release.play_notes("1.2.3", sections)
        self.assertLessEqual(len(notes), 500)
        self.assertIn("b" * 200, notes)
        self.assertNotIn("c" * 200, notes)
        self.assertTrue(notes.endswith("/releases/tag/v1.2.3\n"))

    def test_cut_long_first_entry(self) -> None:
        notes = release.play_notes("1.2.3", {"Changed": [f"- {'a' * 600}"]})
        self.assertLessEqual(len(notes), 500)
        self.assertTrue(notes.startswith("a" * 400))
        self.assertIn("…\nMore: ", notes)

    def test_cut_long_later_entry(self) -> None:
        notes = release.play_notes("1.2.3", {"Changed": ["- Short.", f"- {'a' * 600}"]})
        self.assertLessEqual(len(notes), 500)
        self.assertTrue(notes.startswith("Short.\n" + "a" * 300))
        self.assertIn("…\nMore: ", notes)


class PrepareTest(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        (self.root / "changelog.d").mkdir()
        (self.root / "changelog.d/README.md").write_text("How to write fragments.\n")
        (self.root / "fastlane/metadata/android/en-US/changelogs").mkdir(parents=True)
        (self.root / "pubspec.yaml").write_text("name: x\nversion: 1.10.3+20\n")
        (self.root / "CHANGELOG.md").write_text(CHANGELOG)
        self.git("init", "-q")
        self.git("add", ".")
        self.git("commit", "-qm", "init")
        for name, value in {
            "ROOT": self.root,
            "FRAGMENTS": self.root / "changelog.d",
            "CHANGELOG": self.root / "CHANGELOG.md",
            "PUBSPEC": self.root / "pubspec.yaml",
            "PLAY_NOTES": self.root / "fastlane/metadata/android/en-US/changelogs",
        }.items():
            patcher = mock.patch.object(release, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def git(self, *args: str) -> None:
        subprocess.run(
            ["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], cwd=self.root, check=True
        )

    def merge(self, name: str, text: str) -> None:
        (self.root / "changelog.d" / name).write_text(text)
        self.git("add", ".")
        self.git("commit", "-qm", name)

    def test_assembles_in_merge_order(self) -> None:
        # Named so that alphabetical order differs from merge order.
        self.merge("zz-fix.md", "### Fixed\n- Fix.\n")
        self.merge("aa-feature.md", "### Added\n- Feature.\n### Fixed\n- Second fix.\n")
        self.assertEqual(release.prepare("auto", date="2026-10-13"), "1.11.0")
        self.assertIn("version: 1.11.0+21\n", (self.root / "pubspec.yaml").read_text())
        self.assertEqual(
            (self.root / "CHANGELOG.md").read_text(),
            "# Changelog\n\nIntro.\n\n## [1.11.0] - 2026-10-13\n### Added\n- Feature.\n"
            "### Fixed\n- Fix.\n- Second fix.\n\n## [1.10.3] - 2026-10-10\n### Changed\n- Old entry.\n",
        )
        notes = self.root / "fastlane/metadata/android/en-US/changelogs"
        self.assertEqual((notes / "210.txt").read_text(), "Feature.\nFix.\nSecond fix.\n")
        self.assertEqual((notes / "211.txt").read_text(), "Feature.\nFix.\nSecond fix.\n")
        self.assertEqual(
            sorted(p.name for p in (self.root / "changelog.d").iterdir()), ["README.md"]
        )

    def test_note_without_fragments(self) -> None:
        with self.assertRaises(release.FragmentError):
            release.prepare("auto")
        self.assertEqual(release.prepare("auto", "Updated libraries.", "2026-10-13"), "1.10.4")
        self.assertIn("### Changed\n- Updated libraries.\n", (self.root / "CHANGELOG.md").read_text())

    def test_invalid_fragment_changes_nothing(self) -> None:
        self.merge("bad.md", "no heading\n")
        with self.assertRaises(release.FragmentError):
            release.prepare("auto")
        self.assertIn("version: 1.10.3+20\n", (self.root / "pubspec.yaml").read_text())
        self.assertTrue((self.root / "changelog.d/bad.md").exists())


if __name__ == "__main__":
    unittest.main()
