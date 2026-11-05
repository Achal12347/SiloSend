# Vayu

**Vayu by Achyrio** is a fast, secure, and completely offline device-to-device sharing app.

*Note: Previously developed under the name SiloSend.*

Share files, chat and contact cards directly with nearby phones. No internet connection, cloud server or mobile data is involved.

---

## Available now (Android)

### 📡 Offline, direct sharing
- **No internet needed:** phones find each other over Bluetooth and hand the transfer over to Wi-Fi Direct (Android 10 and later, 5 GHz where both phones support it). If that is not possible they use the Wi-Fi they share, a hotspot one phone creates, or Bluetooth for small items. The direct link closes when the transfer is done.
- **No accounts, no cloud:** nothing leaves the two phones.

### ⚡ File transfer
- **Any file type and size:** photos, videos, documents, archives, APKs and audio, one file or a whole batch with a single accept.
- **Whole folders:** send a folder and it arrives with the same subfolders.
- **No waiting to start:** even very large files are offered right away; the file's fingerprint is worked out while it is being sent.
- **Reliable:** chunked transfer with progress, retries, and resume: if the connection drops, sending again continues where it stopped.
- **Verified:** every file is checked with SHA-256 on arrival before it counts as received.

### 📥 Receive on your terms
- **Receive screen:** files arrive only while Receive is open, or when you accept them in a chat or download them from a host, so nobody nearby can send you popups.
- **Tap or scan:** hold the phones together (NFC) or scan the Receive code; the transfer then starts without another prompt.

### 💬 Offline chat
- **Messages** between nearby phones, with delivered and seen receipts; a first message from someone new is a request until you open it.
- **Files in chats:** they arrive in the chat; with the chat open they download at once, otherwise they wait for you to tap Download.
- **Encrypted on your phone too:** chat history is stored sealed with a key held in the phone's secure hardware.

### 📂 Host & Client
- **Share a set of files or a folder** that nearby phones browse and download.
- **Open to all, or private with a 6-digit PIN** shown on your phone; you see who is browsing and receiving.

### 🕸️ Through other phones (mesh)
- **Reach a phone out of range** through Vayu phones in between (up to three hops). The phones in between forward only encrypted data and cannot read it.
- **Off by default:** relaying for others is a switch in Settings, and never runs on Battery Saver or low battery.

### 📇 Contact cards
- **Your card:** name, title, company, phone, email and website, shared by tap, QR code or to a nearby phone.
- **Received cards:** cards people give you are kept in the app; you choose when to save one to your contacts.

### 🛡️ Security and privacy
- **End-to-end encryption:** authenticated key exchange and AES-256-GCM for every file and card.
- **No tracking:** no analytics, no advertising IDs, no activity tracking.
- **Clean up:** partial files are removed automatically.

### ⚙️ Clear permissions
- **Permissions & settings:** one screen shows what Vayu needs on your Android version and opens the exact setting to fix it.

---

## Planned

- **Windows** app.

Every feature above is tested automatically; testing on real phones is in progress (see the feature tracker).

---

## Supported platforms

- **Android:** Android 8.0 (API level 26) and above
- **Windows:** planned

---

## Versioning

Versions follow `MAJOR.MINOR.PATCH`, with a stage until the first stable release, and start at **0.1.0-alpha**:

- **Stage:** `alpha` (features still changing), then `beta` (feature-complete, being tested), then none for a stable release (1.0.0).
- **MINOR** goes up for new features, **PATCH** for fixes.
- **Build number:** the part after `+` in `pubspec.yaml` (`0.1.0-alpha+1`) goes up by one for every build given to anyone, because Android and the Play Store require it.

When releasing, change `version` in `pubspec.yaml` and `appVersion` in `lib/core/constants/app_constants.dart`. A test fails if they differ.

---

## Building a release

Phones download only the build for their processor when Vayu is published as an App Bundle; obfuscation makes the code harder to reverse-engineer and slightly smaller. Keep the symbols folder to read crash reports.

```sh
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols
```

For installing directly (one APK per processor type):

```sh
flutter build apk --release --split-per-abi --obfuscate --split-debug-info=build/symbols
```

Measured on 2026-10-19: one universal APK is 54.6 MB; the arm64 APK is 19.0 MB, and 17.9 MB with obfuscation. Release signing reads `android/key.properties` (see `android/key.properties.example`).
