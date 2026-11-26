#!/usr/bin/env python3
"""Write status.json for the Wrist Check watch app from an Uptime Kuma status page.

Reads Uptime Kuma's public status page API (no Kuma login or API key needed) and writes
the JSON the watch expects, atomically. Run it every minute (install.sh sets up a systemd timer).

Settings come from environment variables (install.sh puts them in /etc/wrist-check/env):
  KUMA_URL         base URL of Uptime Kuma, e.g. http://127.0.0.1:3001
  KUMA_SLUG        slug of a status page that lists the monitors to watch (required)
  OUT              output file (default /var/lib/wrist-check/status.json)
  SLOW_MS          response time in ms above which an UP monitor counts as SLOW (default 2000, 0 = off)
  SLOW_RUNS        how many of the latest checks in a row must all be over the limit before a
                   monitor counts as SLOW (default 3, 1 = only the latest check)
  PENDING          what to do with a monitor Kuma is retrying ("pending"):
                   ignore (default, leave it out) | slow (report "<Name> SLOW") | down ("<Name> DOWN")
  PRIORITY_GROUPS  comma-separated status page group names whose problems come first, in that
                   order, e.g. "Public,Jobs,Host". Empty = the order of the status page.
  DETAIL_POINTS    how many recent response times to send per monitor for the watch's sparkline
                   (default 40, 0 = none). Lowered automatically if the file would pass MAX_BYTES.
  MAX_BYTES        size limit for status.json (default 60000; the watch reads at most 96 KB)

Per-monitor settings, read from Kuma tags (turn on "Show Tags" on the status page):
  slow_ms:<ms>     this monitor's own SLOW limit (0 = never SLOW)
  priority:high    this monitor's problems come before everything else

Output, e.g.:
  {"short":"PKVault DOWN","title":"20:16","count":1,"problems":["PKVault DOWN"],
   "up":["Immich","Jellyfin"],
   "groups":[{"name":"Media","problems":["PKVault DOWN"],"up":["Immich","Jellyfin"]}],
   "updated":1795637760}
DOWN problems come before SLOW ones. "groups" follows the groups on the Kuma status page.
"details" has one entry per listed monitor, keyed by its name, for the watch's detail screen:
  {"state":"down","since":1795637400,"msg":"timeout of 48000ms exceeded","ping":null,
   "pings":[120,118,null,...],"up24":99.31,"cert":41}
  state  up | down | slow | pending       since  unix time the state began ("before": true when
  msg    Kuma's last message (cut to 120)        it began before the oldest check Kuma sent)
  ping   latest response time in ms         pings  recent response times, oldest first, null = down
  up24   24-hour uptime in percent          cert   days until the TLS certificate expires (only with
                                                   "Show Certificate Expiry" on the status page)
Fields Kuma doesn't provide are left out.
If Kuma can't be read: "short" is "Kuma DOWN", "count" is 0 and an "error" field is present.

  kuma-status.py            write OUT
  kuma-status.py --print    print the JSON instead
  kuma-status.py --summary  print one line, e.g. "2 problems: PKVault DOWN, Immich SLOW"
  kuma-status.py --check    only check that the status page exists (exit 0 ok, 3 no such page, 4 other error)
"""
import datetime
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

KUMA_URL = os.environ.get("KUMA_URL", "http://127.0.0.1:3001").rstrip("/")
KUMA_SLUG = os.environ.get("KUMA_SLUG", "").strip()
OUT = os.environ.get("OUT", "") or "/var/lib/wrist-check/status.json"
TIMEOUT = 10

DOWN, UP, PENDING, MAINTENANCE = 0, 1, 2, 3


def int_env(name, default):
    try:
        return max(0, int(os.environ.get(name, "") or default))
    except ValueError:
        sys.exit("%s must be a whole number" % name)


SLOW_MS = int_env("SLOW_MS", 2000)
SLOW_RUNS = max(1, int_env("SLOW_RUNS", 3))
PENDING_MODE = (os.environ.get("PENDING", "") or "ignore").strip().lower()
if PENDING_MODE not in ("ignore", "slow", "down"):
    sys.exit("PENDING must be ignore, slow or down")
PRIORITY_GROUPS = [g.strip().lower() for g in os.environ.get("PRIORITY_GROUPS", "").split(",") if g.strip()]
DETAIL_POINTS = int_env("DETAIL_POINTS", 40)
MAX_BYTES = max(4000, int_env("MAX_BYTES", 60000))
MSG_MAX = 120


