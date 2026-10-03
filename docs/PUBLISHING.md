# Publishing

## Releasing a version
1. Bump `version:` in `pubspec.yaml` and add a `## [x.y.z]` section to `CHANGELOG.md`, plus
   `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt` (Play's "What's new", at most 500
   characters; versionCode = build × 10 for the phone, build × 10 + 1 for the watch).
2. Merge to `main`.
3. GitHub → **Actions → Release → Run workflow** on `main`. (Pushing a tag `v<version>` does the same.)
   `.github/workflows/release.yml` then:
   - checks the version isn't released yet, and creates the tag `v<version>`,
   - builds signed APKs and app bundles,
   - publishes a GitHub Release with the APKs and the changelog section,
   - keeps the bundles as the run's `play-bundles-<version>` artifact,
   - when `PLAY_SERVICE_ACCOUNT_JSON` is set, uploads the phone bundle to the Play track
     `PLAY_TRACK` (repository variable, default `internal`) and the watch bundle to `wear:<track>`,
     with the "What's new" text.

The store listing (texts, icon, feature graphic, screenshots) is uploaded separately with
**Actions → Play listing → Run workflow** (`.github/workflows/play-listing.yml`, fastlane supply)
whenever `fastlane/metadata/android/en-US/` changes.

## Google Play: first launch
Work through these in order in [Play Console](https://play.google.com/console) (existing developer
account, so no closed-testing requirement).

### 1. Create the app
*Home → Create app*: name **Track Watch**, default language English (United States), **App**, **Free**.
Accept the declarations. The package name `su.iho.trackwatch` is fixed by the first upload.

### 2. App signing: use the existing key
*Test and release → Setup → App signing* (shown during the first upload): choose
**"Use a different key" → "Export and upload a key from Java keystore"** and follow the steps with
Google's PEPK tool and the Track Watch keystore (the one in the `TRACKWATCH_KEYSTORE_*` secrets).

Why: Play-installed apps then have the same signature as the GitHub APKs, so
- users can switch between GitHub and Play installs without uninstalling,
- a Play phone app talks to a GitHub watch app and vice versa (the Wear Data Layer requires the same
  signature),
- Block Store backups restore across both.

If Google generates its own key instead, those three break, and it can't be changed later.

The upload key is the same key, so the bundles CI builds are accepted as they are.

### 3. Add Wear OS
*Test and release → Setup → Advanced settings → Form factors → Add form factor → Wear OS*. Opt in
to Wear OS review and confirm you checked the Wear OS app quality guidelines:
- dark background, text readable on round screens (tested on the Pixel Watch and the Wear emulator),
- tile and complication work, with the running timer and start buttons,
- the watch app is **not standalone** (`com.google.android.wearable.standalone=false`): it needs
  the phone app, which the listing says. When the phone app is missing, the watch offers
  **Install on phone**.

### 4. First upload
Run the Release workflow (see above) and download the `play-bundles-<version>` artifact from the
run. In Play Console:
- *Test and release → Testing → Internal testing → Create new release*: upload
  `track-watch-phone-<version>.aab`.
- *Internal testing → Wear OS only* (track selector at the top): upload `track-watch-wear-<version>.aab`.
- Add yourself as a tester (*Testers* tab, an email list) and roll out.

Play's API refuses uploads for apps that never had one, so this first one must be manual.

### 5. Store listing
*Grow users → Store presence → Main store listing*. Either set up the service account first (step 8)
and run **Play listing**, or paste by hand from `fastlane/metadata/android/en-US/`:
- App name `title.txt`, short description `short_description.txt`, full description
  `full_description.txt`.
- App icon `images/icon.png` (512×512), feature graphic `images/featureGraphic.png` (1024×500).
- Phone screenshots `images/phoneScreenshots/` (at least 2). Wear OS screenshots
  `images/wearScreenshots/` (1:1, at least 384 px, no device frame, no mask).

*Store settings*:
- App category: **Productivity**. Tags: Time tracking, Productivity.
- Contact details: email **ihor.polyakov@gmail.com**, website
  `https://github.com/ihoru/toggl-track-watch`.

