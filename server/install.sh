#!/usr/bin/env bash
# Wrist Check server setup: the Uptime Kuma status writer and/or the token check in your reverse proxy.
# Proxies: Caddy and nginx are set up by the script; Nginx Proxy Manager, Traefik, Apache, HAProxy and
# anything else get the exact lines to add and where (PROXY=caddy|nginx|npm|traefik|apache|haproxy|other).
#
# One server with Kuma, Caddy and Python, one line:
#   curl -fsSL https://raw.githubusercontent.com/grandevr/Self-Hosting-Wrist-Check/main/server/install.sh | sudo bash
#
# Split across machines (writer next to Kuma, token check on the edge Caddy):
#   ... | sudo bash -s -- --writer-only              on the Kuma machine (needs python3, not Caddy)
#   ... | sudo bash -s -- --route-only               on the Caddy machine (edits the Caddyfile, reloads)
#   ... | bash -s -- --print-snippet                 no root: print the Caddy lines to paste in yourself
#
# Any of these with --dry-run: look around, ask, and show the plan, without changing anything.
#
# Later:
#   --verify      test the status URL from any machine: answers with the token, 404 without it
#   --upgrade     install the latest writer and token check with the saved settings, no questions
#                 (running the installer again does the same, but asks again)
#   --show        print the URL and token (to set up another watch); nothing prints the token otherwise
#   --rotate      make a new token (every watch must be set up again)
#   --uninstall   remove what this script added; with --writer-only / --route-only only that part
#   --version     print which version this is
#
# Pinned to a release: use the install.sh attached to it,
#   https://github.com/grandevr/Self-Hosting-Wrist-Check/releases/download/<tag>/install.sh
# It downloads only that release's files and refuses them unless they match the checksums built into it.
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
#   /etc/caddy/wrist-check.caddy        route role: the token check, imported in your site's part of the Caddyfile
#   /usr/local/bin/wrist-check-status   writer role: kuma-status.py
#   wrist-check-status.service/.timer   writer role: runs the writer every minute
#   /var/lib/wrist-check/status.json    writer role: the file the watch reads (OUT changes it)
#
# Every question can be answered ahead of time with an environment variable; without a terminal
# (or with NONINTERACTIVE=yes) the required ones must be given, nothing is guessed. See the README.
#   Route:  DOMAIN  STATUS_PATH  ROUTE=file|check-only|proxy  UPSTREAM  PROTECT=file|folder
#           TOKEN_FILE  TOKEN  OLD_CHECK=disable|keep  CADDYFILE  CADDY_SNIPPET  EDIT_CADDYFILE
#           SKIP_VALIDATE  RELOAD_CMD  SKIP_VERIFY  SNIPPET_OUT (with --print-snippet: write to this file)
#           SAVE_TOKEN=no (with --print-snippet: don't keep a copy of the token in the settings folder)
#   Writer: KUMA_URL  KUMA_SLUG  OUT  OUT_ACCESS=acl|chown|owner  SLOW_MS  SLOW_RUNS  PENDING=ignore|slow|down
#           PRIORITY_GROUPS  WRITER_USER  WRITER_SRC  SKIP_KUMA_CHECK
#   nginx:  NGINX_DIR  NGINX_SNIPPET  NGINX_SITE (the file with the server { } for DOMAIN)
#   Both:   ROLE=all|writer|route  PROXY  CONF_DIR
#   --verify: STATUS_URL  TOKEN_FILE (or the saved token, or it asks)
# Needs: bash and coreutils. Writer: python3, systemd. curl only to pipe this script.

# Everything runs from main() at the very end, so a half-downloaded script never runs partly.
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/grandevr/Self-Hosting-Wrist-Check/${WRIST_CHECK_REF:-main}/server"
# A tagged release sets these three (see .github/workflows/release.yml): the files it downloads must
# then match the checksums, so a pinned install.sh only ever runs the code from its own release.
VERSION=main
WRITER_SHA256=""
PROXIES_SHA256=""
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
SETTINGS="ROLE PROXY DOMAIN STATUS_PATH STATUS_URL ROUTE UPSTREAM PROTECT OLD_CHECK KUMA_URL KUMA_SLUG OUT SLOW_MS SLOW_RUNS PENDING PRIORITY_GROUPS WRITER_USER OUT_ACCESS OUT_OWNER"
TMP_DIR=""
USED_LOCAL_WRITER=""
USED_LOCAL_PROXIES=""
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
      [ "$key" = OLD_CHECK ] && [ "$val" != keep ] && val=""   # only "keep" is a lasting choice
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

# The path the token check covers: just the status file, or everything in its folder.
protect_path() {
  if [ "${PROTECT:-file}" = folder ] && [ "${STATUS_PATH%/*}" != "" ]; then echo "${STATUS_PATH%/*}/*"
  else echo "$STATUS_PATH"; fi
}

snippet_text() { # the token check for the chosen proxy
  case "${PROXY:-caddy}" in
    caddy) caddy_text ;;
    nginx|npm) nginx_text ;;
    apache) load_proxies; apache_text ;;
    haproxy) load_proxies; haproxy_text ;;
    traefik) load_proxies; traefik_text ;;
    *) load_proxies; other_text ;;
  esac
}

caddy_text() {
  local how="install.sh" pp; pp=$(protect_path)
  case "$ROUTE" in
    file) cat <<CADDY
# Wrist Check ($how, ROUTE=file): serves $OUT for $STATUS_PATH, only with the right token.
# Anything else gets 404.
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
# Wrist Check ($how, ROUTE=check-only): requests for $pp without the right token get 404.
# Requests with it carry on to this site's own reverse_proxy. Keep these lines at the top level of
# the site (not inside a handle or route section), or the check is skipped.
@wristcheck_denied {
	path $pp
	not header Authorization "Bearer $TOKEN"
}
respond @wristcheck_denied 404
CADDY
    ;;
    proxy) cat <<CADDY
