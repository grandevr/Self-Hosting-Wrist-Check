# Self-Hosting Wrist Check

A tiny standalone Wear OS app (Java, with the screens in Kotlin and Compose for Wear OS Material 3) that reads `status.json` from the homelab and shows it on the watch:

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

- Tapping the complication opens the **debil status** screen: the status (`ALL UP`, `2 DOWN`, ...), every problem in a scrollable list (touch or rotating bezel), the check time and a round **Refresh** button at the bottom edge. It is also in the watch's app list.
- The screens use Material 3 for Wear OS and pick up the watch's dynamic colours (Wear OS 6 takes them from the watch face). Status colours stay fixed: green for up, amber for slow, red for down.
- Opening the screen, or tapping **Refresh**, also asks Wear OS to refresh the complication, so the watch face catches up at the same time.
- Complications only get a single tap from the watch face; double tap and long press aren't passed to the app (long press opens watch face editing).

## Optional: list working services

If `status.json` includes an `up` array with the names of the services that are working, the list screen shows them under the problems (header `UP · n`). Without the field everything works as before.

```json
{"short":"PKVault DOWN","title":"20:16","count":1,"problems":["PKVault DOWN"],"up":["Immich","Jellyfin","Nextcloud"],"updated":1795637760}
```

Use plain service names (no ` UP` suffix), in the order you want them shown. Leave slow and down services out of `up`, since they're already in `problems`. The complication ignores this field.

## Server setup

The watch needs one URL that returns `status.json` only when the request carries the right bearer token (404 otherwise). `server/install.sh` sets that up. It has two parts, which can run on the same machine or on different ones:

- **writer**: `kuma-status.py`, run every minute by a systemd timer. It reads an Uptime Kuma status page and writes `status.json`. It goes where Python can reach Kuma.
- **route**: a Caddy snippet that checks the token. It goes on the Caddy the watch connects to.

### One server (Kuma, Caddy and Python together)

```
curl -fsSL https://raw.githubusercontent.com/grandevr/Self-Hosting-Wrist-Check/main/server/install.sh | sudo bash
```

Run in a terminal, the installer first looks around: it finds Uptime Kuma (local ports and Docker containers) and its status pages, Caddy and its sites, a web server folder that already serves `/health/`, and older timers that look like a status writer. It suggests what to install and the settings to use, you confirm or change each answer, and it shows the plan before changing anything.

What it does:

- installs `kuma-status.py` as `/usr/local/bin/wrist-check-status` with a timer that rewrites `/var/lib/wrist-check/status.json` every minute. It reads Kuma's public status page API, so no Kuma login is needed and Kuma can run in Docker. It checks the status page slug first and stops if Kuma doesn't know it;
- makes a random 64-character token (or reuses one, see below) and keeps it in `/etc/wrist-check/token`, readable by root only;
- writes `/etc/caddy/wrist-check.caddy` and adds `import wrist-check.caddy` to your site's block in the Caddyfile. It asks first, keeps `Caddyfile.wrist-check.bak`, checks the result with `caddy validate`, reloads, and puts the old files back if either step fails.

The token is not printed unless you ask for it with `--show`.

### Writer and token check on different machines

A common homelab layout has two hops: Kuma and a web server on one machine at home, and a public Caddy (often on a VPS) that terminates TLS and proxies to it. Then:

1. **On the Kuma machine**, install only the writer, and point `OUT` at a folder your web server already serves, so the existing proxy chain carries the file:

   ```
   curl -fsSL .../server/install.sh | sudo bash -s -- --writer-only
   ```

   It needs python3 and systemd, not Caddy. If the folder belongs to another user, it offers to run the writer as that user (`WRITER_USER`).

