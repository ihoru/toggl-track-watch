# Contributing

Thanks for helping! Bug reports and pull requests are welcome.

## Setup
- Flutter 3.47+ (stable) and the Android SDK.
- `flutter pub get`, then `flutter test`.
- Run the phone app: `flutter run --flavor phone -t lib/main_phone.dart`;
  the watch app: `flutter run --flavor wear -t lib/main_wear.dart` (on a Wear OS emulator or watch).
  Both apps must be signed with the same key to talk to each other (see README → Signing).

## Pull requests
- Branch from `main`, keep changes focused, and describe what you tested on which devices.
- Before pushing: `dart format lib test`, `flutter analyze`, `flutter test`.
- Changes that ship in the apps bump `version:` in `pubspec.yaml` (the `+N` build number always;
  the version name for features or fixes) and add a line to `CHANGELOG.md` under that version.
- CI builds both APKs and launches them in phone and Wear OS emulators; it must be green.

## Code layout
See [README](README.md#project-layout) and [docs/SPEC.md](docs/SPEC.md).
