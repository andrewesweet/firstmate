#!/usr/bin/env bash
# Strict no-emit contract check for the tracked Firstmate Pi extensions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v npm >/dev/null 2>&1 || { echo "skip: Pi extension typecheck prerequisite not found: npm"; exit 0; }
command -v tsc >/dev/null 2>&1 || { echo "skip: Pi extension typecheck prerequisite not found: tsc"; exit 0; }

PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
  echo "skip: Pi extension typecheck prerequisite not found: installed @earendil-works/pi-coding-agent package"
  exit 0
fi
for dep in typebox @earendil-works/pi-tui @earendil-works/pi-ai @types/node; do
  fm_pi_dependency_dir "$dep" >/dev/null || {
    echo "not ok - installed Pi package is missing pi-tui, pi-ai, typebox, or Node declarations in both dependency layouts" >&2
    exit 1
  }
done

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-primary-types.XXXXXX")
cleanup() {
  rm -rf "$TMP_ROOT"
  fm_test_cleanup
}
trap cleanup EXIT

# Mirror the tracked repo layout so each module's relative imports resolve
# exactly as they do in production: the extensions under
# .pi/extensions/ with their lib/ beside them, and the shared eligibility
# module the dispatch lib imports at the repo-root lib/.
mkdir -p "$TMP_ROOT/.pi/extensions/lib" "$TMP_ROOT/lib" "$TMP_ROOT/node_modules/@earendil-works" "$TMP_ROOT/node_modules/@types"
cp "$ROOT/.pi/extensions/fm-branch-supervision.ts" "$TMP_ROOT/.pi/extensions/fm-branch-supervision.ts"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$TMP_ROOT/.pi/extensions/fm-calm.ts"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$TMP_ROOT/.pi/extensions/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$TMP_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$TMP_ROOT/.pi/extensions/lib/fm-async-exec.ts"
cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$TMP_ROOT/.pi/extensions/lib/fm-branch-dispatch.ts"
cp "$ROOT/.pi/extensions/lib/fm-branch-model-picker.ts" "$TMP_ROOT/.pi/extensions/lib/fm-branch-model-picker.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts" "$TMP_ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts" "$TMP_ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-pending-operational-layout.ts" "$TMP_ROOT/.pi/extensions/lib/fm-calm-pending-operational-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-preservation.ts" "$TMP_ROOT/.pi/extensions/lib/fm-calm-preservation.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$TMP_ROOT/.pi/extensions/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$TMP_ROOT/.pi/extensions/lib/fm-calm-working-ship.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship-sprite.ts" "$TMP_ROOT/.pi/extensions/lib/fm-calm-working-ship-sprite.ts"
cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$TMP_ROOT/.pi/extensions/lib/fm-native-contract.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$TMP_ROOT/.pi/extensions/lib/fm-operational-input.ts"
cp "$ROOT/lib/fm-branch-classifier.ts" "$TMP_ROOT/lib/fm-branch-classifier.ts"
cp "$ROOT/lib/fm-branch-eligibility.ts" "$TMP_ROOT/lib/fm-branch-eligibility.ts"
cp "$ROOT/lib/fm-branch-eligibility-core.ts" "$TMP_ROOT/lib/fm-branch-eligibility-core.ts"
cp "$ROOT/lib/fm-branch-shadow.ts" "$TMP_ROOT/lib/fm-branch-shadow.ts"
cp "$ROOT/lib/fm-branch-report-sequence.ts" "$TMP_ROOT/lib/fm-branch-report-sequence.ts"
cp "$ROOT/lib/fm-branch-provider-latch.ts" "$TMP_ROOT/lib/fm-branch-provider-latch.ts"
ln -s "$PI_PACKAGE_DIR" "$TMP_ROOT/node_modules/@earendil-works/pi-coding-agent"
fm_pi_link_dependency @earendil-works/pi-tui "$TMP_ROOT/node_modules/@earendil-works/pi-tui"
fm_pi_link_dependency @earendil-works/pi-ai "$TMP_ROOT/node_modules/@earendil-works/pi-ai"
fm_pi_link_dependency typebox "$TMP_ROOT/node_modules/typebox"
fm_pi_link_dependency @types/node "$TMP_ROOT/node_modules/@types/node"

cat > "$TMP_ROOT/package.json" <<'JSON'
{"type":"module"}
JSON
cat > "$TMP_ROOT/tsconfig.json" <<'JSON'
{
  "compilerOptions": {
    "allowImportingTsExtensions": true,
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "noEmit": true,
    "skipLibCheck": true,
    "strict": true,
    "target": "ES2022",
    "types": ["node"]
  },
  "include": [".pi/**/*.ts", "lib/*.ts"]
}
JSON

tsc -p "$TMP_ROOT/tsconfig.json" || exit 1
version=$(jq -r '.version' "$PI_PACKAGE_DIR/package.json" 2>/dev/null || printf 'unknown')
printf 'ok - tracked Pi extensions pass strict no-emit typecheck against Pi %s\n' "$version"
