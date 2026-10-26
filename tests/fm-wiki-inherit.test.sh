#!/usr/bin/env bash
# Crew wiki slice 05 tests: secondmate provisioning seeds each child home's
# config/wiki from the primary's own wiki settings through the inherited
# local-material path.
#
# Under test:
#   A) The payload transform. A primary config/wiki seeds a validated
#      secondmate home's config/wiki with the same remote= and role=contributor
#      for every second mate (Q12 C: every second mate contributes fully),
#      never the primary's gardener role, and without host= so each home
#      stamps its own machine.
#   B) Absence. A primary without config/wiki seeds nothing and never removes
#      a child's existing copy; propagation still succeeds.
#   C) Malformed or inactive primaries. A primary config/wiki whose role is
#      off or unrecognized, or that is not a regular file, seeds nothing,
#      never fails provisioning, and warns on stderr.
#   D) Primary authority. A valid primary value converges a divergent child
#      copy, and a re-run is idempotent.
#   E) The remote route. The sender stages the transformed payload, a primary
#      without an active crew-wiki config plans a skip whose replay reads
#      "unchanged: config/wiki", and the receiver accepts config/wiki as
#      inherited material.
#   F) The seeded child activates the feature: brief-snippet prints the
#      contributor lesson instructions and the reader consult paragraph.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-wiki-inherit)

# wiki_home <name>: one fake FM_HOME with config/, state/, and data/.
wiki_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/data"
  printf '%s\n' "$home"
}

# primary_cfg <home>: a valid gardener primary config/wiki, the shape the
# merged slice-01 feature gives the main home.
primary_cfg() {
  local home=$1
  {
    printf 'host=laptop-main\n'
    printf 'remote=git@github.com:andrewesweet/crew-wiki.git\n'
    printf 'role=gardener\n'
    printf 'jev=on\n'
  } > "$home/config/wiki"
}

# run_wiki <home> <args...>: run one wiki verb pinned to the fake home.
run_wiki() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-wiki.sh" "$@"
}

