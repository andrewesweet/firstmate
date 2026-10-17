#!/usr/bin/env bash
# fm-install-pi.sh - install CI's pinned, reproducible Pi package set.
#
# The Pi extension tests import the installed Pi package's runtime and types,
# so they need the real thing. Pinning only @earendil-works/pi-coding-agent is
# not reproducible: Pi 1.0.4 declares its @earendil-works/* siblings as ^1.0.4
# ranges, and a fresh resolve floats them to releases Pi 1.0.4 cannot import.
# Observed October 2026: the float resolved @earendil-works/pi-codemode to
# 1.3.0, which removed the MCP_TYPESCRIPT_PREAMBLE export Pi 1.0.4's
# dist/extensions/codemode/tool.js statically imports, so every import of the
# Pi package failed with "does not provide an export named
# 'MCP_TYPESCRIPT_PREAMBLE'" and every pull request broke in the portable
# serial Pi extension shards. This helper installs from the committed
# etc/ci-pi manifest (exact Pi pin plus exact overrides for every
# @earendil-works/* transitive) with its lockfile, so the installed closure is
# bit-identical on every run. The post-install proof replays the exact import
# that broke, so a future incompatible float fails here with the package set
# named instead of surfacing as a mysterious extension-test failure.
#
# Usage:
#   fm-install-pi.sh <destination-directory>
#
# The destination must not be the global npm root: the host's global install
# is shared state this helper never touches. CI installs into $RUNNER_TEMP/pi,
# then adds <dest>/node_modules/.bin to PATH and exports
# FM_PI_PACKAGE_DIR=<dest>/node_modules/@earendil-works/pi-coding-agent for
# the test steps (the extension tests honor FM_PI_PACKAGE_DIR and fall back to
# the global root only when it is unset).
#
# Regenerating the pin: edit etc/ci-pi/package.json (exact versions only),
# delete etc/ci-pi/package-lock.json, run
# `npm install --package-lock-only --no-audit --no-fund` in etc/ci-pi, verify
# every @earendil-works/* entry in the lockfile carries the intended version,
# and run this helper plus the two Pi extension tests against the result
# before committing.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST_DIR="$ROOT/etc/ci-pi"

PI_VERSION=1.2.0
# Every @earendil-works/* package in Pi's dependency closure. The manifest
# overrides pin these; this list re-verifies the installed tree matches.
PI_SCOPE_PACKAGES="pi-agent-core pi-ai pi-codemode pi-coding-agent pi-mcp pi-telemetry pi-tui"

die() {
  printf 'fm-install-pi.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-pi.sh <destination-directory>}

command -v npm >/dev/null 2>&1 || die "npm is required to install the pinned Pi package set"
command -v node >/dev/null 2>&1 || die "node is required to verify the pinned Pi package set"
[ -f "$MANIFEST_DIR/package.json" ] || die "pin manifest not found: $MANIFEST_DIR/package.json"
[ -f "$MANIFEST_DIR/package-lock.json" ] || die "pin lockfile not found: $MANIFEST_DIR/package-lock.json"

GLOBAL_ROOT=$(npm root -g 2>/dev/null) || die "cannot resolve the global npm root"
mkdir -p "$DESTINATION" || die "cannot create destination directory: $DESTINATION"
DEST_ABS=$(cd "$DESTINATION" && pwd -P) || die "cannot resolve destination directory: $DESTINATION"
[ "$DEST_ABS" != "$GLOBAL_ROOT" ] || die "refusing to install into the global npm root ($GLOBAL_ROOT)"

cp "$MANIFEST_DIR/package.json" "$MANIFEST_DIR/package-lock.json" "$DEST_ABS/" \
  || die "cannot stage the pin manifest in $DEST_ABS"
npm ci --prefix "$DEST_ABS" --no-audit --no-fund || die "npm ci of the pinned Pi package set failed"

PKG_DIR="$DEST_ABS/node_modules/@earendil-works/pi-coding-agent"
[ -f "$PKG_DIR/package.json" ] || die "pinned install is missing the Pi package: $PKG_DIR"
[ -x "$DEST_ABS/node_modules/.bin/pi" ] || die "pinned install provides no pi binary: $DEST_ABS/node_modules/.bin/pi"

INSTALLED_VERSION=$("$DEST_ABS/node_modules/.bin/pi" --version 2>/dev/null | head -n 3) \
  || die "installed pi binary does not run"
case "$INSTALLED_VERSION" in
  *"$PI_VERSION"*) ;;
  *) die "installed pi reports [$INSTALLED_VERSION], expected $PI_VERSION" ;;
esac

# Replay the exact import whose failure broke CI: Pi 1.0.4 statically imports
# MCP_TYPESCRIPT_PREAMBLE from its pi-codemode sibling, so a float that drops
# that export fails here with the package set named.
node --input-type=module -e "await import('file://$PKG_DIR/dist/index.js')" \
  || die "installed Pi package fails to import (incompatible dependency float)"

# The overrides must have held across the whole scope, not just the top level.
mismatch=""
for scope_pkg in $PI_SCOPE_PACKAGES; do
  installed=$(node -p "require('$DEST_ABS/node_modules/@earendil-works/$scope_pkg/package.json').version" 2>/dev/null) \
    || die "pinned install is missing @earendil-works/$scope_pkg"
  if [ "$installed" != "$PI_VERSION" ]; then
    mismatch="${mismatch}@earendil-works/${scope_pkg}=${installed} "
  fi
done
[ -z "$mismatch" ] || die "pinned install floated off $PI_VERSION: $mismatch"

printf 'fm-install-pi.sh: installed pi %s with all %s scope packages at %s\n' \
  "$PI_VERSION" "$(printf '%s' "$PI_SCOPE_PACKAGES" | wc -w | tr -d ' ')" "$PI_VERSION"
printf 'fm-install-pi.sh: add to PATH: %s/node_modules/.bin\n' "$DEST_ABS"
printf 'fm-install-pi.sh: FM_PI_PACKAGE_DIR=%s\n' "$PKG_DIR"
