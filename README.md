# Track Watch

A Toggl Track client for Wear OS, with a companion Android phone app. Built with Flutter for the UI
and Kotlin for the background parts.

* **Watch:** start and stop timers, start favorites and recent entries with one tap, start a new
  timer (description by voice or keyboard, project from a list), browse the last 7 days of history
  with daily totals, and continue, edit (description and project) or delete entries. Also includes
  a **tile**, a **short-text complication** showing elapsed time, and an **Ongoing Activity** icon
  on the watch face while a timer runs.
* **Phone:** paste your Toggl API token, manage favorites (add, add from recent, reorder, delete),
  and check sync status.
* **Nothing is lost offline:** the watch queues commands until the phone is reachable, and the
  phone queues them until Toggl accepts them (no network, API quota reached, server errors).
  Offline starts and stops keep the time you tapped.

See [docs/SPEC.md](docs/SPEC.md) for the decisions and architecture.

## Project layout

```
lib/
  main_phone.dart, main_wear.dart   entry points (lib/main.dart = phone)
  src/                              shared Dart models, formatting, theme
  phone/                            phone settings UI + channel bridge
  wear/                             watch UI + channel bridge
android/app/src/
  main/kotlin/.../shared/           shared Kotlin: data model, optimistic reducer, queue logic
  phone/kotlin/                     Toggl API client, token store, queue, SyncWorker, Data Layer listener
  wear/kotlin/                      watch store, Data Layer listener, tile, complication, ongoing activity
  test/kotlin/                      JVM unit tests for the shared Kotlin logic
```

One Flutter project builds two APKs using the `phone` and `wear` flavors. Both use the same
application id (`su.iho.trackwatch`), which the Wearable Data Layer requires.

## Build

Requires Flutter 3.47+ and the Android SDK.

```sh
flutter pub get
flutter test
flutter build apk --release --flavor phone -t lib/main_phone.dart
flutter build apk --release --flavor wear  -t lib/main_wear.dart
```

The APKs are written to `build/app/outputs/flutter-apk/app-phone-release.apk` and `app-wear-release.apk`.
GitHub Actions (`.github/workflows/build.yml`) runs the tests and builds both APKs as a downloadable
artifact on every push.

### Signing (important)

The phone and watch apps only see each other if **both APKs are signed with the same key**.

* Local builds use your debug key, so this works when you build both APKs on the same machine.
* For a stable key, create `android/key.properties` (it is git-ignored):

  ```properties
  storeFile=/absolute/path/to/trackwatch.jks
  storePassword=...
  keyAlias=trackwatch
  keyPassword=...
  ```

* In CI, set the repository secrets `TRACKWATCH_KEYSTORE_BASE64` (`base64 -w0 trackwatch.jks`),
  `TRACKWATCH_KEYSTORE_PASSWORD`, `TRACKWATCH_KEY_ALIAS` and `TRACKWATCH_KEY_PASSWORD`. Without
  them, each CI run signs with a fresh debug key, so you have to uninstall the old apps before
  installing APKs from a different run.

## Install

```sh
# Phone (USB or wireless debugging)
adb -s <phone> install build/app/outputs/flutter-apk/app-phone-release.apk

# Watch: enable Developer options → ADB debugging + Wireless debugging on the watch, then
adb pair <watch-ip>:<pair-port>        # code shown on the watch
adb connect <watch-ip>:<port>
adb -s <watch-ip>:<port> install build/app/outputs/flutter-apk/app-wear-release.apk
```

Then:

1. Open **Track Watch** on the phone and paste your API token (Toggl Track → Profile → API Token).
2. Add favorites on the phone.
3. Open Track Watch on the watch. Allow notifications so the Ongoing Activity can be shown.
4. Optional: add the **Track Watch** tile, and the **Toggl timer** complication on your watch face.

## Notes

* On the watch, swipe right to go back. The system swipe-to-dismiss is disabled so the gesture
  works per screen instead of closing the app.
* The phone refreshes from Toggl when the watch app or tile opens, after each change, and every
  15 minutes. Projects are refreshed at most once an hour, to stay within Toggl's API quotas.
* If Toggl reports the API quota as exhausted (HTTP 402), the phone waits until the quota resets
  and then sends the queued changes. The phone app shows when it will retry.
