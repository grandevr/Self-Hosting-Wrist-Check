#!/usr/bin/env bash
# Wrist Check server setup: token, Caddy route and (optionally) the Uptime Kuma status writer.
#
#   sudo ./install.sh              first-time setup (asks a few questions)
#   sudo ./install.sh --show       print the URL and token again (to set up another watch)
#   sudo ./install.sh --rotate     make a new token (every watch must be set up again)
#
# What it creates:
#   /etc/wrist-check/env                settings (status URL, Kuma URL and slug)
#   /etc/caddy/wrist-check.caddy        Caddy snippet: serves status.json only with the token, 404 otherwise
#   /usr/local/bin/wrist-check-status   the status writer (copy of kuma-status.py)
#   wrist-check-status.service/.timer   runs the writer every minute
# Needs: bash, openssl, python3, systemd, Caddy.
set -euo pipefail

CONF_DIR=/etc/wrist-check
ENV_FILE=$CONF_DIR/env
CADDY_SNIPPET=/etc/caddy/wrist-check.caddy
DATA_DIR=/var/lib/wrist-check
HERE=$(cd "$(dirname "$0")" && pwd)

die() { echo "Error: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root (sudo $0)"

ask() { # ask VAR "question" "default"
  local reply
  read -r -p "$2 [$3]: " reply
  printf -v "$1" '%s' "${reply:-$3}"
}

load_env() { [ -f "$ENV_FILE" ] && . "$ENV_FILE"; true; }

current_token() {
  [ -f "$CADDY_SNIPPET" ] || return 0
  sed -n 's/.*"Bearer \([0-9a-f]*\)".*/\1/p' "$CADDY_SNIPPET" | head -n1
}

write_caddy() { # write_caddy PATH TOKEN
  install -d -m 755 "$(dirname "$CADDY_SNIPPET")"
  umask 027
  cat > "$CADDY_SNIPPET" <<CADDY
# Managed by wrist-check install.sh. Import it inside your site block:  import wrist-check.caddy
# Serves the status file only with the right bearer token and answers 404 otherwise.
handle $1 {
	@wristcheck_denied not header Authorization "Bearer $2"
	respond @wristcheck_denied 404
	header Cache-Control "no-store"
	root * $DATA_DIR
	rewrite * /status.json
	file_server
}
CADDY
  umask 022
  # Caddy runs as user "caddy" on most installs; let it read the snippet but nobody else.
  if getent group caddy >/dev/null; then chgrp caddy "$CADDY_SNIPPET"; fi
  chmod 640 "$CADDY_SNIPPET"
}

reload_caddy() {
  if command -v caddy >/dev/null && systemctl is-active --quiet caddy; then
    if caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
      systemctl reload caddy && echo "Caddy reloaded."
    else
      echo "Caddy config doesn't validate yet. Add 'import wrist-check.caddy' to your site block, then: systemctl reload caddy"
    fi
  else
    echo "Reload Caddy yourself once 'import wrist-check.caddy' is in your site block."
  fi
}

show() {
  load_env
  local token; token=$(current_token)
  [ -n "${STATUS_URL:-}" ] && [ -n "$token" ] || die "not set up yet, run $0 without options"
  cat <<INFO

  Status URL:  $STATUS_URL
  Token:       $token

On the watch: tap the Homelab status complication (it says SETUP), scan the QR code with
your phone, and paste these two values into the page. Or use "Enter on watch".
Test from anywhere:  curl -H "Authorization: Bearer $token" $STATUS_URL

INFO
}

case "${1:-}" in
  --show) show; exit 0 ;;
  --rotate)
    load_env
    [ -n "${STATUS_PATH:-}" ] || die "not set up yet, run $0 without options"
    write_caddy "$STATUS_PATH" "$(openssl rand -hex 32)"
    reload_caddy; show; exit 0 ;;
  "") ;;
  *) die "unknown option $1 (use --show or --rotate)" ;;
esac

command -v openssl >/dev/null || die "openssl is needed"
load_env

echo "Wrist Check server setup"
echo
ask DOMAIN "Public domain Caddy serves" "${DOMAIN:-example.com}"
ask STATUS_PATH "Path of the status file" "${STATUS_PATH:-/health/status.json}"
case "$STATUS_PATH" in /*) ;; *) STATUS_PATH="/$STATUS_PATH" ;; esac
STATUS_URL="https://$DOMAIN$STATUS_PATH"

ask WRITER "Install the Uptime Kuma status writer? (no = you already write $DATA_DIR/status.json yourself)" "${WRITER:-yes}"
if [[ "$WRITER" =~ ^[Yy] ]]; then
  WRITER=yes
  ask KUMA_URL "Uptime Kuma URL (as seen from this server)" "${KUMA_URL:-http://127.0.0.1:3001}"
  ask KUMA_SLUG "Slug of the Kuma status page listing the monitors" "${KUMA_SLUG:-homelab}"
  ask SLOW_MS "Response time in ms that counts as SLOW (0 = off)" "${SLOW_MS:-2000}"
else
  WRITER=no
fi

install -d -m 755 "$CONF_DIR"
cat > "$ENV_FILE" <<ENV
DOMAIN=$DOMAIN
STATUS_PATH=$STATUS_PATH
STATUS_URL=$STATUS_URL
WRITER=$WRITER
KUMA_URL=${KUMA_URL:-}
KUMA_SLUG=${KUMA_SLUG:-}
SLOW_MS=${SLOW_MS:-2000}
OUT=$DATA_DIR/status.json
ENV
chmod 644 "$ENV_FILE"

TOKEN=$(current_token)
[ -n "$TOKEN" ] || TOKEN=$(openssl rand -hex 32)
write_caddy "$STATUS_PATH" "$TOKEN"
install -d -m 755 "$DATA_DIR"

if [ "$WRITER" = yes ]; then
  command -v python3 >/dev/null || die "python3 is needed for the status writer"
  install -m 755 "$HERE/kuma-status.py" /usr/local/bin/wrist-check-status
  id wrist-check >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin wrist-check
  cat > /etc/systemd/system/wrist-check-status.service <<UNIT
[Unit]
Description=Write Wrist Check status.json from Uptime Kuma

[Service]
Type=oneshot
EnvironmentFile=$ENV_FILE
ExecStart=/usr/local/bin/wrist-check-status
User=wrist-check
UMask=0022
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$DATA_DIR
UNIT
  cat > /etc/systemd/system/wrist-check-status.timer <<UNIT
[Unit]
Description=Write Wrist Check status.json every minute

[Timer]
OnCalendar=*-*-* *:*:00
AccuracySec=5s
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  chown wrist-check: "$DATA_DIR"
  systemctl daemon-reload
  systemctl enable --now wrist-check-status.timer
  systemctl start wrist-check-status.service || echo "First run failed: journalctl -u wrist-check-status"
  echo
  echo "Status writer installed. Current status:"
  set -a; . "$ENV_FILE"; set +a
  /usr/local/bin/wrist-check-status --print || true
fi

echo
grep -q 'import wrist-check.caddy' /etc/caddy/Caddyfile 2>/dev/null || cat <<NOTE
One manual step: add this line inside the "$DOMAIN { ... }" block of /etc/caddy/Caddyfile:

    import wrist-check.caddy

NOTE
reload_caddy
show
