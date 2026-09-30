#!/usr/bin/env bash
# Opt-in credentialed live regression for the Claude Code supervision-branch mod
# (.claude/mods/fm-branch-mod, docs/claude-supervision-branch.md): one real
# Claude Code primary in tmux, launched exactly as the docs page prescribes,
# supervising one stand-in task in a temporary scratch home. It proves, on the
# installed Claude Code version:
#   1. the module loads (enabled by state/.branch-mod-mode) and main takes the
#      home's session lock;
#   2. the first watcher wake on a routine status line passes the classifier
#      and is routed to a freshly spawned branch agent, which handles it and
#      reports a routine outcome without a main turn;
#   3. the next wake, carrying a captain-class `done:` line, is passed to main
#      by the classifier with a covering captain outcome row, main drains it,
#      and the routine wake after it reaches the same agent through
#      SendMessage;
#   4. across that run: one spawn, every send successful, no dropped hand-back,
#      no backstop delivery;
#   5. a wake arriving after Claude Code's in-memory transcript window, with
#      transcript persistence on, still reaches the same agent: the send
#      succeeds and nothing new spawns;
#   6. the same minutes-later gap on a session that inherited
#      CLAUDE_CODE_CHILD_SESSION=1 (transcript saving off, the production
#      defect's launch shape) rotates to a fresh agent (agent.rotated
#      why=unresumable, a second agent.spawn) and keeps the wake instead of
#      passing it to main.
# The test runs against whatever Claude Code is installed and records the
# installed version in its output, so a failure names the release it was found
# on (docs/claude-supervision-branch.md "Claude Code versions").
# The project and FM_HOME are isolated; Claude keeps using its existing managed
# authentication and one trusted temporary folder. A few Sonnet turns are
# submitted (about six minutes across the two labs). FM_BRANCH_MOD_LIVE_KEEP=1
# copies each lab's logs (module events, Claude debug, watcher triage, status)
# to a fresh temporary directory named on stdout, for a post-mortem.
# shellcheck disable=SC2016 # prompt text is read by the model, not this test shell, and settle conditions are re-evaluated, not expanded
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_BRANCH_MOD_LIVE claude tmux

MOD="$ROOT/.claude/mods/fm-branch-mod"
CLAUDE_VERSION=$(claude --version 2>/dev/null | awk '{ print $1 }')
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"

REAL_TMUX=$(command -v tmux)
SESSION="fm-branch-e2e"
SOCKET1="fm-branch-claude-$$"
SOCKET2="fm-branch-claude-child-$$"
LAB1='' LAB2='' # every lab root, so cleanup reaches both
SOCKET='' LAB='' HOME_DIR='' STATE='' EVENTS='' SHIM='' # the lab under setup
GAP_BASELINE=0 SENDS_BEFORE_GAP=0 # where the production gap left the branch

# shellcheck source=tests/branch-mod-lab-helpers.sh
. "$ROOT/tests/branch-mod-lab-helpers.sh"

