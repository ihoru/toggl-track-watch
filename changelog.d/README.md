# Entries for the next release

Every pull request that changes something users or developers notice adds its own file here,
`changelog.d/<PR number or short topic>.md`, with [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
sections:

```markdown
### Added
- Watch: **Compact favorites** in Settings shows the Favorites page as small buttons.
### Fixed
- Phone: the favorites list keeps its scroll position after a sync.
```

Sections: Added, Changed, Deprecated, Removed, Fixed, Security. Continue a long entry on lines
indented by two spaces. Pull requests don't edit `CHANGELOG.md`, the version in `pubspec.yaml` or
the Play notes in `fastlane/.../changelogs/`, so parallel pull requests don't conflict.

**Actions → Prepare release → Run workflow** (`scripts/release.py`) then bumps the version (minor
when there is an Added entry, otherwise patch, unless chosen), moves these entries into a new
`CHANGELOG.md` section in merge order, writes Play's "What's new" from them, deletes the files and
commits that to `main`, which builds and publishes the release.
