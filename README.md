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
- Fetch: `GET <status URL>` with `Authorization: Bearer <token>`, 8 s connect/read timeouts, response capped at 96 KB, redirects not followed. The token is never logged. Uses the watch's own connection (phone over Bluetooth, or Wi-Fi/LTE).

## Problem list

- Tapping the complication opens the **debil status** screen: the status (`ALL UP`, `2 DOWN`, ...), every problem in a scrollable list (touch or rotating bezel), the check time and a round **Refresh** button at the bottom edge. It is also in the watch's app list.
- The screens use Material 3 for Wear OS and pick up the watch's dynamic colours (Wear OS 6 takes them from the watch face). Status colours stay fixed: green for up, amber for slow, red for down.
- Opening the screen, or tapping **Refresh**, also asks Wear OS to refresh the complication, so the watch face catches up at the same time.
- Complications only get a single tap from the watch face; double tap and long press aren't passed to the app (long press opens watch face editing).

## Service detail

Tap a service in the list to open its detail screen (rows that can be opened end in `›`). It shows:

- **status and since when**: `DOWN`, `SLOW`, `UP` or `PENDING`, e.g. "since 14:02 · 1 h 12 min" ("since before ..." when the change is older than the checks Kuma keeps on its status page);
- **Kuma's message**: the last heartbeat message, e.g. `timeout of 48000ms exceeded` or `502 - Bad Gateway`;
- **response time**: the latest ping, and a small graph of the last 40 checks (red ticks along the bottom are checks that got no answer);
- **24h uptime** in percent;
- **certificate expiry** in days, when **Show Certificate Expiry** is turned on for the Kuma status page.

Everything comes from the same `status.json` the list already fetched, so opening a detail costs no extra request and no extra battery. Items the server doesn't send are left out. Each item can be turned off under **Settings** at the bottom of the list. Rows can only be tapped when the server sends `details` (the writer from `server/install.sh` does, from this version on; update it by running the installer again).

The `details` object, keyed by service name (every field optional):

```json
"details": {
  "PKVault": {"state":"down","since":1795637400,"msg":"timeout of 48000ms exceeded","ping":null,
              "pings":[120,118,null,null],"up24":95.83},
  "Jellyfin": {"state":"up","since":1795600000,"before":true,"ping":144,"pings":[150,144],"up24":100,"cert":41}
}
```

`state` is `up`, `down`, `slow` or `pending`; `since` is unix time; `pings` are milliseconds, oldest first, `null` for a check with no answer; `up24` is percent; `cert` is days left.

## Optional: list working services

If `status.json` includes an `up` array with the names of the services that are working, the list screen shows them under the problems (header `UP · n`). Without the field everything works as before.

```json
{"short":"PKVault DOWN","title":"20:16","count":1,"problems":["PKVault DOWN"],"up":["Immich","Jellyfin","Nextcloud"],"updated":1795637760}
```

Use plain service names (no ` UP` suffix), in the order you want them shown. Leave slow and down services out of `up`, since they're already in `problems`. The complication ignores this field.

## Server setup

The watch reads one URL, such as `https://example.com/health/status.json`. It must return the status file when the request carries your token, and 404 otherwise. `server/install.sh` sets this up. It installs two parts, on one machine or on two:

- **the writer** reads your Uptime Kuma status page every minute and writes `status.json`. It runs where Kuma can be reached and needs python3.
- **the token check** goes into the reverse proxy that the watch connects to. It turns away requests without the token.

### Supported reverse proxies

| Proxy | What the installer does |
|---|---|
| Caddy | adds the check to the Caddyfile itself, validates, reloads, rolls back on failure |
| nginx | writes `/etc/nginx/snippets/wrist-check.conf`, includes it in the `server { }` for your domain, runs `nginx -t`, reloads, rolls back on failure |
| Nginx Proxy Manager | prints the lines for the proxy host's **Advanced** tab |
| Traefik | prints a file-provider config (two routers and a service). Without the token Traefik answers 403, because it has no built-in 404 reply |
| Apache | prints the lines for the `<VirtualHost>` (uses mod_rewrite), plus the modules to turn on |
| HAProxy | prints one `http-request deny` line for the frontend |
| anything else | describes the rule: with `Authorization: Bearer <token>` pass on as usual, without it answer 404 |