cleanup() {
  local lab st keep
  teardown_lab "$SOCKET1" "$LAB1"
  teardown_lab "$SOCKET2" "$LAB2"
  if [ "${FM_BRANCH_MOD_LIVE_KEEP:-}" = 1 ]; then
    for lab in "$LAB1" "$LAB2"; do
      [ -n "$lab" ] || continue
      st="$lab/home/state"
      keep=$(mktemp -d "${TMPDIR:-/tmp}/fm-branch-claude-live-logs.XXXXXX") || continue
      cp "$st/branch-mod-events.jsonl" "$lab/debug.log" "$st/.watch-triage.log" "$st/dummy.status" "$st/.wake-queue" "$keep/" 2>/dev/null || true
      echo "# lab logs kept at $keep (lab $lab)"
    done
  fi
  rm -rf "$LAB1" "$LAB2" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

# Start the stand-in crewmate window running the lab's dummy script.
start_dummy() {
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION" -n dummy -c "$HOME_DIR" "bash '$LAB/dummy.sh' '$STATE/dummy.status' 5"
}

# Pausing freezes the stand-in's status appends without killing its pane, so
# no wake can flow while the production gap elapses. A flag file, not
# SIGSTOP: tmux's server SIGCONTs a stopped pane process at once.
pause_dummy() { : > "$STATE/dummy.pause"; }
resume_dummy() { rm -f "$STATE/dummy.pause"; }

# Claude Code refuses to nest inside another Claude session, and the home's
# scripts must not inherit this shell's firstmate environment.
unset_inherited() {
  local name
  while IFS= read -r name; do
    printf -- '-u %s ' "$name"
  done < <(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_CONFIG_DIR|FM_[A-Z_]+|HERDR_[A-Z_]+|TMUX|TMUX_PANE)=' | cut -d= -f1 | sort -u)
}

# Launch Claude Code exactly as the docs page prescribes, in a fresh tmux
# session of the current lab. Any arguments become extra environment
# assignments in the pane after the scrub, so the child-session case passes
# CLAUDE_CODE_CHILD_SESSION=1 and the marker survives into Claude's env.
# The lab's tmux server is started scrubbed too: Claude Code keeps transcript
# saving on when `tmux show-environment -g` also carries the marker (an
# ambient marker), so a server inheriting it from a test run inside a Claude
# session would hide the child-session defect.
# The scrub also drops FM_GATE_REFUSE_BYPASS, so the pane re-sets it: the
# watcher arm the mod runs comes from the checkout under test, and from a
# no-mistakes validation worktree bin/fm-watch-arm.sh otherwise refuses with
# "refusing to arm from a disposable validation checkout" and no wake ever
# reaches the mod. Each lab home is the sandboxed home that escape hatch is
# for (tests/lib.sh exports the same variable).
start_claude_session() { # [extra-env...]
  local extra="${*:+$* }"
  # shellcheck disable=SC2046 # intentional: unset_inherited emits separate -u NAME tokens for env
  env $(unset_inherited) "$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n main -x 160 -y 44 -c "$HOME_DIR" \
    "env $(unset_inherited) PATH='$SHIM:$PATH' CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$HOME_DIR' FM_GATE_REFUSE_BYPASS=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 ${extra}claude --model sonnet --plugin-dir '$MOD' --settings '$LAB/settings.json' --strict-mcp-config --dangerously-skip-permissions --debug-file '$LAB/debug.log'; printf '\nCLAUDE_EXIT=%s\n' \"\$?\"; sleep 30"
}

screen() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION:main" 2>/dev/null || true
}

enter() {
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:main" Enter
}

# The folder-trust dialog opens with its cursor on "No, exit": move the cursor
# onto the trusting option first, then confirm.
answer_trust_dialog() {  # <screen text>
  local selected
  case "$1" in
    *'Yes, I trust this folder'*) : ;;
    *) return 0 ;;
  esac
  selected=$(printf '%s\n' "$1" | grep -F '❯' | head -1)
  case "$selected" in
    *'Yes, I trust this folder'*) enter ;;
    *) "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:main" Down ;;
  esac
}

events() {  # <kind> -> the matching event lines
  grep -F "\"kind\":\"$1\"" "$EVENTS" 2>/dev/null || true
}

# Wait until at least <min> events (default 1) of <kind> whose lines contain
# <needle> have been logged, answering the folder-trust dialog on the way;
# iteration-counted so it stretches under load.
wait_event() {  # <kind> <needle> <what> [seconds] [min]
  local kind=$1 needle=$2 what=$3 limit=${4:-240} want=${5:-1} i=0 shot
  while [ "$i" -lt "$((limit * 2))" ]; do
    if [ "$(count "$kind" "$needle")" -ge "$want" ]; then return 0; fi
    shot=$(screen)
    case "$shot" in
      *'CLAUDE_EXIT='*)
        printf '%s\n' "$shot" >&2
        fail "Claude Code $CLAUDE_VERSION exited while waiting for $what"
        ;;
    esac
    answer_trust_dialog "$shot"
    sleep 0.5
    i=$((i + 1))
  done
  printf '%s\n' "$(screen)" >&2
  tail -n 20 "$EVENTS" >&2 2>/dev/null || true
  fail "Claude Code $CLAUDE_VERSION never reached $what"
}