test_local_seeding() {
  local primary child out err
  primary=$(wiki_home primary-a)
  child=$(wiki_home child-a)
  primary_cfg "$primary"

  # A1: the seeded child carries the primary's remote and role=contributor,
  # never gardener, and no host= stamp of the primary's machine.
  out="$TMP_ROOT/a1.out"
  err="$TMP_ROOT/a1.err"
  propagate_secondmate_inheritance "$primary" "$child" >"$out" 2>"$err" \
    || fail "seeding propagation returned non-zero"
  [ ! -s "$out" ] || fail "seeding propagation wrote to stdout"
  [ ! -s "$err" ] || fail "clean seeding wrote to stderr"
  [ -f "$child/config/wiki" ] || fail "child config/wiki was not seeded"
  grep -q '^remote=git@github.com:andrewesweet/crew-wiki.git$' "$child/config/wiki" \
    || fail "child remote differs from the primary's remote"
  grep -q '^role=contributor$' "$child/config/wiki" \
    || fail "child role is not contributor"
  grep -q '^role=gardener$' "$child/config/wiki" \
    && fail "child inherited the primary's gardener role"
  grep -q '^host=' "$child/config/wiki" \
    && fail "child inherited the primary's host stamp"
  grep -q '^jev=on$' "$child/config/wiki" \
    || fail "child did not inherit the primary's jev posture"

  # A2: idempotent - an unchanged re-run does not churn the mtime.
  local m1 m2
  m1=$(stat -c %Y "$child/config/wiki" 2>/dev/null || stat -f %m "$child/config/wiki")
  sleep 1
  propagate_secondmate_inheritance "$primary" "$child" 2>"$err" \
    || fail "idempotent re-run returned non-zero"
  m2=$(stat -c %Y "$child/config/wiki" 2>/dev/null || stat -f %m "$child/config/wiki")
  [ "$m1" = "$m2" ] || fail "idempotent re-run churned the child config mtime"

  # D1: a changed primary remote converges the child.
  printf 'remote=file:///tmp/other-wiki.git\n' > "$primary/config/wiki"
  printf 'role=contributor\n' >> "$primary/config/wiki"
  propagate_secondmate_inheritance "$primary" "$child" 2>"$err" \
    || fail "convergence propagation returned non-zero"
  grep -q '^remote=file:///tmp/other-wiki.git$' "$child/config/wiki" \
    || fail "changed primary remote did not converge"
  grep -q '^role=contributor$' "$child/config/wiki" \
    || fail "convergence lost the contributor role"

  # D2: a divergent child copy (here a reader role) converges back to
  # contributor under a valid primary.
  printf 'remote=file:///tmp/other-wiki.git\nrole=reader\n' > "$child/config/wiki"
  propagate_secondmate_inheritance "$primary" "$child" 2>"$err" \
    || fail "divergence convergence returned non-zero"
  grep -q '^role=contributor$' "$child/config/wiki" \
    || fail "divergent child role did not converge to contributor"

  # B1: a primary without config/wiki seeds nothing and leaves the child's
  # existing copy untouched; propagation still succeeds.
  local bytes_before
  bytes_before=$(wc -c < "$child/config/wiki")
  rm -f "$primary/config/wiki"
  out="$TMP_ROOT/b1.out"
  err="$TMP_ROOT/b1.err"
  propagate_secondmate_inheritance "$primary" "$child" >"$out" 2>"$err" \
    || fail "absence propagation must not fail provisioning"
  [ ! -s "$out" ] || fail "absence propagation wrote to stdout"
  [ "$(wc -c < "$child/config/wiki")" = "$bytes_before" ] \
    || fail "primary absence removed or changed the child's copy"

  # B2: a fresh child gets no config/wiki from an absent primary.
  local fresh
  fresh=$(wiki_home child-fresh)
  propagate_secondmate_inheritance "$primary" "$fresh" 2>"$err" \
    || fail "absence propagation to a fresh home returned non-zero"
  [ ! -e "$fresh/config/wiki" ] || fail "absent primary seeded a config"

  # C1: an inactive primary role seeds nothing and never fails provisioning.
  printf 'remote=file:///tmp/w.git\nrole=off\n' > "$primary/config/wiki"
  err="$TMP_ROOT/c1.err"
  propagate_secondmate_inheritance "$primary" "$fresh" 2>"$err" \
    || fail "an inactive primary role must not fail provisioning"
  [ ! -e "$fresh/config/wiki" ] || fail "an inactive primary role seeded a config"
  assert_contains "$(cat "$err")" "fm-config-inherit: warning: skipped wiki" \
    "an inactive primary role did not emit a stderr warning"

  # C2: an unrecognized role seeds nothing, same contract.
  printf 'remote=file:///tmp/w.git\nrole=emperor\n' > "$primary/config/wiki"
  rm -rf "$fresh/config/wiki"
  propagate_secondmate_inheritance "$primary" "$fresh" 2>"$err" \
    || fail "an unrecognized primary role must not fail provisioning"
  [ ! -e "$fresh/config/wiki" ] || fail "an unrecognized primary role seeded a config"

  # C3: a nonregular primary source seeds nothing.
  rm -f "$primary/config/wiki"
  mkdir -p "$primary/config/wiki"
  rm -rf "$fresh/config/wiki"
  propagate_secondmate_inheritance "$primary" "$fresh" 2>"$err" \
    || fail "a nonregular primary source must not fail provisioning"
  [ ! -e "$fresh/config/wiki" ] || fail "a nonregular primary source seeded a config"

  # E0: the destination gitignore guard still applies to the seeded item.
  local guard_repo guard_primary
  guard_repo="$TMP_ROOT/guard-repo"
  guard_primary=$(wiki_home primary-g)
  primary_cfg "$guard_primary"
  git init -q -b main "$guard_repo"
  printf 'other-file\n' > "$guard_repo/.gitignore"
  printf 'guard\n' > "$guard_repo/README.md"
  fm_git_identity "$guard_repo"
  git -C "$guard_repo" add -A
  git -C "$guard_repo" commit -qm guard
  err="$TMP_ROOT/e0.err"
  FM_INHERITABLE_CONFIG=wiki propagate_inheritable_config "$guard_primary/config" "$guard_repo/config" 2>"$err" \
    || fail "gitignore guard skip must not fail propagation"
  assert_contains "$(cat "$err")" "fm-config-inherit: warning: skipped wiki" \
    "gitignore guard skip did not emit a stderr warning"
  [ ! -e "$guard_repo/config/wiki" ] || fail "guard skip still seeded the unignored item"

  pass "wiki seeding: contributor transform, absence no-op, malformed no-op, convergence, guard"
}

