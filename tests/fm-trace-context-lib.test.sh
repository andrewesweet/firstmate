#!/usr/bin/env bash
# tests/fm-trace-context-lib.test.sh - unit tests for the native, default-off
# W3C trace-context library (bin/fm-trace-context-lib.sh) plus structural checks
# that bin/fm-spawn.sh wires it in at the pre-launch injection seam and that the
# capability is inherited into secondmate homes. Pure functions, no backend and
# no live spawn required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"

VALID='00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'

# --- strict W3C validation ---------------------------------------------------

fm_trace_context_valid "$VALID" || fail "a conformant traceparent must validate"
pass "fm_trace_context_valid accepts a conformant W3C traceparent"

for bad in \
  '00-00000000000000000000000000000000-00f067aa0ba902b7-01' \
  '00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01' \
  'ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' \
  '00-4BF92F3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' \
  '00-4bf92f3577b34da6a3ce929d0e0e473-00f067aa0ba902b7-01' \
  '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7' \
  '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01; rm -rf /' \
  '' ; do
  if fm_trace_context_valid "$bad"; then
    fail "invalid traceparent wrongly accepted: '$bad'"
  fi
done
pass "fm_trace_context_valid rejects all-zero ids, ff version, uppercase, wrong length, missing field, shell metacharacters, and empty"

# A value shaped like a command substitution must be rejected as inert data and
# never executed. Assemble it so the test itself never runs it.
dollar='$'
fm_trace_context_valid "${dollar}(touch pwned-$$)" && fail "command-substitution-shaped value wrongly accepted"
[ ! -e "pwned-$$" ] || fail "validation must never execute an injected value"
pass "a command-substitution-shaped value is rejected as inert data, never executed"

# --- entropy source: exact length, hex-only, fresh each call -----------------

t=$(fm_trace_context_hex 16)
[ "${#t}" -eq 32 ] || fail "16-byte hex must be 32 chars, got ${#t}"
case "$t" in *[!0-9a-f]*) fail "trace hex is not lowercase hex: $t" ;; esac
s=$(fm_trace_context_hex 8)
[ "${#s}" -eq 16 ] || fail "8-byte hex must be 16 chars, got ${#s}"
[ "$(fm_trace_context_hex 8)" != "$(fm_trace_context_hex 8)" ] || fail "hex must be fresh per call"
pass "fm_trace_context_hex yields exact-length lowercase hex, distinct per call"

# --- root mint ---------------------------------------------------------------

ROOT_TP=$(fm_trace_context_mint)
fm_trace_context_valid "$ROOT_TP" || fail "root mint must be a valid traceparent: $ROOT_TP"
[ "${ROOT_TP:53:2}" = "01" ] || fail "root mint must default to sampled flags 01: $ROOT_TP"
[ "${ROOT_TP:3:32}" != "00000000000000000000000000000000" ] || fail "root trace id must be non-zero"
pass "fm_trace_context_mint starts a valid sampled root trace"

# --- every mint roots a distinct trace: no parent-adoption path exists --------
# The trace boundary is each task, so consecutive mints from one process must
# never share a trace id; there is no argument or environment input through
# which a caller could chain them.

SECOND_TP=$(fm_trace_context_mint)
fm_trace_context_valid "$SECOND_TP" || fail "second mint must be a valid traceparent: $SECOND_TP"
[ "${SECOND_TP:3:32}" != "${ROOT_TP:3:32}" ] || fail "every mint must root a distinct trace id"
[ "${SECOND_TP:36:16}" != "${ROOT_TP:36:16}" ] || fail "every mint must carry a distinct span id"
pass "every mint is an unrelated fresh root - one trace per task, no parent adoption"

# --- minted-root shape --------------------------------------------------------
# A firstmate-MINTED root is exactly the fixed 55-char W3C form with random ids
# and no free-form field where firstmate could originate a prompt, path, or
# secret (that the lib reads no task prose is asserted separately below). With
# no inherited-context path, every carrier the lib yields is either such a mint
# or the same task's previously recorded carrier reused verbatim.
case "$ROOT_TP" in
  *[!0-9a-f-]*) fail "a minted traceparent must contain only hex and hyphens: $ROOT_TP" ;;
esac
[ "${#ROOT_TP}" -eq 55 ] || fail "a minted traceparent is exactly 55 chars, got ${#ROOT_TP}"
pass "a minted root is the fixed 55-char W3C form (hex and hyphens only), so firstmate originates no free-form content in the carrier"

# --- enablement precedence ---------------------------------------------------