count() {  # <kind> [needle]
  if [ "$#" -gt 1 ]; then events "$1" | grep -cF -- "$2" || true; else events "$1" | wc -l | tr -d ' '; fi
}

# Event lines are appended by one fire-and-forget shell per record, so under
# load a count can lag the events it counts. Count assertions re-read a few
# times before they are allowed to fail.
settle() { # <attempts> <shell condition, evaluated fresh on each try>
  local attempts=$1 i=0
  shift
  while ! eval "$*"; do
    i=$((i + 1))
    [ "$i" -ge "$attempts" ] && return 1
    sleep 2
  done
}

# Successful sends, counted through the escaped-JSON success marker.
success_sends() { count agent.send '\"success\":true'; }

# The composer is up once the trust dialog is gone and the prompt glyph shows.
wait_composer() {
  local i=0 shot
  while [ "$i" -lt 240 ]; do
    shot=$(screen)
    answer_trust_dialog "$shot"
    case "$shot" in *'❯'*) [ "$i" -gt 4 ] && return 0 ;; esac
    sleep 0.5
    i=$((i + 1))
  done
  fail "the composer never came up"
}

# Main's first prompt: take the home's session lock.
take_lock() {
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:main" -l "Take this home's session lock with bin/fm-lock.sh, then reply ready."
  sleep 0.5
  enter
  wait_event turn.complete.main '"kind":"turn.complete.main"' "main's lock turn"
  [ -s "$STATE/.lock" ] || fail "main did not take the session lock"
}

# The branch finished every wake already delivered: with the stand-in paused,
# its turn-complete count stops rising.
wait_branch_quiet() {
  local last=-1 stable=0 i=0 n
  while [ "$i" -lt 240 ]; do
    n=$(count turn.complete.branch)
    if [ "$n" = "$last" ]; then stable=$((stable + 1)); else stable=0; fi
    [ "$stable" -ge 5 ] && return 0
    last=$n
    answer_trust_dialog "$(screen)"
    sleep 2
    i=$((i + 1))
  done
  fail "the branch never went quiet: $(events turn.complete.branch)"
}

# One more branch turn than <baseline> completed.
wait_branch_turn() { # <baseline> <what>
  local baseline=$1 what=$2 i=0
  while [ "$(count turn.complete.branch)" -le "$baseline" ] && [ "$i" -lt 480 ]; do
    answer_trust_dialog "$(screen)"
    sleep 1
    i=$((i + 1))
  done
  [ "$(count turn.complete.branch)" -gt "$baseline" ] || fail "Claude Code $CLAUDE_VERSION never reached $what"
}

# The production-shaped gap: pause the stand-in, let the branch finish what it
# already has, then hold past Claude Code's in-memory transcript window
# (measured at 30 s plus at most one further 30 s idle window) before the
# stand-in's next line becomes the next wake. Sets GAP_BASELINE to the
# branch-turn count and SENDS_BEFORE_GAP to the send count to wait against
# afterwards; both are captured only once the branch is quiet, so no send is
# in flight.
production_gap() {
  pause_dummy
  wait_branch_quiet
  GAP_BASELINE=$(count turn.complete.branch)
  SENDS_BEFORE_GAP=$(count agent.send)
  sleep 75
  resume_dummy
}

