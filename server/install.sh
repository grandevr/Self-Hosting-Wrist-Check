#!/usr/bin/env bash
# Wrist Check server setup: the Uptime Kuma status writer and/or the Caddy route that checks the token.
#
# One server with Kuma, Caddy and Python, one line:
#   curl -fsSL https://raw.githubusercontent.com/grandevr/Self-Hosting-Wrist-Check/main/server/install.sh | sudo bash
#
# Split across machines (writer next to Kuma, token check on the edge Caddy):
#   ... | sudo bash -s -- --writer-only              on the Kuma machine (needs python3, not Caddy)
#   ... | sudo bash -s -- --route-only               on the Caddy machine (edits the Caddyfile, reloads)
#   ... | bash -s -- --print-snippet                 no root: print the Caddy lines to paste in yourself
#
# Later:
#   --show        print the URL and token (to set up another watch); nothing prints the token otherwise
#   --rotate      make a new token (every watch must be set up again)
#   --uninstall   remove what this script added; with --writer-only / --route-only only that part
#
# Without curl (python3 is enough):
#   python3 -c "import urllib.request,sys;sys.stdout.buffer.write(urllib.request.urlopen('https://raw.githubusercontent.com/grandevr/Self-Hosting-Wrist-Check/main/server/install.sh').read())" | sudo bash -s -- --writer-only
# Or download install.sh and kuma-status.py anywhere, copy both to the server and run sudo bash install.sh.
#
# Piped, nothing is left on disk except what it installs. Run as a downloaded file, it deletes itself
# (and kuma-status.py next to it) at the end, unless it sits in a git checkout or KEEP_INSTALLER=yes.
#
# What it installs (as root):
#   /etc/wrist-check/env                settings
#   /etc/wrist-check/token              the token, readable by root only
#   /etc/caddy/wrist-check.caddy        route role: the Caddy snippet, imported in your site block
#   /usr/local/bin/wrist-check-status   writer role: kuma-status.py
#   wrist-check-status.service/.timer   writer role: runs the writer every minute
#   /var/lib/wrist-check/status.json    writer role: the file the watch reads (OUT changes it)
#
# Every question can be answered ahead of time with an environment variable; without a terminal
# (or with NONINTERACTIVE=yes) the required ones must be given, nothing is guessed. See the README.
#   Route:  DOMAIN  STATUS_PATH  ROUTE=file|check-only|proxy  UPSTREAM  TOKEN_FILE  TOKEN
#           CADDYFILE  CADDY_SNIPPET  EDIT_CADDYFILE  SKIP_VALIDATE  RELOAD_CMD  ALLOW_EXISTING_ROUTE
#           SNIPPET_OUT (with --print-snippet: write to this file instead of stdout)
#   Writer: KUMA_URL  KUMA_SLUG  OUT  SLOW_MS  SLOW_RUNS  PENDING=ignore|slow|down  PRIORITY_GROUPS
#           WRITER_USER  WRITER_SRC  SKIP_KUMA_CHECK
#   Both:   ROLE=all|writer|route  CONF_DIR
# Needs: bash and coreutils. Writer: python3, systemd. Route: Caddy. curl only to pipe this script.

# Everything runs from main() at the very end, so a half-downloaded script never runs partly.
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/grandevr/Self-Hosting-Wrist-Check/${WRIST_CHECK_REF:-main}/server"
IS_ROOT=no; [ "$(id -u)" -eq 0 ] && IS_ROOT=yes
if [ "$IS_ROOT" = yes ]; then CONF_DIR=${CONF_DIR:-/etc/wrist-check}
else CONF_DIR=${CONF_DIR:-${XDG_CONFIG_HOME:-${HOME:-/tmp}/.config}/wrist-check}; fi
ENV_FILE=$CONF_DIR/env
TOKEN_PATH=$CONF_DIR/token
CADDYFILE=${CADDYFILE:-/etc/caddy/Caddyfile}
CADDY_SNIPPET=${CADDY_SNIPPET:-$(dirname "$CADDYFILE")/wrist-check.caddy}
if [ "$(dirname "$CADDY_SNIPPET")" = "$(dirname "$CADDYFILE")" ]; then IMPORT_LINE="import $(basename "$CADDY_SNIPPET")"
else IMPORT_LINE="import $CADDY_SNIPPET"; fi
DEFAULT_OUT=/var/lib/wrist-check/status.json
DATA_DIR=/var/lib/wrist-check
WRITER_BIN=${WRITER_BIN:-/usr/local/bin/wrist-check-status}
UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
SETTINGS="ROLE DOMAIN STATUS_PATH STATUS_URL ROUTE UPSTREAM KUMA_URL KUMA_SLUG OUT SLOW_MS SLOW_RUNS PENDING PRIORITY_GROUPS WRITER_USER"
TMP_DIR=""
USED_LOCAL_WRITER=""
exec 3>&1   # messages; moved to stderr by --print-snippet so stdout is only the snippet

die() { echo "Error: $*" >&2; exit 1; }
msg() { printf '%s\n' "$*" >&3; }
cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; true; }
is_yes() { [[ "${1:-}" =~ ^([Yy]|[Yy][Ee][Ss]|1|true)$ ]]; }

have_tty() { ! is_yes "${NONINTERACTIVE:-}" && ( : </dev/tty >/dev/tty ) 2>/dev/null; }

ask() { # ask VAR "question" "default": asks on the terminal; without one keeps VAR or takes the default
  local reply="" cur="${!1:-$3}"
  if have_tty; then
    printf '%s [%s]: ' "$2" "$cur" > /dev/tty
    read -r reply < /dev/tty || true
  fi
  printf -v "$1" '%s' "${reply:-$cur}"
}

need() { # need VAR "question" "hint": like ask, but there's no default to fall back on
  local reply="" cur="${!1:-}"
  if ! have_tty; then
    [ -n "$cur" ] || die "$1 is required and there's no terminal to ask ($3). Set it, e.g.: ... | $([ "$IS_ROOT" = yes ] && echo "sudo ")$1=... bash"
    return 0
  fi
  while :; do
    if [ -n "$cur" ]; then printf '%s [%s]: ' "$2" "$cur" > /dev/tty; else printf '%s: ' "$2" > /dev/tty; fi
    read -r reply < /dev/tty || die "no answer for $1"
    reply=${reply:-$cur}
    [ -n "$reply" ] && break
    echo "  An answer is needed ($3)." > /dev/tty
  done
  printf -v "$1" '%s' "$reply"
}

check() { # check VAR REGEX "what it should look like"
  [[ "${!1}" =~ $2 ]] || die "$1='${!1}' isn't valid: $3"
}

