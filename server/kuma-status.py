#!/usr/bin/env python3
"""Write status.json for the Wrist Check watch app from an Uptime Kuma status page.

Reads Uptime Kuma's public status page API (no Kuma login or API key needed) and writes
the JSON the watch expects, atomically. Run it every minute (install.sh sets up a systemd timer).

Settings come from environment variables (install.sh puts them in /etc/wrist-check/env):
  KUMA_URL   base URL of Uptime Kuma, e.g. http://127.0.0.1:3001
  KUMA_SLUG  slug of a status page that lists the monitors to watch, e.g. homelab
  OUT        output file (default /var/lib/wrist-check/status.json)
  SLOW_MS    response time in ms above which an UP monitor counts as SLOW (default 2000, 0 = off)

Output, e.g.:
  {"short":"PKVault DOWN","title":"20:16","count":1,"problems":["PKVault DOWN"],
   "up":["Immich","Jellyfin"],"updated":1795637760}
If Kuma can't be read: "short" is "Kuma DOWN" and an "error" field is present.
"""
import json
import os
import sys
import tempfile
import time
import urllib.request

KUMA_URL = os.environ.get("KUMA_URL", "http://127.0.0.1:3001").rstrip("/")
KUMA_SLUG = os.environ.get("KUMA_SLUG", "homelab")
OUT = os.environ.get("OUT", "/var/lib/wrist-check/status.json")
SLOW_MS = int(os.environ.get("SLOW_MS", "2000") or 0)
TIMEOUT = 10

DOWN, UP, PENDING, MAINTENANCE = 0, 1, 2, 3


def get(path):
    req = urllib.request.Request(KUMA_URL + path, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.load(r)


def build():
    now = int(time.time())
    title = time.strftime("%H:%M", time.localtime(now))
    try:
        page = get("/api/status-page/" + KUMA_SLUG)
        beats = get("/api/status-page/heartbeat/" + KUMA_SLUG).get("heartbeatList", {})
    except Exception as e:  # Kuma down, wrong slug, ...
        return {"short": "Kuma DOWN", "title": title, "count": 0, "problems": [],
                "error": type(e).__name__, "updated": now}

    down, slow, up = [], [], []
    seen = set()
    for group in page.get("publicGroupList", []):
        for mon in group.get("monitorList", []):
            mid, name = mon.get("id"), (mon.get("name") or "").strip()
            if not name or mid in seen:
                continue
            seen.add(mid)
            history = beats.get(str(mid)) or []
            if not history:
                continue  # no heartbeat yet
            last = max(history, key=lambda b: b.get("time") or "")
            status, ping = last.get("status"), last.get("ping")
            if status == DOWN:
                down.append(name + " DOWN")
            elif status == PENDING:
                slow.append(name + " SLOW")  # retrying: not down yet, but not fine either
            elif status == UP and SLOW_MS and isinstance(ping, (int, float)) and ping > SLOW_MS:
                slow.append(name + " SLOW")
            elif status == UP:
                up.append(name)
            # MAINTENANCE: left out on purpose

    problems = down + slow  # most important first
    return {"short": problems[0] if problems else "ALL UP", "title": title,
            "count": len(problems), "problems": problems, "up": up, "updated": now}


def write_atomic(path, data):
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".status-", suffix=".json")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, separators=(",", ":"))
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


if __name__ == "__main__":
    status = build()
    if "--print" in sys.argv:
        print(json.dumps(status, indent=2))
    else:
        write_atomic(OUT, status)
