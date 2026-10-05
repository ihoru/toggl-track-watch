# Changelog

All notable changes. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions match `version:` in `pubspec.yaml`. The release workflow publishes the section of the
tagged version as the GitHub Release notes.

## [1.6.1] - 2026-10-05
### Fixed
- The watch APK installs on watches with a 32-bit userspace (such as Galaxy Watch 4-6 and Pixel
  Watch 1-2), which rejected the arm64-only APK with `INSTALL_FAILED_NO_MATCHING_ABIS`.

## [1.6.0] - 2026-10-05
### Added
- Phone app: ⋮ menu with the privacy policy, source code and app version.
### Changed
- Google Play preparation: app bundles carry native debug symbols, Play releases get "What's new"
  notes and a configurable track, and the store listing is uploaded from the repository.

## [1.5.0] - 2026-10-05
### Added
- Watch: a **Recent** page after Favorites with up to 30 distinct timers of the last 30 days, most
  recent first. Tap one to start it.
### Changed
- Watch: the Frequent page leaves out timers that are already favorites and shows up to 30 timers.
- Releases are published automatically when a new version is merged to `main`; no manual tag needed.

## [1.4.2] - 2026-10-05
### Fixed
- Watch battery: background syncs on the phone no longer wake the watch when nothing changed (only
  the sync time and API quota moved). Timers started or stopped elsewhere still reach the watch
  within 15 minutes; the watch's Sync page catches up as soon as the app or tile opens.
- Watch battery: the tile no longer refreshes itself every minute, and the tile and complication
  are only updated when what they show changed.
- The running-timer indicator no longer flickers: it shows "description · since 9:41" instead of a
  ticking stopwatch, and isn't re-posted when the watch app restarts in the background.
- Running clocks in the watch app stop ticking while the app is in the background.

## [1.4.1] - 2026-10-02
### Changed
- Watch tile: while a timer runs, the bottom button is **Open** (opens the app) instead of **Stop**.
  Stop is still in the app and in the running-timer notification.

## [1.4.0] - 2026-09-29
### Added
- Watch settings screen (Sync page → Settings): running-timer notification on/off, vibration on/off,
  crown step for editing the start time (1 or 5 minutes), privacy policy and source code links.
- When the phone app isn't set up, the watch offers **Install on phone** and **Open on phone**.
- Tagged releases: GitHub Releases with the APKs, and uploads to Google Play when configured.
### Changed
- Phone and watch get distinct Android version codes (build × 10, + 1 on the watch), as Google Play
  requires. The apps still show the pubspec build number.
- Build uses Android Gradle Plugin's built-in Kotlin support.

## [1.3.2] - 2026-09-29
### Changed
- Start-time editor steps are −15 / −5 / +5 / +15 minutes.

## [1.3.1] - 2026-09-29
### Changed
- Much smaller APKs: arm64-only, Dart debug info stripped, unused resources removed.

## [1.3.0] - 2026-09-28
### Added
- Edit the start time of the running timer on the watch (crown or buttons).
### Fixed
- Swiping right on the watch's first page closes the app again.

## [1.2.0] - 2026-09-28
### Added
- The phone app backs up the Toggl token, favorites and settings with Google Block Store and restores
  them after a reinstall.

## [1.1.0] - 2026-09-28
### Added
- Watch: five pages (Now, Favorites, Frequent, History, Sync), frequent timers of the last 30 days,
  Cancel for the running timer, remembered positions, ambient mode, Open on phone.
- Tile with up to six timers in two columns.
- Phone: swipe right to start a favorite, delete confirmation, compact list, API quota display.
- The installed version is shown in both apps.

## [1.0.0] - 2026-09-26
### Added
- First version: phone settings app and Wear OS app for Toggl Track with offline queue, tile,
  complication and Ongoing Activity.

[1.6.0]: https://github.com/ihoru/toggl-track-watch/releases/tag/v1.6.0
[1.5.0]: https://github.com/ihoru/toggl-track-watch/releases/tag/v1.5.0
[1.4.2]: https://github.com/ihoru/toggl-track-watch/releases/tag/v1.4.2
[1.4.1]: https://github.com/ihoru/toggl-track-watch/releases/tag/v1.4.1
[1.4.0]: https://github.com/ihoru/toggl-track-watch/releases/tag/v1.4.0