# Settings file: KEY="value" lines. Read without sourcing it, and never over a value already set in
# the environment, so DOMAIN=... on the command line wins over what was saved last time.
load_env() {
  [ -r "$ENV_FILE" ] || return 0
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^([A-Z_]+)=\"?([^\"]*)\"?$ ]] || continue
    key=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}
    case " $SETTINGS WRITER " in *" $key "*) ;; *) continue ;; esac
    [ -n "${!key+x}" ] || printf -v "$key" '%s' "$val"
  done < "$ENV_FILE"
  # Files from before the role split: WRITER=no meant "only the Caddy route".
  if [ -z "${ROLE:-}" ] && [ -n "${WRITER:-}" ]; then
    if is_yes "$WRITER"; then ROLE=all; else ROLE=route; ROUTE=${ROUTE:-file}; fi
  fi
  true
}

save_env() {
  local key val
  install -d -m 755 "$CONF_DIR" 2>/dev/null && [ -w "$CONF_DIR" ] || die "can't write settings to $CONF_DIR as $(id -un)"
  {
    echo "# Wrist Check settings, written by install.sh. Also read by the status writer's systemd unit."
    for key in $SETTINGS; do
      val=${!key:-}
      [[ "$val" == *[\"\\\$\`]* ]] && die "$key can't contain quotes, backslashes, \$ or backticks"
      printf '%s="%s"\n' "$key" "$val"
    done
  } > "$ENV_FILE.tmp"
  chmod 644 "$ENV_FILE.tmp"
  mv -f "$ENV_FILE.tmp" "$ENV_FILE"
}

status_url() { [ -n "${DOMAIN:-}" ] && STATUS_URL="https://$DOMAIN$STATUS_PATH"; true; }

# ---------------------------------------------------------------------------------------- token

gen_token() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

read_token_file() { # first line, without whitespace
  local t=""
  IFS= read -r t < "$1" || true
  printf '%s' "$t" | tr -d ' \t\r\n'
}

legacy_token() { # token inside a snippet written by an older install.sh (only read once, to migrate)
  [ -r "$CADDY_SNIPPET" ] || return 0
  sed -n 's/.*"Bearer \([0-9a-f]*\)".*/\1/p' "$CADDY_SNIPPET" | head -n1
}

# Sets TOKEN and TOKEN_SOURCE. resolve_token new  = ignore the saved one (rotate).
resolve_token() {
  TOKEN_SOURCE=""
  if [ -n "${TOKEN:-}" ]; then TOKEN_SOURCE="the TOKEN variable"
  elif [ -n "${TOKEN_FILE:-}" ]; then
    [ -r "$TOKEN_FILE" ] || die "can't read TOKEN_FILE=$TOKEN_FILE"
    TOKEN=$(read_token_file "$TOKEN_FILE"); TOKEN_SOURCE="$TOKEN_FILE"
  elif [ "${1:-}" != new ] && [ -r "$TOKEN_PATH" ]; then
    TOKEN=$(read_token_file "$TOKEN_PATH"); TOKEN_SOURCE=saved
  elif [ "${1:-}" != new ] && [ -n "$(legacy_token)" ]; then
    TOKEN=$(legacy_token); TOKEN_SOURCE=saved
  elif [ "${1:-}" != new ] && [ -e "$TOKEN_PATH" ]; then
    die "$TOKEN_PATH exists but isn't readable: run with sudo"
  else
    TOKEN=$(gen_token); TOKEN_SOURCE=new
  fi
  [[ "$TOKEN" =~ ^[A-Za-z0-9._~+/=-]{16,512}$ ]] \
    || die "the token must be 16 to 512 characters of letters, digits and . _ ~ + / = -"
}

save_token() { # returns 1 if it couldn't be saved
  if [ -r "$TOKEN_PATH" ] && [ "$(read_token_file "$TOKEN_PATH")" = "$TOKEN" ]; then return 0; fi
  install -d -m 755 "$CONF_DIR" 2>/dev/null || return 1
  ( umask 077; printf '%s\n' "$TOKEN" > "$TOKEN_PATH.tmp" && mv -f "$TOKEN_PATH.tmp" "$TOKEN_PATH" ) 2>/dev/null || return 1
}

token_note() {
  case "$TOKEN_SOURCE" in
    new) msg "New token saved in $TOKEN_PATH${1:+ ($1)}. Watches need it: print it with --show." ;;
    saved) msg "Kept the existing token ($TOKEN_PATH), so watches already set up keep working." ;;
    *) msg "Using the token from $TOKEN_SOURCE (saved in $TOKEN_PATH), so watches set up with it keep working." ;;
  esac
}

# ---------------------------------------------------------------------------------------- caddy

snippet_text() {
  local how="this script"; [ "$ACTION" = print ] && how="install.sh --print-snippet"
  case "$ROUTE" in
    file) cat <<CADDY
# Wrist Check, from $how (ROUTE=file). Serves $OUT only with the right bearer token, 404 otherwise.
handle $STATUS_PATH {
	@wristcheck_denied not header Authorization "Bearer $TOKEN"
	respond @wristcheck_denied 404
	header Cache-Control "no-store"
	root * $(dirname "$OUT")
	rewrite * /$(basename "$OUT")
	file_server
}
CADDY
    ;;
    check-only) cat <<CADDY
# Wrist Check, from $how (ROUTE=check-only). Answers 404 for $STATUS_PATH without the right bearer
# token. With the token, the request goes on to this site's own handlers (its reverse_proxy), so this
# belongs at the top level of the site block, which must not route the path through handle/route blocks.
@wristcheck_denied {
	path $STATUS_PATH
	not header Authorization "Bearer $TOKEN"
}
respond @wristcheck_denied 404
CADDY
    ;;
    proxy) cat <<CADDY
# Wrist Check, from $how (ROUTE=proxy). Answers 404 without the right bearer token and sends
# requests with it to $UPSTREAM (the token itself isn't passed on).
handle $STATUS_PATH {
	@wristcheck_denied not header Authorization "Bearer $TOKEN"
	respond @wristcheck_denied 404
	reverse_proxy $UPSTREAM {
		header_up -Authorization
	}
}
CADDY
    ;;
  esac
}

site_re() { # ERE for the first line of DOMAIN's site block: "example.com {", "a.com, example.com:443 {"
  local esc; esc=$(printf '%s' "$DOMAIN" | sed 's/[.*]/\\&/g')
  printf '^([^#{]*[ ,])?(https?://)?%s(:[0-9]+)?([ ,][^{]*)?[[:space:]]*\\{[[:space:]]*$' "$esc"
}