WORK=$(fm_test_tmproot fm-trace-context)
CFG_ON="$WORK/cfg-on"; CFG_OFF="$WORK/cfg-off"
mkdir -p "$CFG_ON" "$CFG_OFF"
: > "$CFG_ON/trace-context"

unset FM_TRACE_CONTEXT
fm_trace_context_enabled "$CFG_OFF" && fail "absent config/trace-context must be off by default"
fm_trace_context_enabled "$CFG_ON" || fail "present config/trace-context must enable"
FM_TRACE_CONTEXT=off fm_trace_context_enabled "$CFG_ON" && fail "FM_TRACE_CONTEXT=off must override a present file"
FM_TRACE_CONTEXT=on fm_trace_context_enabled "$CFG_OFF" || fail "FM_TRACE_CONTEXT=on must override an absent file"
FM_TRACE_CONTEXT=1 fm_trace_context_enabled "$CFG_OFF" || fail "FM_TRACE_CONTEXT=1 must enable"
FM_TRACE_CONTEXT=maybe fm_trace_context_enabled "$CFG_ON" && fail "a non-truthy FM_TRACE_CONTEXT must disable"
FM_TRACE_CONTEXT='' fm_trace_context_enabled "$CFG_ON" || fail "empty FM_TRACE_CONTEXT must defer to a present file (enabled)"
FM_TRACE_CONTEXT='' fm_trace_context_enabled "$CFG_OFF" && fail "empty FM_TRACE_CONTEXT must defer to an absent file (disabled)"
pass "enablement is default-off; FM_TRACE_CONTEXT overrides with truthy/other precedence, and unset or empty defers to config/trace-context"

SESSION_DIR="$WORK/session-state"
SESSION_STATE="$SESSION_DIR/.trace-context-effective"
mkdir -p "$SESSION_DIR"
printf '101\n' > "$SESSION_DIR/.lock"
FM_TRACE_CONTEXT=off fm_trace_context_session_start "$CFG_ON" "$SESSION_STATE"
[ "$(fm_trace_context_session_effective "$SESSION_STATE")" = off ] \
  || fail "session state must freeze an env-off override over a present config file"
FM_TRACE_CONTEXT=on fm_trace_context_session_start "$CFG_OFF" "$SESSION_STATE"
[ "$(fm_trace_context_session_effective "$SESSION_STATE")" = on ] \
  || fail "a new session state must freeze an env-on override over an absent config file"
pass "session start normalizes config and environment precedence into frozen on/off state"

printf '100 on\n' > "$SESSION_STATE"
chmod 0400 "$SESSION_STATE"
FM_TRACE_CONTEXT=off fm_trace_context_session_start "$CFG_ON" "$SESSION_STATE"
[ "$(fm_trace_context_session_effective "$SESSION_STATE")" = off ] \
  || fail "atomic publication must replace a read-only stale on record with the current off decision"
[ "$(cat "$SESSION_STATE")" = "101 off" ] \
  || fail "session publication must bind the normalized decision to the current lock (got '$(cat "$SESSION_STATE")')"
pass "session state is atomically published through a same-directory replacement"

FM_TRACE_CONTEXT=on fm_trace_context_session_start "$CFG_OFF" "$SESSION_STATE"
printf '202\n' > "$SESSION_DIR/.lock"
chmod 0500 "$SESSION_DIR"
FM_TRACE_CONTEXT=off fm_trace_context_session_start "$CFG_ON" "$SESSION_STATE"
chmod 0700 "$SESSION_DIR"
[ "$(fm_trace_context_session_effective "$SESSION_STATE")" = off ] \
  || fail "a failed publication must not reactivate the prior session's on decision"
pass "a stale on record is inactive when publication fails in a new locked session"

printf '202 invalid\n' > "$SESSION_STATE"
[ "$(fm_trace_context_session_effective "$SESSION_STATE")" = off ] \
  || fail "invalid session state must fail independent and default off"
rm "$SESSION_STATE"
[ "$(fm_trace_context_session_effective "$SESSION_STATE")" = off ] \
  || fail "missing session state must fail independent and default off"
pass "missing or invalid frozen session state defaults off"

# --- resolve: default-off omits; enabled mints ------------------------------

NOMETA="$WORK/none.meta"
out=$(fm_trace_context_resolve "$CFG_OFF" "$NOMETA"); rc=$?
[ -z "$out" ] && [ "$rc" -eq 0 ] || fail "default-off resolve must omit and return 0 (got rc=$rc out='$out')"
pass "resolve omits the carrier and returns success when the capability is off (byte-identical default)"