test_remote_route() {
  local primary fakebin out args_file payload_file
  primary=$(wiki_home primary-r)
  printf -- '- sm - remote fixture (host: host-sm; root: /remote/code; home: /remote/home; scope: work; projects: alpha; added 2026-08-02)\n' \
    > "$primary/data/secondmates.md"
  primary_cfg "$primary"

  # E1: the receiver accepts config/wiki as inherited material and publishes
  # the exact payload bytes.
  local rhome payload bytes hash
  rhome=$(wiki_home child-r)
  payload="$TMP_ROOT/remote-payload"
  printf 'remote=file:///tmp/remote-wiki.git\nrole=contributor\n' > "$payload"
  bytes=$(LC_ALL=C wc -c < "$payload" | tr -d ' ')
  hash=$(fm_inherit_sha256 "$payload") || fail "cannot hash payload"
  out=$(PATH="$BASE_PATH" FM_HOME="$rhome" "$ROOT/bin/fm-remote-inherit.sh" \
    put config/wiki "$bytes" "$hash" 1 < "$payload" 2>&1) \
    || fail "receiver refused config/wiki: $out"
  assert_contains "$out" "pushed: config/wiki" "receiver did not publish config/wiki"
  cmp -s "$payload" "$rhome/config/wiki" \
    || fail "receiver published different bytes than the payload"

  # E2: the sender stages the transformed payload - role=contributor, the
  # primary's remote, no host=.
  fakebin=$(fm_fakebin "$TMP_ROOT/push-fakebin")
  payload_file="$TMP_ROOT/push-captured-payload"
  args_file="$TMP_ROOT/push-captured-args"
  cat > "$fakebin/ssh" <<SH
#!/usr/bin/env bash
while [ "\$#" -gt 0 ]; do
  case "\$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
shift 2
args=()
while IFS= read -r -d '' arg; do args+=("\$arg"); done < <(printf '%s' "\$4" | base64 --decode 2>/dev/null || printf '%s' "\$4" | base64 -D)
printf '%s\n' "\${args[*]}" >> '$args_file'
if [ "\${args[2]}" = config/wiki ]; then
  cat > '$payload_file'
  printf 'pushed: %s\n' "\${args[2]}"
else
  printf 'unchanged: %s\n' "\${args[2]}"
fi
SH
  chmod +x "$fakebin/ssh"
  push_run() {  # <seq>: one sender run against the fake ssh, stdout on stdout
    PATH="$fakebin:$BASE_PATH" FM_HOME="$primary" FM_ROOT_OVERRIDE="$ROOT" \
      FM_SSH_BIN="$fakebin/ssh" FM_INHERITABLE_CONFIG=wiki \
      python3 - "$ROOT/bin/fm-remote-inherit-push.sh" "$1" <<'PYTHON'
import subprocess, sys
result = subprocess.run([sys.argv[1], "sm", sys.argv[2]], capture_output=True, text=True, timeout=15)
print(result.stdout, end="")
sys.exit(result.returncode)
PYTHON
  }
  out=$(push_run 1) || fail "remote push failed: $out"
  assert_contains "$out" "pushed: config/wiki" "sender did not plan a config/wiki put"
  grep -q 'put config/wiki' "$args_file" \
    || fail "sender did not send a config/wiki put: $(cat "$args_file")"
  grep -q '^remote=git@github.com:andrewesweet/crew-wiki.git$' "$payload_file" \
    || fail "sender payload lost the primary's remote"
  grep -q '^role=contributor$' "$payload_file" \
    || fail "sender payload role is not contributor"
  grep -q '^host=' "$payload_file" \
    && fail "sender payload kept the primary's host stamp"

  # E3: a primary without an active crew-wiki config plans a skip whose
  # replay reads "unchanged: config/wiki" and sends nothing.
  rm -f "$primary/config/wiki"
  rm -f "$payload_file" "$args_file"
  out=$(push_run 2) || fail "remote push with an absent primary config failed: $out"
  assert_contains "$out" "unchanged: config/wiki" \
    "absent primary config did not replay an unchanged line"
  [ ! -s "$payload_file" ] || fail "absent primary config still sent a payload"

  # E4: a malformed primary config also seeds nothing remotely.
  printf 'remote=file:///tmp/w.git\nrole=off\n' > "$primary/config/wiki"
  rm -f "$payload_file" "$args_file"
  out=$(push_run 3) || fail "remote push with a malformed primary config failed: $out"
  assert_contains "$out" "unchanged: config/wiki" \
    "malformed primary config did not replay an unchanged line"
  [ ! -s "$payload_file" ] || fail "malformed primary config still sent a payload"

  pass "remote wiki seeding: transformed put, absent skip, malformed skip, receiver allowlist"
}

test_seeded_child_brief_snippet() {
  local primary child out
  primary=$(wiki_home primary-s)
  child=$(wiki_home child-s)
  primary_cfg "$primary"
  propagate_secondmate_inheritance "$primary" "$child" \
    || fail "seeding propagation returned non-zero"

  # F1: the seeded child prints the contributor lesson instructions.
  out=$(run_wiki "$child" brief-snippet) || fail "brief-snippet returned non-zero"
  assert_contains "$out" "data/<task-id>/lessons.md" \
    "contributor snippet missing the lesson-file instruction"
  assert_contains "$out" "nothing-to-teach" \
    "contributor snippet missing the nothing-to-teach line"

  # F2: with the seeded remote, the child also gets the consult paragraph.
  out=$(run_wiki "$child" brief-snippet --role reader) || fail "reader snippet failed"
  assert_contains "$out" "crew-wiki mirror lives at" \
    "reader consult paragraph missing for a seeded contributing child"

  # F3: a child with no config stays silent.
  local bare
  bare=$(wiki_home child-bare)
  out=$(run_wiki "$bare" brief-snippet) || fail "bare brief-snippet returned non-zero"
  [ -z "$out" ] || fail "bare child printed a contributor snippet"

  pass "seeded child activates the contributor and reader brief snippets"
}

test_local_seeding
test_remote_route
test_seeded_child_brief_snippet
