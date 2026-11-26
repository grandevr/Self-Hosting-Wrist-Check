#!/usr/bin/env bash
# Builds the files for a GitHub release: release.sh TAG OUTDIR
# install.sh gets the tag as its version, downloads from that release's assets, and carries the
# checksums of the two files it may download, so it refuses anything else.
set -euo pipefail
tag=$1 out=$2
[[ "$tag" =~ ^v[0-9A-Za-z.-]+$ ]] || { echo "tag must look like v1.2.3" >&2; exit 1; }
src=$(cd "$(dirname "$0")/.." && pwd)
base="https://github.com/grandevr/Self-Hosting-Wrist-Check/releases/download/$tag"
mkdir -p "$out"
cp "$src/kuma-status.py" "$src/proxies.sh" "$out/"
w=$(sha256sum "$out/kuma-status.py" | cut -d' ' -f1)
p=$(sha256sum "$out/proxies.sh" | cut -d' ' -f1)
sed -e "s|^REPO_RAW=.*|REPO_RAW=\"$base\"|" \
    -e "s|^VERSION=main\$|VERSION=$tag|" \
    -e "s|^WRITER_SHA256=\"\"\$|WRITER_SHA256=\"$w\"|" \
    -e "s|^PROXIES_SHA256=\"\"\$|PROXIES_SHA256=\"$p\"|" \
    -e "s|https://raw.githubusercontent.com/grandevr/Self-Hosting-Wrist-Check/main/server|$base|g" \
    "$src/install.sh" > "$out/install.sh"
# Every replacement must have happened.
grep -qx "REPO_RAW=\"$base\"" "$out/install.sh"
grep -qx "VERSION=$tag" "$out/install.sh"
grep -qx "WRITER_SHA256=\"$w\"" "$out/install.sh"
grep -qx "PROXIES_SHA256=\"$p\"" "$out/install.sh"
! grep -q "Wrist-Check/main/" "$out/install.sh"
(cd "$out" && sha256sum install.sh kuma-status.py proxies.sh > SHA256SUMS)
echo "Built $tag in $out:"
cat "$out/SHA256SUMS"