# --- 1. load and lock (lab 1: the scrubbed launch, transcript persistence on)
make_lab "$SOCKET1"
LAB1=$LAB
start_claude_session
wait_event session.start '"enabled":true' 'the module loading enabled'
wait_composer
take_lock
pass "Claude Code $CLAUDE_VERSION loads the supervision-branch mod enabled and main holds the session lock"

# --- 2. routine wake: spawn ----------------------------------------------------
start_dummy
wait_event classifier '"verdict":"routine"' "the classifier's routine verdict on the working line"
wait_event wake.delivered '"via":"spawn"' 'the first wake delivered by spawning the branch'
wait_event report.call '"verdict":"routine"' "the branch's routine outcome"
wait_event turn.complete.branch '"kind":"turn.complete.branch"' "the branch's first turn end"
pass "the first routine wake passes the classifier and spawns the branch agent, which reports it routine"

# --- 3. captain wake: classifier pass to main, then a send -------------------
: > "$STATE/dummy.done-request"
wait_event classifier '"verdict":"captain"' "the classifier's captain verdict on the done line"
wait_event wake.passed '"why":"classifier captain"' 'the done wake passed to main'
wait_event pass.cover '"processed":true' "the covering captain outcome row for main's direct handling"
i=0
while [ "$(count turn.complete.main)" -lt 2 ] && [ "$i" -lt 480 ]; do
  answer_trust_dialog "$(screen)"
  sleep 0.5
  i=$((i + 1))
done
[ "$(count turn.complete.main)" -ge 2 ] || fail "main never finished the turn that drains the done wake: $(events turn.complete.main)"
[ "$(count deliver.captain)" = 0 ] || fail "the branch re-escalated the done line main already handled: $(events deliver.captain)"
wait_event wake.delivered '"via":"send"' 'the next routine wake delivered by SendMessage'
pass "the captain-class wake is passed to main by the classifier with a covering outcome row, and the next routine wake reaches the same agent through SendMessage"

# --- 4. minutes-later wake, persistence on: the same agent resumes -------------
# The scenarios above fire seconds apart, inside the window Claude Code keeps
# a finished background agent's transcript in memory; production wakes arrive
# minutes later. Pause the stand-in, hold past that window, then deliver the
# next wake: the scrubbed launch saves transcripts, so the SAME agent must
# take it - the send succeeds and nothing new spawns.
production_gap
# The turn after the gap proves the wake was delivered and handled: only
# then do the no-rotation and all-sends-succeeded assertions mean anything.
wait_branch_turn "$GAP_BASELINE" "the resumed agent's turn on the minutes-later wake"
[ "$(count agent.rotated)" = 0 ] || fail "the minutes-later wake rotated a persisted agent: $(events agent.rotated)"
settle 10 '[ "$(count agent.spawn)" = 1 ]' || fail "the minutes-later wake spawned a fresh agent: $(events agent.spawn)"
settle 10 '[ "$(count agent.send)" -gt "$SENDS_BEFORE_GAP" ]' || fail "no send reached the branch after the gap"
settle 10 '[ "$(count agent.send)" = "$(success_sends)" ]' || fail "a send failed after the gap: $(events agent.send)"
pass "a wake after the in-memory window reaches the same persisted agent: the send succeeds, no rotation"

# --- 5. the whole run ----------------------------------------------------------
settle 10 '[ "$(count agent.spawn)" = 1 ]' || fail "expected exactly one spawn, got $(count agent.spawn): $(events agent.spawn)"
[ "$(count handback.dropped)" = 0 ] || fail "a branch hand-back was dropped: $(events handback.dropped)"
[ "$(count backstop.delivered)" = 0 ] || fail "the backstop re-presented a covered line: $(events backstop.delivered)"
[ "$(count agent.send)" -ge 1 ] || fail "no send reached the branch: $(events agent.send)"
settle 10 '[ "$(count agent.send)" = "$(success_sends)" ]' || fail "a send was retried or refused: $(events agent.send)"
pass "one spawn, every send successful, no dropped hand-back, no backstop delivery across the run"

