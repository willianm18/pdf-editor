// Centralized download URLs for Stirling PDF desktop installers
export const DOWNLOAD_URLS = {
  WINDOWS: "https://files.stirlingpdf.com/win-installer.exe",
  MAC: "https://files.stirlingpdf.com/mac-installer.dmg",
  LINUX_DOCS: "https://docs.stirlingpdf.com/Installation/Unix%20Installation/",
} as const;

export const DOWNLOAD_BASE_URL = "https://files.stirlingpdf.com/";

// Native Android scanner app (this fork). The APK is built locally and published
// to GitHub Releases by hand under the stable asset name `stirling-scanner.apk`
// (see mobile-scanner-app/README.md), so `latest/download` always resolves to
// the newest build.
//
// ANDROID_APP_AVAILABLE gates the in-app download button: keep it false until a
// release with that asset exists, otherwise the link 404s. APK_VERSION is shown
// next to the button — bump it whenever a new APK is published.
export const ANDROID_APP_AVAILABLE = true;
export const ANDROID_APK_URL =
  "https://github.com/willianm18/pdf-editor/releases/latest/download/stirling-scanner.apk";
export const ANDROID_APK_VERSION = "1.0.0";