# Wrist Check ($how, ROUTE=proxy): requests for $pp without the right token get 404.
# Requests with it go to $UPSTREAM (without the token).
handle $pp {
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

# --- Reading the Caddyfile ---------------------------------------------------------------------
# The checks below look at one listing of the site's config, one line per Caddyfile line:
#     file <US> line number <US> depth <US> text          (US is the \037 character)
# It holds the DOMAIN section of the Caddyfile ("example.com { ... }") and every file that section
# imports at its top level. depth 1 is the top level inside the section; imported files count as
# depth 1 too, because that's where their lines end up.

US=$'\037'

site_re() { # matches the line that opens DOMAIN's section: "example.com {", "a.com, example.com:443 {"
  local esc; esc=$(printf '%s' "$DOMAIN" | sed 's/[.*]/\\&/g')
  printf '^([^#{]*[ ,])?(https?://)?%s(:[0-9]+)?([ ,][^{]*)?[[:space:]]*\\{[[:space:]]*$' "$esc"
}

list_lines() { # list_lines FILE START_DEPTH [START_RE]: the listing for FILE, or for one section of it
  START_RE=${3:-} awk -v file="$1" -v depth="$2" '
    BEGIN { re = ENVIRON["START_RE"]; inside = (re == "") }
    !inside && $0 ~ re { inside = 1; depth = 0 }
    inside {
      code = $0; sub(/#.*/, "", code)                       # ignore comments
      opens = gsub(/\{/, "{", code); closes = gsub(/\}/, "}", code)
      shown = (closes > opens) ? depth - closes + opens : depth   # a closing line belongs to the outer level
      print file "\037" NR "\037" shown "\037" $0
      depth += opens - closes
      if (re != "" && depth <= 0) exit                       # end of the section
    }' "$1"
}

site_block() { # the DOMAIN section of the Caddyfile only
  [ -r "$CADDYFILE" ] && [ -n "${DOMAIN:-}" ] || return 0
  list_lines "$CADDYFILE" 0 "$(site_re)"
}

site_lines() { # the DOMAIN section plus the files it imports (except our own snippet)
  local blk file num depth text pat f
  blk=$(site_block)
  [ -n "$blk" ] || return 0
  printf '%s\n' "$blk"
  while IFS="$US" read -r file num depth text; do
    [ "$depth" = 1 ] && [[ "$text" =~ ^[[:space:]]*import[[:space:]]+([^[:space:]#]+) ]] || continue
    pat=${BASH_REMATCH[1]}
    case "$pat" in /*) ;; *) pat="$(dirname "$CADDYFILE")/$pat" ;; esac
    while IFS= read -r f; do
      [ -f "$f" ] && [ -r "$f" ] || continue          # "import name" of a (snippet) is not a file
      [ "$(readlink -f "$f")" = "$(readlink -f "$CADDY_SNIPPET")" ] && continue
      list_lines "$f" 1
    done < <(compgen -G "$pat" || true)
  done <<< "$blk"
}

# caddy_scan old      the old token checks for the protected folder, as "file<US>first<US>last<US>what"
# caddy_scan handles  top-level handle/route sections (other than old token checks), as "file<US>line<US>text"
#
# An old token check is a named matcher whose definition mentions the folder (e.g. "/health") and the
# Authorization header, plus the respond/abort/error lines that use it, plus any handle/route section
# for the folder that checks Authorization itself. Error pages (handle_errors) and headers are left out:
# they don't block requests, so they can stay.
caddy_scan() {
  local dir=${STATUS_PATH%/*}
  [ -n "$dir" ] || dir=$STATUS_PATH
  site_lines | awk -F'\037' -v mode="$1" -v dir="$dir" '
    { n++; F[n] = $1; L[n] = $2; D[n] = $3
      t = $4; sub(/#.*/, "", t); gsub(/^[ \t]+|[ \t]+$/, "", t); T[n] = t }
    END {
      # 1. For each line that opens a block, find the line that closes it (E[i]; E[i] = i for one line).
      for (i = 1; i <= n; i++) {
        if (F[i] != prev) { sp = 0; prev = F[i] }
        x = T[i]; opens = gsub(/\{/, "{", x); x = T[i]; closes = gsub(/\}/, "}", x)
        E[i] = i
        for (k = 0; k < opens; k++) stack[++sp] = i
        for (k = 0; k < closes && sp > 0; k++) E[stack[sp--]] = i
      }
      # 2. Mark the lines inside handle_errors sections: those are error pages, never a token check.
      for (i = 1; i <= n; i++) if (T[i] ~ /^handle_errors([ \t{]|$)/) for (k = i; k <= E[i]; k++) ERR[k] = 1
      # 3. Named matchers: does the definition mention the folder and the Authorization header?
      for (i = 1; i <= n; i++) {
        if (ERR[i] || !match(T[i], /^@[A-Za-z0-9_-]+/)) continue
        name = substr(T[i], 1, RLENGTH); body = ""
        for (k = i; k <= E[i]; k++) { body = body " " T[k]; DEF[k] = 1 }
        if (index(body, dir)) PATH[name] = 1
        if (body ~ /Authorization/) AUTH[name] = 1
        defs[name] = defs[name] " " i
      }
      for (name in defs) if (PATH[name] && AUTH[name]) TOKEN[name] = 1
      # 4. Report.
      for (i = 1; i <= n; i++) {
        if (ERR[i]) continue
        if (mode == "old") {
          if (DEF[i] && match(T[i], /^@[A-Za-z0-9_-]+/) && TOKEN[substr(T[i], 1, RLENGTH)]) {
            print F[i] "\037" L[i] "\037" L[E[i]] "\037" "matcher " substr(T[i], 1, RLENGTH) " (checks a token)"; i = E[i]; continue
          }
          if (!DEF[i] && T[i] ~ /^(respond|abort|error)[ \t]+@/) {
            split(T[i], w, /[ \t]+/)
            if (TOKEN[w[2]]) { print F[i] "\037" L[i] "\037" L[E[i]] "\037" T[i]; i = E[i]; continue }
          }
          if (D[i] == 1 && T[i] ~ /^(handle|handle_path|route)[ \t]/) {
            split(T[i], w, /[ \t]+/); body = ""
            for (k = i; k <= E[i]; k++) body = body " " T[k]
            if (index(w[2], dir) == 1 && body ~ /Authorization/) { print F[i] "\037" L[i] "\037" L[E[i]] "\037" w[1] " " w[2] " section (checks a token)"; i = E[i] }
          }
        } else if (mode == "handles" && D[i] == 1 && T[i] ~ /^(handle|handle_path|route)([ \t{]|$)/) {
          body = ""
          for (k = i; k <= E[i]; k++) body = body " " T[k]
          if (body !~ /Authorization/) print F[i] "\037" L[i] "\037" T[i]
        }
      }
    }'
}

old_checks() { caddy_scan old; }
handle_blocks() { caddy_scan handles; }

show_old_checks() { # show_old_checks LIST [INDENT]: human-readable list of old_checks
  local file first last what ind=${2:-    }
  while IFS="$US" read -r file first last what; do
    [ -n "$file" ] || continue
    if [ "$first" = "$last" ]; then msg "$ind$file, line $first:  $what"
    else msg "$ind$file, lines $first-$last:  $what"; fi
  done <<< "$1"
}

show_handles() {
  local file num text
  while IFS="$US" read -r file num text; do
    [ -n "$file" ] && msg "    $file, line $num:  $text"
  done <<< "$(handle_blocks)"
}

old_folder_wide() { # did the old check cover the whole folder ("/health/*")?
  local dir=${STATUS_PATH%/*}
  [ -n "$dir" ] && site_lines | cut -d"$US" -f4- | grep -v '^[[:space:]]*#' | grep -qF -- "$dir/*"
}

# --- Changing the Caddy config -------------------------------------------------------------------

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

backup_dir() { # backup_dir FILE: next to FILE if that folder is writable, otherwise the settings folder.
  # nginx files always go to the settings folder: nginx loads every file in sites-enabled/, copies too.
  case "$1" in "$NGINX_DIR"/*) install -d -m 700 "$CONF_DIR" 2>/dev/null; echo "$CONF_DIR"; return ;; esac
  if [ -w "$(dirname "$1")" ]; then dirname "$1"; else install -d -m 700 "$CONF_DIR" 2>/dev/null; echo "$CONF_DIR"; fi
}

# Every file this run changes is copied first (once), so restore() can put them all back.
BACKED_UP=()
BACKUPS=()
SN_NEW=no
backup() { # backup FILE: copies it once per run; BK is where the copy is
  local f=$1 i
  for i in "${!BACKED_UP[@]}"; do
    [ "${BACKED_UP[$i]}" = "$f" ] && { BK=${BACKUPS[$i]}; return 0; }
  done
  BK="$(backup_dir "$f")/$(basename "$f").wrist-check.bak"
  ( umask 077; cp "$f" "$BK" )
  BACKED_UP+=("$f"); BACKUPS+=("$BK")
}

restore() {
  local i
  for i in "${!BACKED_UP[@]}"; do cat "${BACKUPS[$i]}" > "${BACKED_UP[$i]}"; done
  [ "$SN_NEW" = yes ] && rm -f "$(snippet_file)"
  true
}

can_write_snippet() { [ -w "$(dirname "$CADDY_SNIPPET")" ] || { [ -f "$CADDY_SNIPPET" ] && [ -w "$CADDY_SNIPPET" ]; }; }

caddy_readable() { # caddy_readable FILE: let Caddy read FILE (it holds the token), and keep everyone else out
  # 1. an ACL for the caddy user (works without root when setfacl is installed), 2. group caddy,
  # 3. only then readable by all, with a warning.
  chmod 600 "$1"
  if id caddy >/dev/null 2>&1 && command -v setfacl >/dev/null && setfacl -m u:caddy:r "$1" 2>/dev/null; then
    :   # owner read/write, caddy read, nobody else (ls shows the ACL mask as group "r")
  elif getent group caddy >/dev/null 2>&1 && chgrp caddy "$1" 2>/dev/null; then
    chmod 640 "$1"
  else
    chmod 644 "$1"
    msg "Note: $1 is readable by every local user, so Caddy can read it (it holds the token)."
    msg "      Installing setfacl (package acl) or joining the caddy group avoids that."
  fi
}

write_snippet() {
  can_write_snippet || die "can't write $CADDY_SNIPPET as $(id -un). Use sudo, or --print-snippet to add the lines by hand."
  SN_NEW=yes
  if [ -f "$CADDY_SNIPPET" ]; then SN_NEW=no; backup "$CADDY_SNIPPET"; fi
  ( umask 077; snippet_text > "$CADDY_SNIPPET" )
  caddy_readable "$CADDY_SNIPPET"
}

# Comments out the old token check (lines from old_checks), so it stops blocking requests. Nothing
# is deleted: each line gets "# [wrist-check] " in front, and the files are backed up first.
disable_old_checks() {
  local file first last what done_files=""
  while IFS="$US" read -r file first last what; do
    [ -n "$file" ] || continue
    [ -w "$file" ] || { restore; die "can't edit $file as $(id -un)."; }
    backup "$file"
    awk -v a="$first" -v z="$last" 'NR >= a && NR <= z { print "# [wrist-check] " $0; next } { print }' "$file" > "$file.wrist-check.tmp"
    cat "$file.wrist-check.tmp" > "$file"; rm -f "$file.wrist-check.tmp"
    [[ " $done_files " == *" $file "* ]] || done_files="$done_files $file"
  done <<< "$1"
  for file in $done_files; do
    backup "$file"
    msg "Turned off the old token check in $file: its lines now start with '# [wrist-check]' (old version: $BK)."
  done
}

has_import() { [ -f "$CADDYFILE" ] && grep -qxF -- "$IMPORT_LINE" <(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' "$CADDYFILE"); }

add_import() {
  [ -w "$CADDYFILE" ] || { restore; die "can't edit $CADDYFILE as $(id -un). Use sudo, or --print-snippet."; }
  local first
  first=$(site_block | head -n1 | cut -d"$US" -f2)
  backup "$CADDYFILE"
  awk -v n="$first" -v imp="$IMPORT_LINE" '{ print } NR == n { print "\t" imp }' "$BK" > "$CADDYFILE"
  msg "Added '$IMPORT_LINE' to the $DOMAIN part of $CADDYFILE (old version: $BK)."
}

manual_import() {
  msg "Add this line inside the \"${DOMAIN:-your site} { ... }\" part of $CADDYFILE yourself, then reload Caddy:"
  msg ""
  msg "    $IMPORT_LINE"
  msg ""
}

# Runs the checks again (they were also asked about earlier), writes the snippet, turns off an old
# check if that was chosen, adds the import line, validates and reloads. If validate or reload
# fails, every changed file goes back to how it was.
# Stops (before anything is changed) when the route can't work as asked.
check_route() {
  case "$PROXY" in caddy) ;; nginx) check_route_nginx; return ;; *) return 0 ;; esac
  local old
  old=$(old_checks)
  if [ -n "$old" ] && [ "${OLD_CHECK:-}" != disable ] && [ "${OLD_CHECK:-}" != keep ]; then
    msg "Your Caddy config already checks a token for $(dirname "$STATUS_PATH")/:"
    show_old_checks "$old"
    die "a second check with a different token would answer 404 to every request, so nothing was changed.
Run again with OLD_CHECK=disable to have those lines commented out (backup kept, rolled back if Caddy
complains), or remove them yourself. OLD_CHECK=keep adds the new check anyway."
  fi
  if [ "$ROUTE" = check-only ] && [ -n "$(handle_blocks)" ]; then
    msg "In the $DOMAIN part of $CADDYFILE, requests are passed on inside handle/route sections:"
    show_handles
    die "those run before a token check placed next to them, so check-only can't protect the file here.
Use ROUTE=proxy with UPSTREAM=<where the file is served>: it handles $(protect_path) itself."
  fi
  true
}

apply_route() {
  local old ok=0 rc=0
  if [ -r "$CADDYFILE" ] && [ -z "$(site_block)" ]; then
    msg "Couldn't find the \"$DOMAIN {\" part in $CADDYFILE."
  fi
  old=$(old_checks)
  write_snippet
  [ -n "$old" ] && [ "$OLD_CHECK" = disable ] && disable_old_checks "$old"

  if has_import; then
    ok=1
  elif [ ! -f "$CADDYFILE" ] || [ -z "$(caddy_bin)" ] || [ -z "$(site_block)" ]; then
    manual_import
  elif is_yes "${EDIT_CADDYFILE:-yes}"; then
    add_import; ok=1
  else
    manual_import
  fi

  if [ "$ok" = 1 ] || [ "${#BACKED_UP[@]}" -gt 0 ]; then
    if ! caddy_validate; then
      restore
      die "Caddy didn't accept the new config, so every changed file was put back. If it only fails
because the Caddy service gets settings this script can't see, run again with SKIP_VALIDATE=yes: the
reload then does the check, and a failed reload is rolled back the same way."
    fi
    reload_caddy || rc=$?
    if [ "$rc" = 1 ]; then
      restore
      reload_caddy >/dev/null 2>&1 || true
      die "reloading Caddy failed, so every changed file was put back (and Caddy reloaded)."
    elif [ "$rc" = 2 ]; then
      msg "Reload Caddy yourself (e.g. sudo systemctl reload caddy), or set RELOAD_CMD=\"...\" next time."
    fi
  fi
}

ask_route() {
  ask_proxy
  [ "$PROXY" = caddy ] && suggest DOMAIN "$D_DOMAIN"
  [ "$PROXY" = nginx ] && have_tty && suggest DOMAIN "$(nginx_domain)"
  ask DOMAIN "Domain the watch connects to (as in https://<domain>/...)" "${DOMAIN:-}"
  [ -n "$DOMAIN" ] || [ "$ACTION" = print ] || need DOMAIN "Domain the watch connects to (as in https://<domain>/...)" "it's part of the status URL"
  [ -z "$DOMAIN" ] || check DOMAIN '^[A-Za-z0-9*.-]+$' "a host name like example.com"
  ask STATUS_PATH "Path of the status file on that domain" "${STATUS_PATH:-/health/status.json}"
  case "$STATUS_PATH" in /*) ;; *) STATUS_PATH="/$STATUS_PATH" ;; esac
  check STATUS_PATH '^/[A-Za-z0-9._~/-]+$' "a URL path like /health/status.json"
  local modes; modes=$(modes_for "$PROXY")
  if [ "$modes" = check-only ] || [ "$modes" = proxy ]; then
    [ -z "${ROUTE:-}" ] || [ "$ROUTE" = "$modes" ] || die "ROUTE=$ROUTE doesn't work with $(proxy_name): it supports only $modes"
    ROUTE=$modes   # the only mode this proxy supports
    [ "$PROXY" = traefik ] && have_tty && msg "Traefik passes the status path on to the address that serves it (proxy mode)."
  elif [ "$ROLE" = all ]; then
    ROUTE="file"   # the writer is on this machine, so the proxy serves its file
  else
    if have_tty; then
      if [ "$PROXY" = nginx ]; then detect_route_nginx; elif [ "$PROXY" = caddy ]; then detect_route; fi
      case "$D_ROUTE" in
        check-only) msg "This site already passes requests on to ${D_UPSTREAM:-another server}, so it only needs the token check (check-only)." ;;
        proxy) msg "This site passes requests on inside handle/route sections, where an added check would be skipped, so proxy fits." ;;
      esac
      suggest ROUTE "$D_ROUTE"
      msg "Where is the status file?
  file        on this machine (the writer runs here, or you copy the file here)
  check-only  on another machine this site already passes requests to: just check the token here
  proxy       on another machine: check the token here, then fetch the file from an address you give"
    fi
    need ROUTE "Answer (file / check-only / proxy)" "file, check-only or proxy"
  fi
  check ROUTE '^(file|check-only|proxy)$' "file, check-only or proxy"
  case " $modes " in *" $ROUTE "*) ;; *) die "ROUTE=$ROUTE doesn't work with $PROXY (it supports: $modes)" ;; esac
  if [ "$ROUTE" = proxy ]; then
    suggest UPSTREAM "$D_UPSTREAM"
    need UPSTREAM "Address that serves the status file, e.g. the one your site already goes to (host:port or URL)" "where requests with the token go"
    check UPSTREAM '^[][A-Za-z0-9.:/_-]+$' "host:port or a URL like http://10.0.0.5:8080"
  fi
  if [ "$ROUTE" != file ] && [ "$STATUS_PATH" != "/${STATUS_PATH##*/}" ]; then
    have_tty && [ "$PROXY" = caddy ] && old_folder_wide && suggest PROTECT folder
    ask PROTECT "Protect only ${STATUS_PATH##*/}, or everything in $(dirname "$STATUS_PATH")/ (file / folder)" "${PROTECT:-file}"
    check PROTECT '^(file|folder)$' "file or folder"
  else
    PROTECT="file"
  fi
  [ "$ROUTE" = file ] && OUT=${OUT:-$DEFAULT_OUT}
  status_url
}

# An old token check found earlier: with a terminal, ask what to do; without one, OLD_CHECK decides.
ask_old_check() {
  [ "$PROXY" = caddy ] || return 0
  [ -n "${ALLOW_EXISTING_ROUTE:-}" ] && is_yes "$ALLOW_EXISTING_ROUTE" && OLD_CHECK=${OLD_CHECK:-keep}
  local old; old=$(old_checks)
  [ -n "$old" ] && [ -z "${OLD_CHECK:-}" ] && have_tty || return 0
  msg ""
  msg "Your Caddy config already checks a token for $(dirname "$STATUS_PATH")/:"
  show_old_checks "$old"
  msg "Two checks with different tokens would block every request, so the old one has to go. Error pages
(handle_errors) and headers aren't affected and stay as they are."
  local writable=yes file
  while IFS="$US" read -r file _; do [ -w "$file" ] || writable=no; done <<< "$old"
  if [ "$ACTION" = install ] && [ "$writable" = yes ]; then
    msg "  disable  comment those lines out (nothing deleted, backup kept, undone if Caddy complains)"
    msg "  print    show the new lines, and change the config yourself"
    msg "  stop     change nothing"
    ask OLD_CHECK "Answer (disable / print / stop)" "disable"
  else
    ask OLD_CHECK "Show the new lines, to put in place of those yourself? (print / stop)" "print"
  fi
  check OLD_CHECK '^(disable|print|stop|keep)$' "disable, print or stop"
  [ "$OLD_CHECK" = stop ] && die "stopped, nothing changed."
  true
}

# ------------------------------------------------------------------------------- other proxies
# PROXY says which reverse proxy the watch connects to:
#   caddy    edits the Caddyfile itself (above)
#   nginx    writes a snippet, includes it in the server { } for DOMAIN, runs nginx -t and reloads
#   npm      Nginx Proxy Manager: prints lines for the proxy host's "Advanced" tab
#   traefik  prints a file-provider config (routers + service)
#   apache   prints lines for the <VirtualHost>
#   haproxy  prints a line for the frontend
#   other    describes the rule, for any other web server
# Only caddy and nginx are changed by the script; the others get exact paste-in steps.

PROXIES="caddy nginx npm traefik apache haproxy other"
NGINX_DIR=${NGINX_DIR:-/etc/nginx}
NGINX_SNIPPET=${NGINX_SNIPPET:-$NGINX_DIR/snippets/wrist-check.conf}

snippet_file() { # where this proxy's snippet lives when the script installs it
  case "$PROXY" in nginx) echo "$NGINX_SNIPPET" ;; *) echo "$CADDY_SNIPPET" ;; esac
}

proxy_name() {
  case "${1:-$PROXY}" in
    caddy) echo Caddy ;; nginx) echo nginx ;; npm) echo "Nginx Proxy Manager" ;; traefik) echo Traefik ;;
    apache) echo Apache ;; haproxy) echo HAProxy ;; *) echo "your proxy" ;;
  esac
}