site_block() { # prints "lineno<US>depth<US>line" (US = \037) for DOMAIN's site block (depth 1 = top level inside it)
  [ -r "$CADDYFILE" ] && [ -n "${DOMAIN:-}" ] || return 0
  SITE_RE=$(site_re) awk '
    !inside && $0 ~ ENVIRON["SITE_RE"] { inside = 1; depth = 0 }
    inside {
      line = $0; sub(/#.*/, "", line)
      o = gsub(/\{/, "{", line); c = gsub(/\}/, "}", line)
      print NR "\037" (c > o ? depth - c + o : depth) "\037" $0
      depth += o - c
      if (depth <= 0) exit
    }' "$CADDYFILE"
}

existing_routes() { # lines in the site block (not our import) that mention the path, plus every line
  # using a named matcher that matches it, e.g. "@health_denied { path /health/* ... }" and "respond @health_denied"
  local pat=${STATUS_PATH%/*}
  [ -n "$pat" ] || pat=$STATUS_PATH
  site_block | awk -F'\037' -v pat="$pat" -v imp="$IMPORT_LINE" '
    { n++; ln[n] = $1; d[n] = $2; code = $3; sub(/#.*/, "", code); gsub(/^[ \t]+|[ \t]+$/, "", code); c[n] = code }
    END {
      blk = ""                            # named matchers whose definition mentions the path
      for (i = 1; i <= n; i++) {
        nm = ""
        if (match(c[i], /^@[A-Za-z0-9_-]+/)) { nm = substr(c[i], 1, RLENGTH); if (c[i] ~ /\{$/) blk = nm }
        else if (d[i] <= 1) blk = ""      # back at the top level: the matcher block has ended
        if (index(c[i], pat)) { if (nm != "") m[nm] = 1; if (blk != "") m[blk] = 1 }
      }
      for (i = 2; i <= n; i++) {
        hit = index(c[i], pat) > 0
        for (k in m) { s = c[i] " "; while ((p = index(s, k)) > 0) { ch = substr(s, p + length(k), 1); if (ch !~ /[A-Za-z0-9_-]/) { hit = 1; break } s = substr(s, p + length(k)) } }
        if (hit && c[i] != "" && c[i] != imp) print "    line " ln[i] ":  " c[i]
      }
    }'
}

handle_blocks() { # handle/handle_path/route blocks in the site block: those run before a top-level respond
  site_block | awk -F'\037' '$2 == 1 && $3 ~ /^[ \t]*(handle|handle_path|route)([ \t{]|$)/ { l = $3; gsub(/^[ \t]+/, "", l); print "    line " $1 ":  " l }'
}

caddy_bin() { # the binary the caddy unit runs (it may be a custom build with extra modules)
  local p=""
  command -v systemctl >/dev/null && p=$(systemctl show caddy -p ExecStart --value 2>/dev/null | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -n1)
  if [ -n "$p" ] && [ -x "$p" ]; then echo "$p"; else command -v caddy || true; fi
}

# caddy validate with the environment of the running caddy service, so {$CF_API_TOKEN} and friends
# from the unit (Environment=, EnvironmentFile=, override.conf) are there like they are for Caddy itself.
caddy_validate() {
  local bin pid out envs=() pre=()
  is_yes "${SKIP_VALIDATE:-}" && return 0
  bin=$(caddy_bin); [ -n "$bin" ] || return 0
  pid=0
  command -v systemctl >/dev/null && pid=$(systemctl show caddy -p MainPID --value 2>/dev/null || echo 0)
  if [ "${pid:-0}" -gt 0 ] 2>/dev/null && [ -r "/proc/$pid/environ" ]; then
    mapfile -d '' envs < "/proc/$pid/environ"
    pre=(env -i "${envs[@]}")
  fi
  if ! out=$(cd "$(dirname "$CADDYFILE")" && "${pre[@]}" "$bin" validate --config "$CADDYFILE" --adapter caddyfile 2>&1); then
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/    /' >&2
    return 1
  fi
}

reload_caddy() { # 0 reloaded, 1 reload failed, 2 not attempted
  if [ -n "${RELOAD_CMD:-}" ]; then
    bash -c "$RELOAD_CMD" >&3 || return 1
  elif [ "$IS_ROOT" = yes ] && command -v systemctl >/dev/null && systemctl is-active --quiet caddy 2>/dev/null; then
    systemctl reload caddy || return 1
  else
    return 2
  fi
  msg "Caddy reloaded."
}

backup_dir() { if [ -w "$(dirname "$CADDYFILE")" ]; then dirname "$CADDYFILE"; else echo "$CONF_DIR"; fi; }

# Puts the Caddyfile and snippet back as they were before this run.
restore() {
  [ -n "${CF_BACKUP:-}" ] && [ -f "$CF_BACKUP" ] && cat "$CF_BACKUP" > "$CADDYFILE"
  if [ -n "${SN_BACKUP:-}" ] && [ -f "$SN_BACKUP" ]; then cat "$SN_BACKUP" > "$CADDY_SNIPPET"
  elif [ "${SN_NEW:-}" = yes ]; then rm -f "$CADDY_SNIPPET"; fi
}

can_write_snippet() { [ -w "$(dirname "$CADDY_SNIPPET")" ] || { [ -f "$CADDY_SNIPPET" ] && [ -w "$CADDY_SNIPPET" ]; }; }

write_snippet() {
  can_write_snippet || die "can't write $CADDY_SNIPPET as $(id -un). Use sudo, or --print-snippet to add the lines by hand."
  SN_BACKUP=""; SN_NEW=yes
  if [ -f "$CADDY_SNIPPET" ]; then
    SN_NEW=no; SN_BACKUP="$(backup_dir)/$(basename "$CADDY_SNIPPET").wrist-check.bak"
    ( umask 077; cp "$CADDY_SNIPPET" "$SN_BACKUP" )
  fi
  ( umask 077; snippet_text > "$CADDY_SNIPPET" )
  # Caddy runs as user "caddy" on most installs: let it read the snippet, nobody else.
  if getent group caddy >/dev/null 2>&1 && chgrp caddy "$CADDY_SNIPPET" 2>/dev/null; then
    chmod 640 "$CADDY_SNIPPET"
  else
    chmod 644 "$CADDY_SNIPPET"
    [ "$IS_ROOT" = yes ] || msg "Note: $CADDY_SNIPPET is readable by all local users (couldn't give it to group caddy)."
  fi
}

manual_import() {
  msg "Add this line inside the \"${DOMAIN:-your site} { ... }\" block of $CADDYFILE yourself, then reload Caddy:"
  msg ""
  msg "    $IMPORT_LINE"
  msg ""
}

# Checks the site block, writes the snippet, adds the import line after "<domain> {", validates and
# reloads. On any failure the Caddyfile and snippet go back to how they were.
apply_route() {
  local found first ok=0 rc=0
  CF_BACKUP=""
  if [ -r "$CADDYFILE" ] && [ -z "$(site_block)" ]; then
    msg "Couldn't find a \"$DOMAIN {\" block in $CADDYFILE."
  fi
  found=$(existing_routes)
  if [ -n "$found" ] && ! is_yes "${ALLOW_EXISTING_ROUTE:-}"; then
    die "the $DOMAIN block in $CADDYFILE already handles $STATUS_PATH:
$found
Two token checks with different tokens would answer 404 to every request. Remove those lines (and
reload Caddy) first, or replace them with the output of --print-snippet. ALLOW_EXISTING_ROUTE=yes
skips this check."
  fi
  if [ "$ROUTE" = check-only ] && [ -n "$(handle_blocks)" ]; then
    die "ROUTE=check-only needs the site's proxy at the top level of the $DOMAIN block, but it has:
$(handle_blocks)
Those run before the token check, so it would be skipped. Use ROUTE=proxy UPSTREAM=<host:port> instead."
  fi

  write_snippet

  if grep -qxF -- "$IMPORT_LINE" <(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' "$CADDYFILE" 2>/dev/null); then
    ok=1
  elif [ ! -f "$CADDYFILE" ] || [ -z "$(caddy_bin)" ] || [ -z "$(site_block)" ]; then
    manual_import
  else
    ask EDIT_CADDYFILE "Add '$IMPORT_LINE' to the $DOMAIN block in $CADDYFILE? (a backup is kept)" "${EDIT_CADDYFILE:-yes}"
    if ! is_yes "$EDIT_CADDYFILE"; then
      manual_import
    else
      [ -w "$CADDYFILE" ] || { restore; die "can't edit $CADDYFILE as $(id -un). Use sudo, or --print-snippet."; }
      CF_BACKUP="$(backup_dir)/$(basename "$CADDYFILE").wrist-check.bak"
      cp "$CADDYFILE" "$CF_BACKUP"
      first=$(site_block | head -n1 | cut -d"$(printf '\037')" -f1)
      awk -v n="$first" -v imp="$IMPORT_LINE" '{ print } NR == n { print "\t" imp }' "$CF_BACKUP" > "$CADDYFILE"
      msg "Added '$IMPORT_LINE' to $CADDYFILE (old version: $CF_BACKUP)."
      ok=1
    fi
  fi

  if [ "$ok" = 1 ]; then
    if ! caddy_validate; then
      restore
      die "Caddy didn't accept the new config, so the Caddyfile and snippet were put back. If it only fails
because the service gets settings this script can't see, run again with SKIP_VALIDATE=yes: the reload
then does the check, and a failed reload is rolled back the same way."
    fi
    reload_caddy || rc=$?
    if [ "$rc" = 1 ]; then
      restore
      reload_caddy >/dev/null 2>&1 || true
      die "reloading Caddy failed, so the Caddyfile and snippet were put back (and reloaded)."
    elif [ "$rc" = 2 ]; then
      msg "Reload Caddy yourself (e.g. sudo systemctl reload caddy), or set RELOAD_CMD=\"...\" next time."
    fi
  fi
}

ask_route() {
  suggest DOMAIN "$D_DOMAIN"
  ask DOMAIN "Public domain the watch connects to (the Caddy site)" "${DOMAIN:-}"
  [ -n "$DOMAIN" ] || [ "$ACTION" = print ] || need DOMAIN "Public domain the watch connects to (the Caddy site)" "for the status URL and to find the site block"
  [ -z "$DOMAIN" ] || check DOMAIN '^[A-Za-z0-9*.-]+$' "a host name like example.com"
  ask STATUS_PATH "Path of the status file" "${STATUS_PATH:-/health/status.json}"
  case "$STATUS_PATH" in /*) ;; *) STATUS_PATH="/$STATUS_PATH" ;; esac
  check STATUS_PATH '^/[A-Za-z0-9._~/-]+$' "a URL path like /health/status.json"
  if [ "$ROLE" = all ]; then
    ROUTE="file"   # the writer is on this machine, so Caddy serves its file
  else
    if have_tty; then
      detect_route
      case "$D_ROUTE" in
        check-only) msg "The $DOMAIN block sends requests on with a top-level reverse_proxy${D_UPSTREAM:+ ($D_UPSTREAM)}: check-only fits." ;;
        proxy) msg "The $DOMAIN block uses handle/route blocks, so a top-level token check would be skipped: proxy fits." ;;
      esac
      suggest ROUTE "$D_ROUTE"
    fi
    have_tty && msg "How Caddy here answers $STATUS_PATH:
  file        serve the status file from this machine (you write it there yourself)
  check-only  check the token, then let the site's existing reverse_proxy handle the request
  proxy       check the token, then send the request to an upstream you name"
    need ROUTE "Route mode (file / check-only / proxy)" "file, check-only or proxy"
  fi
  check ROUTE '^(file|check-only|proxy)$' "file, check-only or proxy"
  if [ "$ROUTE" = proxy ]; then
    suggest UPSTREAM "$D_UPSTREAM"
    need UPSTREAM "Upstream that serves the status file (host:port or URL)" "where requests with the token go"
    check UPSTREAM '^[][A-Za-z0-9.:/_-]+$' "host:port or a URL like http://10.0.0.5:8080"
  fi
  [ "$ROUTE" = file ] && OUT=${OUT:-$DEFAULT_OUT}
  status_url
}

# --------------------------------------------------------------------------------------- writer

ask_writer() {
  suggest KUMA_URL "$D_KUMA_URL"
  if [ -n "$D_SLUGS" ] && [ -z "${KUMA_SLUG:-}" ]; then
    [ "${D_SLUGS// /}" != "$D_SLUGS" ] && msg "Kuma has these status pages: $D_SLUGS"
    KUMA_SLUG=${D_SLUGS%% *}
  fi
  if have_tty && [ "$ROLE" = writer ] && [ -z "${OUT:-}" ]; then
    detect_out
    [ -n "$D_OUT" ] && msg "A web server here serves $(dirname "$D_OUT"): the writer can write straight into it."
    suggest OUT "$D_OUT"
  fi
  ask KUMA_URL "Uptime Kuma URL (as seen from this machine)" "${KUMA_URL:-http://127.0.0.1:3001}"
  check KUMA_URL '^https?://[^[:space:]]+$' "a URL like http://127.0.0.1:3001"
  need KUMA_SLUG "Slug of the Kuma status page listing the monitors" "the last part of the status page URL, /status/<slug>"
  check KUMA_SLUG '^[A-Za-z0-9_-]+$' "letters, digits, - and _"
  ask OUT "File to write the status to (Caddy or your web server serves it)" "${OUT:-$DEFAULT_OUT}"
  check OUT '^/[A-Za-z0-9._/-]+$' "an absolute path without spaces"
  ask SLOW_MS "Response time in ms that counts as SLOW (0 = off)" "${SLOW_MS:-2000}"
  check SLOW_MS '^[0-9]+$' "a number"
  ask SLOW_RUNS "Checks in a row that must be slow before it says SLOW" "${SLOW_RUNS:-3}"
  check SLOW_RUNS '^[1-9][0-9]*$' "a number from 1"
  ask PENDING "Monitors Kuma is retrying: ignore, slow or down" "${PENDING:-ignore}"
  check PENDING '^(ignore|slow|down)$' "ignore, slow or down"
  ask PRIORITY_GROUPS "Status page groups whose problems come first, comma-separated (empty = page order)" "${PRIORITY_GROUPS:-}"
  [[ "$PRIORITY_GROUPS" == *[\"\\\$\`]* ]] && die "PRIORITY_GROUPS can't contain quotes, backslashes, \$ or backticks"
  WRITER_USER=${WRITER_USER:-wrist-check}
  local out_dir; out_dir=$(dirname "$OUT")
  if [ -d "$out_dir" ] && [ "$out_dir" != "$DATA_DIR" ] && ! writable_by "$WRITER_USER" "$out_dir"; then
    have_tty && msg "$WRITER_USER can't write to $out_dir (owned by $(stat -c %U "$out_dir")). The writer can run as that owner instead."
    [ "$WRITER_USER" = wrist-check ] && have_tty && WRITER_USER=$(stat -c %U "$out_dir")
    ask WRITER_USER "User the writer runs as" "$WRITER_USER"
  fi
  check WRITER_USER '^[a-z_][a-z0-9_-]*$' "a user name"
  command -v python3 >/dev/null || die "python3 is needed for the status writer"
  fetch_writer
  check_kuma
}

fetch_writer() { # sets WRITER_SRC to a local kuma-status.py
  if [ -n "${WRITER_SRC:-}" ]; then [ -r "$WRITER_SRC" ] || die "can't read WRITER_SRC=$WRITER_SRC"; return 0; fi
  if [ -f "$0" ] && [ "$(basename "$0")" = install.sh ] && [ -f "$(dirname "$0")/kuma-status.py" ]; then
    WRITER_SRC="$(dirname "$0")/kuma-status.py"; USED_LOCAL_WRITER=$WRITER_SRC; return 0
  fi
  TMP_DIR=$(mktemp -d)
  WRITER_SRC="$TMP_DIR/kuma-status.py"
  if command -v curl >/dev/null; then
    curl -fsSL "$REPO_RAW/kuma-status.py" -o "$WRITER_SRC" || die "couldn't download $REPO_RAW/kuma-status.py"
  else
    python3 - "$REPO_RAW/kuma-status.py" "$WRITER_SRC" <<'PY' || die "couldn't download the status writer"
import sys, urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=30) as r, open(sys.argv[2], "wb") as f:
    f.write(r.read())
PY
  fi
}

check_kuma() {
  is_yes "${SKIP_KUMA_CHECK:-}" && return 0
  local rc=0
  KUMA_URL=$KUMA_URL KUMA_SLUG=$KUMA_SLUG python3 "$WRITER_SRC" --check >&3 || rc=$?
  case "$rc" in
    0) ;;
    3) die "no Kuma status page with the slug '$KUMA_SLUG' (the slug is the last part of /status/<slug>)." ;;
    *) die "couldn't check the status page (see above). Fix KUMA_URL, or set SKIP_KUMA_CHECK=yes if Kuma isn't up yet." ;;
  esac
}

writable_by() { # writable_by USER DIR
  if [ "$1" = root ]; then return 0; fi
  id "$1" >/dev/null 2>&1 || return 1
  if command -v runuser >/dev/null; then runuser -u "$1" -- test -w "$2" 2>/dev/null
  elif command -v setpriv >/dev/null; then
    setpriv --reuid="$1" --regid="$(id -g "$1")" --init-groups test -w "$2" 2>/dev/null
  else return 0; fi
}

install_writer() {
  [ "$IS_ROOT" = yes ] || die "installing the status writer needs root (sudo): it adds a systemd timer"
  command -v systemctl >/dev/null || die "systemd is needed for the status writer's timer"
  local out_dir protect_home=yes
  out_dir=$(dirname "$OUT")
  case "$out_dir/" in /home/*|/root/*|/run/user/*) protect_home=read-only ;; esac

  install -m 755 "$WRITER_SRC" "$WRITER_BIN"
  if [ "$WRITER_USER" = wrist-check ] && ! id wrist-check >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin wrist-check
  fi
  id "$WRITER_USER" >/dev/null 2>&1 || die "user $WRITER_USER doesn't exist"
  if [ ! -d "$out_dir" ]; then
    install -d -m 755 -o "$WRITER_USER" "$out_dir"
  elif [ "$out_dir" = "$DATA_DIR" ]; then
    chown "$WRITER_USER" "$out_dir"
  elif ! writable_by "$WRITER_USER" "$out_dir"; then
    die "$WRITER_USER can't write to $out_dir. Let it (e.g. setfacl -m u:$WRITER_USER:rwx $out_dir), or run the
writer as the folder's owner with WRITER_USER=$(stat -c %U "$out_dir")."
  fi

  cat > "$UNIT_DIR/wrist-check-status.service" <<UNIT
[Unit]
Description=Write Wrist Check status.json from Uptime Kuma

[Service]
Type=oneshot
EnvironmentFile=$ENV_FILE
ExecStart=$WRITER_BIN
User=$WRITER_USER
UMask=0022
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=$protect_home
ReadWritePaths=$out_dir
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
  systemctl daemon-reload
  systemctl enable --now wrist-check-status.timer
  systemctl start wrist-check-status.service || msg "First run failed: journalctl -u wrist-check-status"
  msg ""
  msg "Status writer installed: writes $OUT every minute."
  printf 'Right now: ' >&3
  ( set -a; KUMA_URL=$KUMA_URL KUMA_SLUG=$KUMA_SLUG OUT=$OUT SLOW_MS=$SLOW_MS SLOW_RUNS=$SLOW_RUNS \
      PENDING=$PENDING PRIORITY_GROUPS=$PRIORITY_GROUPS "$WRITER_BIN" --summary >&3 ) || msg "(couldn't run it)"
}

# ------------------------------------------------------------------------------------ detection
# Only with a terminal: what's found becomes the suggested answer, and you confirm or change it.
# Without a terminal nothing is guessed: answers come from the environment or the saved settings.

D_ROLE=""; D_KUMA_URL=""; D_SLUGS=""; D_CADDY=""; D_DOMAIN=""; D_ROUTE=""; D_UPSTREAM=""; D_OUT=""; D_OTHER_TIMERS=""

py_get() { # py_get URL: prints the body of a 200 answer (3 s timeout), python3 or curl
  if command -v python3 >/dev/null; then
    python3 -c 'import sys,urllib.request
try:
    with urllib.request.urlopen(sys.argv[1], timeout=3) as r: sys.stdout.write(r.read(65536).decode("utf-8","replace"))
except Exception: sys.exit(1)' "$1" 2>/dev/null
  elif command -v curl >/dev/null; then curl -fsS -m 3 "$1" 2>/dev/null
  else return 1; fi
}

docker_ok() { command -v docker >/dev/null && docker info >/dev/null 2>&1; }

kuma_containers() { docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | awk 'tolower($2) ~ /uptime-kuma/ { print $1 }'; }

detect_kuma() {
  local c cands="${KUMA_URL:-} http://127.0.0.1:3001 http://localhost:3001" u p ip db
  if docker_ok; then
    for c in $(kuma_containers); do
      p=$(docker port "$c" 3001/tcp 2>/dev/null | head -n1 | sed 's/^0\.0\.0\.0:/127.0.0.1:/; s/^\[::\]:/127.0.0.1:/')
      [ -n "$p" ] && cands="$cands http://$p"
      for ip in $(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$c" 2>/dev/null); do
        cands="$cands http://$ip:3001"
      done
    done
  fi
  for u in $cands; do
    if py_get "${u%/}/api/entry-page" | grep -q '"type"'; then D_KUMA_URL=${u%/}; break; fi
  done
  # Status page slugs, read straight from Kuma's SQLite database when it's on this machine.
  command -v python3 >/dev/null || return 0
  local dbs="/opt/uptime-kuma/data/kuma.db /var/lib/uptime-kuma/kuma.db /root/uptime-kuma/data/kuma.db"
  [ -n "${HOME:-}" ] && dbs="$dbs $HOME/uptime-kuma/data/kuma.db"
  if docker_ok; then
    for c in $(kuma_containers); do
      db=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Source}}{{end}}{{end}}' "$c" 2>/dev/null)
      [ -n "$db" ] && dbs="$db/kuma.db $dbs"
    done
  fi
  for db in $dbs; do
    [ -r "$db" ] || continue
    D_SLUGS=$(python3 -c 'import sqlite3,sys
c = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
print(" ".join(r[0] for r in c.execute("SELECT slug FROM status_page ORDER BY id")))' "$db" 2>/dev/null || true)
    [ -n "$D_SLUGS" ] && break
  done
  true
}

caddy_sites() { # site addresses at the top level of the Caddyfile, one site per line
  [ -r "$CADDYFILE" ] || return 0
  awk '{ line = $0; sub(/#.*/, "", line) }
    depth == 0 && line ~ /\{[ \t]*$/ { a = line; sub(/\{[ \t]*$/, "", a); gsub(/^[ \t]+|[ \t]+$/, "", a); if (a != "" && a !~ /^\(/) print a }
    { depth += gsub(/\{/, "{", line) - gsub(/\}/, "}", line) }' "$CADDYFILE"
}

detect_caddy() {
  [ -n "$(caddy_bin)" ] || [ -r "$CADDYFILE" ] || return 0
  D_CADDY=yes
  local site a
  # Suggest the first HTTPS site (Caddy gets the certificate): an address with a dot, not http://.
  while IFS= read -r site; do
    for a in ${site//,/ }; do
      case "$a" in http://*|\*.*|:*) continue ;; esac
      a=${a#https://}; a=${a%%:*}
      [[ "$a" == *.* ]] && { D_DOMAIN=$a; break 2; }
    done
  done < <(caddy_sites)
}

detect_route() { # needs DOMAIN and STATUS_PATH: how the site serves things today
  local dom=${DOMAIN:-$D_DOMAIN}
  [ -n "$dom" ] || return 0
  local blk; blk=$(DOMAIN=$dom site_block)
  [ -n "$blk" ] || return 0
  D_UPSTREAM=$(printf '%s\n' "$blk" | awk -F'\037' '$3 ~ /^[ \t]*reverse_proxy[ \t]/ { n = split($3, w, /[ \t]+/); for (i = 1; i <= n; i++) if (w[i] == "reverse_proxy") { t = w[i+1]; if (t ~ /^[@\/]/) t = w[i+2]; print t; exit } }')
  D_UPSTREAM=${D_UPSTREAM%\{}
  if [ -n "$(DOMAIN=$dom handle_blocks)" ]; then D_ROUTE=proxy
  elif printf '%s\n' "$blk" | awk -F'\037' '$2 == 1 && $3 ~ /^[ \t]*reverse_proxy[ \t]/ { f = 1 } END { exit !f }'; then D_ROUTE=check-only
  else D_ROUTE="file"; fi
}

detect_out() { # where a local web server would serve STATUS_PATH from
  local rel=${STATUS_PATH:-/health/status.json} roots="" c r
  if docker_ok; then
    for c in $(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | awk 'tolower($2) ~ /nginx|caddy|httpd|apache/ { print $1 }'); do
      roots="$roots $(docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}} {{end}}{{end}}' "$c" 2>/dev/null)"
    done
  fi
  command -v nginx >/dev/null && roots="$roots $(nginx -T 2>/dev/null | awk '$1 == "root" { gsub(/;/, "", $2); print $2 }' | sort -u | tr '\n' ' ')"
  for r in $roots; do
    [ -d "$r" ] || continue
    if [ -f "$r$rel" ]; then D_OUT=$r$rel; return 0; fi
    [ -d "$r${rel%/*}" ] && [ -z "$D_OUT" ] && D_OUT=$r$rel
  done
  true
}

detect_other_timers() { # an older status writer that should go once this one works
  command -v systemctl >/dev/null || return 0
  D_OTHER_TIMERS=$(systemctl list-unit-files --type=timer --no-legend 2>/dev/null | awk '{ print $1 }' \
    | grep -iE 'kuma|status|health' | grep -v '^wrist-check' | tr '\n' ' ' || true)
}

detect_all() {
  have_tty || return 0
  msg "Looking around this machine..."
  detect_kuma; detect_caddy; detect_other_timers
  local py=no; command -v python3 >/dev/null && py=yes
  if [ -n "$D_KUMA_URL" ]; then msg "  Uptime Kuma:  $D_KUMA_URL${D_SLUGS:+ (status pages: $D_SLUGS)}"
  elif [ -n "$D_SLUGS" ]; then msg "  Uptime Kuma:  its database is here (status pages: $D_SLUGS), but nothing answers on the usual ports"
  else msg "  Uptime Kuma:  not found"; fi
  if [ -n "$D_CADDY" ]; then msg "  Caddy:        yes ($CADDYFILE${D_DOMAIN:+, site $D_DOMAIN})"; else msg "  Caddy:        not found"; fi
  msg "  python3:      $py"
  [ -n "$D_OTHER_TIMERS" ] && msg "  Other timers: $D_OTHER_TIMERS(maybe an older status writer)"
  local why
  if [ -z "${ROLE:-}" ]; then
    if [ -n "$D_KUMA_URL" ] && [ -n "$D_CADDY" ]; then D_ROLE=all; why="Kuma and Caddy are both here"
    elif [ -n "$D_KUMA_URL" ]; then D_ROLE=writer; why="Kuma is here, Caddy isn't"
    elif [ -n "$D_CADDY" ]; then D_ROLE=route; why="Caddy is here, Kuma isn't"
    else D_ROLE=all; why="found neither, so assuming one server"; fi
    [ "$D_ROLE" != route ] && [ "$py" = no ] && { D_ROLE=route; why="no python3 here for the writer"; }
    msg "  Suggested:    $D_ROLE ($why)"
  fi
  msg ""
}

suggest() { # suggest VAR VALUE: VALUE becomes the default answer if VAR has none yet
  [ -n "${!1:-}" ] || [ -z "$2" ] || printf -v "$1" '%s' "$2"
}

confirm_plan() {
  have_tty || return 0
  msg ""
  msg "Plan for this machine:"
  [ "$ROLE" = route ] || msg "  Writer:  reads status page '$KUMA_SLUG' at $KUMA_URL every minute, writes $OUT
           SLOW after $SLOW_RUNS checks over ${SLOW_MS} ms, retrying monitors: $PENDING${PRIORITY_GROUPS:+, first: $PRIORITY_GROUPS}"
  [ "$ROLE" = writer ] || msg "  Route:   $STATUS_URL, ROUTE=$ROUTE${UPSTREAM:+ -> $UPSTREAM}, snippet $CADDY_SNIPPET imported in the $DOMAIN block"
  local go=""
  ask go "Go ahead? (yes / no)" "yes"
  is_yes "$go" || die "stopped, nothing changed. Run again to change the answers."
}

ask_existing_token() { # with a terminal, offer to reuse a token instead of making a new one
  [ "$TOKEN_SOURCE" = new ] && have_tty || return 0
  local t="" keep=""
  # A hand-written route in the site block may already check a token: keeping it keeps the watches working.
  t=$(site_block | cut -d"$(printf '\037')" -f3- | sed -n 's/.*"Bearer \([A-Za-z0-9._~+\/=-]\{16,512\}\)".*/\1/p' | head -n1)
  if [ -n "$t" ]; then
    ask keep "The $DOMAIN block already checks a token (${t:0:4}...). Use the same one, so watches keep working? (yes / no)" "yes"
    if is_yes "$keep"; then TOKEN=$t; TOKEN_SOURCE="your existing Caddy route"; return 0; fi
    t=""
  fi
  printf 'Paste an existing token to keep watches already set up (Enter = make a new one): ' > /dev/tty
  read -rs t < /dev/tty || true
  echo > /dev/tty
  t=$(printf '%s' "$t" | tr -d ' \t\r\n')
  [ -n "$t" ] || return 0
  [[ "$t" =~ ^[A-Za-z0-9._~+/=-]{16,512}$ ]] || die "that token isn't valid: 16 to 512 characters of letters, digits and . _ ~ + / = -"
  TOKEN=$t; TOKEN_SOURCE="what you pasted"
}

# -------------------------------------------------------------------------------------- actions

show() {
  load_env
  [ -n "${STATUS_PATH:-}" ] || die "no route set up here (no $ENV_FILE): run --show where the route was installed"
  status_url
  [ -n "${STATUS_URL:-}" ] || die "DOMAIN isn't known here: run with DOMAIN=..."
  [ -r "$TOKEN_PATH" ] || die "can't read $TOKEN_PATH$([ "$IS_ROOT" = yes ] || echo ': run with sudo')"
  local token; token=$(read_token_file "$TOKEN_PATH")
  cat <<INFO

  Status URL:  $STATUS_URL
  Token:       $token

On the watch: tap the Homelab status complication (it says SETUP), scan the QR code with
your phone, and paste these two values into the page. Or use "Enter on watch".
Test from anywhere:  curl -H "Authorization: Bearer $token" $STATUS_URL

INFO
}

print_snippet() {
  exec 3>&2
  load_env
  ROLE=route
  if [ "${ROUTE_ASKED:-}" != yes ]; then
    have_tty && { detect_caddy; msg ""; }
    ask_route
  fi
  resolve_token
  ask_existing_token
  local saved=yes
  save_token || saved=no
  if [ -r "$CADDYFILE" ] && [ -n "${DOMAIN:-}" ]; then
    local found; found=$(existing_routes)
    [ -n "$found" ] && msg "The $DOMAIN block in $CADDYFILE already handles $STATUS_PATH. Replace these lines with the snippet:
$found
"
    [ "$ROUTE" = check-only ] && [ -n "$(handle_blocks)" ] && msg "Warning: these blocks run before a top-level token check, so check-only wouldn't protect the path. Use ROUTE=proxy:
$(handle_blocks)
"
  fi
  if [ -n "${SNIPPET_OUT:-}" ]; then
    ( umask 077; snippet_text > "$SNIPPET_OUT" )
    msg "Snippet written to $SNIPPET_OUT (it holds the token: delete it once it's in place)."
  else
    snippet_text
  fi
  if [ "$saved" = yes ]; then token_note
  elif [ "$TOKEN_SOURCE" = new ]; then msg "Couldn't save the new token in $TOKEN_PATH: it's only in the snippet."; fi
  msg "Put it inside the site block (or save it as a file there and 'import' it), then check and reload:
    caddy validate --config $CADDYFILE --adapter caddyfile && sudo systemctl reload caddy"
  [ "$ROUTE" = check-only ] && msg "check-only needs the site's reverse_proxy at the top level of the block, not inside handle/route."
  [ -n "${STATUS_URL:-}" ] && { ( save_env ) 2>/dev/null || true; }
  true
}

install_all() {
  load_env
  [ "$IS_ROOT" = yes ] || [ "$ROLE" = route ] || die "run as root (sudo), or use --route-only / --print-snippet"
  msg "Wrist Check server setup"
  msg ""
  detect_all
  if [ -z "$ROLE" ]; then
    have_tty && msg "What runs here? all = status writer + Caddy route on this machine, writer = only the
Kuma status writer (Caddy elsewhere), route = only the Caddy token check (writer elsewhere)."
    ask ROLE "Install (all / writer / route)" "${D_ROLE:-all}"
  fi
  check ROLE '^(all|writer|route)$' "all, writer or route"
  if [ "$ROLE" = route ] && ! can_write_snippet; then
    die "can't write $CADDY_SNIPPET as $(id -un). Use sudo, or --print-snippet to add the lines by hand."
  fi

  [ "$ROLE" = writer ] || ask_route
  if [ "$ROLE" != writer ] && have_tty && [ -n "$(existing_routes)" ] && ! is_yes "${ALLOW_EXISTING_ROUTE:-}"; then
    msg "The $DOMAIN block in $CADDYFILE already handles $STATUS_PATH:"
    msg "$(existing_routes)"
    msg "A second token check would break it, so those lines must be replaced. The safest way is by hand."
    local p=""
    ask p "Print the replacement lines to paste in place of those? (yes / no = stop)" "yes"
    is_yes "$p" || die "stopped, nothing changed."
    ACTION=print; ROUTE_ASKED=yes; print_snippet; exit 0
  fi
  [ "$ROLE" = route ] || ask_writer
  if [ "$ROLE" != writer ]; then
    resolve_token
    ask_existing_token
  fi
  confirm_plan
  save_env

  [ "$ROLE" = route ] || install_writer

  if [ "$ROLE" != writer ]; then
    command -v caddy >/dev/null || [ -n "$(caddy_bin)" ] || msg "Note: Caddy isn't installed here."
    save_token || die "couldn't save the token in $TOKEN_PATH"
    msg ""
    apply_route
    msg ""
    token_note "readable by $(id -un) only"
    msg "Status URL: $STATUS_URL"
    if [ "$SHOW" = yes ]; then show; else msg "Print the URL and token for a watch with --show."; fi
  fi
  if [ "$ROLE" != route ] && [ -n "$D_OTHER_TIMERS" ]; then
    msg ""
    msg "Once the watch shows the right status, turn off the older timer(s): systemctl disable --now $D_OTHER_TIMERS"
  fi
  if [ "$ROLE" = writer ]; then
    msg ""
    msg "Next: on the machine with the public Caddy, run this script with --route-only (ROUTE=check-only"
    msg "or proxy), or --print-snippet to add the token check by hand."
  fi
}

rotate() {
  load_env
  [ -n "${STATUS_PATH:-}" ] || die "no route set up here: run the installer (or --print-snippet) first"
  ROUTE=${ROUTE:-file}; [ "$ROUTE" = file ] && OUT=${OUT:-$DEFAULT_OUT}
  status_url
  resolve_token new
  save_token || die "couldn't save the token in $TOKEN_PATH"
  if [ -f "$CADDY_SNIPPET" ]; then
    write_snippet
    CF_BACKUP=""
    local rc=0
    caddy_validate || { restore; die "Caddy didn't accept the new snippet; it was put back."; }
    reload_caddy || rc=$?
    [ "$rc" = 1 ] && { restore; reload_caddy >/dev/null 2>&1 || true; die "reloading Caddy failed; the old snippet was put back."; }
    [ "$rc" = 2 ] && msg "Reload Caddy yourself to start using the new token."
    msg "New token is in place. Every watch must be set up again (--show prints it)."
  else
    msg "New token saved in $TOKEN_PATH. Run --print-snippet and replace the old lines on your Caddy, then set the watches up again (--show)."
  fi
  [ "$SHOW" = yes ] && show
  true
}

uninstall() {
  load_env
  local role=${ROLE_FLAG:-all}
  if [ "$role" != route ]; then
    if [ -f "$UNIT_DIR/wrist-check-status.timer" ] || [ -f "$WRITER_BIN" ]; then
      [ "$IS_ROOT" = yes ] || die "removing the status writer needs root (sudo)"
      systemctl disable --now wrist-check-status.timer 2>/dev/null || true
      rm -f "$UNIT_DIR/wrist-check-status.service" "$UNIT_DIR/wrist-check-status.timer" "$WRITER_BIN"
      systemctl daemon-reload 2>/dev/null || true
      if [ "${OUT:-$DEFAULT_OUT}" = "$DEFAULT_OUT" ]; then rm -rf "$DATA_DIR"
      else msg "Left $OUT in place (not this script's folder): delete it yourself if nothing serves it."; fi
      id wrist-check >/dev/null 2>&1 && userdel wrist-check 2>/dev/null || true
      msg "Status writer removed."
    fi
  fi
  if [ "$role" != writer ]; then
    if [ -f "$CADDYFILE" ] && grep -qxF -- "$IMPORT_LINE" <(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' "$CADDYFILE"); then
      [ -w "$CADDYFILE" ] || die "can't edit $CADDYFILE as $(id -un): use sudo"
      local b; b="$(backup_dir)/$(basename "$CADDYFILE").wrist-check.bak"
      cp "$CADDYFILE" "$b"
      awk -v imp="$IMPORT_LINE" '{ l = $0; gsub(/^[ \t]+|[ \t]+$/, "", l) } l != imp' "$b" > "$CADDYFILE"
      msg "Removed '$IMPORT_LINE' from $CADDYFILE (old version: $b)."
    fi
    if [ -f "$CADDY_SNIPPET" ]; then
      rm -f "$CADDY_SNIPPET"
      local rc=0; reload_caddy || rc=$?
      [ "$rc" = 2 ] && msg "Reload Caddy yourself."
    fi
    rm -f "$TOKEN_PATH"
    msg "Caddy route and token removed. Lines you pasted by hand (--print-snippet) stay: remove those yourself."
  fi
  if [ "$role" = all ]; then rm -rf "$CONF_DIR"
  elif [ -f "$ENV_FILE" ]; then ROLE=$([ "$role" = writer ] && echo route || echo writer); save_env; fi
  msg "Done."
}

# Deletes this script if it was run from a file, unless that file is part of a git checkout.
remove_self() {
  local self="$0"
  [ -f "$self" ] && [ "$(basename "$self")" = "install.sh" ] || return 0
  is_yes "${KEEP_INSTALLER:-}" && return 0
  if command -v git >/dev/null && git -C "$(dirname "$self")" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi
  rm -f "$self" && msg "Installer removed ($self)."
  [ -n "$USED_LOCAL_WRITER" ] && rm -f "$USED_LOCAL_WRITER"
  true
}

usage() { sed -n '2,/^# Needs/p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || echo "See the README."; }

main() {
  trap cleanup EXIT
  ACTION=install; SHOW=no; ROLE_FLAG=""
  local a
  for a in "$@"; do
    case "$a" in
      --writer-only) ROLE_FLAG=writer ;;
      --route-only) ROLE_FLAG=route ;;
      --show) SHOW=yes ;;
      --print-snippet) [ "$ACTION" = install ] || die "pick one of --print-snippet, --rotate, --uninstall"; ACTION=print ;;
      --rotate) [ "$ACTION" = install ] || die "pick one of --print-snippet, --rotate, --uninstall"; ACTION=rotate ;;
      --uninstall) [ "$ACTION" = install ] || die "pick one of --print-snippet, --rotate, --uninstall"; ACTION=uninstall ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option $a (see --help)" ;;
    esac
  done
  [ -n "$ROLE_FLAG" ] && ROLE=$ROLE_FLAG
  ROLE=${ROLE:-}
  # "--show" on its own prints the URL and token once set up; on a fresh machine it installs and then shows.
  if [ "$ACTION" = install ] && [ "$SHOW" = yes ] && [ -z "$ROLE_FLAG" ] && [ $# -eq 1 ] && [ -r "$ENV_FILE" ]; then ACTION=show; fi
  case "$ACTION" in
    show) show ;;
    print) print_snippet ;;
    rotate) rotate ;;
    uninstall) uninstall ;;
    install) install_all ;;
  esac
  case "$ACTION" in install|uninstall|rotate) remove_self ;; esac
}

main "$@"
