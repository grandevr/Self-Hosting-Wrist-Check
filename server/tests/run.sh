#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2015  # variables are read by the sourced install.sh
# Tests for install.sh's config reading and for the lines it writes. No root, Caddy or nginx needed:
# install.sh is sourced (WRIST_CHECK_SOURCE_ONLY=yes) and single functions run on the sample configs
# in tests/fixtures. Run from anywhere: bash server/tests/run.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
FIX=$HERE/fixtures
FAILED=0 PASSED=0

# shellcheck source=../install.sh
WRIST_CHECK_SOURCE_ONLY=yes . "$HERE/../install.sh"
set +e   # install.sh turns on -e; a failing check here should be reported, not end the run
# shellcheck source=../proxies.sh
. "$HERE/../proxies.sh"
exec 3>/dev/null   # install.sh's messages

ok() { PASSED=$((PASSED + 1)); }
fail() { FAILED=$((FAILED + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /'; }
has() { # has NAME TEXT PATTERN: TEXT has a line matching the regex PATTERN
  if grep -qE -- "$3" <<< "$2"; then ok; else fail "$1: no line matches /$3/" "$2"; fi
}
hasnt() {
  if grep -qE -- "$3" <<< "$2"; then fail "$1: a line matches /$3/" "$2"; else ok; fi
}
same() { if [ "$2" = "$3" ]; then ok; else fail "$1: expected '$3', got '$2'"; fi; }

use_caddy() { # use_caddy FIXTURE: point install.sh at that sample Caddyfile
  CADDYFILE=$FIX/$1/Caddyfile
  CADDY_SNIPPET=$FIX/$1/wrist-check.caddy
  DOMAIN=example.com STATUS_PATH=/health/status.json
}

# --- Caddy: the token check is in an imported file ------------------------------------------------
use_caddy caddy-import
out=$(old_checks)
has  "import: finds the matcher in the imported file" "$out" "health-token\.caddy${US}2${US}5${US}matcher @notoken"
has  "import: finds the respond line that uses it"     "$out" "health-token\.caddy${US}6${US}6${US}respond @notoken 404"
hasnt "import: leaves the header line alone"          "$out" "header"
same "import: only the example.com site is read" "$(site_block | grep -c 'not this site')" "0"
same "import: no handle sections" "$(handle_blocks)" ""

# --- Caddy: handle_errors that matches /health/* is an error page, not a token check ----------------
use_caddy caddy-errors
same "errors: handle_errors and headers aren't old checks" "$(old_checks)" ""
same "errors: no handle sections" "$(handle_blocks)" ""

# --- Caddy: the check is inlined in a handle section that proxies -----------------------------------
use_caddy caddy-inline
out=$(old_checks)
has  "inline: the handle /health/* section is an old check" "$out" "${US}2${US}6${US}handle /health/\* section"
same "inline: one old check (the section, not its lines again)" "$(grep -c . <<< "$out")" "1"
out=$(handle_blocks)
has  "inline: the catch-all handle is listed" "$out" "${US}7${US}handle \{"
hasnt "inline: the old check isn't listed as a handle" "$out" "/health"

# --- Caddy: an http:// site address -----------------------------------------------------------------
use_caddy caddy-http
has  "http: the site is found" "$(site_block)" "http://example\.com \{"
out=$(old_checks)
has  "http: finds the matcher" "$out" "matcher @nobearer"
has  "http: finds the error line" "$out" "error @nobearer 404"
old_folder_wide && ok || fail "http: the old check covered the whole folder"

# --- nginx ------------------------------------------------------------------------------------------
NGINX_DIR=$FIX/nginx NGINX_SNIPPET=$FIX/nginx/wrist-check.conf DOMAIN=example.com
same "nginx: the site file" "$(nginx_sites)" "$FIX/nginx/sites-enabled/example"
same "nginx: the domain (not _)" "$(nginx_domain)" "example.com"
has  "nginx: the old Authorization check" "$(nginx_old_checks)" "example, line 5:"
D_ROUTE="" D_UPSTREAM=""; detect_route_nginx
same "nginx: it passes requests on" "$D_ROUTE" "check-only"
same "nginx: to" "$D_UPSTREAM" "http://10.0.0.7:8080"

# --- The lines the script writes --------------------------------------------------------------------
TOKEN=test-token-0123456789abcdef OUT=/var/lib/wrist-check/status.json UPSTREAM=10.0.0.7:8080
DOMAIN=example.com STATUS_PATH=/health/status.json
for PROXY in caddy nginx npm traefik apache haproxy other; do
  for ROUTE in $(modes_for "$PROXY"); do
    for PROTECT in file folder; do
      out=$(snippet_text)
      has "$PROXY/$ROUTE/$PROTECT: has the token" "$out" "Bearer $TOKEN"
      [ "$PROXY" = other ] && continue
      [ "$PROTECT" = folder ] && has "$PROXY/$ROUTE/$PROTECT: covers the folder" "$out" "/health/"
      [ "$ROUTE" = proxy ] && has "$PROXY/$ROUTE/$PROTECT: passes on to the upstream" "$out" "10\.0\.0\.7:8080"
      [ "$ROUTE" = file ] && has "$PROXY/$ROUTE/$PROTECT: serves the file" "$out" "/var/lib/wrist-check"
    done
    [ "$PROXY" = caddy ] && continue   # Caddy's steps are part of print_snippet
    steps=$(exec 3>&1; paste_steps 1)
    has "$PROXY/$ROUTE: paste-in steps" "$steps" "^  1\. "
  done
done 2>/dev/null
PROXY=caddy ROUTE=check-only PROTECT=file
has "caddy: answers 404 without the token" "$(snippet_text)" "404"

# --- Settings file ----------------------------------------------------------------------------------
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
(
  CONF_DIR=$T ENV_FILE=$T/env
  ROLE=route PROXY=caddy DOMAIN=example.com STATUS_PATH=/health/status.json OLD_CHECK=disable
  save_env
  unset ROLE OLD_CHECK; DOMAIN=from-env.example
  load_env
  same "settings: ROLE is read back" "$ROLE" "route"
  same "settings: the environment wins" "$DOMAIN" "from-env.example"
  same "settings: OLD_CHECK=disable isn't kept" "${OLD_CHECK:-}" ""
  echo "$PASSED $FAILED" > "$T/counts"
)
read -r PASSED FAILED < "$T/counts"

echo "$PASSED passed, $FAILED failed"
[ "$FAILED" = 0 ]
