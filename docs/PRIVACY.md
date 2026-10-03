# Privacy policy

*Last updated: 2026-10-03*

Track Watch is an unofficial companion app for [Toggl Track](https://toggl.com/track/), made by
Ihor Polyakov. This policy covers the Track Watch phone app and Wear OS app.

## What the app handles
- **Your Toggl Track API token**, which you paste into the phone app. It's stored encrypted on your
  phone (Android Keystore) and never sent to the watch.
- **Your Toggl Track data** the app needs to work: time entries of the last 30 days, projects and
  your account's name, email address and default workspace. The name and email are only shown in
  the phone app; they stay on the phone.
- **Your favorites and app settings.**

## Where it goes
- The phone app talks **only to Toggl's API** (`api.track.toggl.com`) with your token, to read and
  change your time entries. Toggl's own [privacy policy](https://toggl.com/legal/privacy/) applies there.
- The phone and watch exchange time entries, projects and favorites over the Wear OS connection
  (Google Play services Wearable Data Layer), directly between your devices.
- **Backup:** the token, favorites and settings (not your time entries) are saved with Google Play services **Block Store**
  so they survive reinstalling. With a screen lock set, the backup is end-to-end encrypted in your
  Google account; otherwise it stays on the device. The developer can't read it.

## What the app doesn't do
- No analytics, ads, tracking or crash reporting.
- No servers of its own; nothing is sent to the developer.
- No data is sold or shared with anyone besides Toggl (for the time tracking you ask it to do).

## Deleting your data
- In the phone app, **Change token** removes the token from the phone and from the backup.
- Uninstalling both apps deletes everything they stored on your devices. The Block Store backup is
  kept by Google Play services while Google backup is on, and deleted when you remove the app's
  backup data in your Google account.
- Your time entries remain in your Toggl Track account.

## Contact
Questions: email <ihor.polyakov@gmail.com> or open an issue at
<https://github.com/ihoru/toggl-track-watch/issues>.