out=$(FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CFG_OFF" "$NOMETA")
fm_trace_context_valid "$out" || fail "enabled resolve must mint a valid traceparent: $out"
pass "resolve mints a valid traceparent when enabled"

# --- secondmate home-session boundary ---------------------------------------
# fm-spawn launches every Secondmate with the primary session's non-empty frozen
# FM_TRACE_CONTEXT decision. The Secondmate resolves it at its own session start.
# Its own launch-time TRACEPARENT stays in its process environment for its whole
# life, but that is the Secondmate's agent identity, never a parent: every task
# it spawns must root a fresh trace, or unrelated routed tasks would accumulate
# into one ever-growing trace per Secondmate.
PRIMARY_TP='00-abcabcabcabcabcabcabcabcabcabcab-1212121212121212-01'
saved_tp=${TRACEPARENT-__unset__}
unset TRACEPARENT
frozen_off=$(FM_TRACE_CONTEXT=off fm_trace_context_resolve "$CFG_ON" "$WORK/sm-frozen-off.meta")
[ -z "$frozen_off" ] || fail "a Secondmate launched off must stay disabled even after the config file appears: $frozen_off"
frozen_on=$(FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CFG_OFF" "$WORK/sm-frozen-on.meta")
fm_trace_context_valid "$frozen_on" || fail "a Secondmate launched on must stay enabled even while the config file is absent: $frozen_on"
[ "${frozen_on:3:32}" != "${PRIMARY_TP:3:32}" ] || fail "an enabled Secondmate without an ambient carrier must start a new root"
routed_a=$(TRACEPARENT="$PRIMARY_TP" FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CFG_ON" "$WORK/sm-routed-a.meta")
routed_b=$(TRACEPARENT="$PRIMARY_TP" FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CFG_ON" "$WORK/sm-routed-b.meta")
fm_trace_context_valid "$routed_a" || fail "resolving under an ambient TRACEPARENT must still mint a valid carrier (a='$routed_a')"
fm_trace_context_valid "$routed_b" || fail "resolving under an ambient TRACEPARENT must still mint a valid carrier (b='$routed_b')"
[ "${routed_a:3:32}" != "${PRIMARY_TP:3:32}" ] && [ "${routed_b:3:32}" != "${PRIMARY_TP:3:32}" ] \
  || fail "a task resolved under a persistent ambient TRACEPARENT must root its own trace, never adopt it (a='$routed_a' b='$routed_b')"
[ "${routed_a:3:32}" != "${routed_b:3:32}" ] \
  || fail "two tasks resolved from one ambient environment must root distinct traces (a='$routed_a' b='$routed_b')"
[ "$saved_tp" = "__unset__" ] || export TRACEPARENT="$saved_tp"
pass "Secondmate home-session state stays off or on despite later file state; ambient TRACEPARENT is never adopted, so each routed task roots its own trace"

# --- recovery: a recorded value is reused verbatim, disabled still omits -----

REC_META="$WORK/rec.meta"
printf 'kind=ship\ntraceparent=%s\nmode=no-mistakes\n' "$VALID" > "$REC_META"
out=$(TRACEPARENT='00-ffffffffffffffffffffffffffffffff-1111111111111111-01' \
  FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CFG_ON" "$REC_META")
[ "$out" = "$VALID" ] || fail "recovery must reuse the recorded traceparent verbatim, ignoring the ambient environment (got '$out')"
pass "resolve reuses a valid recorded traceparent verbatim on relaunch (stable identity across restarts)"

out=$(fm_trace_context_resolve "$CFG_OFF" "$REC_META")
[ -z "$out" ] || fail "a disabled home must omit even when a traceparent is already recorded (got '$out')"
pass "disabling the capability omits the carrier even for a task with a recorded identity"

CORRUPT_META="$WORK/corrupt.meta"
printf 'traceparent=not-a-valid-traceparent\n' > "$CORRUPT_META"
out=$(FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CFG_ON" "$CORRUPT_META")
fm_trace_context_valid "$out" || fail "a corrupt recorded value must be re-minted to a valid one"
[ "$out" != "not-a-valid-traceparent" ] || fail "a corrupt recorded value must not be reused"
pass "a corrupt recorded traceparent is re-minted rather than propagated"

# --- durable metadata consistency: one value for record and injection --------

out=$(FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CFG_ON" "$NOMETA")
fm_trace_context_valid "$out" || fail "resolve must yield a single valid carrier per call"
pass "resolve yields exactly one carrier per logical task, so the recorded and injected values are identical by construction"

# --- entropy failure omits telemetry safely (never aborts) -------------------

fm_trace_context_hex() { return 1; }
ef_mint=$(fm_trace_context_mint); ef_mint_rc=$?
ef_res=$(FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CFG_ON" "$NOMETA"); ef_res_rc=$?
# Restore the real entropy source for any later use.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"
[ -z "$ef_mint" ] && [ "$ef_mint_rc" -ne 0 ] || fail "mint must omit and report failure on entropy failure (rc=$ef_mint_rc out='$ef_mint')"
[ -z "$ef_res" ] && [ "$ef_res_rc" -eq 0 ] || fail "resolve must omit and STILL return 0 on entropy failure (rc=$ef_res_rc out='$ef_res')"
pass "entropy failure omits telemetry safely: mint reports failure, resolve returns success with no carrier"

# --- fail-independent timing: no hang source, always returns 0 ---------------

assert_no_grep 'sleep' "$ROOT/bin/fm-trace-context-lib.sh" "trace-context lib must not sleep on the spawn path"
assert_no_grep 'timeout' "$ROOT/bin/fm-trace-context-lib.sh" "trace-context lib must not depend on an external timeout"
assert_no_grep 'command:' "$ROOT/bin/fm-trace-context-lib.sh" "trace-context lib must not run an arbitrary command provider"
fm_trace_context_resolve "$CFG_OFF" "$NOMETA" >/dev/null || fail "resolve must return 0 when off"
pass "the resolver has no sleep/timeout/command hang source and always returns success"

# --- harness/backend/kind independence (code only, comments stripped) ---------
# The invariant covers the carrier mint/resolve path, which must have no
# harness, backend, or spawn-kind branching. The resource-attribute section at
# the end of the lib legitimately names kind/harness/secondmate in its fixed
# key list, so the check slices the file at that section's first function and
# pins the slice still contains the mint path.
LIB_CODE=$(sed '/^fm_trace_attrs_percent_encode() {/,$d' "$ROOT/bin/fm-trace-context-lib.sh" | sed 's/#.*$//')
case "$LIB_CODE" in
  *fm_trace_context_mint*) : ;;
  *) fail "the agnostic-source slice lost the mint path; rescope it" ;;
esac
for tok in harness backend tmux herdr zellij orca cmux claude codex opencode grok kind ship scout secondmate ; do
  case "$LIB_CODE" in
    *"$tok"*) fail "trace-context carrier code must be harness/backend/kind agnostic, but references '$tok'" ;;
  esac
done
pass "the carrier is minted identically for every harness, backend, and spawn kind (no such branching in the carrier code)"

# --- no prompt / task-prose reads (code only, comments stripped) --------------

for tok in brief prompt report status ; do
  case "$LIB_CODE" in
    *"$tok"*) fail "trace-context lib code must never read task prose, but references '$tok'" ;;
  esac
done
pass "the lib code never reads a brief, prompt, report, or status - it cannot leak content"

# --- secondmate inheritance wires the nested chain ---------------------------

# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"
case " $FM_INHERITABLE_CONFIG " in
  *" trace-context "*) : ;;
  *) fail "config/trace-context must be in FM_INHERITABLE_CONFIG so secondmate homes stay traced" ;;
esac
pass "config/trace-context is inherited into secondmate homes, keeping the nested chain enabled end to end"

# --- per-task resource attributes: percent-encoding ---------------------------
# Anything outside [A-Za-z0-9._-/] becomes %XX, byte-wise, so a path with a
# space, a shell metacharacter, a quote, and a multi-byte character all render
# as inert percent escapes and the safe set passes through untouched.
enc=$(fm_trace_attrs_percent_encode 'plain-slug_2.0/sub.dir')
[ "$enc" = 'plain-slug_2.0/sub.dir' ] || fail "safe characters must pass through unencoded (got '$enc')"
enc=$(fm_trace_attrs_percent_encode 'my path/x')
[ "$enc" = 'my%20path/x' ] || fail "a space must become %20 (got '$enc')"
enc=$(fm_trace_attrs_percent_encode 'a&b=c d%e')
[ "$enc" = 'a%26b%3Dc%20d%25e' ] || fail "shell metacharacters and a literal percent must encode (got '$enc')"
enc=$(fm_trace_attrs_percent_encode "it's")
[ "$enc" = 'it%27s' ] || fail "a single quote must become %27 (got '$enc')"
enc=$(fm_trace_attrs_percent_encode $'caf\xc3\xa9')
[ "$enc" = 'caf%C3%A9' ] || fail "a multi-byte character must encode byte-wise (got '$enc')"
enc=$(fm_trace_attrs_percent_encode '')
[ -z "$enc" ] || fail "an empty value must encode to empty (got '$enc')"
case "$(fm_trace_attrs_percent_encode 'x&y z')" in
  *[!A-Za-z0-9._%/-]*) fail "encoded output must contain only the safe set and percent escapes" ;;
esac
pass "the percent encoder passes the safe set byte-wise and escapes everything else per W3C Baggage rules"

# --- per-task resource attributes: render -------------------------------------
# The rendered list must carry the header's fixed key order, encode unsafe
# values, derive home from the meta, and append firstmate.secondmate.id only
# for a secondmate. Expected values are built here from the fixture inputs,
# never by calling the renderer on itself.
ATTRS_META="$WORK/attrs.meta"
fm_write_meta "$ATTRS_META" \
  "window=firstmate:fm-attrs1" \
  "endpoint_task_id=attrs1" \
  "worktree=$WORK/wt" \
  "project=$WORK/proj dir" \
  "harness=claude" \
  "kind=ship" \
  "model=" \
  "effort=default" \
  "spawn_gen=s1.100.1"
ATTRS_EXPECTED="firstmate.task.id=attrs1,firstmate.project=proj%20dir,firstmate.home=$WORK,firstmate.task.kind=ship,firstmate.harness=claude,firstmate.model=,firstmate.effort=default,firstmate.spawn_gen=s1.100.1"

mkdir -p "$WORK/main-home"
out=$(FM_HOME="$WORK/main-home" fm_trace_attrs_render "$ATTRS_META")
[ "$out" = "$ATTRS_EXPECTED" ] || fail "render must produce the fixed key list from the meta (got '$out')"
pass "render yields the fixed key list in order, with the project path encoded and an empty model rendered empty"

out=$(FM_HOME="$WORK/main-home" fm_trace_attrs_render "$ATTRS_META")
case "$out" in
  *firstmate.secondmate.id*) fail "a task in a main home must carry no secondmate id (got '$out')" ;;
