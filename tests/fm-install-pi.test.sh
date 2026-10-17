#!/usr/bin/env bash
# The installer promises never to touch shared global npm state. Exercise its
# executable with a real, disposable npm prefix; an accepted destination or
# any changed package/manifest rejects that contract, without mocking npm ci.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v npm >/dev/null 2>&1 || { printf 'SKIP: npm is required\n'; exit 0; }
command -v node >/dev/null 2>&1 || { printf 'SKIP: node is required\n'; exit 0; }

tmp=$(fm_test_tmproot fm-install-pi)
export npm_config_prefix="$tmp/global" npm_config_cache="$tmp/npm-cache"
export npm_config_userconfig="$tmp/npm-user.conf" npm_config_globalconfig="$tmp/npm-global.conf"
export PI_CODING_AGENT_DIR="$tmp/pi-config"
global_root=$(npm root -g)
case "$global_root" in
  "$tmp"/*) ;;
  *) fail "npm did not use the disposable global prefix: $global_root" ;;
esac

sentinel="$global_root/pre-existing-global-package/package.json"
mkdir -p "$(dirname "$sentinel")"
printf '{"name":"pre-existing-global-package","version":"1.0.0"}\n' > "$tmp/expected-package.json"
cp "$tmp/expected-package.json" "$sentinel"
printf '{"name":"pre-existing-manifest","version":"1.0.0"}\n' > "$tmp/expected-manifest.json"
ln -s "$tmp/global" "$tmp/global-link"

for npm_config_prefix in "$tmp/global" "$tmp/global-link"; do
  for destination in "$(dirname "$global_root")" "$global_root"; do
    cp "$tmp/expected-manifest.json" "$destination/package.json"
    cp "$tmp/expected-manifest.json" "$destination/package-lock.json"
    rc=0
    bash "$ROOT/bin/fm-install-pi.sh" "$destination" > "$tmp/install.log" 2>&1 || rc=$?
    if ! cmp -s "$tmp/expected-package.json" "$sentinel"; then
      cat "$tmp/install.log"
      fail "installer changed a pre-existing global package: $destination (exit=$rc)"
    fi
    if [ "$rc" -eq 0 ]; then
      cat "$tmp/install.log"
      fail "installer accepted a destination in the global npm tree: $destination"
    fi
    assert_contains "$(cat "$tmp/install.log")" "refusing to install into the global npm root" \
      "installer must reject the global destination before npm ci"
    cmp -s "$tmp/expected-manifest.json" "$destination/package.json" \
      || fail "installer staged package.json before refusing: $destination"
    cmp -s "$tmp/expected-manifest.json" "$destination/package-lock.json" \
      || fail "installer staged package-lock.json before refusing: $destination"
    pass "installer refuses $destination without changing global packages or manifests (prefix=$npm_config_prefix)"
  done
done
