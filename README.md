# Self-Hosting Wrist Check

A tiny standalone Wear OS app (Java) that reads `status.json` from the homelab and shows it on the watch:

- **Homelab status** complication for the watch face.
- Tap the complication to open a scrollable list of everything that's down or slow. Opening it also refreshes the complication.

Built for a Galaxy Watch8 (Wear OS 6), works on any Wear OS 3+ watch (minSdk 30).

## What it shows

| status.json | SHORT_TEXT text | SHORT_TEXT title | LONG_TEXT text | LONG_TEXT title |
|---|---|---|---|---|
| no problems | `ALL UP` | check time `HH:MM` | `All up` | `Checked HH:MM` |
| at least one DOWN | `<n> DOWN` | first service name, `+N` if more | first problem label | `+N more` / `Checked HH:MM` |
| only SLOW problems | `SLOW` | first service name, `+N` if more | first problem label | `+N more` / `Checked HH:MM` |
| `error` field (Kuma not readable) | `KUMA` | `NOT READABLE` | `Uptime Kuma not readable` | `Checked HH:MM` |
| `updated` older than 5 min | `STALE` | `SINCE HH:MM` | `Status not updating` | `Last update HH:MM` |
| fetch failed / non-200 | `OFFLINE` | `NO CONNECTION` | `Server unreachable` | `Homelab` |

- Both types carry a monochrome server icon.
- Refreshes every 15 minutes (`UPDATE_PERIOD_SECONDS` 900). Opening the problem list (by tapping the complication) refreshes it right away via `ComplicationDataSourceUpdateRequester.requestUpdateAll()`.
- Fetch: `GET STATUS_URL` with `Authorization: Bearer STATUS_TOKEN`, 8 s connect/read timeouts, response capped at 16 KB. The token is never logged. Uses the watch's own connection (phone over Bluetooth, or Wi-Fi/LTE).

## Problem list

- Tapping the complication opens the **debil status** screen: the status (`ALL UP`, `2 DOWN`, ...), every problem in a scrollable list (touch or rotating bezel), the check time and a **Refresh** button. It is also in the watch's app list.
- Opening the screen, or tapping **Refresh**, also asks Wear OS to refresh the complication, so the watch face catches up at the same time.
- Complications only get a single tap from the watch face; double tap and long press aren't passed to the app (long press opens watch face editing).

## Build

Requirements: JDK 17+, Android SDK with platform 36 (Android Studio's SDK is fine; point to it with `ANDROID_HOME` or a `local.properties` containing `sdk.dir=...`). Gradle 9.2.1 and Android Gradle Plugin 9.0.0 come via the wrapper.

1. Copy `secrets.properties.example` to `secrets.properties` and fill in `STATUS_URL` and `STATUS_TOKEN`. The build stops with a clear error if either is missing.
2. Run:
   ```
   ./gradlew assembleDebug
   ```
   The APK lands in `app/build/outputs/apk/debug/app-debug.apk`.

Never commit or share `secrets.properties` or a built APK: the token is compiled into it. Both are gitignored. The GitHub Actions workflow only builds with the placeholder values from the example file to check that everything compiles.

## Install on the watch

1. On the watch: Settings → Developer options → turn on **ADB debugging** and **Debug over Wi-Fi** (Developer options appear after tapping Settings → About watch → Software → Software version 7 times).
2. Pair and connect (the watch shows the IP, ports and pairing code under *Wireless debugging*):
   ```
   adb pair <watch-ip>:<pairing-port>
   adb connect <watch-ip>:<port>
   adb -s <watch-ip>:<port> install -r app/build/outputs/apk/debug/app-debug.apk
   ```

## Pick the complication

Long-press the watch face → **Customize** → swipe to the complications screen → tap a slot → choose **debil status → Homelab status**. Short slots get SHORT_TEXT, wide slots get LONG_TEXT.

On the Galaxy Wearable phone app the same thing is under Watch faces → Customize → Complications.

Logs: `adb logcat -s DebilStatus`

## Files

```
app/src/main/java/uk/debil/status/
  StatusDataSource.java   complication service, builds SHORT_TEXT / LONG_TEXT data
  StatusFetcher.java      HTTP fetch + JSON parsing
  Status.java             status model and wording
  ProblemsActivity.java   scrollable full list, opened by tapping the complication
  Refresh.java            asks Wear OS to update the complication now
app/src/main/AndroidManifest.xml
app/src/main/res/drawable/ic_server.xml
secrets.properties.example
```
