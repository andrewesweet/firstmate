#!/usr/bin/env bash
# Portable checks for the Claude Code supervision-branch mod
# (.claude/mods/fm-branch-mod, docs/claude-supervision-branch.md) that need no
# Claude Code binary, so CI enforces them wherever Node runs:
#   - the plugin's declared shape: one hooks module plus the one agent it
#     spawns, reached only through --plugin-dir, never through the project's
#     .claude/skills auto-load path, so nothing of it can load into a home that
#     did not launch with it;
#   - the generated agent definition is current with its generator
#     (bin/fm-branch-agent-md.sh) and carries the name and tools the module
#     spawns it with.
# The engine-bound behaviour runs under tests/fm-branch-claude-mod-plugin.test.sh
# and the real session under tests/fm-branch-claude-mod-live-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MOD="$ROOT/.claude/mods/fm-branch-mod"
GENERATOR="$ROOT/bin/fm-branch-agent-md.sh"
SYNC_GENERATOR="$ROOT/bin/fm-branch-shared-sync.sh"
TMP_ROOT=$(fm_test_tmproot fm-branch-claude-mod)

command -v node >/dev/null 2>&1 || { echo "skip: node not found for the Claude Code supervision-branch mod checks"; exit 0; }

test_plugin_shape() {
  local out
  [ ! -e "$ROOT/.agents/skills/fm-branch-mod" ] \
    || fail "the mod is linked into .agents/skills, so every Claude home would adopt its agent and hooks without launching with --plugin-dir"
  [ ! -e "$ROOT/.claude/skills/fm-branch-mod" ] \
    || fail "the mod is reachable from the project's .claude/skills auto-load path"
  [ ! -e "$MOD/SKILL.md" ] || fail "the mod carries a SKILL.md and would load as a skill on every harness"
  cat >"$TMP_ROOT/shape.mjs" <<JS
import { readFileSync, readdirSync, existsSync } from "node:fs";
const mod = ${MOD@Q};
const manifest = JSON.parse(readFileSync(\`\${mod}/.claude-plugin/plugin.json\`, "utf8"));
if (manifest.name !== "fm-branch-mod") throw new Error(\`manifest name \${manifest.name}\`);
for (const key of ["commands", "agents", "skills", "hooks", "mcpServers", "lspServers", "outputStyles"]) {
  if (key in manifest) throw new Error(\`manifest declares \${key}: only the default hooks/ and agents/ folders may load\`);
}
const hooks = JSON.parse(readFileSync(\`\${mod}/hooks/hooks.json\`, "utf8"));
const keys = Object.keys(hooks).sort();
if (JSON.stringify(keys) !== JSON.stringify(["description", "modules"])) {
  throw new Error(\`hooks.json declares \${keys.join(", ")}: a classic hook would run while the flag is off\`);
}
if (JSON.stringify(hooks.modules) !== JSON.stringify(["./branch.ts"])) throw new Error("hooks.json names a different module");
if (!existsSync(\`\${mod}/hooks/branch.ts\`)) throw new Error("the hooks module is missing");
const agents = readdirSync(\`\${mod}/agents\`).sort();
if (JSON.stringify(agents) !== JSON.stringify(["fm-branch.md"])) throw new Error(\`agents/ holds \${agents.join(", ")}: only the one branch agent may exist\`);
const entries = readdirSync(mod).filter((name) => name !== ".claude-plugin").sort();
if (JSON.stringify(entries) !== JSON.stringify(["agents", "classifier-system.txt", "hooks", "lib", "tests"])) {
  throw new Error(\`the mod folder holds \${entries.join(", ")}: only agents, classifier-system.txt, hooks, lib, and tests may exist\`);
}
console.log("shape-ok");
JS
  out=$(node --input-type=module <"$TMP_ROOT/shape.mjs" 2>&1) || fail "plugin shape: $out"
  assert_contains "$out" "shape-ok" "plugin shape check did not complete"
  pass "the mod is one hooks module and one agent, reached only through --plugin-dir, with no command, skill, or classic hook path"
}

test_agent_definition_is_generated_and_current() {
  local out frontmatter
  out=$("$GENERATOR" --check 2>&1) || fail "the tracked agent definition is stale against its generator: $out"
  frontmatter=$(awk 'NR == 1 && $0 != "---" { exit 1 } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$MOD/agents/fm-branch.md") \
    || fail "agents/fm-branch.md does not open with a frontmatter block"
  printf '%s\n' "$frontmatter" | grep -qx 'name: fm-branch' \
    || fail "the agent is not named fm-branch, which the module spawns as fm-branch-mod:fm-branch: $frontmatter"
  printf '%s\n' "$frontmatter" | grep -q '^tools: .*\bBash\b' \
    || fail "the branch agent cannot run the fleet scripts without Bash: $frontmatter"
  printf '%s\n' "$frontmatter" | grep -q '^tools: .*mcp__fm-branch-mod__fm_branch_report' \
    || fail "the branch agent cannot report an outcome without the module's fm_branch_report tool: $frontmatter"
  out=$("$GENERATOR" --print) || fail "the generator cannot print the definition"
  [ "$out" = "$(cat "$MOD/agents/fm-branch.md")" ] || fail "--print differs from the tracked definition"
  "$GENERATOR" --bogus >/dev/null 2>&1 && fail "an unknown generator argument was accepted"
  pass "agents/fm-branch.md is current with bin/fm-branch-agent-md.sh and names the agent and tools the module spawns"
}

test_vendored_eligibility_module_is_generated_and_current() {
  local out
  out=$("$SYNC_GENERATOR" --check 2>&1) || fail "the vendored eligibility module is stale against lib/fm-branch-eligibility.ts: $out"
  out=$("$SYNC_GENERATOR" --print) || fail "the generator cannot print the vendored module"
  [ "$out" = "$(cat "$MOD/lib/fm-branch-eligibility.ts")" ] || fail "--print differs from the tracked vendored module"
  "$SYNC_GENERATOR" --bogus >/dev/null 2>&1 && fail "an unknown generator argument was accepted"
  grep -q 'GENERATED FILE - DO NOT EDIT BY HAND' "$MOD/lib/fm-branch-eligibility.ts" \
    || fail "the vendored module does not announce itself as generated"
  if grep -q 'from "node:fs"' "$MOD/lib/fm-branch-eligibility.ts"; then
    fail "the vendored module imports node:fs, which the hooks-module validator refuses"
  fi
  pass "the vendored eligibility module is current with bin/fm-branch-shared-sync.sh and free of node:fs"
}

test_vendored_a4_modules_are_generated_and_current() {
  local out module source tracked
  for module in fm-branch-report-sequence.ts fm-branch-provider-latch.ts fm-branch-classifier.ts fm-branch-shadow.ts; do
    source="$ROOT/lib/$module"
    tracked="$MOD/lib/$module"
    [ -f "$source" ] || fail "the shared A4 module is missing: $source"
    [ -f "$tracked" ] || fail "the vendored A4 module is missing: $tracked"
    out=$("$SYNC_GENERATOR" --print "$module") || fail "the generator cannot print $module"
    [ "$out" = "$(cat "$tracked")" ] || fail "--print $module differs from the tracked vendored copy"
    grep -q 'GENERATED FILE - DO NOT EDIT BY HAND' "$tracked" \
      || fail "$tracked does not announce itself as generated"
    if grep -q 'from "node:' "$tracked"; then
      fail "$tracked imports node:, which the hooks-module validator refuses"
    fi
    # The vendored copy is the shared source verbatim under its generated
    # header: strip everything through the header's Regenerate line and
    # compare to the source byte for byte.
    if [ "$(awk 'f{print} /^\/\/ Regenerate with/{f=1}' "$tracked")" != "$(cat "$source")" ]; then
      fail "$tracked is not the source verbatim under its generated header"
    fi
  done
  pass "the vendored report-sequence, provider-latch, classifier, and shadow modules are current with bin/fm-branch-shared-sync.sh"
}

test_plugin_shape
test_agent_definition_is_generated_and_current
test_vendored_eligibility_module_is_generated_and_current
test_vendored_a4_modules_are_generated_and_current
