# Self-Hosting Wrist Check

A tiny standalone Wear OS app (Java) that reads `status.json` from the homelab and shows it on the watch:

- **Homelab status** complication for the watch face.
- Tap the complication to open a scrollable list of everything that's down or slow. Opening it also refreshes the complication.

Built for a Galaxy Watch8 (Wear OS 6), works on any Wear OS 3+ watch (minSdk 30).

Setup in short: run `server/install.sh` on the server, install the APK on the watch, add the complication, tap it, scan the QR code with your phone and paste the URL and token. Nothing secret is compiled into the app.

## What it shows

| status.json | SHORT_TEXT text | SHORT_TEXT title | LONG_TEXT text | LONG_TEXT title |
|---|---|---|---|---|
| no problems | `ALL UP` | check time `HH:MM` | `All up` | `Checked HH:MM` |
| at least one DOWN | `<n> DOWN` | first service name, `+N` if more | first problem label | `+N more` / `Checked HH:MM` |
| only SLOW problems | `SLOW` | first service name, `+N` if more | first problem label | `+N more` / `Checked HH:MM` |
| `error` field (Kuma not readable) | `KUMA` | `NOT READABLE` | `Uptime Kuma not readable` | `Checked HH:MM` |
| `updated` older than 5 min | `STALE` | `SINCE HH:MM` | `Status not updating` | `Last update HH:MM` |
| fetch failed / non-200 | `OFFLINE` | `NO CONNECTION` | `Server unreachable` | `Homelab` |
| not set up yet | `SETUP` | `TAP HERE` | `Tap to set up` | `Homelab` |

- Both types carry a monochrome server icon.
- Refreshes every 15 minutes (`UPDATE_PERIOD_SECONDS` 900). Opening the problem list (by tapping the complication) refreshes it right away via `ComplicationDataSourceUpdateRequester.requestUpdateAll()`.
- Fetch: `GET <status URL>` with `Authorization: Bearer <token>`, 8 s connect/read timeouts, response capped at 32 KB, redirects not followed. The token is never logged. Uses the watch's own connection (phone over Bluetooth, or Wi-Fi/LTE).

## Problem list

- Tapping the complication opens the **debil status** screen: the status (`ALL UP`, `2 DOWN`, ...), every problem in a scrollable list (touch or rotating bezel), the check time and a **Refresh** button. It is also in the watch's app list.
- Opening the screen, or tapping **Refresh**, also asks Wear OS to refresh the complication, so the watch face catches up at the same time.
- Complications only get a single tap from the watch face; double tap and long press aren't passed to the app (long press opens watch face editing).

## Optional: list working services

If `status.json` includes an `up` array with the names of the services that are working, the list screen shows them under the problems (header `UP · n`). Without the field everything works as before.

```json
{"short":"PKVault DOWN","title":"20:16","count":1,"problems":["PKVault DOWN"],"up":["Immich","Jellyfin","Nextcloud"],"updated":1795637760}
```

Use plain service names (no ` UP` suffix), in the order you want them shown. Leave slow and down services out of `up`, since they're already in `problems`. The complication ignores this field.

## Server setup

The watch needs one URL that returns `status.json` only when the request carries the right bearer token (404 otherwise). `server/` sets that up on a Linux server running Caddy and Uptime Kuma:

```
git clone https://github.com/grandevr/Self-Hosting-Wrist-Check
cd Self-Hosting-Wrist-Check/server
sudo ./install.sh
```

It asks for your domain, the path (default `/health/status.json`) and whether to install the status writer, then:

- makes a random 64-character token and writes `/etc/caddy/wrist-check.caddy`, a snippet that serves the file only with that token. Add `import wrist-check.caddy` inside your site block in the Caddyfile (the script tells you if it's missing) and it reloads Caddy;
- optionally installs `kuma-status.py` as `/usr/local/bin/wrist-check-status` with a systemd timer that rewrites `/var/lib/wrist-check/status.json` every minute. It reads an Uptime Kuma **status page** (public API, no Kuma login needed): create a status page in Kuma with the monitors you want on your wrist and give the script its slug. DOWN monitors come first, then SLOW ones (Kuma "pending", or slower than `SLOW_MS`, default 2000 ms); monitors in maintenance are left out. Skip it if you already write the file yourself;
- prints the URL and token to enter on the watch.

Later: `sudo ./install.sh --show` prints the URL and token again (for another watch), `sudo ./install.sh --rotate` makes a new token (every watch then needs setting up again). Settings live in `/etc/wrist-check/env`; run the writer by hand with `wrist-check-status --print` after `set -a; . /etc/wrist-check/env`.

Not using Caddy? Any web server works if it answers 200 with the file for `Authorization: Bearer <token>` and 404 for anything else.

## Watch setup

1. Install the APK (below) and add the **Homelab status** complication to your watch face. It shows `SETUP` / `TAP HERE`.
2. Tap it. The watch turns on Wi-Fi and shows a QR code, an address like `192.168.1.42:8765` and a 6-digit PIN.
3. Scan the QR code with your phone (or type the address into any browser on the same network). The page has the PIN filled in; paste the status URL and token and press **Test and save**.
4. The watch fetches the URL with the token first and only saves if it gets a valid `status.json`, so you see "wrong token" or "can't reach server" right on the page. The complication updates straight away.

No Wi-Fi, or a different network? Tap **Enter on watch** and type the URL and token on the watch (the Wear OS keyboard can take input from the paired phone, which helps with the long token).

To change the URL or token later: open the status list (tap the complication) → **Settings** at the bottom.

How it's kept safe:
- The setup page is served by the watch itself, only while the setup screen is open (10 minutes at most), and only on its Wi-Fi address. Saving needs the PIN from the watch screen; after 5 wrong PINs a new one is drawn.
- The page travels over your local network as plain HTTP (the watch can't get a certificate for a LAN address), so do this on your home network, not public Wi-Fi.
- The token is stored encrypted with an AES key held in the Android Keystore, never logged, never shown again on the page, and not included in backups.
- The status URL has to be `https://`.

## Build

Requirements: JDK 17+, Android SDK with platform 36 (Android Studio's SDK is fine; point to it with `ANDROID_HOME` or a `local.properties` containing `sdk.dir=...`). Gradle 9.2.1 and Android Gradle Plugin 9.0.0 come via the wrapper.

```
./gradlew assembleDebug
```

The APK lands in `app/build/outputs/apk/debug/app-debug.apk`. It contains no URL or token, so it's safe to share; every watch is set up as described above.

Optional build-time default: copy `secrets.properties.example` to `secrets.properties` and fill in `STATUS_URL` and `STATUS_TOKEN`. The app then works without any watch setup, until something is entered on the watch (which wins). If the file exists, both values must be filled in or the build stops with a clear error. An APK built this way contains the token: don't share or commit it (both are gitignored). The GitHub Actions workflow builds without the file.

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
  Config.java             URL + token storage (token encrypted with an Android Keystore key)
  SetupActivity.java      setup screen: Wi-Fi, QR code, address and PIN
  SetupServer.java        the one-page web server the phone talks to during setup
  ManualSetupActivity.java  fallback: type URL and token on the watch
app/src/main/AndroidManifest.xml
app/src/main/res/drawable/ic_server.xml
server/
  install.sh              server setup: token, Caddy snippet, status writer + timer
  kuma-status.py          writes status.json from an Uptime Kuma status page
secrets.properties.example  optional build-time default URL + token
```