2. **On the public Caddy**, add only the token check. There are three route modes:

   | `ROUTE=` | What Caddy does with the status path |
   |---|---|
   | `file` | serves the file from this machine (the writer runs here, or you copy the file here) |
   | `check-only` | answers 404 without the token, and otherwise lets the site's existing `reverse_proxy` handle the request |
   | `proxy` | answers 404 without the token, and otherwise sends the request to `UPSTREAM` |

   `check-only` needs the site's `reverse_proxy` at the top level of the site block. If the block uses `handle` or `route` blocks, those run before the check, so the installer refuses `check-only` and suggests `proxy`.

   With root:

   ```
   curl -fsSL .../server/install.sh | sudo bash -s -- --route-only
   ```

   Without root (you can edit the Caddyfile and reload, but can't run the installer as root), print the lines and paste them into the site block yourself:

   ```
   curl -fsSL .../server/install.sh | ROUTE=check-only bash -s -- --print-snippet
   caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile && sudo systemctl reload caddy
   ```

   Only the snippet goes to stdout, so `> file` works; `SNIPPET_OUT=file` writes it with mode 600. The token is kept in `~/.config/wrist-check/token`.

3. Any Caddy in between (for example an inner Caddy at home that only proxies over `http://`) stays as it is.

**An existing route for the same path.** If the site block already handles the status path (say, your own `@health_denied` matcher with a token), the installer lists those lines and stops instead of adding a second check: two checks with different tokens would answer 404 to every request. In a terminal it offers to print the replacement lines instead, and to keep the token your current route uses, so watches already set up keep working.

**Optional extras the installer leaves alone.** Your `handle_errors` blocks stay as they are. Two that pair well with a two-hop setup:

- on the public Caddy, when home can't be reached (502/503/504 for the status path), answer 200 with a small `status.json` whose `short` is `HOME DOWN`, so the watch names the problem instead of showing `OFFLINE`;
- on an inner Caddy, the same for the machine behind it, e.g. `<machine> DOWN`.

Set `updated` to the current time (Caddy's `{time.now.unix}` placeholder), or the watch shows `STALE`, and put the label in `problems` with `count` 1.

### Without curl

python3 is enough to fetch and run the installer:

```
python3 -c "import urllib.request,sys;sys.stdout.buffer.write(urllib.request.urlopen('https://raw.githubusercontent.com/grandevr/Self-Hosting-Wrist-Check/main/server/install.sh').read())" | sudo bash -s -- --writer-only
```

Or download `install.sh` and `kuma-status.py` on any machine, copy both to the server, and run `sudo bash install.sh --writer-only`. Run from a file, the installer deletes itself and `kuma-status.py` when done (unless it's in a git checkout, or with `KEEP_INSTALLER=yes`).

### Later

```
... | sudo bash -s -- --show          # print the URL and token (to set up another watch)
... | sudo bash -s -- --rotate        # new token; every watch must be set up again
... | sudo bash -s -- --uninstall     # remove everything it added here
... | sudo bash -s -- --uninstall --writer-only   # only the writer (a route elsewhere stays)
```

### Settings

Every question can be answered ahead of time with an environment variable, e.g. `curl ... | sudo DOMAIN=example.com KUMA_SLUG=homelab bash -s -- --writer-only`. Without a terminal (or with `NONINTERACTIVE=yes`) nothing is guessed: required answers that are missing stop the installer with a message. Settings are saved in `/etc/wrist-check/env` and reused next time; a variable on the command line wins over the saved value.

| Variable | Part | Meaning |
|---|---|---|
| `ROLE` | both | `all`, `writer` or `route` (same as `--writer-only` / `--route-only`) |
| `DOMAIN` | route | public domain of the Caddy site (required) |
| `STATUS_PATH` | route | path of the status file, default `/health/status.json` |
| `ROUTE` | route | `file`, `check-only` or `proxy` (required for route-only) |
| `UPSTREAM` | route | where `proxy` sends requests, e.g. `http://10.0.0.5:8080` |
| `TOKEN_FILE` / `TOKEN` | route | reuse an existing token (e.g. the one in your password manager) instead of making one. `TOKEN_FILE` keeps it out of your shell history |
| `CADDYFILE`, `CADDY_SNIPPET` | route | default `/etc/caddy/Caddyfile` and `wrist-check.caddy` next to it |
| `EDIT_CADDYFILE=no` | route | don't touch the Caddyfile; print the import line to add instead |
| `SKIP_VALIDATE=yes` | route | skip `caddy validate` and rely on the reload (a failed reload is still rolled back) |
| `RELOAD_CMD` | route | how to reload Caddy, e.g. `"sudo systemctl reload caddy"` |
| `ALLOW_EXISTING_ROUTE=yes` | route | add the route even though the site block already handles the path |
| `KUMA_URL` | writer | Uptime Kuma as seen from this machine, default `http://127.0.0.1:3001` |
| `KUMA_SLUG` | writer | slug of the status page (required); checked against Kuma before installing |
| `OUT` | writer | file to write, default `/var/lib/wrist-check/status.json` |
| `SLOW_MS` | writer | response time that counts as slow, default 2000 (0 = off) |
| `SLOW_RUNS` | writer | how many checks in a row must be slow before it says SLOW, default 3 |
| `PENDING` | writer | monitors Kuma is retrying: `ignore` (default), `slow` or `down` |
| `PRIORITY_GROUPS` | writer | status page groups whose problems come first, e.g. `"Public,Jobs,Host"` |
| `WRITER_USER` | writer | user the timer runs as, default `wrist-check` |
| `SKIP_KUMA_CHECK=yes` | writer | install even if Kuma can't be reached yet |

The validation runs with the environment of the running `caddy` service, so a Caddyfile that uses `{$CF_API_TOKEN}` or similar from the unit's `Environment=` or an `override.conf` validates like it does for Caddy itself.

### What the writer reports

DOWN monitors come first, then SLOW ones. Within each, monitors tagged `priority:high` come first, then the groups in `PRIORITY_GROUPS`, then the status page order. Monitors in maintenance are left out. With **Show Tags** turned on for the status page, two Kuma tags tune single monitors:

- `slow_ms` with a value, e.g. `slow_ms: 5000`: that monitor's own SLOW limit (0 = never SLOW);
- `priority` with the value `high`: its problems are listed first.

SLOW needs the last `SLOW_RUNS` heartbeats to all be over the limit, read from Kuma's own heartbeat list, so one slow check doesn't flip the watch and no state file is needed. If Kuma can't be read, `short` is `Kuma DOWN`, `count` is 0 and an `error` field says why.

Not using Caddy? Any web server works if it answers 200 with the file for `Authorization: Bearer <token>` and 404 for anything else.

## Watch setup

1. Install the APK (below) and add the **Homelab status** complication to your watch face. It shows `SETUP` / `TAP HERE`.
2. Tap it. The watch turns on Wi-Fi and shows a QR code, an address like `192.168.1.42:8765` and a 6-digit PIN.
3. Scan the QR code with your phone (or type the address into any browser on the same network). The page has the PIN filled in; paste the status URL and token and press **Test and save**.
4. The watch fetches the URL with the token first and only saves if it gets a valid `status.json`, so you see "wrong token" or "can't reach server" right on the page. The complication updates straight away.

No Wi-Fi, or a different network? Tap the keyboard button at the bottom edge (**Enter on watch**) and type the URL and token on the watch (the Wear OS keyboard can take input from the paired phone, which helps with the long token).

To change the URL or token later: open the status list (tap the complication) → **Settings** at the bottom.

How it's kept safe:
- The setup page is served by the watch itself, only while the setup screen is open (10 minutes at most), and only on its Wi-Fi address. Saving needs the PIN from the watch screen; after 5 wrong PINs a new one is drawn.
- The page travels over your local network as plain HTTP (the watch can't get a certificate for a LAN address), so do this on your home network, not public Wi-Fi.
- The token is stored encrypted with an AES key held in the Android Keystore, never logged, never shown again on the page, and not included in backups.
- The status URL has to be `https://`.

## Optional: categories

If `status.json` includes a `groups` array, the list screen shows collapsible categories instead of the flat list. A collapsed category shows its name and `UP n • DOWN n` (plus `• SLOW n` when something is slow). Tap it to expand it and see its problems (red/amber) and working services (green). Categories with problems start expanded. Without `groups`, the flat list above is used.

```json
{
  "short": "Sonarr DOWN", "title": "20:16", "count": 1,
  "problems": ["Sonarr DOWN", "Radarr SLOW"],
  "groups": [
    {"name": "Media", "problems": ["Sonarr DOWN", "Radarr SLOW"], "up": ["Jellyfin", "Immich"]},
    {"name": "Infra", "problems": [], "up": ["Caddy", "Uptime Kuma"]}
  ],
  "updated": 1795637760
}
```

- `name`: the category (for example the Uptime Kuma group name). Put ungrouped monitors in a group like `"Other"`.
- `problems`: the same `"<Name> DOWN"` / `"<Name> SLOW"` labels as the top-level `problems`, for this category only.
- `up`: plain names of this category's working services.
- Keep the top-level `problems` as it is: the complication still reads it.

The status writer from `server/install.sh` fills in `groups` from the groups on your Uptime Kuma status page.

## Build

Requirements: JDK 17+, Android SDK with platform 36 (Android Studio's SDK is fine; point to it with `ANDROID_HOME` or a `local.properties` containing `sdk.dir=...`). Gradle 9.2.1 and Android Gradle Plugin 9.0.0 come via the wrapper.

```
./gradlew assembleRelease
```

The APK lands in `app/build/outputs/apk/release/app-release.apk` (about 2.6 MB). It contains no URL or token, so it's safe to share; every watch is set up as described above.

The release build runs R8, which strips the parts of Compose and the other libraries the app doesn't use and drops unused resources. `./gradlew assembleDebug` still works (`app/build/outputs/apk/debug/app-debug.apk`), but keeps everything unshrunk and comes out at about 29 MB. Keep rules, if ever needed, go in `app/proguard-rules.pro`; a crash trace from a release build can be decoded with `app/build/outputs/mapping/release/mapping.txt`.

### Signing key

Android only installs an update over an existing app if both are signed with the same key. Otherwise `adb install -r` fails with `INSTALL_FAILED_UPDATE_INCOMPATIBLE` and you have to uninstall first (which also clears the URL and token on the watch). So sign every build with one key you keep:

1. Make a keystore once (any password; keep the file and password safe, they're not committed):
   ```
   keytool -genkeypair -keystore wrist-check.jks -storetype PKCS12 -alias wrist-check \
     -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Self-Hosting Wrist Check"
   ```
2. Copy `keystore.properties.example` to `keystore.properties` and fill in the path and password.

`keystore.properties`, `*.jks` and `*.keystore` are gitignored. Without `keystore.properties`, release builds are signed with the machine's debug key (`~/.android/debug.keystore`), which is stable on one computer but differs between computers. If `keystore.properties` exists but a value is missing, the build stops with a clear error.

If the watch still has an APK signed with a different key, uninstall it once (`adb uninstall uk.debil.status`) before installing; after that, updates install with `-r`.

Optional build-time default: copy `secrets.properties.example` to `secrets.properties` and fill in `STATUS_URL` and `STATUS_TOKEN`. The app then works without any watch setup, until something is entered on the watch (which wins). If the file exists, both values must be filled in or the build stops with a clear error. An APK built this way contains the token: don't share or commit it (both are gitignored). The GitHub Actions workflow builds without the file.

## Install on the watch

1. On the watch: Settings → Developer options → turn on **ADB debugging** and **Debug over Wi-Fi** (Developer options appear after tapping Settings → About watch → Software → Software version 7 times).
2. Pair and connect (the watch shows the IP, ports and pairing code under *Wireless debugging*):
   ```
   adb pair <watch-ip>:<pairing-port>
   adb connect <watch-ip>:<port>
   adb -s <watch-ip>:<port> install -r app/build/outputs/apk/release/app-release.apk
   ```

## Pick the complication

Long-press the watch face → **Customize** → swipe to the complications screen → tap a slot → choose **debil status → Homelab status**. Short slots get SHORT_TEXT, wide slots get LONG_TEXT.

On the Galaxy Wearable phone app the same thing is under Watch faces → Customize → Complications.

Logs: `adb logcat -s DebilStatus`

## Battery use

The app has no background service, wake lock, alarm or scheduled job. Wear OS asks the
complication for data every 15 minutes, and each ask is one small HTTPS request (8-second
timeouts, at most 32 KB). Requests that arrive close together (both complication types, a watch
face rebinding, the list screen opening) share one result for up to a minute. The setup screen
turns Wi-Fi on and keeps the screen awake only while it is open, for at most 10 minutes.

To see what the app costs on your watch (with adb connected):

```
adb shell dumpsys batterystats --reset        # start counting now, then wear the watch a few hours
adb shell dumpsys batterystats uk.debil.status | grep -iE "wake|network|mobile|wifi|cpu|Estimated power"
adb shell dumpsys batterystats | grep -A40 "Estimated power use"   # who used the battery
adb shell dumpsys alarm | grep -i debil       # expect nothing
adb shell dumpsys jobscheduler | grep -i debil  # expect nothing
adb shell dumpsys power | grep -i -A2 "wake locks"  # expect nothing from uk.debil.status
```

Leaving wireless debugging switched on keeps the watch's Wi-Fi up all day and drains the battery
quickly, so turn it off in Developer options after installing.

## Files

```
app/src/main/java/uk/debil/status/
  StatusDataSource.java   complication service, builds SHORT_TEXT / LONG_TEXT data
  StatusFetcher.java      HTTP fetch + JSON parsing
  Status.java             status model and wording
  ProblemsActivity.kt     scrollable full list (or categories), opened by tapping the complication
  Theme.kt                Material 3 theme, status colours and shared list rows
  Group.java              one category from the optional "groups" field
  Refresh.java            asks Wear OS to update the complication now
  Config.java             URL + token storage (token encrypted with an Android Keystore key)
  SetupActivity.kt        setup screen: Wi-Fi, QR code, address and PIN
  SetupServer.java        the one-page web server the phone talks to during setup
  ManualSetupActivity.kt  fallback: type URL and token on the watch
app/src/main/AndroidManifest.xml
app/src/main/res/drawable/ic_server.xml
server/
  install.sh              server setup: status writer + timer and/or the Caddy token check, guided or scripted
  kuma-status.py          writes status.json from an Uptime Kuma status page
secrets.properties.example  optional build-time default URL + token
keystore.properties.example optional release signing key
app/proguard-rules.pro      R8 keep rules for the release build
```