In a terminal it finds the proxies on the machine and asks which one the watch goes through; `PROXY=` answers it ahead of time (default `caddy`). Not every proxy can do every mode: HAProxy and "other" only check the token (`check-only`), and Traefik always passes the path to an address you give (`proxy`).

Run it in a terminal and it guides you. It looks around the machine first (Kuma, its status pages, the reverse proxies and their sites, a web server folder that already serves `/health/`, older status timers), suggests an answer to each question, and shows a plan before it changes anything. Add `--dry-run` to see the plan without changing anything.

### Everything on one machine

```
curl -fsSL https://raw.githubusercontent.com/grandevr/Self-Hosting-Wrist-Check/main/server/install.sh | sudo bash
```

Then print the URL and token for the watch with the same line plus `-s -- --show`, and enter them on the watch (see [Watch setup](#watch-setup)).

### Writer at home, token check on another machine

A common homelab layout: Kuma and a web server (nginx, or an inner Caddy) at home, and a public reverse proxy (Caddy, nginx, Traefik, ...), often on a VPS, that handles HTTPS and passes requests home. Set it up in this order:

1. **On the Kuma machine, install the writer.**

   ```
   curl -fsSL .../server/install.sh | sudo bash -s -- --writer-only
   ```

   Point it at a folder your web server already serves, for example the folder behind `/health/`. The existing chain of proxies then carries the file to the public Caddy unchanged. If the writer's user can't write to that folder, the installer asks before changing anything: it can give that user access to that one folder (`acl`) or run the writer as the folder's owner (`owner`). At the end it prints the exact command for step 2.

2. **On the public proxy, add the token check.** The steps below use Caddy; nginx works the same way, and the other proxies get their lines printed with the steps to add them. Pick the mode that matches your setup:

   | Mode | Use it when |
   |---|---|
   | `check-only` | this site already passes requests home with `reverse_proxy`. The check turns away requests without the token, and the rest go on as before. This is usually the one. |
   | `proxy` | the site passes requests on inside `handle` or `route` sections, where an added check would be skipped. The check fetches the file from an address you give. |
   | `file` | the status file is on this machine. |

   With sudo, the installer edits the Caddyfile itself. It backs it up, checks the result with `caddy validate`, reloads, and puts everything back if either step fails:

   ```
   curl -fsSL .../server/install.sh | sudo bash -s -- --route-only
   ```

   Without sudo (you can edit `/etc/caddy` and reload Caddy, but can't run the installer as root), print the lines and paste them in yourself. The output ends with numbered steps:

   ```
   curl -fsSL .../server/install.sh | bash -s -- --print-snippet
   ```

   `SNIPPET_OUT=/etc/caddy/wrist-check.caddy` writes the lines to a file you can `import` instead. The file is made readable for Caddy.

3. **Already checking a token there?** The installer finds an existing token check for the same folder, including one in a file the site imports, and lists exactly those lines. Error pages (`handle_errors`) and headers aren't affected and stay. It offers to keep your current token, so watches already set up keep working. With sudo it can comment the old lines out for you: nothing is deleted, the files are backed up, and the change is undone if Caddy complains. Otherwise you remove those lines by hand.

4. **Anything in between**, such as an inner Caddy at home, stays as it is.

5. **Set up the watch**: run `--show` on the machine with the token check.

**Only the status file, or the whole folder?** By default the check covers just `status.json`. Other paths in the same folder are then answered by whatever serves them (for example an nginx 403 or 404). Answer `folder` (or `PROTECT=folder`) to cover everything under `/health/`. The installer suggests this when your old check covered the whole folder.

**Optional extras the installer leaves alone.** Your `handle_errors` blocks stay as they are. Two that pair well with this layout:

- on the public Caddy, when home can't be reached (502/503/504 for the status path), answer 200 with a small `status.json` whose `short` is `HOME DOWN`, so the watch names the problem instead of showing `OFFLINE`;
- on an inner Caddy, the same for the machine behind it, e.g. `<machine> DOWN`.

Set `updated` to the current time (Caddy's `{time.now.unix}` placeholder), or the watch shows `STALE`. Put the label in `problems` and set `count` to 1.

### Without curl

python3 is enough to fetch and run the installer:

```
python3 -c "import urllib.request,sys;sys.stdout.buffer.write(urllib.request.urlopen('https://raw.githubusercontent.com/grandevr/Self-Hosting-Wrist-Check/main/server/install.sh').read())" | sudo bash -s -- --writer-only
```

Or download `install.sh` and `kuma-status.py` on any machine, copy both to the server, and run `sudo bash install.sh --writer-only`. Run from a file, the installer deletes itself and `kuma-status.py` when done, unless it's in a git checkout or you set `KEEP_INSTALLER=yes`.

### Later

```
... | sudo bash -s -- --show          # print the URL and token (to set up another watch)
... | sudo bash -s -- --rotate        # new token; every watch must be set up again
... | sudo bash -s -- --uninstall     # remove everything it added here (lists it first)
... | sudo bash -s -- --uninstall --writer-only   # only the writer (a token check elsewhere stays)
```

`--dry-run` works with all of these.

### Settings

Every question can be answered ahead of time with an environment variable, e.g. `curl ... | sudo KUMA_SLUG=homelab OUT_ACCESS=acl bash -s -- --writer-only`. Without a terminal (or with `NONINTERACTIVE=yes`) nothing is guessed. If a required answer is missing, the installer stops before changing anything and tells you which variable to set. Answers are saved in `/etc/wrist-check/env` and reused next time. A variable on the command line wins over the saved value.

| Variable | Part | Meaning |
|---|---|---|
| `ROLE` | both | `all`, `writer` or `route` (same as `--writer-only` / `--route-only`) |
| `PROXY` | check | `caddy` (default), `nginx`, `npm`, `traefik`, `apache`, `haproxy` or `other` |
| `NGINX_SITE` | check | nginx: the file with the `server { }` for your domain, if the installer doesn't find it |
| `DOMAIN` | check | domain the watch connects to (required) |
| `STATUS_PATH` | check | path of the status file, default `/health/status.json` |
| `ROUTE` | check | `file`, `check-only` or `proxy` (required when the writer is elsewhere) |
| `UPSTREAM` | check | where `proxy` fetches the file, e.g. `http://10.0.0.5:8080` |
| `PROTECT` | check | `file` (default) or `folder`: what the check covers |
| `TOKEN_FILE` / `TOKEN` | check | reuse an existing token (e.g. from your password manager). `TOKEN_FILE` keeps it out of your shell history |
| `OLD_CHECK` | check | an existing token check for the folder: `disable` (comment it out) or `keep`. Without it, the installer stops and lists the lines |
| `CADDYFILE`, `CADDY_SNIPPET` | check | default `/etc/caddy/Caddyfile` and `wrist-check.caddy` next to it |
| `EDIT_CADDYFILE=no` | check | don't touch the Caddyfile; print the import line to add instead |
| `SKIP_VALIDATE=yes` | check | skip `caddy validate` and rely on the reload (a failed reload is still rolled back) |
| `RELOAD_CMD` | check | how to reload Caddy or nginx, e.g. `"sudo systemctl reload caddy"` |
| `SNIPPET_OUT` | check | with `--print-snippet`: write the lines to this file |
| `KUMA_URL` | writer | Uptime Kuma as seen from this machine, default `http://127.0.0.1:3001` |
| `KUMA_SLUG` | writer | the status page's slug, the last part of `/status/<slug>` (required, checked against Kuma) |
| `OUT` | writer | file to write, default `/var/lib/wrist-check/status.json` |
| `OUT_ACCESS` | writer | when the writer's user can't write to `OUT`'s folder: `acl` (give it access to that folder) or `owner` (run as the folder's owner) |
| `SLOW_MS` | writer | response time that counts as slow, default 2000 (0 = off) |
| `SLOW_RUNS` | writer | how many checks in a row must be slow before it says SLOW, default 3 |
| `PENDING` | writer | monitors Kuma is retrying: `ignore` (default), `slow` or `down` |
| `PRIORITY_GROUPS` | writer | status page groups whose problems come first, e.g. `"Public,Jobs,Host"` |
| `WRITER_USER` | writer | user the timer runs as, default `wrist-check` |
| `SKIP_KUMA_CHECK=yes` | writer | install even if Kuma can't be reached yet |

`caddy validate` runs with the environment of the running Caddy service. A Caddyfile that uses `{$CF_API_TOKEN}` (or similar) from the service's settings, such as an `override.conf`, therefore validates the same way Caddy itself would read it.

### What the writer reports

DOWN monitors come first, then SLOW ones. Within each, the groups in `PRIORITY_GROUPS` come first, then the status page order. Monitors in maintenance are left out. SLOW needs the last `SLOW_RUNS` checks to all be over the limit, so one slow check doesn't flip the watch. It reads them from Kuma's own heartbeat list, so no state file is needed. If Kuma can't be read, `short` is `Kuma DOWN`, `count` is 0 and an `error` field says why.

**Per-monitor settings (optional).** Two Kuma tags tune single monitors: `slow_ms` with a value (that monitor's own SLOW limit, 0 = never SLOW) and `priority` with the value `high` (listed before everything else). The status page only passes tags along with **Show Tags** turned on, and that also shows the tags to anyone who can open the page. If you'd rather keep tags hidden, leave it off and use `PRIORITY_GROUPS` and `SLOW_MS` instead.

The writer also adds `details` for the watch's detail screen (see [Service detail](#service-detail)). Two settings tune its size; the defaults suit most setups, and they can be set with `sudo systemctl edit wrist-check-status` (`[Service]` then `Environment=DETAIL_POINTS=20`):

- `DETAIL_POINTS`: response times per monitor for the graph, default 40 (0 = no graph);
- `MAX_BYTES`: size limit for `status.json`, default 60000. When the file would be bigger, the graphs get fewer points, and as a last resort `details` is left out. The watch reads at most 96 KB.

Using something not listed? Pick `other`: any web server works if it answers 200 with the file for `Authorization: Bearer <token>` and 404 for anything else.

## Watch setup

1. Install the APK (below) and add the **Homelab status** complication to your watch face. It shows `SETUP` / `TAP HERE`.
2. Tap it. The watch turns on Wi-Fi and shows a QR code, an address like `192.168.1.42:8765` and a 6-digit PIN.
3. Scan the QR code with your phone (or type the address into any browser on the same network). The page has the PIN filled in; paste the status URL and token and press **Test and save**.
4. The watch fetches the URL with the token first and only saves if it gets a valid `status.json`, so you see "wrong token" or "can't reach server" right on the page. The complication updates straight away.

No Wi-Fi, or a different network? Tap the keyboard button at the bottom edge (**Enter on watch**) and type the URL and token on the watch (the Wear OS keyboard can take input from the paired phone, which helps with the long token).

To change the URL or token later: open the status list (tap the complication) → **Settings** at the bottom → **Setup**. Settings also has the switches for the detail screen.

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
  DetailActivity.kt       one service's detail, opened by tapping it in the list
  Detail.java             one service from the optional "details" field
  SettingsActivity.kt     detail screen switches and the Setup button
  DisplayPrefs.kt         which detail items are shown
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
  install.sh              server setup: status writer + timer and/or the token check for Caddy, nginx and others, guided or scripted
  kuma-status.py          writes status.json from an Uptime Kuma status page
secrets.properties.example  optional build-time default URL + token
keystore.properties.example optional release signing key
app/proguard-rules.pro      R8 keep rules for the release build
```
