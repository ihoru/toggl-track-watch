# Publishing checklist

## GitHub releases (works now)
1. Bump `version:` in `pubspec.yaml` and add a `## [x.y.z]` section to `CHANGELOG.md`
   (plus `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt` for Play, where
   versionCode = build × 10 for the phone and build × 10 + 1 for the watch).
2. Merge to `main`. `.github/workflows/release.yml` sees that `v<version>` isn't tagged yet, builds
   signed APKs and app bundles, and publishes a GitHub Release (creating the tag) with the APKs and
   the changelog section. Merges that don't change the version release nothing.
3. Pushing a tag by hand (`git tag v1.4.0 && git push origin v1.4.0`) still works; it must match
   pubspec. To retry a failed release, re-run the workflow run.

## Google Play (one-time setup)
1. **Developer account**: <https://play.google.com/console/signup> (one-time fee).
2. **Create the app** with package name `su.iho.trackwatch`, default language English, app, free.
3. **App signing — important:** in *Setup → App signing*, choose **"Use a different key" / "Export and
   upload a key from Java keystore"** and upload the existing Track Watch key (the one in the
   `TRACKWATCH_KEYSTORE_*` secrets) with Google's PEPK tool.
   Why: then Play-installed apps have the same signature as the GitHub APKs, so
   - users can switch between GitHub and Play installs without uninstalling,
   - a Play phone app talks to a GitHub watch app and vice versa (the Wear Data Layer requires the same signature),
   - Block Store backups restore across both.
   If Google generates its own key instead, those three break.
4. **Wear OS**: *Setup → Advanced settings → Form factors → add Wear OS*, and accept the Wear OS
   review. The watch app is non-standalone (needs the phone app); declared in its manifest.
5. **Store listing**: texts and images are in `fastlane/metadata/android/en-US/`
   (title, short/full description, `images/icon.png` 512×512, `images/featureGraphic.png` 1024×500,
   phone and Wear screenshots). Privacy policy URL:
   `https://github.com/ihoru/toggl-track-watch/blob/main/docs/PRIVACY.md`.
6. **App content**:
   - *Data safety*: Collected: "App activity / Other user-generated content" is **not** collected by the
     developer. Data is **shared** with Toggl only as the service the user asked for (user-initiated),
     **encrypted in transit** (HTTPS), and the user can delete it (Change token / uninstall).
     The API token counts as "Personal info → Other" handled on-device only.
   - *Content rating* questionnaire: utility app, no user-generated public content → "Everyone".
   - *Target audience*: 18+ (it's a work tool); no ads.
7. **First upload manually**: upload the phone `.aab` and the watch `.aab` from a GitHub Release
   (attached as build artifacts of the release run) to the *Internal testing* track in the console once.
   Play's API refuses uploads for apps that have never had one.
8. **CI uploads**: in Google Cloud create a service account, grant it *Release manager* for this app in
   Play Console → *Users and permissions*, create a JSON key, and add it as the repository secret
   `PLAY_SERVICE_ACCOUNT_JSON`. From then on every tag uploads the phone bundle to the `internal` track
   and the watch bundle to `wear:internal`. Promote to production in the console.
9. Switch the watch's "Install on phone" link in `lib/src/links.dart` to the Play Store page.

## Screenshots
- Watch: 1:1, at least 384×384 (current ones are 426×426).
- Phone: aspect ratio at most 2:1 — the full-length `docs/screenshots/phone.png` is cropped to
  1280×2560 for the store.