modes_for() { # route modes each proxy supports
  case "$1" in
    haproxy|other) echo "check-only" ;;
    traefik) echo "proxy" ;;
    *) echo "file check-only proxy" ;;
  esac
}

upstream_url() { case "$UPSTREAM" in http://*|https://*) echo "${UPSTREAM%/}" ;; *) echo "http://${UPSTREAM%/}" ;; esac; }

path_regex() { # protected path as an anchored regex: ^/health/status\.json$ or ^/health/
  if [ "${PROTECT:-file}" = folder ]; then printf '^%s/' "$(dirname "$STATUS_PATH" | sed 's/\./\\./g')"
  else printf '^%s$' "$(printf '%s' "$STATUS_PATH" | sed 's/\./\\./g')"; fi
}

prefix_path() { # protected path as a plain prefix (folder) or exact path (file)
  if [ "${PROTECT:-file}" = folder ]; then echo "$(dirname "$STATUS_PATH")/"; else echo "$STATUS_PATH"; fi
}

nginx_text() {
  cat <<NGINX
# Wrist Check (install.sh, nginx, ROUTE=$ROUTE): requests for $(prefix_path) without the right token get 404.
# Goes inside the server { } for $DOMAIN. The checks run before nginx picks a location.
set \$wristcheck "";
if (\$uri ~ "$(path_regex)") { set \$wristcheck "p"; }
if (\$http_authorization != "Bearer $TOKEN") { set \$wristcheck "\${wristcheck}t"; }
if (\$wristcheck = "pt") { return 404; }
NGINX
  case "$ROUTE" in
    file) cat <<NGINX
location = $STATUS_PATH {
	alias $OUT;
	default_type application/json;
	add_header Cache-Control "no-store";
}
NGINX
    ;;
    proxy) cat <<NGINX
