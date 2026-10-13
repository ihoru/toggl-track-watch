"""Assembles a release from the changelog.d/ fragments.

Every pull request adds its own file changelog.d/<name>.md instead of editing CHANGELOG.md or the
version, so parallel pull requests don't conflict. A fragment holds Keep a Changelog sections:

    ### Added
    - Watch: a new page.

`check` validates the fragments (CI on pull requests).

`prepare BUMP [NOTE]` (the Prepare release workflow) bumps `version:` in pubspec.yaml (the build
number always, the version name by BUMP: auto, patch, minor or major; auto is minor when a fragment
has an Added section, else patch), adds the version's section to CHANGELOG.md with the fragments'
entries in the order they were merged, writes Play's "What's new" files for the new build and
deletes the fragments. NOTE is used as a Changed entry when there are no fragments (for example a
release of library updates only). Prints the new version.

Runs on the runner's system python3, without dependencies.
"""

import datetime
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FRAGMENTS = ROOT / "changelog.d"
CHANGELOG = ROOT / "CHANGELOG.md"
PUBSPEC = ROOT / "pubspec.yaml"
PLAY_NOTES = ROOT / "fastlane/metadata/android/en-US/changelogs"
RELEASES_URL = "https://github.com/ihoru/toggl-track-watch/releases"
# Keep a Changelog order.
SECTIONS = ["Added", "Changed", "Deprecated", "Removed", "Fixed", "Security"]
# Play allows 500 characters; the release workflow counts the trailing newline too.
PLAY_LIMIT = 499
VERSION = re.compile(r"^version: (\d+)\.(\d+)\.(\d+)\+(\d+)$", re.MULTILINE)


class FragmentError(Exception):
    pass


def parse(name: str, text: str) -> dict[str, list[str]]:
    """Section name → entries; an entry is a "- " line with its indented continuation lines."""
    sections: dict[str, list[str]] = {}
    current: list[str] | None = None
    for line in text.splitlines():
        if not line.strip():
            continue
        if line.startswith("### "):
            title = line[4:].strip()
            if title not in SECTIONS:
                raise FragmentError(f"{name}: unknown section '{title}' (use {', '.join(SECTIONS)})")
            current = sections.setdefault(title, [])
        elif current is None:
            raise FragmentError(f"{name}: text before the first '### Section' heading")
        elif line.startswith("- "):
            if not line[2:].strip():
                raise FragmentError(f"{name}: empty '- ' entry")
            current.append(line)
        elif line.startswith("  ") and current:
            current[-1] += "\n" + line
        else:
            raise FragmentError(f"{name}: expected a '- ' entry, got '{line}'")
    if not any(sections.values()):
        raise FragmentError(f"{name}: no entries")
    return sections


def fragment_paths() -> list[Path]:
    """Fragments in the order they were added to the branch's history, unknown ones last."""
    paths = [p for p in FRAGMENTS.glob("*.md") if p.name != "README.md"]
    try:
        log = subprocess.run(
            ["git", "log", "--first-parent", "--reverse", "--diff-filter=A", "--format=",
             "--name-only", "--", "changelog.d/"],
            cwd=ROOT, check=True, capture_output=True, text=True,
        ).stdout.splitlines()
    except (OSError, subprocess.CalledProcessError):
        log = []
    order = {}
    for position, line in enumerate(log):
        # A name freed by an earlier release can come back: its last addition counts.
        order[Path(line).name] = position
    return sorted(paths, key=lambda p: (order.get(p.name, len(log)), p.name))


def read_fragments() -> list[tuple[str, dict[str, list[str]]]]:
    return [(p.name, parse(p.name, p.read_text(encoding="utf-8"))) for p in fragment_paths()]


def merged(fragments: list[tuple[str, dict[str, list[str]]]]) -> dict[str, list[str]]:
    result: dict[str, list[str]] = {}
    for title in SECTIONS:
        entries = [e for _, sections in fragments for e in sections.get(title, [])]
        if entries:
            result[title] = entries
    return result