class NoSuchPage(Exception):
    pass


def get(path):
    req = urllib.request.Request(KUMA_URL + path, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.load(r)


def fetch_page():
    slug = urllib.parse.quote(KUMA_SLUG, safe="")
    try:
        page = get("/api/status-page/" + slug)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            raise NoSuchPage(KUMA_SLUG) from e
        raise
    # Some Kuma versions answer 200 with {"ok": false, "msg": ...} for an unknown slug.
    if not isinstance(page, dict) or page.get("ok") is False or "publicGroupList" not in page:
        raise NoSuchPage(KUMA_SLUG)
    return page


def tags_of(mon):
    """Kuma tags as {name: value}, lower-case names. Only present with "Show Tags" on."""
    out = {}
    for t in mon.get("tags") or []:
        name = str(t.get("name") or "").strip().lower()
        if name:
            out[name] = str(t.get("value") or "").strip()
    return out


def slow_limit(tags):
    v = tags.get("slow_ms")
    if v is not None and v != "":
        try:
            return max(0, int(float(v)))
        except ValueError:
            pass
    return SLOW_MS


def is_slow(history, limit):
    """SLOW only when the last SLOW_RUNS checks were all UP and over the limit."""
    if not limit or len(history) < SLOW_RUNS:
        return False
    for beat in history[-SLOW_RUNS:]:
        ping = beat.get("ping")
        if beat.get("status") != UP or not isinstance(ping, (int, float)) or ping <= limit:
            return False
    return True


def priority_rank(tags, group_name):
    if tags.get("priority", "").lower() == "high":
        return 0
    g = group_name.lower()
    if g in PRIORITY_GROUPS:
        return 1 + PRIORITY_GROUPS.index(g)
    return 1 + len(PRIORITY_GROUPS)


def beat_time(beat):
    """Kuma heartbeat time ("2026-11-26 21:30:00.123", UTC) as unix seconds, or None."""
    t = str(beat.get("time") or "").strip().replace("T", " ").rstrip("Z")
    for fmt in ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S"):
        try:
            d = datetime.datetime.strptime(t, fmt)
            return int(d.replace(tzinfo=datetime.timezone.utc).timestamp())
        except ValueError:
            pass
    return None


def detail(mon, history, state, uptime, limit=0):
    """Detail for the watch's detail screen. Only fields Kuma actually gave us."""
    last = history[-1]
    d = {"state": state}
    status = last.get("status")

    def same(beat):  # still in the current state (for SLOW: UP and over the limit)
        if beat.get("status") != status:
            return False
        p = beat.get("ping")
        return state != "slow" or (isinstance(p, (int, float)) and p > limit)

    i = len(history) - 1
    while i > 0 and same(history[i - 1]):
        i -= 1
    since = beat_time(history[i])
    if since:
        d["since"] = since
        if i == 0:
            d["before"] = True  # the state started before the oldest check we have
    msg = " ".join(str(last.get("msg") or "").split())
    if msg:
        d["msg"] = msg[:MSG_MAX]
    ping = last.get("ping")
    d["ping"] = int(round(ping)) if isinstance(ping, (int, float)) and status == UP else None
    pings = []
    for b in history:
        p = b.get("ping")
        pings.append(int(round(p)) if isinstance(p, (int, float)) and b.get("status") == UP else None)
    d["pings"] = pings  # trimmed to DETAIL_POINTS in build()
    if isinstance(uptime, (int, float)):
        d["up24"] = round(uptime * 100, 2)
    cert = mon.get("certExpiryDaysRemaining")
    if isinstance(cert, (int, float)) and mon.get("validCert", True) is not False:
        d["cert"] = int(cert)
    return d


def fit(status):
    """Trims the sparklines so the file stays under MAX_BYTES. Returns the JSON text."""
    details = status.get("details") or {}
    full = {n: d.get("pings") or [] for n, d in details.items()}
    points = DETAIL_POINTS
    while True:
        for n, d in details.items():
            if points:
                d["pings"] = full[n][-points:]
            else:
                d.pop("pings", None)
        text = json.dumps(status, separators=(",", ":"))
        if len(text.encode()) <= MAX_BYTES or points == 0:
            break
        points //= 2
    if len(text.encode()) > MAX_BYTES and details:  # still too big: leave the detail out
        status = {k: v for k, v in status.items() if k != "details"}
        text = json.dumps(status, separators=(",", ":"))
    return text


def build():
    now = int(time.time())
    title = time.strftime("%H:%M", time.localtime(now))
    try:
        page = fetch_page()
        beats = get("/api/status-page/heartbeat/" + urllib.parse.quote(KUMA_SLUG, safe=""))
        uptimes = (beats.get("uptimeList") or {}) if isinstance(beats, dict) else {}
        beats = beats.get("heartbeatList", {}) if isinstance(beats, dict) else {}
    except Exception as e:  # Kuma down, wrong slug, ...
        return {"short": "Kuma DOWN", "title": title, "count": 0, "problems": [],
                "error": type(e).__name__, "updated": now}

    # Each problem: (kind 0=DOWN 1=SLOW, priority rank, position on the page, label, group index)
    found, up, groups, details = [], [], [], {}
    seen = set()
    pos = 0
    for group in page.get("publicGroupList") or []:
        gname = (group.get("name") or "").strip() or "Other"
        gi = len(groups)
        g_up, has_any = [], False
        for mon in group.get("monitorList") or []:
            mid, name = mon.get("id"), (mon.get("name") or "").strip()
            if not name or mid in seen:
                continue
            seen.add(mid)
            history = sorted(beats.get(str(mid)) or [], key=lambda b: str(b.get("time") or ""))
            if not history:
                continue  # no heartbeat yet
            tags = tags_of(mon)
            rank = priority_rank(tags, gname)
            status = history[-1].get("status")
            pos += 1
            kind = None
            if status == DOWN:
                kind = 0
            elif status == PENDING:
                kind = {"down": 0, "slow": 1}.get(PENDING_MODE)  # ignore: left out
                if kind is None:
                    continue
            elif status == UP:
                if is_slow(history, slow_limit(tags)):
                    kind = 1
                else:
                    g_up.append(name)
                    has_any = True
                    details[name] = detail(mon, history, "up", uptimes.get("%s_24" % mid))
                    continue
            else:
                continue  # MAINTENANCE (or unknown): left out on purpose
            state = "pending" if status == PENDING else ("down" if kind == 0 else "slow")
            details[name] = detail(mon, history, state, uptimes.get("%s_24" % mid), slow_limit(tags))
            label = name + (" DOWN" if kind == 0 else " SLOW")
            found.append((kind, rank, pos, label, gi))
            has_any = True
        up += g_up
        groups.append({"name": gname, "problems": [], "up": g_up, "_keep": has_any})

    found.sort(key=lambda p: (p[0], p[1], p[2]))  # DOWN first, then priority, then page order
    problems = [p[3] for p in found]
    for p in found:
        groups[p[4]]["problems"].append(p[3])
    groups = [{"name": g["name"], "problems": g["problems"], "up": g["up"]} for g in groups if g["_keep"]]
    return {"short": problems[0] if problems else "ALL UP", "title": title,
            "count": len(problems), "problems": problems, "up": up, "groups": groups,
            "details": details, "updated": now}


def write_atomic(path, data):
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".status-", suffix=".json")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(fit(data))
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def check():
    try:
        page = fetch_page()
    except NoSuchPage:
        print("Uptime Kuma at %s has no status page with the slug '%s'." % (KUMA_URL, KUMA_SLUG), file=sys.stderr)
        return 3
    except Exception as e:
        print("Couldn't read Uptime Kuma at %s: %s: %s" % (KUMA_URL, type(e).__name__, e), file=sys.stderr)
        return 4
    n = sum(len(g.get("monitorList") or []) for g in page.get("publicGroupList") or [])
    print("Found status page '%s' with %d monitors." % (KUMA_SLUG, n))
    return 0


def main():
    if not KUMA_SLUG:
        sys.exit("KUMA_SLUG is not set (the slug of the Uptime Kuma status page to read)")
    if "--check" in sys.argv:
        sys.exit(check())
    status = build()
    if "--print" in sys.argv:
        print(json.dumps(json.loads(fit(status)), indent=2))
    elif "--summary" in sys.argv:
        if "error" in status:
            print("Kuma DOWN (%s)" % status["error"])
        elif status["problems"]:
            print("%d problem%s: %s" % (status["count"], "" if status["count"] == 1 else "s", ", ".join(status["problems"])))
        else:
            print("ALL UP (%d monitors)" % len(status["up"]))
    else:
        write_atomic(OUT, status)


if __name__ == "__main__":
    main()