esac
out=$(fm_trace_attrs_render "$ATTRS_META")
case "$out" in
  *firstmate.secondmate.id*) fail "an unset FM_HOME must carry no secondmate id (got '$out')" ;;
esac
pass "a ship meta in a main home (or with no home set) carries no firstmate.secondmate.id"

mkdir -p "$WORK/sm-home"
printf 'sm-x\n' > "$WORK/sm-home/.fm-secondmate-home"
out=$(FM_HOME="$WORK/sm-home" fm_trace_attrs_render "$ATTRS_META")
[ "$out" = "$ATTRS_EXPECTED,firstmate.secondmate.id=sm-x" ] \
  || fail "a routed task inside a secondmate home must carry the home's marker id (got '$out')"
pass "a routed task spawned inside a secondmate home carries firstmate.secondmate.id from the home's marker"

SM_META="$WORK/attrs-sm.meta"
fm_write_meta "$SM_META" \
  "window=firstmate:fm-attrs2" \
  "endpoint_task_id=attrs2" \
  "worktree=$WORK/sm-home" \
  "project=$WORK/sm-home" \
  "harness=codex" \
  "kind=secondmate" \
  "model=default" \
  "effort=default" \
  "spawn_gen=s1.101.2" \
  "home=$WORK/sm-home"
out=$(FM_HOME="$WORK/main-home" fm_trace_attrs_render "$SM_META")
case "$out" in
  *",firstmate.secondmate.id=attrs2") : ;;
  *) fail "the secondmate agent's own resource must carry its own task id (got '$out')" ;;
esac
case "$out" in
  *firstmate.home=$WORK/sm-home*) : ;;
  *) fail "a secondmate meta's home field must supply firstmate.home (got '$out')" ;;
esac
pass "a kind=secondmate meta renders the agent's own task id as firstmate.secondmate.id, with home from the meta"

: > "$WORK/none.meta-expected-absent"
out=$(fm_trace_attrs_render "$WORK/really-absent.meta")
[ -z "$out" ] || fail "an absent meta must render nothing (got '$out')"
fm_write_meta "$WORK/no-id.meta" "kind=ship" "harness=claude"
out=$(fm_trace_attrs_render "$WORK/no-id.meta"); rc=$?
[ -z "$out" ] && [ "$rc" -eq 0 ] || fail "a meta without a task id must render nothing and return 0 (rc=$rc out='$out')"
pass "an absent meta or one without a task id renders nothing and always returns success"

echo "# fm-trace-context-lib.test.sh: all assertions passed"
