<div align="center">
<br />
<img src="logo/krab_logo.png" width="120" height="120" alt="KRAB Logo"></div>

<h1 align="center">KRAB</h1>

<br />

<h4 align="center">KRAB is an Android app for quickly sharing photos within groups of friends.
Photos shared to a group appear directly on every member's home screen.</h4>

<div align="center">
  <a href="https://flutter.dev/">
    <img alt="Flutter" src="https://img.shields.io/badge/Flutter-02569B?logo=flutter&logoColor=white&style=for-the-badge" />
  </a>
  <a href="https://dart.dev/">
    <img alt="Dart" src="https://img.shields.io/badge/Dart-0175C2?logo=dart&logoColor=white&style=for-the-badge" />
  </a>
  <a href="https://supabase.com/">
    <img alt="Supabase" src="https://img.shields.io/badge/Supabase-3FCF8E?logo=supabase&logoColor=white&style=for-the-badge" />
  </a>
  <br />
  <img alt="API 24+" src="https://img.shields.io/badge/Api%2024+-50f270?logo=android&logoColor=black&style=for-the-badge" />
  <a href="LICENSE">
    <img alt="License GPL-3.0" src="https://img.shields.io/github/license/zatomos/KRAB?style=for-the-badge" />
  </a>
</div>

<br />

<div align="center" style="display: flex; justify-content: center; gap: 10px;">
  <img src="github/camera_page_preview.png" alt="Camera preview" height="400">
  <img src="github/home_screen_preview.png" alt="Home screen preview" height="400">
<br />
  <img src="github/group_gallery_preview.png" alt="Group gallery preview" height="400">
  <img src="github/fullscreen_image_preview.png" alt="Fullscreen image preview" height="400">
</div>

<p align="center"><i>Originally developed as a privacy-friendly alternative to the <a href="https://play.google.com/store/apps/details?id=com.locket.Locket&hl=en-US">Locket Widget App</a>.</i></p>

## ✨ Features

- 🔄 Sharing:
  - Snap a photo to one or more groups and optionally add a caption.
  - A notification is sent to every member of the group.
  - Photos appear instantly on every group member's home screen via a widget.
  - Users can choose to display the most recent or the three most recent images they received.

- 🌐 Social:
  - Create or join groups with friends using an invite system.
  - Comment on photos and reply to comments.
  - React to photos with emojis.

