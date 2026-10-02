# Track Watch

Flutter UI (phone + Wear OS flavors) with a Kotlin native layer. See `README.md` and `docs/SPEC.md`.

## Rules
- **Bump the version on every change that ships in the APKs.** Edit `version:` in `pubspec.yaml`:
  increase the build number (`+N`) every time, and the version name (`1.2.0`) for user-visible
  features (minor) or fixes (patch). The installed version is shown in the phone's Sync details and
  on the watch's Sync page, so the user can confirm an update.
- With every version bump, add its section to `CHANGELOG.md`; the release workflow uses it as the
  release notes. For Play, also add `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt`
  (versionCode = build × 10 for the phone, build × 10 + 1 for the watch).
- Branches: `main` is the default branch. Work on a feature branch and open a pull request into `main`.
- After opening a pull request, always watch it: follow CI and reviews, and fix failures until it is green
  and mergeable.
- Releases: after merging to `main`, push a tag `v<version>` matching `pubspec.yaml`
  (see `docs/PUBLISHING.md`).
- Before pushing: `dart format lib test`, `flutter analyze`, `flutter test`.
- Android builds can't run in the cloud sandbox (dl.google.com is blocked); CI builds both APKs and
  smoke-tests them in emulators.
- The repository is public: never commit keys, tokens or `android/key.properties`.