location ^~ $(prefix_path) {
	proxy_pass $(upstream_url);
	proxy_set_header Authorization "";
}
NGINX
    ;;
  esac
}

# Steps after printing, for the proxies the script doesn't change itself. $1 = step number to start at.
paste_steps() {
  local n=$1 where=${SNIPPET_OUT:-}
  case "$PROXY" in
    nginx)
      if [ -n "$where" ]; then msg "  $n. Add  include $where;  inside the server { } for $DOMAIN (next to server_name)."
      else msg "  $n. Paste the lines above inside the server { } for $DOMAIN (next to server_name)."; fi
      msg "  $((n + 1)). Check and reload:  sudo nginx -t && sudo systemctl reload nginx" ;;
    *) load_proxies; proxy_steps "$n" ;;
  esac
}

# --- nginx, changed by the script ----------------------------------------------------------------

nginx_conf_files() { # config files that can hold server blocks
  local f
  for f in "$NGINX_DIR"/sites-enabled/* "$NGINX_DIR"/conf.d/*.conf "$NGINX_DIR"/nginx.conf; do
    [ -f "$f" ] && [ -r "$f" ] && echo "$f"
  done
}

nginx_sites() { # files with "server_name ... DOMAIN ...;" (NGINX_SITE overrides)
  if [ -n "${NGINX_SITE:-}" ]; then echo "$NGINX_SITE"; return 0; fi
  [ -n "${DOMAIN:-}" ] || return 0
  local esc; esc=$(printf '%s' "$DOMAIN" | sed 's/[.*]/\\&/g')
  nginx_conf_files | while IFS= read -r f; do
    grep -qE "^[[:space:]]*server_name[^;]*[[:space:]]$esc([[:space:];]|$)" "$f" && echo "$f"
  done
  true
}

nginx_old_checks() { # lines in those files that already check the Authorization header
  local f
  while IFS= read -r f; do
    [ -n "$f" ] && grep -nE 'http_authorization' "$f" | grep -v 'wrist-check' | sed "s|^|    $f, line |; s|:|:  |"
  done <<< "$(nginx_sites)"
  true
}

nginx_has_include() { grep -qF "include $NGINX_SNIPPET;" "$1"; }

nginx_ok() { command -v nginx >/dev/null || return 0; nginx -t >/dev/null 2>&1 || { nginx -t 2>&1 | tail -n 5 | sed 's/^/    /' >&2; return 1; }; }

nginx_reload() { # 0 reloaded, 1 failed, 2 not attempted
  if [ -n "${RELOAD_CMD:-}" ]; then bash -c "$RELOAD_CMD" >&3 || return 1
  elif command -v systemctl >/dev/null && systemctl is-active --quiet nginx 2>/dev/null; then systemctl reload nginx || return 1
  elif command -v nginx >/dev/null && [ -n "$(pgrep -x nginx 2>/dev/null)" ]; then nginx -s reload || return 1
  else return 2; fi
  msg "nginx reloaded."
}

check_route_nginx() {
  [ "$IS_ROOT" = yes ] || [ -w "$(dirname "$NGINX_SNIPPET")" ] || is_yes "${DRY_RUN:-}" \
    || die "can't write $NGINX_SNIPPET as $(id -un). Use sudo, or --print-snippet to add the lines by hand."
  local old; old=$(nginx_old_checks)
  if [ -n "$old" ] && [ "${OLD_CHECK:-}" != keep ]; then
    msg "Your nginx config for $DOMAIN already checks the Authorization header:"
    msg "$old"
    die "a second check with a different token would answer 404 to every request, so nothing was changed.
Remove that check (or turn it into the new one by hand with --print-snippet), or set OLD_CHECK=keep."
  fi
  [ -n "$(nginx_sites)" ] || msg "Couldn't find \"server_name $DOMAIN\" in the nginx config: you'll add the include line yourself."
  true
}

apply_route_nginx() {
  local f rc=0 added=0
  install -d -m 755 "$(dirname "$NGINX_SNIPPET")"
  SN_NEW=yes
  if [ -f "$NGINX_SNIPPET" ]; then SN_NEW=no; backup "$NGINX_SNIPPET"; fi
  ( umask 077; snippet_text > "$NGINX_SNIPPET" )
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    nginx_has_include "$f" && { added=1; continue; }
    [ -w "$f" ] || { restore; die "can't edit $f as $(id -un)."; }
    backup "$f"
    # The include goes right after each "server_name ... DOMAIN" line (port 80 and 443 servers alike).
    local esc; esc=$(printf '%s' "$DOMAIN" | sed 's/[.*]/\\&/g')
    awk -v re="^[[:space:]]*server_name[^;]*[[:space:]]$esc([[:space:];]|\$)" -v inc="include $NGINX_SNIPPET;" \
      '{ print } $0 ~ re { match($0, /^[ \t]*/); print substr($0, 1, RLENGTH) inc }' "$BK" > "$f"
    msg "Added 'include $NGINX_SNIPPET;' to the $DOMAIN server in $f (old version: $BK)."
    added=1
  done <<< "$(nginx_sites)"
  if [ "$added" = 0 ]; then
    msg "Add this line inside the server { } for $DOMAIN yourself, then reload nginx:"
    msg ""; msg "    include $NGINX_SNIPPET;"; msg ""
    return 0
  fi
  nginx_ok || { restore; die "nginx -t didn't accept the new config, so every changed file was put back."; }
  nginx_reload || rc=$?
  if [ "$rc" = 1 ]; then restore; nginx_reload >/dev/null 2>&1 || true; die "reloading nginx failed, so every changed file was put back."
  elif [ "$rc" = 2 ]; then msg "Reload nginx yourself (e.g. sudo systemctl reload nginx)."; fi
}

uninstall_nginx() {
  local f
  while IFS= read -r f; do
    [ -f "$f" ] && nginx_has_include "$f" || continue
    backup "$f"
    grep -vF "include $NGINX_SNIPPET;" "$BK" > "$f" || true
    msg "Removed the include from $f (old version: $BK)."
  done <<< "$(nginx_conf_files)"
  rm -f "$NGINX_SNIPPET"
  local rc=0; nginx_reload || rc=$?
  [ "$rc" = 2 ] && msg "Reload nginx yourself."
  true
}

nginx_domain() { # first real name in a server_name line (not "_" or "localhost")
  nginx_conf_files | while IFS= read -r f; do grep -hE '^[[:space:]]*server_name[[:space:]]' "$f"; done \
    | tr -d ';' | awk '{ for (i = 2; i <= NF; i++) if ($i ~ /\./ && $i !~ /^[*~]/) { print $i; exit } }'
  true
}

detect_route_nginx() {
  local f
  D_ROUTE="file"
  while IFS= read -r f; do
    [ -n "$f" ] && grep -qE '^[[:space:]]*proxy_pass[[:space:]]' "$f" && {
      D_ROUTE=check-only
      D_UPSTREAM=$(grep -m1 -E '^[[:space:]]*proxy_pass[[:space:]]' "$f" | awk '{ gsub(/;/, "", $2); print $2 }')
    }
  done <<< "$(nginx_sites)"
  true
}

detect_proxies() { # which reverse proxies run here, best guess first
  D_PROXIES=""
  local imgs=""
  docker_ok && imgs=$(docker ps --format '{{.Image}}' 2>/dev/null | tr 'A-Z' 'a-z')
  { [ -n "$(caddy_bin)" ] || [ -r "$CADDYFILE" ]; } && D_PROXIES="$D_PROXIES caddy"
  grep -q 'nginx-proxy-manager' <<< "$imgs" && D_PROXIES="$D_PROXIES npm"
  { command -v traefik >/dev/null || grep -q 'traefik' <<< "$imgs"; } && D_PROXIES="$D_PROXIES traefik"
  { command -v haproxy >/dev/null || grep -q 'haproxy' <<< "$imgs"; } && D_PROXIES="$D_PROXIES haproxy"
  { command -v nginx >/dev/null && [ -d "$NGINX_DIR" ]; } && D_PROXIES="$D_PROXIES nginx"
  { command -v apache2 >/dev/null || command -v httpd >/dev/null; } && D_PROXIES="$D_PROXIES apache"
  D_PROXIES=${D_PROXIES# }
  true
}

ask_proxy() {
  if [ -z "${PROXY:-}" ]; then
    if have_tty; then
      [ -n "${D_PROXIES:-}" ] || detect_proxies
      msg "Which reverse proxy does the watch connect through?"
      msg "  caddy  nginx  npm (Nginx Proxy Manager)  traefik  apache  haproxy  other"
      [ -n "$D_PROXIES" ] && msg "  Found here: $D_PROXIES"
      ask PROXY "Answer" "${D_PROXIES%% *}"
    fi
    PROXY=${PROXY:-caddy}   # without a terminal, Caddy as before
  fi
  case " $PROXIES " in *" $PROXY "*) ;; *) die "PROXY='$PROXY' isn't one of: $PROXIES" ;; esac
}

# --------------------------------------------------------------------------------------- writer

