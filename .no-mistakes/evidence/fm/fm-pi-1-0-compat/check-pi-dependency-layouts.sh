#!/usr/bin/env bash
set -eu
export FM_TEST_SKIP_ORPHAN_REAP=1
. tests/lib.sh
TMP_ROOT=$(fm_test_tmproot fm-pi-layout-validation)
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:?}
for layout in bundled hoisted; do
  install_root="$TMP_ROOT/$layout/install/node_modules"
  fixture="$TMP_ROOT/$layout/fixture"
  package="$install_root/@earendil-works/pi-coding-agent"
  mkdir -p "$package" "$fixture/node_modules/@earendil-works"
  printf '{"type":"module"}\n' > "$fixture/package.json"
  ln -s "$PI_PACKAGE_DIR" "$fixture/node_modules/@earendil-works/pi-coding-agent"
  for dep in @earendil-works/pi-tui @earendil-works/pi-ai typebox @types/node; do
    real_dep=$(fm_pi_dependency_dir "$dep" "$PI_PACKAGE_DIR")
    if [ "$layout" = bundled ]; then target="$package/node_modules/$dep"; else target="$install_root/$dep"; fi
    mkdir -p "$(dirname "$target")"
    ln -s "$real_dep" "$target"
    mkdir -p "$(dirname "$fixture/node_modules/$dep")"
    fm_pi_link_dependency "$dep" "$fixture/node_modules/$dep" "$package"
    resolved=$(fm_pi_dependency_dir "$dep" "$package")
    [ -d "$resolved" ] || fail "resolved $dep is not usable"
  done
  (cd "$fixture" && node --input-type=module <<'JS'
import {Input, SelectList} from '@earendil-works/pi-tui';
import {Type} from 'typebox';
import * as ai from '@earendil-works/pi-ai';
import {createAgentSession} from '@earendil-works/pi-coding-agent';
const input = new Input();
input.handleInput('search');
if (input.getValue() !== 'search') throw new Error('real TUI input could not consume text');
const schema=Type.Object({name:Type.String()});
if(schema.type!=='object'||schema.properties.name.type!=='string') throw new Error('real schema constructor failed');
if(typeof createAgentSession!=='function'||typeof SelectList!=='function'||Object.keys(ai).length===0) throw new Error('real dependency exports failed');
console.log(JSON.stringify({input:input.getValue(),schema,piAiExports:Object.keys(ai).length,agentSession:typeof createAgentSession}));
JS
  ) || fail "$layout dependencies did not execute"
  echo "resolved and executed real installed Pi dependencies using $layout layout"
done
mkdir -p "$TMP_ROOT/missing/@earendil-works/pi-coding-agent"
if (fm_pi_link_dependency absent-dependency "$TMP_ROOT/no-link" "$TMP_ROOT/missing/@earendil-works/pi-coding-agent") > "$TMP_ROOT/missing-result" 2>&1; then
  fail "missing dependency was accepted"
fi
[ ! -e "$TMP_ROOT/no-link" ] || fail "missing dependency created a misleading link"
cat "$TMP_ROOT/missing-result"
echo 'missing dependency refused before a fixture link was created'
