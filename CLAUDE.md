# Track Watch

Flutter UI (phone + Wear OS flavors) with a Kotlin native layer. See `README.md` and `docs/SPEC.md`.

## Rules
- **Every change that ships in the APKs adds a changelog fragment** `changelog.d/<PR number or
  topic>.md` with `### Added` / `### Changed` / `### Fixed` entries (see `changelog.d/README.md`).
  Pull requests never edit `version:` in `pubspec.yaml`, `CHANGELOG.md` or the Play notes in
  `fastlane/metadata/android/en-US/changelogs/`: the **Prepare release** workflow bumps the version
  (minor with an Added entry, otherwise patch), assembles those from the fragments and commits
  them to `main`. That keeps parallel pull requests from conflicting.
- Branches: `main` is the default branch. Work on a feature branch and open a pull request into `main`.
- After opening a pull request, always watch it: follow CI and reviews, and fix failures until it is green
  and mergeable.
- Releases: Iggy runs **Actions → Prepare release**; its commit to `main` makes the release workflow
  build and publish the version and create the tag `v<version>` (see `docs/PUBLISHING.md`).
- Before pushing: `dart format lib test`, `flutter analyze`, `flutter test`.
- Android builds can't run in the cloud sandbox (dl.google.com is blocked); CI builds both APKs and
  smoke-tests them in emulators.
- The repository is public: never commit keys, tokens or `android/key.properties`.