### 6. App content (*Policy → App content*)
- **Privacy policy:** `https://github.com/ihoru/toggl-track-watch/blob/main/docs/PRIVACY.md`
  (also linked in the app: phone ⋮ menu, watch Sync → Settings).
- **App access:** *All or some functionality is restricted* → add instructions:
  - Create a free Toggl Track account for reviewers (e.g. a new Gmail address).
  - Add 2–3 projects and a few time entries.
  - Copy its API token from *Profile settings → API Token*.
  - Instructions text:
    > Track Watch needs a Toggl Track account. Open the phone app and paste this API token: `<token>`.
    > Then add a favorite with +. The paired Wear OS watch app shows the favorites and the running timer;
    > the tile is available from the watch's tile carousel.
  - Keep that account; reviewers may come back with every update.
- **Ads:** No ads.
- **Content rating:** questionnaire, category *Utility, Productivity, Communication or other*;
  answer No to everything (no violence, user-generated public content, purchases, location sharing,
  etc.) → *Everyone* / PEGI 3.
- **Target audience:** 18 and over. Not designed for children.
- **News app:** No. **Government app:** No. **Financial features:** none. **Health:** none.
  **COVID-19 apps:** No.
- **Data safety:**
  - *Does your app collect or share any of the required user data types?* **Yes.**
  - *Is all of the user data collected by your app encrypted in transit?* **Yes** (HTTPS to Toggl,
    the Data Layer and Block Store are encrypted).
  - *Which account creation methods?* **None** (the app uses an existing Toggl account and makes no accounts).
  - *Data types*, each with: Collected **Yes**, Shared **No** (sending to Toggl is what the user asks
    the app to do), Processed ephemerally **No**, **Required**, purpose **App functionality** only:
    - **Personal info → User IDs**: the Toggl API token. It identifies the user's Toggl account, is
      sent to Toggl with every request, and is saved in the Block Store backup.
    - **App activity → Other user-generated content**: time entries (description, project, times)
      the user starts, edits or deletes, sent to Toggl; favorites, saved in the Block Store backup.
    - Not collected: the Toggl name and email are only received and shown on the phone, never sent
      anywhere. No App info and performance data (no analytics or crash reporting).
  - *Data deletion* (describe it like this):
    - **Change token** removes the token from the phone and from the backup.
    - Favorites and settings stay in the Block Store backup (so a reinstall restores them) until the
      user deletes the app's backup data in their Google account (Android Settings → Google →
      Backup, or Google One → Manage backup); uninstalling removes everything on the devices.
    - Time entries are deleted in Toggl Track itself. There is no developer account or server.
- **Advertising ID:** the app doesn't use it (no `AD_ID` permission).

### 7. Review and publish
*Publishing overview → Send for review*. Once approved, promote the internal release to
**Production** (phone and Wear OS tracks) in the console, or set the repository variable
`PLAY_TRACK=production` so CI releases go straight there.

### 8. CI uploads
- Google Cloud console → create a project → enable the **Google Play Android Developer API**.
- *IAM → Service accounts* → create one → *Keys → Add key → JSON*.
- Play Console → *Users and permissions → Invite new users*: the service account's email, with
  *Release apps to testing tracks*, *Release to production*, *Manage store presence* for Track Watch.
- GitHub → *Settings → Secrets and variables → Actions*:
  - secret `PLAY_SERVICE_ACCOUNT_JSON` = the JSON key file's contents,
  - variable `PLAY_RELEASE_STATUS` = `completed` once the app passed its first review (until then
    Play only accepts drafts),
  - optional variable `PLAY_TRACK` (`internal`, `alpha`, `beta` or `production`).

### 9. After the production launch
Switch `installUrl` in `lib/src/links.dart` to
`https://play.google.com/store/apps/details?id=su.iho.trackwatch` (the watch's **Install on phone**
button), and add the Play badge to `README.md`. Before launch that page doesn't exist.

## Screenshots
- Watch: 1:1, at least 384×384 (ours are 426×426 from the Pixel Watch), round content on black.
- Phone: aspect ratio at most 2:1 (crop long screenshots to 1280×2560), at least 2.
- Sources live in `docs/screenshots/` (README) and `fastlane/metadata/android/en-US/images/` (Play).