def bumped(text: str, bump: str, sections: dict[str, list[str]]) -> tuple[str, int]:
    match = VERSION.search(text)
    if match is None:
        raise FragmentError("pubspec.yaml has no 'version: x.y.z+N' line")
    major, minor, patch, build = map(int, match.groups())
    if bump == "auto":
        bump = "minor" if "Added" in sections else "patch"
    if bump == "major":
        major, minor, patch = major + 1, 0, 0
    elif bump == "minor":
        minor, patch = minor + 1, 0
    elif bump == "patch":
        patch += 1
    else:
        raise FragmentError(f"Unknown bump '{bump}' (auto, patch, minor or major)")
    return f"{major}.{minor}.{patch}", build + 1


def section(version: str, date: str, sections: dict[str, list[str]]) -> str:
    lines = [f"## [{version}] - {date}"]
    for title, entries in sections.items():
        lines += [f"### {title}", *entries]
    return "\n".join(lines) + "\n"


def with_section(changelog: str, text: str) -> str:
    """Inserts the section above the newest one (or at the end of an empty changelog)."""
    index = changelog.find("\n## [")
    if index < 0:
        return changelog.rstrip("\n") + "\n\n" + text
    return changelog[: index + 1] + text + "\n" + changelog[index + 1 :]


def plain(entry: str) -> str:
    text = " ".join(line.strip() for line in entry.splitlines()).removeprefix("- ")
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    return text.replace("**", "").replace("`", "")


def play_notes(version: str, sections: dict[str, list[str]]) -> str:
    """Play's "What's new" (at most 500 characters): the entries as plain text, cut to fit."""
    entries = [plain(e) for title in sections for e in sections[title]]
    more = f"More: {RELEASES_URL}/tag/v{version}"
    text = "\n".join(entries)
    if len(text) <= PLAY_LIMIT:
        return text + "\n"
    kept: list[str] = []
    for entry in entries:
        if len("\n".join([*kept, entry, more])) > PLAY_LIMIT:
            if not kept:
                # Keep the start of an entry that is too long on its own.
                room = PLAY_LIMIT - len(more) - 2
                kept.append(entry[:room].rstrip() + "…")
            break
        kept.append(entry)
    return "\n".join([*kept, more]) + "\n"


def prepare(bump: str, note: str = "", date: str | None = None) -> str:
    fragments = read_fragments()
    sections = merged(fragments)
    if not sections:
        if not note.strip():
            raise FragmentError("Nothing to release: changelog.d/ has no fragments and no note was given")
        sections = {"Changed": [f"- {note.strip()}"]}
    pubspec = PUBSPEC.read_text(encoding="utf-8")
    version, build = bumped(pubspec, bump, sections)
    date = date or datetime.datetime.now(datetime.timezone.utc).date().isoformat()
    PUBSPEC.write_text(VERSION.sub(f"version: {version}+{build}", pubspec, count=1), encoding="utf-8")
    changelog = CHANGELOG.read_text(encoding="utf-8")
    CHANGELOG.write_text(with_section(changelog, section(version, date, sections)), encoding="utf-8")
    notes = play_notes(version, sections)
    # versionCode: build × 10 for the phone, build × 10 + 1 for the watch.
    for code in (build * 10, build * 10 + 1):
        (PLAY_NOTES / f"{code}.txt").write_text(notes, encoding="utf-8")
    for name, _ in fragments:
        (FRAGMENTS / name).unlink()
    return version


def main(argv: list[str]) -> int:
    try:
        if argv == ["check"]:
            fragments = read_fragments()
            print(f"{len(fragments)} changelog fragment(s) OK")
            return 0
        if len(argv) in (2, 3) and argv[0] == "prepare":
            print(prepare(argv[1], argv[2] if len(argv) == 3 else ""))
            return 0
    except FragmentError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    print("Usage: release.py check | prepare auto|patch|minor|major [NOTE]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