ask_writer() {
  suggest KUMA_URL "$D_KUMA_URL"
  if have_tty && [ -z "${KUMA_SLUG:-}" ]; then
    if [ -n "$D_SLUGS" ]; then
      [ "${D_SLUGS// /}" != "$D_SLUGS" ] && msg "Kuma has these status pages: $D_SLUGS"
      KUMA_SLUG=${D_SLUGS%% *}
    elif [ -n "$D_KUMA_URL" ]; then
      msg "Couldn't list Kuma's status pages from here (Kuma 2 with MariaDB keeps them out of reach), so enter the slug."
    fi
  fi
  if have_tty && [ "$ROLE" = writer ] && [ -z "${OUT:-}" ]; then
    detect_out
    [ -n "$D_OUT" ] && msg "A web server here serves $(dirname "$D_OUT"): the writer can write straight into it."
    suggest OUT "$D_OUT"
  fi
  ask KUMA_URL "Uptime Kuma URL (as seen from this machine)" "${KUMA_URL:-http://127.0.0.1:3001}"
  check KUMA_URL '^https?://[^[:space:]]+$' "a URL like http://127.0.0.1:3001"
  need KUMA_SLUG "Slug of the Kuma status page listing the monitors" "the last part of the status page's URL, /status/<slug>"
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
  check WRITER_USER '^[a-z_][a-z0-9_-]*$' "a user name"
  plan_out_access
  command -v python3 >/dev/null || die "python3 is needed for the status writer"
  fetch_writer
  check_kuma
}

tmp_dir() { [ -n "$TMP_DIR" ] || TMP_DIR=$(mktemp -d); }

local_file() { # local_file NAME: NAME next to this script, when it was run from a downloaded install.sh
  [ -f "$0" ] && [ "$(basename "$0")" = install.sh ] && [ -f "$(dirname "$0")/$1" ] || return 1
  echo "$(dirname "$0")/$1"
}

download() { # download NAME DEST SHA256: a file from this script's release (or main); checked if SHA256 is set
  local url="$REPO_RAW/$1" got
  if command -v curl >/dev/null; then
    curl -fsSL "$url" -o "$2" || die "couldn't download $url"
  elif command -v python3 >/dev/null; then
    python3 - "$url" "$2" <<'PY' || die "couldn't download $url"
import sys, urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=30) as r, open(sys.argv[2], "wb") as f:
    f.write(r.read())
PY
  else
    die "can't download $1: needs curl or python3"
  fi
  check_sum "$2" "$3"
}

check_sum() { # check_sum FILE SHA256: a release only uses its own files (no SHA256 = not a release)
  [ -n "$2" ] || return 0
  local got; got=$(sha256sum "$1" | cut -d' ' -f1)
  [ "$got" = "$2" ] || die "$1 isn't the $(basename "$1") of release $VERSION (sha256 $got): not using it"
}

fetch_writer() { # sets WRITER_SRC to a local kuma-status.py
  if [ -n "${WRITER_SRC:-}" ]; then [ -r "$WRITER_SRC" ] || die "can't read WRITER_SRC=$WRITER_SRC"; return 0; fi
  if WRITER_SRC=$(local_file kuma-status.py); then
    check_sum "$WRITER_SRC" "$WRITER_SHA256"; USED_LOCAL_WRITER=$WRITER_SRC; return 0
  fi
  tmp_dir
  WRITER_SRC="$TMP_DIR/kuma-status.py"
  download kuma-status.py "$WRITER_SRC" "$WRITER_SHA256"
}

load_proxies() { # the printers for npm, Traefik, Apache, HAProxy and "other" live in proxies.sh
  declare -F proxy_steps >/dev/null && return 0
  local f
  if f=$(local_file proxies.sh); then check_sum "$f" "$PROXIES_SHA256"; USED_LOCAL_PROXIES=$f
  else tmp_dir; f="$TMP_DIR/proxies.sh"; download proxies.sh "$f" "$PROXIES_SHA256"; fi
  # shellcheck source=proxies.sh
  . "$f"
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

# Decides, before anything changes, how the writer gets to write into OUT's folder:
#   new     the folder doesn't exist yet: it's created for the writer
#   ok      the writer's user can already write there (or it's this script's own folder)
#   acl     give the writer's user write access to that one folder (setfacl)
#   chown   give that one folder to the writer's user; the old owner is saved (OUT_OWNER) and gets it
#           back on --uninstall
#   owner   run the writer as the folder's owner instead
plan_out_access() {
  local dir owner; dir=$(dirname "$OUT")
  if [ ! -e "$dir" ]; then OUT_ACCESS=new; return 0; fi
  [ -d "$dir" ] || die "$dir isn't a folder"
  if [ "$dir" = "$DATA_DIR" ] || writable_by "$WRITER_USER" "$dir"; then
    case "${OUT_ACCESS:-}" in acl|chown) ;; *) OUT_ACCESS=ok ;; esac   # keep what an earlier run set up
    return 0
  fi
  owner=$(stat -c %U "$dir")
  if [ -z "${OUT_ACCESS:-}" ] || [ "$OUT_ACCESS" = ok ] || [ "$OUT_ACCESS" = new ]; then
    OUT_ACCESS=""
    if have_tty; then
      msg ""
      msg "The writer runs as the user $WRITER_USER, which can't write to $dir (it belongs to $owner)."
      command -v setfacl >/dev/null && msg "  acl    let $WRITER_USER write to that folder only (nothing else changes)"
      msg "  chown  give that folder to $WRITER_USER ($owner gets it back on --uninstall)"
      msg "  owner  run the writer as $owner instead$([ "$owner" = root ] && echo ' (not recommended for root)')"
      if command -v setfacl >/dev/null; then ask OUT_ACCESS "Answer (acl / chown / owner)" "acl"
      else ask OUT_ACCESS "Answer (chown / owner)" "chown"; fi
    else
      die "the writer's user $WRITER_USER can't write to $dir (it belongs to $owner), and nothing was changed.
Set one of:  OUT_ACCESS=acl    let $WRITER_USER write to that folder (needs setfacl, package acl)
             OUT_ACCESS=chown  give the folder to $WRITER_USER; $owner gets it back on --uninstall
             OUT_ACCESS=owner  run the writer as $owner"
    fi
  fi
  check OUT_ACCESS '^(acl|chown|owner)$' "acl, chown or owner"
  case "$OUT_ACCESS" in
    owner) WRITER_USER=$owner ;;
    acl) command -v setfacl >/dev/null || die "OUT_ACCESS=acl needs setfacl (package acl); OUT_ACCESS=chown works without it" ;;
    chown) OUT_OWNER=$(stat -c %U:%G "$dir") ;;
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

  if [ "$WRITER_USER" = wrist-check ] && ! id wrist-check >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin wrist-check
  fi
  id "$WRITER_USER" >/dev/null 2>&1 || die "user $WRITER_USER doesn't exist"
  case "$OUT_ACCESS" in
    new) install -d -m 755 -o "$WRITER_USER" "$out_dir" ;;
    acl) setfacl -m "u:$WRITER_USER:rwx" "$out_dir" && msg "Let $WRITER_USER write to $out_dir (ACL)." ;;
    chown)
      [ "$(stat -c %U "$out_dir")" = "$WRITER_USER" ] || {
        chown "$WRITER_USER" "$out_dir" && msg "Gave $out_dir to $WRITER_USER (it was $OUT_OWNER; --uninstall gives it back)."
      } ;;
  esac
  [ "$out_dir" = "$DATA_DIR" ] && chown "$WRITER_USER" "$out_dir"
  writable_by "$WRITER_USER" "$out_dir" || die "$WRITER_USER still can't write to $out_dir (check the folders above it)"
  install -m 755 "$WRITER_SRC" "$WRITER_BIN"

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
# What's found is always reported. Only with a terminal does it become the suggested answer, which you
# confirm or change; without one nothing is guessed: answers come from the environment or saved settings.

D_PROXIES=""; D_ROLE=""; D_KUMA_URL=""; D_SLUGS=""; D_CADDY=""; D_DOMAIN=""; D_ROUTE=""; D_UPSTREAM=""; D_OUT=""; D_OTHER_TIMERS=""

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

