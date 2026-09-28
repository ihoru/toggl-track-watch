# Track Watch

Flutter UI (phone + Wear OS flavors) with a Kotlin native layer. See `README.md` and `docs/SPEC.md`.

## Rules
- **Bump the version on every change that ships in the APKs.** Edit `version:` in `pubspec.yaml`:
  increase the build number (`+N`) every time, and the version name (`1.2.0`) for user-visible
  features (minor) or fixes (patch). The installed version is shown in the phone's Sync details and
  on the watch's Sync page, so the user can confirm an update.
- Before pushing: `dart format lib test`, `flutter analyze`, `flutter test`.
- Android builds can't run in the cloud sandbox (dl.google.com is blocked); CI builds both APKs and
  smoke-tests them in emulators.
