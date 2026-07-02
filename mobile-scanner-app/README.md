# Stirling Scanner (Android)

Native Android companion app for the Stirling-PDF **mobile scanner**. It is the
native alternative to the in-browser scanner served at `/mobile-scanner`: instead
of scanning inside a mobile browser (OpenCV.js/WASM), it uses the phone's native
camera with **live document-edge detection**, which performs noticeably better on
lower-end devices.

Both paths upload to the **same** Stirling-PDF session API, so the desktop side
is identical either way.

## How it connects

1. On the desktop web app, open the **mobile upload** QR dialog.
2. Open this app and tap **scan QR** — it reads the QR, which encodes
   `http(s)://HOST[:PORT]/mobile-scanner?session=<sessionId>`, and extracts the
   server origin + session id.
3. Capture one or more pages. Each shot runs auto edge-detection + perspective
   crop; a live outline shows the detected document while you aim.
4. Pages are uploaded to `POST {origin}/api/v1/mobile-scanner/upload/{sessionId}`.
   The desktop polls the session and receives them.

Your pages go only to the server encoded in the QR — i.e. **your own
Stirling-PDF instance**.

## Architecture

- `lib/screens/` — QR scan (`qr_scan_screen.dart`), custom camera capture
  (`capture_screen.dart`), and the review/filters/crop flow (`scan_flow_screen.dart`).
- `lib/services/`
  - `qr_parser.dart` — parses the QR into a session target.
  - `document_edge.dart` — OpenCV edge detection + perspective warp (auto-crop).
  - `edge_detector_isolate.dart` — persistent worker isolate that runs live
    per-frame detection off the UI thread (backpressure + orientation mapping).
  - `image_enhance.dart` — the manual document filters (magic color, B&W, …).
  - `upload_service.dart` — multipart upload to the session API.
- `lib/widgets/edge_overlay_painter.dart` — draws the live document outline.

Key packages: `camera`, `mobile_scanner`, `permission_handler`, `http`, and
`opencv_dart` (dartcv4 — native OpenCV via FFI + Dart Native Assets).

> **Note:** `opencv_dart`/dartcv4 requires **Flutter ≥ 3.38** (Native Assets).
> `dartcv4`'s `Mat.dispose()` is not idempotent — never dispose the same `Mat`
> twice (double-free). The filter/detection code disposes each `Mat` exactly once.

## Build & run

```bash
cd mobile-scanner-app
flutter pub get
flutter run                 # on a connected device
flutter build apk --debug   # debug APK
flutter build apk --release # release APK (installable, sideloaded)
```

`flutter build apk --release` is signed with the debug key by default (fine for
sideloading). A dedicated release keystore is optional and, if added, must stay
**out of the repo** (`android/key.properties`, `*.jks`/`*.keystore` are gitignored).

## Publishing a release (manual)

There is **no CI build** for this app — the APK is built locally and published to
GitHub Releases by hand. Steps:

1. Bump `version: X.Y.Z+N` in [`pubspec.yaml`](pubspec.yaml). Always increment the
   `+N` build number (Android `versionCode`) or devices won't accept the update.
2. Build the universal release APK:
   ```bash
   flutter build apk --release
   # -> build/app/outputs/flutter-apk/app-release.apk
   ```
3. Publish it under the **stable asset name `stirling-scanner.apk`** so the
   `latest` download URL never breaks (`file#name` renames the upload asset):
   ```bash
   # first release:
   gh release create v1.0.0 \
     build/app/outputs/flutter-apk/app-release.apk#stirling-scanner.apk \
     --target deploy-clean --title "Stirling Scanner v1.0.0" --notes "…"
   # later releases (new tag):
   gh release create vX.Y.Z \
     build/app/outputs/flutter-apk/app-release.apk#stirling-scanner.apk \
     --target deploy-clean --title "…" --notes "…"
   # or replace the asset on an existing release:
   gh release upload vX.Y.Z \
     build/app/outputs/flutter-apk/app-release.apk#stirling-scanner.apk --clobber
   ```

The download button in the web app points at the fork's `latest` release:
`https://github.com/willianm18/pdf-editor/releases/latest/download/stirling-scanner.apk`.
When you bump the app version, also update `APK_VERSION` in the frontend constant
so the version shown next to the button stays in sync.
