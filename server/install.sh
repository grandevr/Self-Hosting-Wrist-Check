#!/usr/bin/env bash
# Wrist Check server setup: token, Caddy route and (optionally) the Uptime Kuma status writer.
#
# One line, nothing to download by hand:
#   curl -fsSL https://raw.githubusercontent.com/grandevr/Self-Hosting-Wrist-Check/main/server/install.sh | sudo bash
# Later:
#   ... | sudo bash -s -- --show        print the URL and token again (to set up another watch)
#   ... | sudo bash -s -- --rotate      make a new token (every watch must be set up again)
#   ... | sudo bash -s -- --uninstall   remove everything this script added
#
# Piped like this, nothing is left on disk except what it installs. Run as a downloaded file
# (sudo ./install.sh), it deletes itself at the end, unless it sits in a git checkout.
#
# What it installs:
#   /etc/wrist-check/env                settings (status URL, Kuma URL and slug)
#   /etc/caddy/wrist-check.caddy        Caddy snippet: serves status.json only with the token, 404 otherwise
#   /usr/local/bin/wrist-check-status   the status writer (kuma-status.py), only if you choose it
#   wrist-check-status.service/.timer   runs the writer every minute
#   /var/lib/wrist-check/status.json    the file the watch reads
#
# Answers can be given ahead of time as environment variables (DOMAIN, STATUS_PATH, WRITER,
# KUMA_URL, KUMA_SLUG, SLOW_MS, EDIT_CADDYFILE); without a terminal the defaults are used.
# Needs: bash, curl, openssl, systemd, Caddy; python3 for the status writer.

# Everything runs from main() at the very end, so a half-downloaded script never runs partly.
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/grandevr/Self-Hosting-Wrist-Check/${WRIST_CHECK_REF:-main}/server"
CONF_DIR=/etc/wrist-check
ENV_FILE=$CONF_DIR/env
CADDYFILE=/etc/caddy/Caddyfile
CADDY_SNIPPET=/etc/caddy/wrist-check.caddy
DATA_DIR=/var/lib/wrist-check
WRITER_BIN=/usr/local/bin/wrist-check-status
UNIT_DIR=/etc/systemd/system
IMPORT_LINE="import wrist-check.caddy"
TMP_DIR=""

die() { echo "Error: $*" >&2; exit 1; }
cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; true; }

ask() { # ask VAR "question" "default"   (reads the terminal, even when the script is piped in)
  local reply=""
  if ( : </dev/tty >/dev/tty ) 2>/dev/null; then
    printf '%s [%s]: ' "$2" "$3" > /dev/tty
    read -r reply < /dev/tty || true
  fi
  printf -v "$1" '%s' "${reply:-$3}"
}

load_env() { [ -f "$ENV_FILE" ] && . "$ENV_FILE"; true; }

current_token() {
  [ -f "$CADDY_SNIPPET" ] || return 0
  sed -n 's/.*"Bearer \([0-9a-f]*\)".*/\1/p' "$CADDY_SNIPPET" | head -n1
}

write_caddy() { # write_caddy PATH TOKEN
  install -d -m 755 "$(dirname "$CADDY_SNIPPET")"
  ( umask 077; cat > "$CADDY_SNIPPET" <<CADDY
# Managed by wrist-check install.sh. Imported inside your site block:  $IMPORT_LINE
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
  )
  # Caddy runs as user "caddy" on most installs: let it read the snippet, nobody else.
  if getent group caddy >/dev/null; then chgrp caddy "$CADDY_SNIPPET"; chmod 640 "$CADDY_SNIPPET"; fi
}

caddy_valid() {
  command -v caddy >/dev/null && caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1
}

reload_caddy() {
  if command -v caddy >/dev/null && systemctl is-active --quiet caddy; then
    if caddy_valid; then
      systemctl reload caddy && echo "Caddy reloaded."
    else
      echo "Caddy config doesn't validate: check $CADDYFILE, then: systemctl reload caddy"
    fi
  else
    echo "Caddy isn't running as a systemd service here: reload it yourself."
  fi
}

# Adds the import line right after "<domain> {" in the Caddyfile. Keeps a backup and puts the
# old file back if Caddy doesn't accept the result.
add_import() {
  grep -q "^[[:space:]]*$IMPORT_LINE" "$CADDYFILE" 2>/dev/null && return 0
  local manual="Add this line inside the \"$DOMAIN { ... }\" block of $CADDYFILE yourself, then reload Caddy:

    $IMPORT_LINE
"
  if [ ! -f "$CADDYFILE" ] || ! command -v caddy >/dev/null; then echo "$manual"; return 0; fi
  ask EDIT_CADDYFILE "Add '$IMPORT_LINE' to the $DOMAIN block in $CADDYFILE? (a backup is kept)" "${EDIT_CADDYFILE:-yes}"
  if [[ ! "$EDIT_CADDYFILE" =~ ^[Yy] ]]; then echo "$manual"; return 0; fi

  local esc backup
  esc=$(printf '%s' "$DOMAIN" | sed 's/[.[\*^$/]/\\&/g')
  if ! grep -Eq "^(https?://)?$esc([:, ][^{]*)?[[:space:]]*\{[[:space:]]*$" "$CADDYFILE"; then
    echo "Couldn't find a \"$DOMAIN {\" block in $CADDYFILE."; echo "$manual"; return 0
  fi
  backup="$CADDYFILE.wrist-check.bak"
  cp -p "$CADDYFILE" "$backup"
  sed -E -i "0,/^(https?:\/\/)?$esc([:, ][^{]*)?[[:space:]]*\{[[:space:]]*$/s//&\n\t$IMPORT_LINE/" "$CADDYFILE"
  if caddy_valid; then
    echo "Added '$IMPORT_LINE' to $CADDYFILE (old version: $backup)."
  else
    cp -p "$backup" "$CADDYFILE"
    echo "Caddy didn't accept the edited Caddyfile, so it was put back unchanged."; echo "$manual"
  fi
}