detect_route() { # needs DOMAIN and STATUS_PATH: how the site passes requests on today
  local dom=${DOMAIN:-$D_DOMAIN} lines
  [ -n "$dom" ] || return 0
  lines=$(DOMAIN=$dom site_lines)
  [ -n "$lines" ] || return 0
  # The first "reverse_proxy <address>" in the site (the suggested upstream), e.g. 10.0.0.5:8080.
  D_UPSTREAM=$(printf '%s\n' "$lines" | awk -F'\037' '
    $4 ~ /^[ \t]*reverse_proxy[ \t]/ {
      n = split($4, w, /[ \t]+/)
      for (i = 1; i <= n; i++) if (w[i] == "reverse_proxy") {
        t = w[i + 1]; if (t ~ /^[@\/*]/) t = w[i + 2]     # skip a matcher like /api/* or @name
        sub(/\{$/, "", t); print t; exit
      }
    }')
  if [ -n "$(DOMAIN=$dom handle_blocks)" ]; then D_ROUTE=proxy
  elif printf '%s\n' "$lines" | cut -d"$US" -f3- | grep -q "^1${US}[[:space:]]*reverse_proxy[[:space:]]"; then D_ROUTE=check-only
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

detect_all() { # with or without a terminal, so the log shows what was found; only a terminal uses it
  msg "Looking around this machine..."
  detect_kuma; detect_caddy; detect_other_timers
  local py=no; command -v python3 >/dev/null && py=yes
  if [ -n "$D_KUMA_URL" ] && [ -n "$D_SLUGS" ]; then msg "  Uptime Kuma:  $D_KUMA_URL (status pages: $D_SLUGS)"
  elif [ -n "$D_KUMA_URL" ]; then msg "  Uptime Kuma:  $D_KUMA_URL (couldn't list its status pages, e.g. Kuma 2 with MariaDB: enter the slug)"
  elif [ -n "$D_SLUGS" ]; then msg "  Uptime Kuma:  its database is here (status pages: $D_SLUGS), but nothing answers on the usual ports"
  else msg "  Uptime Kuma:  not found"; fi
  detect_proxies
  if [ -n "$D_CADDY" ]; then msg "  Caddy:        yes ($CADDYFILE${D_DOMAIN:+, site $D_DOMAIN})"; fi
  if [ -n "$D_PROXIES" ]; then msg "  Proxies:      $D_PROXIES"; else msg "  Proxy:        none found"; fi
  msg "  python3:      $py"
  [ -n "$D_OTHER_TIMERS" ] && msg "  Other timers: $D_OTHER_TIMERS(maybe an older status writer)"
  local why
  if [ -z "${ROLE:-}" ]; then
    if [ -n "$D_KUMA_URL" ] && [ -n "$D_PROXIES" ]; then D_ROLE=all; why="Kuma and a proxy are both here"
    elif [ -n "$D_KUMA_URL" ]; then D_ROLE=writer; why="Kuma is here, no proxy"
    elif [ -n "$D_PROXIES" ]; then D_ROLE=route; why="a proxy is here, Kuma isn't"
    else D_ROLE=all; why="found neither, so assuming one server"; fi
    [ "$D_ROLE" != route ] && [ "$py" = no ] && { D_ROLE=route; why="no python3 here for the writer"; }
    msg "  Suggested:    $D_ROLE ($why)"
  fi
  have_tty || msg "  (No terminal: this is only a report. The settings come from the environment or $ENV_FILE.)"
  msg ""
}

suggest() { # suggest VAR VALUE: with a terminal, VALUE becomes the default answer if VAR has none yet
  have_tty || return 0
  [ -n "${!1:-}" ] || [ -z "$2" ] || printf -v "$1" '%s' "$2"
}

token_desc() {
  case "$TOKEN_SOURCE" in
    new) echo "a new random one, kept in $TOKEN_PATH" ;;
    saved) echo "keep the current one" ;;
    *) echo "reuse the one from $TOKEN_SOURCE" ;;
  esac
}

plan() { # what this run is about to change, in plain words
  msg "Plan for this machine:"
  if [ "$ROLE" != route ]; then
    msg "  Status writer"
    msg "    - every minute: read the Kuma status page '$KUMA_SLUG' ($KUMA_URL) and write $OUT"
    msg "    - SLOW after $SLOW_RUNS slow checks in a row (over $SLOW_MS ms); retrying monitors: $PENDING${PRIORITY_GROUPS:+; listed first: $PRIORITY_GROUPS}"
    id "$WRITER_USER" >/dev/null 2>&1 || msg "    - create the system user $WRITER_USER"
    case "$OUT_ACCESS" in
      new) msg "    - create the folder $(dirname "$OUT")" ;;
      acl) msg "    - let $WRITER_USER write to $(dirname "$OUT") (an ACL on that folder)" ;;
      chown) [ "$(stat -c %U "$(dirname "$OUT")")" = "$WRITER_USER" ] \
               || msg "    - give the folder $(dirname "$OUT") to $WRITER_USER (now $OUT_OWNER; --uninstall gives it back)" ;;
      owner) msg "    - run as $WRITER_USER, who owns $(dirname "$OUT")" ;;
    esac
    msg "    - install $WRITER_BIN and the wrist-check-status timer"
  fi
  if [ "$ROLE" != writer ]; then
    msg "  Token check in $(proxy_name), for $STATUS_URL"
    msg "    - token: $(token_desc)"
    case "$PROXY" in
      caddy)
        local old; old=$(old_checks)
        msg "    - write $CADDY_SNIPPET ($ROUTE, protects $(protect_path))"
        [ -n "$old" ] && [ "${OLD_CHECK:-}" = disable ] && msg "    - comment out the old token check ($(grep -c . <<< "$old") places)"
        has_import || msg "    - add '$IMPORT_LINE' to the $DOMAIN part of $CADDYFILE"
        msg "    - check the config and reload Caddy; if either fails, put everything back" ;;
      nginx)
        msg "    - write $NGINX_SNIPPET ($ROUTE, protects $(prefix_path))"
        local f; while IFS= read -r f; do [ -n "$f" ] && ! nginx_has_include "$f" && msg "    - include it in the $DOMAIN server in $f"; done <<< "$(nginx_sites)"
        msg "    - run nginx -t and reload nginx; if either fails, put everything back" ;;
      *)
        msg "    - print the lines for $(proxy_name) ($ROUTE, protects $(prefix_path)) and the steps to add them;"
        msg "      the script doesn't change $(proxy_name) itself" ;;
    esac
  fi
  msg "  Settings saved in $ENV_FILE"
}

confirm_plan() {
  msg ""
  plan
  if is_yes "${DRY_RUN:-}"; then msg ""; msg "Dry run: nothing was changed."; exit 0; fi
  have_tty || return 0
  local go=""
  ask go "Go ahead? (yes / no)" "yes"
  is_yes "$go" || die "stopped, nothing changed. Run again to change the answers."
}

next_route_steps() { # after --writer-only: what's left, unless it's already in place
  local line="curl -fsSL $REPO_RAW/install.sh" tok=""
  [ -r "$TOKEN_PATH" ] && tok=$(read_token_file "$TOKEN_PATH")
  msg ""
  if [ -n "${STATUS_URL:-}" ] && [ -n "$tok" ] && ! is_yes "${SKIP_VERIFY:-}"; then
    if verify_url "$STATUS_URL" "$tok"; then msg "The token check is already in place, so nothing else is needed."; return 0; fi
    msg ""
  fi
  msg "Next steps (skip what you've done already):"
  msg "  1. If the token check isn't set up yet: on the machine with the reverse proxy the watch connects to, run"
  msg "       $line | sudo bash -s -- --route-only"
  msg "     or, without sudo there, print the lines to add yourself:"
  msg "       $line | bash -s -- --print-snippet"
  msg "  2. Test it from any machine (it asks for the URL and token if they aren't saved there):"
  msg "       $line | bash -s -- --verify"
  msg "  3. To set up a watch: on the proxy machine, the same line with --show prints the URL and token."
}

proxy_config_text() { # the config text for DOMAIN the script can read, to find a token already in use
  case "$PROXY" in
    caddy) site_lines | cut -d"$US" -f4- ;;
    nginx) local f; while IFS= read -r f; do [ -n "$f" ] && cat "$f"; done <<< "$(nginx_sites)" ;;
  esac
  true
}

ask_existing_token() { # with a terminal, offer to reuse a token instead of making a new one
  [ "$TOKEN_SOURCE" = new ] && have_tty || return 0
  local t="" keep=""
  # A hand-written route in the site block may already check a token: keeping it keeps the watches working.
  t=$(proxy_config_text | grep -v '^[[:space:]]*#' | sed -n 's/.*"Bearer \([A-Za-z0-9._~+\/=-]\{16,512\}\)".*/\1/p' | head -n1)
  if [ -n "$t" ]; then
    ask keep "Your $(proxy_name) config already uses a token (${t:0:4}...). Keep it, so watches already set up keep working? (yes / no)" "yes"
    if is_yes "$keep"; then TOKEN=$t; TOKEN_SOURCE="your existing $(proxy_name) config"; return 0; fi
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

# --------------------------------------------------------------------------------------- verify

# http_probe URL BODYFILE: prints the HTTP status (000 = no answer) and saves the body. A token in
# PROBE_TOKEN goes in the Authorization header; it's passed through the environment or stdin, never as
# an argument, so it doesn't show up in ps.
http_probe() {
  rm -f "$2" "$2.err"
  if command -v python3 >/dev/null; then
    python3 -c 'import os, sys, urllib.request, urllib.error
h = {"User-Agent": "wrist-check-verify", "Cache-Control": "no-cache"}
if os.environ.get("PROBE_TOKEN"):
    h["Authorization"] = "Bearer " + os.environ["PROBE_TOKEN"]
code = 0
try:
    with urllib.request.urlopen(urllib.request.Request(sys.argv[1], headers=h), timeout=10) as r:
        code, body = r.status, r.read(200000)
except urllib.error.HTTPError as e:
    code, body = e.code, e.read(2000)
except Exception as e:
    body = ("%s: %s" % (type(e).__name__, getattr(e, "reason", e))).encode()
open(sys.argv[2], "wb").write(body)
print("%03d" % code)' "$1" "$2" 2>/dev/null || echo 000
  elif command -v curl >/dev/null; then
    { [ -n "${PROBE_TOKEN:-}" ] && printf 'header = "Authorization: Bearer %s"\n' "$PROBE_TOKEN"; true; } \
      | curl -sS -m 10 -K - -H 'Cache-Control: no-cache' -o "$2" -w '%{http_code}' "$1" 2>"$2.err" || true
  else
    echo "needs python3 or curl" > "$2"; echo 000
  fi
}

status_info() { # status_info BODYFILE: "age<TAB>short<TAB>error" if it's the writer's JSON
  if command -v python3 >/dev/null; then
    python3 -c 'import json, sys, time
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert isinstance(d, dict) and isinstance(d.get("updated"), (int, float)) and "short" in d
print("%d\t%s\t%s" % (time.time() - d["updated"], d["short"], d.get("error", "")))' "$1" 2>/dev/null
  else
    local up short
    up=$(grep -o '"updated": *[0-9]*' "$1" | grep -o '[0-9]*$') || return 1
    short=$(sed -n 's/.*"short": *"\([^"]*\)".*/\1/p' "$1" | head -n1)
    printf '%s\t%s\t%s\n' "$(( $(date +%s) - up ))" "$short" "$(grep -q '"error"' "$1" && echo yes)"
  fi
}

verify_url() { # verify_url URL TOKEN: 0 if the watch would get a fresh status and others get nothing
  local url=$1 tok=$2 body code info age short err bad=0
  tmp_dir; body="$TMP_DIR/probe"
  msg "Testing $url"
  code=$(PROBE_TOKEN=$tok http_probe "$url" "$body")
  case "$code" in
    200)
      if info=$(status_info "$body"); then
        IFS=$'\t' read -r age short err <<< "$info"
        if [ -n "$err" ]; then msg "  with the token:     answers, but the writer can't read Kuma ($err)"; bad=1
        elif [ "$age" -gt 300 ]; then
          msg "  with the token:     answers, but the status is $((age / 60)) minutes old. Is the writer running?"
          msg "                      On its machine: systemctl status wrist-check-status.timer"; bad=1
        else msg "  with the token:     OK, \"$short\" (written ${age}s ago)"; fi
      else
        msg "  with the token:     answers 200, but not with the status JSON: something else serves this path"; bad=1
      fi ;;
    000) msg "  with the token:     no answer ($(cat "$body" "$body.err" 2>/dev/null | head -c 200))"; bad=1 ;;
    401|403|404)
      msg "  with the token:     $code. The token check doesn't let this token through (it has another token,"
      msg "                      or isn't in place or reloaded yet), or the status file isn't there yet."; bad=1 ;;
    502|503|504) msg "  with the token:     $code: the proxy can't reach the machine with the status file"; bad=1 ;;
    *) msg "  with the token:     unexpected answer $code"; bad=1 ;;
  esac
  code=$(PROBE_TOKEN="" http_probe "$url" "$body")
  case "$code" in
    404) msg "  without the token:  OK, 404 (to everyone else there's nothing there)" ;;
    401|403) msg "  without the token:  $code, refused. Fine, though a 404 wouldn't even show that something is there." ;;
    200) msg "  without the token:  200! The status can be read WITHOUT the token: check the proxy config."; bad=1 ;;
    000) msg "  without the token:  no answer" ;;
    *) msg "  without the token:  $code" ;;
  esac
  return "$bad"
}