- 🛡️ Privacy:
  - Fully self-hostable backend.
  - Push notifications use [UnifiedPush](https://unifiedpush.org) and standard Web Push. Payloads are
    encrypted to your device, so a push service only ever sees ciphertext.

## 🏗️ Architecture

The backend uses a [Supabase](https://supabase.com/) instance. It authenticates users, stores the
photos, keeps track of who belongs to which group, and sends notifications when something new is
posted.

- The app talks to Supabase directly for all reads and writes. Access rules make sure each user only
  sees content from the groups they belong to.
- When a photo or comment is posted, the database automatically triggers a function that pushes a
  notification to the other group members, whose apps then refresh their widget.

### Uploading

Sending a photo takes two steps, and the database closes the gap between them:

1. `request_image_upload` checks the user may post to those groups, then records the photo and the
   groups it is about to belong to.
2. The app uploads the bytes under the id it got back. A trigger on the storage insert turns those
   staged groups into real ones in the same transaction as the upload.

So the bytes and their group links commit together or not at all. A photo that belongs to no group
can't exist, which means a send that dies partway through leaves nothing behind.

---

## 🚀 Setup

### 1. Backend setup: Supabase

You can use a free or paid hosted instance at https://supabase.com, which has a reasonable
[privacy policy](https://supabase.com/privacy). If you'd rather self-host your own instance, you can
do so by running the included scripts.
> See the [Supabase self-hosting guide](https://supabase.com/docs/guides/self-hosting) to learn more.

**Prerequisites:** a Linux server with [Docker](https://docs.docker.com/engine/install/) and the
Docker Compose plugin.

Run the backend setup script `setup_backend.sh` on the server. It installs self-hosted Supabase
(if missing), configures it for KRAB, loads the database schema, creates the storage buckets,
generates this instance's VAPID keypair, and deploys the edge functions. It also wires the database
triggers that call those functions, injecting your instance's service-role key as their
authorization so the calls aren't rejected:

```bash
curl -fsSL https://raw.githubusercontent.com/zatomos/KRAB/main/scripts/setup_backend.sh | bash
```

It will ask you for:
- **API URL** clients use.
- **Studio dashboard** username / password.
- A **contact email** for push services

When it finishes, it prints a **connection token**, a single string that packs the API URL and the
anon key. That is all a user needs to point the app at your instance; share it with the people you're
inviting.

You'll also want to put your API URL behind HTTPS for production use.

### 2. Building the app yourself (optional)

**Prerequisites:** [Flutter](https://flutter.dev/docs/get-started/install).

1. Clone and install dependencies:
   ```bash
   git clone https://github.com/zatomos/KRAB.git
   cd KRAB
   flutter pub get
   ```
2. Run it:
   ```bash
   flutter run
   ```

#### Release signing

Only needed if you publish APKs. Without a keystore, release builds fall back to Android's **debug**
key.

1. Generate the keystore, once:
   ```bash
   keytool -genkey -v -keystore ~/krab-release.jks \
     -keyalg RSA -keysize 4096 -validity 10000 -alias krab
   ```
2. Point the build at it:
   ```bash
   cp android/key.properties.example android/key.properties
   # then fill in storeFile / storePassword / keyAlias / keyPassword
   ```
   `key.properties` and `*.jks` are gitignored.
3. Build, and confirm it is signed with your key rather than the debug key:
   ```bash
   flutter build apk --release
   apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk
   ```

### 3. Password reset (optional)

Password reset sends an email with a link to a small web page where the user sets a new password.
It needs a publicly reachable page and an SMTP server to send the email.

1. Pick a public hostname for the reset page (e.g. `https://krab.example.com`) and point it
   (via DNS / your reverse proxy) at the server.
2. **Get an SMTP app password.** Use an *app-specific password* from your email provider, **not**
   your account password.
3. Run the setup script on the server:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/zatomos/KRAB/main/scripts/reset_password/setup-reset-pwd-page.sh | sudo bash
   ```
   It asks for your Supabase URL, the public page URL, the anon key, the LAN IP the auth container
   uses to fetch the email template, and your **SMTP host / port / user / password**. It then serves
   the page, whitelists the redirect, installs the branded email template, and configures SMTP.

### 4. Auto-update the app (optional)

The app can check a manifest and prompt users to update. Host a `manifest.json` (template: `manifest.json.example`) listing your releases and their APK download URLs, then build with `--dart-define=MANIFEST_URL=... --dart-define=ENABLE_AUTO_UPDATE=true`.

A helper to publish APKs + manifest to a Nextcloud instance is provided (`scripts/release.sh`).

### 5. Email verification (optional)

When enabled, signing up sends a confirmation email and the account can't log in until the link
is clicked.

It reuses the same infrastructure as password reset, so set that up first; it needs a publicly
reachable page and a working **SMTP** server.

Run the setup script on the server:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/zatomos/KRAB/main/scripts/email_confirmation/setup-email-confirmation.sh | sudo bash
   ```
   It serves an "email confirmed" landing page, whitelists the redirect, installs the confirmation
   email template, and sets `GOTRUE_MAILER_AUTOCONFIRM=false` on the auth container. As with password
   reset, it publishes the landing-page URL to your instance, so the app picks it up on its own.

To turn it back off, remove the `docker-compose.krab-confirm.yml` override from `COMPOSE_FILE` in
your `.env` (or set `GOTRUE_MAILER_AUTOCONFIRM=true`) and re-run `docker compose up -d auth`.

---

## 📄 License

KRAB is licensed under the [GNU General Public License v3.0](LICENSE).