# Lab 1 is proven; free its server and panes before the second lab launches.
teardown_lab "$SOCKET" "$LAB"

# --- 6. inherited CLAUDE_CODE_CHILD_SESSION: the unresumable rotation ----------
# The production defect's launch shape: the primary inherited
# CLAUDE_CODE_CHILD_SESSION=1 (a Herdr server started inside a Claude
# session), so background-agent transcripts are never written to disk. The
# same minutes-later gap then finds no transcript and no in-memory agent: the
# mod must rotate to a fresh agent and keep the wake, never pass it to main.
make_lab "$SOCKET2"
LAB2=$LAB
start_claude_session CLAUDE_CODE_CHILD_SESSION=1
wait_event session.start '"enabled":true' 'the module loading enabled in the child-session lab'
wait_composer
take_lock
start_dummy
wait_event classifier '"verdict":"routine"' "the classifier's routine verdict on the first working line"
wait_event wake.delivered '"via":"spawn"' 'the first wake delivered by spawning the branch'
wait_event turn.complete.branch '"kind":"turn.complete.branch"' "the branch's first turn end"
production_gap
wait_event agent.rotated '"why":"unresumable"' 'the unresumable rotation'
# The defect's signature: the resume failed because no transcript was ever
# written, and the mod still rotated successfully to a fresh agent. Every
# later agent inherits the same launch shape, so once IT evicts the next wake
# rotates again - the invariant is that rotation keeps every wake and main
# never sees one, not a frozen rotation count.
case "$(events agent.rotated)" in
  *'"why":"unresumable"'*) : ;;
  *) fail "no unresumable rotation: $(events agent.rotated)" ;;
esac
if events agent.rotated | grep -v '"ok":true' | grep -q .; then
  fail "a rotation did not succeed: $(events agent.rotated)"
fi
[ "$(count agent.spawn)" -ge 2 ] || fail "the unresumable wake did not spawn a fresh agent: $(events agent.spawn)"
wait_event wake.delivered '"via":"spawn"' 'the unresumable wake delivered to the fresh agent' 240 2
[ "$(count wake.passed)" = 0 ] || fail "the unresumable wake was passed to main instead of rotating: $(events wake.passed)"
[ "$(count handback.dropped)" = 0 ] || fail "a branch hand-back was dropped: $(events handback.dropped)"
settle 10 '[ "$(count agent.send)" -gt "$SENDS_BEFORE_GAP" ]' || fail "no send was attempted after the gap: $(events agent.send)"
wait_branch_turn "$GAP_BASELINE" "the fresh agent's turn on the unresumable wake"
# Every later wake is kept too: with transcripts never written, a resume
# fails even seconds after the agent's turn, so the chain keeps rotating -
# or, on a version that keeps agents warm, the send succeeds. Either way
# main never sees one.
i=0
while [ "$i" -lt 120 ] \
  && [ "$(count wake.passed)" = 0 ] \
  && [ "$(count handback.dropped)" = 0 ] \
  && [ "$(count wake.delivered '"via":"spawn"')" -lt 3 ] \
  && [ "$(count agent.send '\"success\":true')" -le "$SENDS_BEFORE_GAP" ]; do
  sleep 2
  i=$((i + 1))
done
[ "$(count wake.delivered '"via":"spawn"')" -ge 3 ] \
  || [ "$(count agent.send '\"success\":true')" -gt "$SENDS_BEFORE_GAP" ] \
  || fail "the rotation chain stalled: $(events wake.delivered)"
[ "$(count wake.passed)" = 0 ] || fail "a later wake was passed to main: $(events wake.passed)"
[ "$(count handback.dropped)" = 0 ] || fail "a later hand-back was dropped: $(events handback.dropped)"
pass "a minutes-later wake on an inherited CLAUDE_CODE_CHILD_SESSION rotates to a fresh agent (why=unresumable) and keeps the wake"