verify() {
  local given=${STATUS_URL:-} tok=""
  load_env
  [ -n "$given" ] || status_url
  [ -n "${STATUS_URL:-}" ] || need STATUS_URL "Status URL to test" "like https://example.com/health/status.json"
  check STATUS_URL '^https?://[^[:space:]]+$' "a URL like https://example.com/health/status.json"
  if [ -n "${TOKEN:-}" ]; then tok=$TOKEN
  elif [ -n "${TOKEN_FILE:-}" ]; then
    [ -r "$TOKEN_FILE" ] || die "can't read TOKEN_FILE=$TOKEN_FILE"
    tok=$(read_token_file "$TOKEN_FILE")
  elif [ -r "$TOKEN_PATH" ]; then tok=$(read_token_file "$TOKEN_PATH")
  elif have_tty; then
    printf 'Token (not shown as you type or paste): ' > /dev/tty
    read -rs tok < /dev/tty || true
    echo > /dev/tty
    tok=$(printf '%s' "$tok" | tr -d ' \t\r\n')
  fi
  [ -n "$tok" ] || die "no token to test with: run this where it's saved (with sudo), give TOKEN_FILE=<a file holding it>, or run it in a terminal to paste it"
  if verify_url "$STATUS_URL" "$tok"; then msg "All good: the watch will get the status."
  else exit 1; fi
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
    have_tty && { detect_proxies; detect_caddy; msg ""; }
    ask_route
  fi
  [ -n "${TOKEN_SOURCE:-}" ] || { resolve_token; ask_existing_token; }
  local saved=yes old="" n=1
  case "$PROXY" in caddy|nginx) ;; *) load_proxies ;; esac
  case "${SAVE_TOKEN:-yes}" in
    [Nn]|[Nn][Oo]|0|false) saved=skip ;;
    *) save_token || saved=no ;;
  esac
  [ "$PROXY" = caddy ] && [ -r "$CADDYFILE" ] && [ -n "${DOMAIN:-}" ] && old=$(old_checks)
  if [ "$PROXY" = caddy ] && [ "$ROUTE" = check-only ] && [ -n "${DOMAIN:-}" ] && [ -n "$(handle_blocks)" ]; then
    msg "Warning: in the $DOMAIN part of $CADDYFILE, requests are passed on inside handle/route sections:"
    show_handles
    msg "A check-only block next to them would be skipped. Use ROUTE=proxy instead."
    msg ""
  fi
  if [ -n "${SNIPPET_OUT:-}" ]; then
    ( umask 077; snippet_text > "$SNIPPET_OUT" )
    [ "$PROXY" = caddy ] && caddy_readable "$SNIPPET_OUT"
    msg "Saved to $SNIPPET_OUT."
  else
    snippet_text
  fi
  msg ""
  if [ "$saved" = yes ]; then
    token_note
    [ "$IS_ROOT" = yes ] || msg "(SAVE_TOKEN=no skips keeping that copy in your home folder; --show and --verify read it.)"
  elif [ "$saved" = skip ]; then msg "Token not saved anywhere (SAVE_TOKEN=no): it's only in the lines above, so --show can't print it."
  elif [ "$TOKEN_SOURCE" = new ]; then msg "Couldn't save the new token in $TOKEN_PATH: it's only in the snippet."; fi
  msg ""
  msg "Next steps:"
  if [ "$PROXY" != caddy ]; then
    if [ "$PROXY" = nginx ] && [ -n "$(nginx_old_checks)" ]; then
      msg "  $n. Your nginx config already checks the Authorization header. Remove that check first:"
      nginx_old_checks | sed 's/^/   /' >&3
      n=$((n + 1))
    fi
    paste_steps "$n"
    if [ "$saved" = skip ]; then msg "  Then set up the watch with ${STATUS_URL:-the status URL} and the token in those lines."
    else msg "  Then test it from any machine with --verify, and set up the watch (--show prints the URL and token)."; fi
    [ -n "${STATUS_URL:-}" ] && { ( save_env ) 2>/dev/null || true; }
    return 0
  fi
  if [ -n "$old" ]; then
    msg "  $n. Your Caddy config already checks a token for $(dirname "$STATUS_PATH")/. Comment out or delete these"
    msg "     lines (error pages and headers can stay):"
    show_old_checks "$old" "       "
    n=$((n + 1))
  fi
  if [ -n "${SNIPPET_OUT:-}" ]; then
    msg "  $n. The new lines are in $SNIPPET_OUT. Add this line at the top level of the \"${DOMAIN:-your site} { ... }\""
    msg "     part of $CADDYFILE:   import $SNIPPET_OUT"
  else
    msg "  $n. Paste the new lines (above) at the top level of the \"${DOMAIN:-your site} { ... }\" part of $CADDYFILE."
  fi
  n=$((n + 1))
  msg "  $n. Check and reload:  caddy validate --config $CADDYFILE --adapter caddyfile && sudo systemctl reload caddy"
  n=$((n + 1))
  if [ "$saved" = skip ]; then
    msg "  $n. Set up the watch with ${STATUS_URL:-the status URL} and the token in the new lines."
  else
    msg "  $n. Test it from any machine: run this script again with --verify."
    n=$((n + 1))
    msg "  $n. Set up the watch: run this script again with --show to print the URL and token."
  fi
  [ -n "${STATUS_URL:-}" ] && { ( save_env ) 2>/dev/null || true; }
  true
}

install_all() {
  load_env
  ROLE=${ROLE:-}
  [ "$IS_ROOT" = yes ] || [ "$ROLE" = route ] || is_yes "${DRY_RUN:-}" || die "run as root (sudo), or use --route-only / --print-snippet"
  msg "Wrist Check server setup, version $VERSION"
  if is_yes "${UPGRADE:-}"; then
    [ -r "$ENV_FILE" ] && [ -n "$ROLE" ] || die "nothing to upgrade here (no settings in $ENV_FILE): run it without --upgrade"
    NONINTERACTIVE=yes
    msg "Upgrading with the settings in $ENV_FILE, no questions."
  fi
  msg ""
  detect_all
  if [ -z "$ROLE_FLAG" ] && { [ -z "$ROLE" ] || have_tty; }; then
    have_tty && msg "What should run here?
  all     everything on this machine (Kuma and the reverse proxy are both here)
  writer  only the part that reads Kuma (the watch connects through a proxy on another machine)
  route   only the token check in the reverse proxy (Kuma is on another machine)"
    ask ROLE "Answer (all / writer / route)" "$(have_tty && echo "${D_ROLE:-all}" || echo all)"
  fi
  check ROLE '^(all|writer|route)$' "all, writer or route"
  if [ "$ROLE" != writer ]; then
    ask_route
    if [ "$PROXY" = caddy ] && ! can_write_snippet && ! is_yes "${DRY_RUN:-}"; then
      die "can't write $CADDY_SNIPPET as $(id -un). Use sudo, or --print-snippet to add the lines by hand."
    fi
    ask_old_check
    if [ "${OLD_CHECK:-}" = print ]; then ACTION=print; ROUTE_ASKED=yes; print_snippet; exit 0; fi
  fi
  [ "$ROLE" = route ] || ask_writer
  if [ "$ROLE" != writer ]; then
    check_route
    resolve_token
    ask_existing_token
  fi
  confirm_plan
  save_env

  [ "$ROLE" = route ] || install_writer

  if [ "$ROLE" != writer ] && [ "$PROXY" != caddy ] && [ "$PROXY" != nginx ] && is_yes "${UPGRADE:-}"; then
    msg ""
    msg "The token check in $(proxy_name) was added by hand, so it stays as it is."
  elif [ "$ROLE" != writer ] && [ "$PROXY" != caddy ] && [ "$PROXY" != nginx ]; then
    # The script doesn't change this proxy itself: print its config and the steps to add it.
    msg ""
    ACTION=print; ROUTE_ASKED=yes; print_snippet
    exec 3>&1
  elif [ "$ROLE" != writer ]; then
    [ "$PROXY" = caddy ] && { command -v caddy >/dev/null || [ -n "$(caddy_bin)" ] || msg "Note: Caddy isn't installed here."; }
    save_token || die "couldn't save the token in $TOKEN_PATH"
    msg ""
    if [ "$PROXY" = nginx ]; then apply_route_nginx; else apply_route; fi
    msg ""
    token_note "readable by $(id -un) only"
    if ! is_yes "${SKIP_VERIFY:-}"; then
      msg ""
      verify_url "$STATUS_URL" "$TOKEN" || {
        msg "  That was tested from this machine. If the problem is that the writer isn't set up yet, or this"
        msg "  machine can't reach its own domain, test again later from anywhere: the same line with --verify."
      }
    fi
    is_yes "${UPGRADE:-}" || msg ""
    if [ "$SHOW" = yes ]; then show
    elif ! is_yes "${UPGRADE:-}"; then msg "Last step, set up the watch: run this script again with --show to print the URL and token."; fi
  fi
  if [ "$ROLE" != route ] && [ -n "$D_OTHER_TIMERS" ]; then
    msg ""
    msg "Once the watch shows the right status, turn off the older timer(s): systemctl disable --now $D_OTHER_TIMERS"
  fi
  [ "$ROLE" = writer ] && ! is_yes "${UPGRADE:-}" && next_route_steps
  is_yes "${UPGRADE:-}" && msg "" && msg "Upgrade done."
  true
}