show() {
  load_env
  local token; token=$(current_token)
  [ -n "${STATUS_URL:-}" ] && [ -n "$token" ] || die "not set up yet: run the installer without options first"
  cat <<INFO

  Status URL:  $STATUS_URL
  Token:       $token

On the watch: tap the Homelab status complication (it says SETUP), scan the QR code with
your phone, and paste these two values into the page. Or use "Enter on watch".
Test from anywhere:  curl -H "Authorization: Bearer $token" $STATUS_URL

INFO
}

uninstall() {
  systemctl disable --now wrist-check-status.timer 2>/dev/null || true
  rm -f "$UNIT_DIR/wrist-check-status.service" "$UNIT_DIR/wrist-check-status.timer" "$WRITER_BIN"
  systemctl daemon-reload 2>/dev/null || true
  if [ -f "$CADDYFILE" ] && grep -q "^[[:space:]]*$IMPORT_LINE" "$CADDYFILE"; then
    cp -p "$CADDYFILE" "$CADDYFILE.wrist-check.bak"
    sed -i "/^[[:space:]]*$IMPORT_LINE[[:space:]]*$/d" "$CADDYFILE"
    echo "Removed '$IMPORT_LINE' from $CADDYFILE (old version: $CADDYFILE.wrist-check.bak)."
  fi
  rm -f "$CADDY_SNIPPET"
  rm -rf "$CONF_DIR" "$DATA_DIR"
  id wrist-check >/dev/null 2>&1 && userdel wrist-check 2>/dev/null || true
  reload_caddy
  echo "Wrist Check removed from this server."
}

install_writer() {
  command -v python3 >/dev/null || die "python3 is needed for the status writer"
  local src
  # Use kuma-status.py next to this script if there is one (git checkout), otherwise download it.
  if [ -f "$0" ] && [ "$(basename "$0")" = install.sh ] && [ -f "$(dirname "$0")/kuma-status.py" ]; then
    src="$(dirname "$0")/kuma-status.py"
  else
    command -v curl >/dev/null || die "curl is needed to download the status writer"
    TMP_DIR=$(mktemp -d)
    src="$TMP_DIR/kuma-status.py"
    curl -fsSL "$REPO_RAW/kuma-status.py" -o "$src" || die "couldn't download $REPO_RAW/kuma-status.py"
  fi
  install -m 755 "$src" "$WRITER_BIN"
  id wrist-check >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin wrist-check
  cat > "$UNIT_DIR/wrist-check-status.service" <<UNIT
[Unit]
Description=Write Wrist Check status.json from Uptime Kuma

[Service]
Type=oneshot
EnvironmentFile=$ENV_FILE
ExecStart=$WRITER_BIN
User=wrist-check
UMask=0022
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$DATA_DIR
UNIT
  cat > "$UNIT_DIR/wrist-check-status.timer" <<UNIT
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
  ( set -a; . "$ENV_FILE"; set +a; "$WRITER_BIN" --print ) || true
}

# Deletes this script if it was run from a file, unless that file is part of a git checkout.
remove_self() {
  local self="$0"
  [ -f "$self" ] && [ "$(basename "$self")" = "install.sh" ] || return 0
  if command -v git >/dev/null && git -C "$(dirname "$self")" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi
  rm -f "$self" && echo "Installer removed ($self)."
}

setup() {
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

  local token; token=$(current_token)
  [ -n "$token" ] || token=$(openssl rand -hex 32)
  write_caddy "$STATUS_PATH" "$token"
  install -d -m 755 "$DATA_DIR"

  [ "$WRITER" = yes ] && install_writer

  echo
  add_import
  reload_caddy
  show
}

main() {
  [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
  trap cleanup EXIT
  case "${1:-}" in
    --show) show ;;
    --rotate)
      load_env
      [ -n "${STATUS_PATH:-}" ] || die "not set up yet: run the installer without options first"
      write_caddy "$STATUS_PATH" "$(openssl rand -hex 32)"
      reload_caddy; show ;;
    --uninstall) uninstall ;;
    "") setup ;;
    *) die "unknown option $1 (use --show, --rotate or --uninstall)" ;;
  esac
  remove_self
}

main "$@"