rotate() {
  load_env
  [ -n "${STATUS_PATH:-}" ] || die "no token check set up here: run the installer (or --print-snippet) first"
  ROUTE=${ROUTE:-file}; [ "$ROUTE" = file ] && OUT=${OUT:-$DEFAULT_OUT}
  status_url
  resolve_token new
  if is_yes "${DRY_RUN:-}"; then
    msg "Would save a new token in $TOKEN_PATH$([ -f "$CADDY_SNIPPET" ] && echo ", rewrite $CADDY_SNIPPET and reload Caddy"). Dry run: nothing was changed."
    exit 0
  fi
  save_token || die "couldn't save the token in $TOKEN_PATH"
  if [ "${PROXY:-caddy}" = nginx ] && [ -f "$NGINX_SNIPPET" ]; then
    backup "$NGINX_SNIPPET"; SN_NEW=no
    ( umask 077; snippet_text > "$NGINX_SNIPPET" )
    local rc=0
    nginx_ok || { restore; die "nginx -t didn't accept the new snippet; it was put back."; }
    nginx_reload || rc=$?
    [ "$rc" = 1 ] && { restore; nginx_reload >/dev/null 2>&1 || true; die "reloading nginx failed; the old snippet was put back."; }
    [ "$rc" = 2 ] && msg "Reload nginx yourself to start using the new token."
    msg "New token is in place. Every watch must be set up again (--show prints it)."
  elif [ "${PROXY:-caddy}" = caddy ] && [ -f "$CADDY_SNIPPET" ]; then
    write_snippet
    local rc=0
    caddy_validate || { restore; die "Caddy didn't accept the new snippet; it was put back."; }
    reload_caddy || rc=$?
    [ "$rc" = 1 ] && { restore; reload_caddy >/dev/null 2>&1 || true; die "reloading Caddy failed; the old snippet was put back."; }
    [ "$rc" = 2 ] && msg "Reload Caddy yourself to start using the new token."
    msg "New token is in place. Every watch must be set up again (--show prints it)."
  else
    msg "New token saved in $TOKEN_PATH. Run --print-snippet and replace the old lines in your proxy, then set the watches up again (--show)."
  fi
  [ "$SHOW" = yes ] && show
  true
}

# Before the wrist-check user goes: the folder (OUT_ACCESS=chown) and the files the writer made in it
# go back to the folder's owner, so nothing is left owned by a user that no longer exists.
give_back() {
  local dir=$1 to
  id wrist-check >/dev/null 2>&1 || return 0
  if [ "${OUT_ACCESS:-}" = chown ] && [ -n "${OUT_OWNER:-}" ]; then to=$OUT_OWNER
  else to=$(stat -c %U:%G "$dir"); fi
  [ "${to%%:*}" = wrist-check ] && to="root:root"
  find "$dir" -maxdepth 1 -user wrist-check -exec chown "$to" {} + 2>/dev/null || true
  msg "Gave $dir and the writer's files in it back to $to."
}

uninstall() {
  load_env
  local role=${ROLE_FLAG:-all} todo=() dir
  dir=$(dirname "${OUT:-$DEFAULT_OUT}")
  if [ "$role" != route ] && { [ -f "$UNIT_DIR/wrist-check-status.timer" ] || [ -f "$WRITER_BIN" ]; }; then
    todo+=("the status writer: timer, $WRITER_BIN")
    [ "$dir" = "$DATA_DIR" ] && todo+=("$DATA_DIR")
    [ "${OUT_ACCESS:-}" = acl ] && todo+=("the ACL that lets ${WRITER_USER:-wrist-check} write to $dir")
    [ "${OUT_ACCESS:-}" = chown ] && [ -n "${OUT_OWNER:-}" ] && todo+=("$WRITER_USER's hold on $dir: it goes back to $OUT_OWNER")
    id wrist-check >/dev/null 2>&1 && todo+=("the user wrist-check")
  fi
  if [ "$role" != writer ]; then
    [ -f "$NGINX_SNIPPET" ] && todo+=("$NGINX_SNIPPET and the lines that include it")
    has_import && todo+=("'$IMPORT_LINE' from $CADDYFILE")
    [ -f "$CADDY_SNIPPET" ] && todo+=("$CADDY_SNIPPET")
    [ -f "$TOKEN_PATH" ] && todo+=("the token ($TOKEN_PATH)")
  fi
  [ "$role" = all ] && [ -d "$CONF_DIR" ] && todo+=("the settings ($CONF_DIR)")
  if [ "${#todo[@]}" = 0 ]; then msg "Nothing of Wrist Check's to remove here."; return 0; fi
  msg "This removes:"
  printf '  - %s\n' "${todo[@]}" >&3
  if is_yes "${DRY_RUN:-}"; then msg "Dry run: nothing was changed."; exit 0; fi

  if [ "$role" != route ] && { [ -f "$UNIT_DIR/wrist-check-status.timer" ] || [ -f "$WRITER_BIN" ]; }; then
    [ "$IS_ROOT" = yes ] || die "removing the status writer needs root (sudo)"
    systemctl disable --now wrist-check-status.timer 2>/dev/null || true
    rm -f "$UNIT_DIR/wrist-check-status.service" "$UNIT_DIR/wrist-check-status.timer" "$WRITER_BIN"
    systemctl daemon-reload 2>/dev/null || true
    [ "${OUT_ACCESS:-}" = acl ] && command -v setfacl >/dev/null && setfacl -x "u:${WRITER_USER:-wrist-check}" "$dir" 2>/dev/null || true
    if [ "$dir" = "$DATA_DIR" ]; then rm -rf "$DATA_DIR"
    else
      give_back "$dir"
      msg "Left $OUT in place (not this script's folder): delete it yourself if nothing serves it."
    fi
    id wrist-check >/dev/null 2>&1 && userdel wrist-check 2>/dev/null || true
    msg "Status writer removed."
  fi
  if [ "$role" != writer ]; then
    [ -f "$NGINX_SNIPPET" ] && uninstall_nginx
    if has_import; then
      [ -w "$CADDYFILE" ] || die "can't edit $CADDYFILE as $(id -un): use sudo"
      backup "$CADDYFILE"
      awk -v imp="$IMPORT_LINE" '{ l = $0; gsub(/^[ \t]+|[ \t]+$/, "", l) } l != imp' "$BK" > "$CADDYFILE"
      msg "Removed '$IMPORT_LINE' from $CADDYFILE (old version: $BK)."
    fi
    if [ -f "$CADDY_SNIPPET" ]; then
      rm -f "$CADDY_SNIPPET"
      local rc=0; reload_caddy || rc=$?
      [ "$rc" = 2 ] && msg "Reload Caddy yourself."
    fi
    rm -f "$TOKEN_PATH"
    msg "Token check removed. Lines you pasted in by hand (--print-snippet) stay: remove those yourself."
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
  [ -n "$USED_LOCAL_PROXIES" ] && rm -f "$USED_LOCAL_PROXIES"
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
      --dry-run) DRY_RUN=yes ;;
      --upgrade) UPGRADE=yes ;;
      --version) echo "Wrist Check install.sh $VERSION"; exit 0 ;;
      --verify) [ "$ACTION" = install ] || die "pick one of --print-snippet, --rotate, --uninstall, --verify"; ACTION=verify ;;
      --print-snippet) [ "$ACTION" = install ] || die "pick one of --print-snippet, --rotate, --uninstall"; ACTION=print ;;
      --rotate) [ "$ACTION" = install ] || die "pick one of --print-snippet, --rotate, --uninstall"; ACTION=rotate ;;
      --uninstall) [ "$ACTION" = install ] || die "pick one of --print-snippet, --rotate, --uninstall"; ACTION=uninstall ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option $a (see --help)" ;;
    esac
  done
  [ -n "$ROLE_FLAG" ] && ROLE=$ROLE_FLAG   # otherwise ROLE stays unset, so the saved one can load
  # "--show" on its own prints the URL and token once set up; on a fresh machine it installs and then shows.
  if [ "$ACTION" = install ] && [ "$SHOW" = yes ] && [ -z "$ROLE_FLAG" ] && [ $# -eq 1 ] && [ -r "$ENV_FILE" ]; then ACTION=show; fi
  case "$ACTION" in
    show) show ;;
    verify) verify ;;
    print) print_snippet ;;
    rotate) rotate ;;
    uninstall) uninstall ;;
    install) install_all ;;
  esac
  is_yes "${DRY_RUN:-}" || case "$ACTION" in install|uninstall|rotate) remove_self ;; esac
}

# Tests source this file with WRIST_CHECK_SOURCE_ONLY=yes to call single functions.
[ "${WRIST_CHECK_SOURCE_ONLY:-}" = yes ] || main "$@"
