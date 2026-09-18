# Merge-resolution audit: fb2bec9 (merge of upstream/main 9bc051f into fork main acd7047)

## git merge-tree auto-merge vs actual merge commit (only the 8 conflicted files differ)
 bin/fm-crew-state.sh                  |   8 -
 bin/fm-dispatch-resolve.sh            | 408 ---------------------
 bin/fm-spawn.sh                       | 498 ++------------------------
 bin/fm-test-run.sh                    | 316 +----------------
 docs/configuration.md                 |  37 --
 docs/fm-test-portable-shards.md       |  11 +-
 docs/verification/dispatch-resolve.md |  77 ----
 tests/fm-dispatch-resolve.test.sh     | 642 ----------------------------------
 8 files changed, 36 insertions(+), 1961 deletions(-)

## Conflict markers left in tree
none

## Per conflicted file: lines added/removed vs upstream and vs fork
bin/fm-crew-state.sh  vs-upstream:13/2  vs-fork:111/57
bin/fm-dispatch-resolve.sh  vs-upstream:103/1  vs-fork:
bin/fm-spawn.sh  vs-upstream:172/28  vs-fork:385/255
bin/fm-test-run.sh  vs-upstream:22/3  vs-fork:186/164
docs/configuration.md  vs-upstream:34/0  vs-fork:3/2
docs/fm-test-portable-shards.md  vs-upstream:1/0  vs-fork:27/11
docs/verification/dispatch-resolve.md  vs-upstream:1/0  vs-fork:
tests/fm-dispatch-resolve.test.sh  vs-upstream:75/2  vs-fork:

## fork-only mod untouched by merge
(empty = identical to fork main)

## Merge result vs upstream for conflicted bin/docs (fork-only material that survived)
diff --git a/bin/fm-crew-state.sh b/bin/fm-crew-state.sh
index 160c729..4fb9622 100755
--- a/bin/fm-crew-state.sh
+++ b/bin/fm-crew-state.sh
@@ -130,8 +130,19 @@ ID=${1:-}
 
 # Fleet snapshot composition supplies its captured metadata path here so every
 # state read resolves the same task generation selected by that snapshot.
-META=${FM_CREW_STATE_META_OVERRIDE:-"$STATE/$ID.meta"}
-LOG=${FM_CREW_STATE_STATUS_OVERRIDE:-"$STATE/$ID.status"}
+# An override is honoured only when its basename is exactly this task's own
+# file name: an override inherited from another task's environment (via a
+# herdr server started inside that task's fleet-snapshot child, for example)
+# must fall through to $STATE/$ID.* instead of reading another task's
+# captured generation (2026-09-16 override-leak incident).
+case ${FM_CREW_STATE_META_OVERRIDE:-} in
+  "$ID.meta"|*/"$ID.meta") META=$FM_CREW_STATE_META_OVERRIDE ;;
+  *) META=$STATE/$ID.meta ;;
+esac
+case ${FM_CREW_STATE_STATUS_OVERRIDE:-} in
+  "$ID.status"|*/"$ID.status") LOG=$FM_CREW_STATE_STATUS_OVERRIDE ;;
+  *) LOG=$STATE/$ID.status ;;
+esac
 NM_TIMEOUT=${FM_CREW_STATE_NM_TIMEOUT:-10}
 case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac
 # How many of the most recent `no-mistakes runs` rows each ledger read
diff --git a/bin/fm-dispatch-resolve.sh b/bin/fm-dispatch-resolve.sh
index 12f67db..ecf69f9 100755
--- a/bin/fm-dispatch-resolve.sh
+++ b/bin/fm-dispatch-resolve.sh
@@ -43,6 +43,23 @@
 #   existing unreadable rules file, malformed rules, or missing jq), which is
 #   actionable, never selected around.
 #
+# Outcome log (docs/configuration.md "Typed dispatch resolution" owns the
+#   operator contract): every resolved outcome (clear, ambiguous, escalate,
+#   error) appends exactly one JSON object as one line to
+#   $FM_HOME/data/dispatch-resolve.jsonl before the block prints, with fields
+#   ts (UTC ISO 8601), task (the <id> when the brief sits at a
+#   data/<id>/brief.md-shaped path, else null), project (the --project value
+#   or null), status, confidence (number or null), rule ("<choice>
+#   (<when excerpt>)" exactly as the block renders it, or null), profile (the
+#   profile line's value on clear, else null), reason (the non-clear reason,
+#   else null), latency_ms, and tokens (the usage object when the response
+#   carried one, else null). Never recorded: the API key, the brief text, and
+#   the request body. A failed append (unwritable directory, read-only home)
+#   prints one "dispatch-resolve: outcome log unwritable: <path>" line on
+#   stderr and never changes the block or the exit code; only data/ itself is
+#   created when absent. The off path and exit-2 usage or configuration
+#   errors write nothing: they are not calls.
+#
 # Environment:
 #   TYPESAFE_API_KEY is the only resolver-specific environment setting.
 #
@@ -77,6 +94,7 @@ DEFAULT_WHEN="No listed rule applies to this task."
 
 die() { printf 'error: %s\n' "$1" >&2; exit 2; }
 no_rules() {
+  log_dispatch_outcome escalate '' '' '' 'no rules to match'
   printf 'dispatch-resolve:\n  status: escalate\n  reason: no rules to match\n'
   exit 0
 }
@@ -98,6 +116,89 @@ while [ $# -gt 0 ]; do
   esac
 done
 
+LAT_MS=null
+# The outcome log lives beside the home's other private records; only a brief
+# sitting at a data/<id>/brief.md-shaped path contributes a task id, so an
+# arbitrary directory name is never mistaken for one.
+DISPATCH_LOG="$FM_HOME/data/dispatch-resolve.jsonl"
+DISPATCH_TASK_ID=''
+case /${BRIEF%/*} in
+  */data/*)
+    candidate=/$BRIEF
+    candidate=${candidate##*/data/}
+    candidate=${candidate%%/*}
+    case $candidate in
+      *[!a-z0-9-]*|'') DISPATCH_TASK_ID='' ;;
+      *) DISPATCH_TASK_ID=$candidate ;;
+    esac ;;
+esac
+
+# Append exactly one outcome line to the home's dispatch-resolve log. Every
+# argument is shell-controlled and already flat of newlines and tabs; a failed
+# write prints one stderr line and never changes the outcome. Only data/
+# itself is created when absent.
+dispatch_log_append() {  # <json-line>
+  { mkdir -p "${DISPATCH_LOG%/*}" && printf '%s\n' "$1" >> "$DISPATCH_LOG"; } 2>/dev/null || \
+    printf 'dispatch-resolve: outcome log unwritable: %s\n' "$DISPATCH_LOG" >&2
+  return 0
+}
+
+# log_dispatch_outcome <status> <confidence> <rule-render> <profile> <reason>
+# for outcomes resolved without a parsed model answer (no rules, error):
+# confidence, rule, profile, and tokens stay null and latency is whatever the
+# call reached.
+log_dispatch_outcome() {
+  local line
+  line=$(jq -cn \
+    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
+    --arg task "$DISPATCH_TASK_ID" \
+    --arg project "$PROJECT" \
+    --arg status "$1" --arg confidence "$2" --arg rule "$3" --arg profile "$4" --arg reason "$5" \
+    --argjson latency "$LAT_MS" '
+    def n: if . == "" then null else . end;
+    {ts: $ts, task: ($task | n), project: ($project | n), status: $status,
+     confidence: ($confidence | n), rule: ($rule | n), profile: ($profile | n),
+     reason: ($reason | n), latency_ms: $latency, tokens: null}') || {
+    printf 'dispatch-resolve: outcome log unwritable: %s\n' "$DISPATCH_LOG" >&2
+    return 0
+  }
+  dispatch_log_append "$line"
+}
+
+# log_dispatch_result records the resolved RESULT object's own fields; the
+# rule renders as the block renders it and the profile is the profile line's
+# value.
+log_dispatch_result() {
+  local line
+  line=$(jq -cn \
+    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
+    --arg task "$DISPATCH_TASK_ID" \
+    --arg project "$PROJECT" \
+    --argjson result "$RESULT" '
+  ($result) as $r |
+  def flat: tostring | gsub("[\t\r\n]"; " ");
+  {
+    ts: $ts,
+    task: (if $task == "" then null else $task end),
+    project: (if $project == "" then null else $project end),
+    status: $r.status,
+    confidence: $r.confidence,
+    rule: (if $r.rule then (($r.rule | flat) + " (" + ($r.rule_when | flat) + ")") else null end),
+    profile: (if $r.status == "clear" and $r.chosen then
+      "--harness " + ($r.chosen.profile.harness | @sh)
+      + (if $r.chosen.profile.model then " --model " + ($r.chosen.profile.model | @sh) else "" end)
+      + (if $r.chosen.profile.effort then " --effort " + ($r.chosen.profile.effort | @sh) else "" end)
+    else null end),
+    reason: (if $r.status == "clear" then null else ($r.reason // null) end),
+    latency_ms: $r.latency_ms,
+    tokens: $r.tokens
+  }') || {
+    printf 'dispatch-resolve: outcome log unwritable: %s\n' "$DISPATCH_LOG" >&2
+    return 0
+  }
+  dispatch_log_append "$line"
+}
+
 # ---- opt-in gate ---------------------------------------------------------------
 if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
   TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
@@ -207,6 +308,7 @@ RULE_COUNT=$(jq -r '(.rules // []) | length' "$RULES")
 
 emit_error() {
   local reason=$1
+  log_dispatch_outcome error '' '' '' "$reason"
   echo "dispatch-resolve: error ($reason)" >&2
   printf 'dispatch-resolve:\n  status: error\n  reason: %s\n' "$reason"
   exit 0
@@ -219,7 +321,6 @@ fi
 RESP_FILE=$(mktemp) || die "mktemp failed"
 QUOTA=$(mktemp) || { rm -f "$RESP_FILE"; die "mktemp failed"; }
 trap 'rm -f "$RULES" "$RESP_FILE" "$QUOTA"' EXIT
-LAT_MS=null
 command -v curl >/dev/null 2>&1 || emit_error "curl not installed"
   REQUEST=$(jq -n --rawfile brief "$BRIEF" --arg project "$PROJECT" --arg model "$TS_MODEL" \
     --arg none_criterion "$DEFAULT_WHEN" --slurpfile rules "$RULES" '
@@ -400,5 +501,6 @@ TEXT=$(jq -r '
   (if .chosen then "  profile: --harness \(.chosen.profile.harness | shell_arg)"
       + (if .chosen.profile.model then " --model \(.chosen.profile.model | shell_arg)" else "" end)
       + (if .chosen.profile.effort then " --effort \(.chosen.profile.effort | shell_arg)" else "" end) else empty end)' <<<"$RESULT") || emit_error "output rendering failed"
+log_dispatch_result
 printf '%s\n' "$TEXT"
 exit 0
diff --git a/bin/fm-test-run.sh b/bin/fm-test-run.sh
index b939101..98de938 100755
--- a/bin/fm-test-run.sh
+++ b/bin/fm-test-run.sh
@@ -286,7 +286,7 @@ family_for_basename() {
     fm-kimi-harness.test.sh|fm-muse-harness.test.sh|fm-rovo-harness.test.sh|fm-agy-harness.test.sh|fm-omp-harness.test.sh|fm-herdr-lab.test.sh|fm-lint.test.sh|\
     fm-lint-workflows.test.sh|\
     fm-operational-input.test.sh|fm-pi-primary-types.test.sh|\
-    fm-calm-claude-mod.test.sh|\
+    fm-calm-claude-mod.test.sh|fm-branch-claude-mod.test.sh|\
     fm-harness-adapter-references.test.sh|\
     fm-send-popup-settle.test.sh|fm-send-settle.test.sh|\
     fm-subagent-pretool-check.test.sh|\
@@ -299,7 +299,7 @@ family_for_basename() {
     fm-daemon.test.sh|fm-guard-stale-banner.test.sh|fm-pi-watch-extension.test.sh|\
     fm-session-lock-ancestry.test.sh|fm-cursor-primary.test.sh|\
     fm-supervision-events.test.sh|fm-turnend-guard.test.sh|fm-wake-daemon-lifecycle-e2e.test.sh|\
-    fm-wake-drain-unread-status.test.sh|\
+    fm-wake-drain-unread-status.test.sh|fm-branch-mod-bin.test.sh|\
     fm-tool-update-check.test.sh|\
     fm-mail.test.sh|fm-mail-check.test.sh|\
     fm-turnend-foreign-owner-arm-fix.test.sh|\
@@ -361,6 +361,7 @@ family_for_basename() {
     fm-quota-array-dispatch-live-e2e.test.sh|fm-send-secondmate-marker-herdr-e2e.test.sh|\
     fm-send-inbox-doorbell-live-e2e.test.sh|\
     fm-calm-claude-mod-plugin.test.sh|fm-calm-claude-mod-live-e2e.test.sh|\
+    fm-branch-claude-mod-plugin.test.sh|fm-branch-claude-mod-live-e2e.test.sh|\
     fm-herdr-submit-confirm-live-e2e.test.sh)
       printf '%s\n' live-harness-optin
       ;;
@@ -686,6 +687,10 @@ tests/fm-bearings-board.test.sh 36490
 tests/fm-bearings-snapshot.test.sh 171176
 tests/fm-bootstrap-network-parallel.test.sh 9539
 tests/fm-bootstrap.test.sh 46634
+tests/fm-branch-claude-mod-live-e2e.test.sh 60
+tests/fm-branch-claude-mod-plugin.test.sh 60
+tests/fm-branch-claude-mod.test.sh 250
+tests/fm-branch-mod-bin.test.sh 8000
 tests/fm-branch-supervision.test.sh 8915
 tests/fm-busy-adapter-wiring.test.sh 27817
 tests/fm-busy-state.test.sh 2990
@@ -761,10 +766,12 @@ tests/fm-pr-check-security.test.sh 226546
 tests/fm-pr-reviewers.test.sh 273
 tests/fm-pr-state-live-e2e.test.sh 45
 tests/fm-pr-state.test.sh 531
+tests/fm-precompact-skills.test.sh 350
 tests/fm-procevent-quota.test.sh 1900
 tests/fm-procevent-when.test.sh 23805
 tests/fm-procevent.test.sh 221745
 tests/fm-project-origin.test.sh 136
+tests/fm-promote.test.sh 4120
 tests/fm-public-followup.test.sh 153508
 tests/fm-quota-array-dispatch-live-e2e.test.sh 71
 tests/fm-quota-choose.test.sh 1484
@@ -823,6 +830,7 @@ tests/fm-tmux-agent-liveness.test.sh 1953
 tests/fm-tool-update-check.test.sh 13832
 tests/fm-trace-context-lib.test.sh 227
 tests/fm-trace-context-spawn.test.sh 49071
+tests/fm-trace-span-lib.test.sh 1970
 tests/fm-turnend-foreign-owner-arm-fix.test.sh 2397
 tests/fm-turnend-guard.test.sh 33450
 tests/fm-update.test.sh 11572
@@ -1495,6 +1503,13 @@ families_for_changed_path() {
       printf '%s\n' __script__:fm-pi-primary-types.test.sh
       printf '%s\n' live-harness-optin
       ;;
+    .claude/mods/fm-branch-mod/*|bin/fm-branch-agent-md.sh)
+      # The Claude Code supervision-branch mod and the generator of its agent
+      # definition: the portable Node checks, then the Claude-dependent guards
+      # (strict validation, the engine-hosted suite, and the pinned live run).
+      printf '%s\n' __script__:fm-branch-claude-mod.test.sh
+      printf '%s\n' live-harness-optin
+      ;;
     bin/fm-sessionstart-run.sh|.claude/settings.json|.codex/hooks.json|\
     .pi/extensions/fm-primary-turnend-guard.ts)
       # The run tier's two harness-supplied facts (source vocabulary and
@@ -1552,6 +1567,10 @@ families_for_changed_path() {
       printf '%s\n' backend-dispatch
       printf '%s\n' pure-contract-unit
       ;;
+    bin/fm-promote.sh)
+      printf '%s\n' pure-contract-unit
+      printf '%s\n' "__script__:fm-promote.test.sh"
+      ;;
     bin/fm-task-inbox-lib.sh)
       # The steering-inbox record/doorbell/ladder owner: fm-send's data plane
       # (backend-dispatch), the watcher's re-ring check (watcher-wake-lock),
@@ -1576,7 +1595,7 @@ families_for_changed_path() {
     bin/fm-captain-hold.sh|bin/fm-decision-hold.sh|bin/fm-supervision*|bin/fm-transition-lib.sh|\
     bin/fm-tmux-lib.sh|bin/fm-marker-lib.sh|bin/fm-operational-input.sh|bin/fm-tasks-axi-lib.sh|\
     bin/fm-vendor-auth-probe.sh|\
-    bin/fm-primary-scope-lib.sh|bin/fm-project-mode.sh|bin/fm-promote.sh|\
+    bin/fm-primary-scope-lib.sh|bin/fm-project-mode.sh|\
     bin/fm-ff-lib.sh|bin/fm-gotmp*|bin/*pretool*)
       printf '%s\n' pure-contract-unit
       ;;
diff --git a/docs/configuration.md b/docs/configuration.md
index f23b741..4869f18 100644
--- a/docs/configuration.md
+++ b/docs/configuration.md
@@ -94,6 +94,18 @@ Cancelling the model picker cancels the whole command and changes neither choice
 Cancelling only the effort picker keeps the standing effort choice and still applies the model pick made in the same run, and the command's one closing message reports both choices as they will actually take effect.
 Both choices are local to each Firstmate home and are not part of secondmate inherited configuration, the same as the Calm preference; a secondmate home pins its own supervision model and effort with its own `/supervision-model`.
 
+## Claude Code supervision branch (state/.branch-mod-mode, config/classifier-model)
+
+On a Claude Code primary, the `fm-branch-mod` plugin runs the same supervision branch as a persistent background agent inside the captain's `claude` process; [docs/claude-supervision-branch.md](claude-supervision-branch.md) owns its behaviour, launch settings, version pin, and bounds.
+The mod is opt-in per home and inert everywhere else: it loads only through `--plugin-dir`, refuses to load on any Claude Code version other than its pin, and every `bin/` piece it relies on is switched by the presence of `state/.branch-mod-mode`.
+That file's presence is the whole switch and its content is ignored: create it to route eligible wakes to the branch, and remove it to switch the mod and its `bin/` pieces off together.
+A text-only classifier runs ahead of the branch on every eligible wake, and every task wake hands the branch the deterministic new-status-lines note; neither has a switch.
+`config/classifier-model` names the model the classifier's single `$.model.complete` call uses; absent means `haiku`, and the name in force is written into every record of `state/branch-mod-classifications.jsonl`, the durable classification log `bin/fm-branch-classifier-score.sh` scores.
+The branch agent's own model comes from `config/supervision-branch-model`, shared with the Pi branch above, defaulting to `sonnet`; `config/supervision-branch-effort` is Pi-only, because the mod runs the branch's model steps at low effort.
+`state/.branch-mod-counters`, `state/.branch-mod-passed`, `state/branch-mod-events.jsonl`, and `state/.<task>.classifier-offset` are the mod's own runtime records, listed with their owners in `AGENTS.md`'s `state/` inventory.
+A home running the mod should watch Claude Code through the `claude` entry documented under [Watched tool updates](#watched-tool-updates-configwatched-toolsjson), so a new release is reported instead of being discovered as a refusal to load.
+None of these files is inherited by secondmate homes.
+
 ## Backlog backend (.tasks.toml / config/backlog-backend)
 
 The tracked `.tasks.toml` pins the default `tasks-axi` markdown backend to `data/backlog.md`, with `done_keep = 10` and an archive at `data/done-archive.md`.
@@ -201,7 +213,9 @@ The optional local, gitignored `config/trace-context` presence flag enables defa
 Each locked home session resolves those inputs once, and all spawns from that home use the frozen decision until a new session starts.
 When launching a Secondmate, the primary copies the presence flag into its home and passes the primary session's frozen decision as a non-empty `FM_TRACE_CONTEXT=on|off` override for the Secondmate's own session start.
 A Secondmate on a remote route is covered the same way: the primary resolves and records that task's carrier, and the configured host exports it and receives the same enablement snapshot.
+An enabled spawn also exports one `OTEL_RESOURCE_ATTRIBUTES` value into the worker's pane beside the carrier, for harnesses that consume resource attributes; `bin/fm-trace-context-lib.sh`'s header owns the fixed key list and the encoding.
 The presence flag is session-scoped enablement, so it transfers at launch and is left unchanged by live convergence into a running home.
+When enabled, Firstmate also posts its own lifecycle spans over OTLP/HTTP; [`fm-trace-span-lib.sh`](../bin/fm-trace-span-lib.sh) owns endpoint configuration, exported fields, and delivery limits.
 See [`trace-context.md`](trace-context.md) for carrier semantics, supported routes, the manual fleet-restart requirement, the session boundary, and safety limits; `bin/fm-trace-context-lib.sh`'s header owns the exact mechanics, and [`verification/trace-context.md`](verification/trace-context.md) records repeatable evidence.
 
 ## Turn-end pane-churn absorb (config/turnend-churn-absorb)
@@ -387,6 +401,7 @@ SSH_AUTH_SOCK
 
 Firstmate retains basic home, executable search, terminal, locale, temporary-directory, and backend routing variables, plus its explicit launch assignments, its ship and scout task marker, and enabled task trace.
 [`fm-spawn.sh --help`](../bin/fm-spawn.sh) owns the exact retained names and parsing mechanics.
+The `OTEL_EXPORTER_OTLP_*` variables that decide where a worker's own OpenTelemetry instrumentation sends are the host's, like any other ambient name: an allowlisted home lists the ones it needs itself.
 Other ambient names must be listed explicitly, including custom credential-store locations, proxy settings, and certificate overrides when required by the selected tools.
 The command shell and worker may still create their own variables.
 Allowed values come from the destination pane at execution time; they are neither copied from the invoking Firstmate process nor written into the launch command.
@@ -411,6 +426,9 @@ This is not a sandbox: it cannot revoke same-user access to credential files, pr
 Regression coverage executes emitted launch commands with synthetic nonsecret values in [`tests/fm-spawn-dispatch-profile.test.sh`](../tests/fm-spawn-dispatch-profile.test.sh).
 
 Every claude launch's inline `--settings` JSON also carries `"attribution":{"commit":"","pr":"","sessionUrl":false}`, so a spawned worker never writes a Co-Authored-By trailer, Claude-Session link, or generated-with line into a commit or PR body regardless of which settings scopes end up loaded.
+The same JSON trims the worker's startup context: it disables claude.ai connectors, the `claude-in-chrome` MCP server, auto memory, workflows, and bundled skills, and denies `Artifact`, `ReportFindings`, `ScheduleWakeup`, and `AskUserQuestion`; the [Claude adapter reference](../.agents/skills/harness-adapters/references/harness/claude.md) "Startup context" owns why each key is there.
+The same JSON also sets `autoCompactWindow` to 220000, so a Claude worker on a 1M-context model still auto-compacts near 187k tokens instead of never compacting under the default `auto` window; the same reference owns the rationale.
+Pi crewmate launches carry `--exclude-tools` for the primary extension tools; the [Pi adapter reference](../.agents/skills/harness-adapters/references/harness/pi.md) owns that flag.
 
 ## Crew dispatch profiles (config/crew-dispatch.json)
 
@@ -504,6 +522,8 @@ Firstmate passes its profile line unless it states a reason to override, such as
 
 The resolver and bootstrap copy an environment-provided key into a non-exported private variable and unset `TYPESAFE_API_KEY` before launching child processes, so the secret is absent from child environments.
 The resolver sends the key to `curl` only as a header read from a file descriptor, never on argv, and nothing prints, logs, or writes it.
+Every resolved call also appends one JSON line to the home's gitignored `data/dispatch-resolve.jsonl` recording the UTC time, task id, project, status, confidence, matched rule, chosen profile or non-clear reason, and the call's latency and token counts; the API key, the brief text, and the request body are never recorded, and the off path and exit-2 configuration errors write nothing because they are not calls.
+A failed log write prints one stderr line and never blocks the intake or changes the outcome.
 The resolver fixes the endpoint at `https://api.typesafe.ai`, model at `jev-latest`, confidence floor at 0.6, and request timeout at 5 seconds; `TYPESAFE_API_KEY` is its only resolver-specific environment setting.
 The live rule-match evidence is recorded in [`verification/dispatch-resolve.md`](verification/dispatch-resolve.md).
 
@@ -578,6 +598,7 @@ This section is the single owner of the canonical schema.
       "version_args": ["<optional args that make it print its version, default --version>"],
       "announce_pattern": "<optional extended regex matching the tool's own update announcement>",
       "announce_args": ["<optional args for the command that carries that announcement, default version_args>"],
+      "version_url": "<optional https URL whose body carries the newest published version>",
       "git": {
         "repo": "<optional absolute path to a local clone>",
         "remote": "<optional remote name, default origin>",
@@ -593,6 +614,19 @@ A `command` entry gives the `PATH` comparison above, and adding `announce_patter
 A tool does not always announce a new release on the command that prints its version: `no-mistakes --version` prints only the version, while its other commands carry the announcement.
 `announce_args` names the command to search for the announcement in that case, and it is asked only of the copy `PATH` resolves; without it the version probe's own output is searched.
 An `announce_pattern` that is not a usable extended regular expression stops `arm`, and during a sweep it is reported as that one tool's own check failure so one broken pattern never stops the other watched tools from being checked.
+A tool whose CLI never announces its own updates can name a `version_url` instead: the document is fetched read-only with `curl` inside the same probe bound, the first dotted number in its body is the published version, and `update available` is reported when that is newer than the version `PATH` resolves.
+Claude Code is the shipped example, because its `--version` prints only the version and its release channel is a plain-text document; the exact entry is:
+
+```json
+{
+  "name": "claude",
+  "command": "claude",
+  "version_args": ["--version"],
+  "version_url": "https://downloads.claude.ai/claude-code-releases/latest"
+}
+```
+
+A home running the Claude Code supervision-branch mod should carry that entry, because the mod refuses to load on any Claude Code version other than its pin and this check is what turns a new release into the pin-bump procedure in [`docs/claude-supervision-branch.md`](claude-supervision-branch.md).
 A `git` entry reports how many commits the local clone is behind its remote branch, and stays silent when the clone is current or ahead.
 An omitted `branch` uses the remote's default branch, taken from the clone's own record of it and otherwise asked of the remote directly, so a `--single-branch` clone still resolves.
 Both probe kinds are read-only and bounded, and a probe that cannot answer is reported as a check failure rather than assumed current.
diff --git a/docs/fm-test-portable-shards.md b/docs/fm-test-portable-shards.md
index c7d6be3..f6d601e 100644
--- a/docs/fm-test-portable-shards.md
+++ b/docs/fm-test-portable-shards.md
@@ -61,6 +61,7 @@ The serial hints were refreshed from successful per-script records in the `fm-te
 Together these cover all 176 serial scripts at refresh time; retain the slower successful sample where both exist.
 The native-Windows-only `tests/fm-pi-windows-shell-invocation.test.sh` retains its separate 5121 ms measurement from 2026-09-06T21:02Z instead of a portable capability skip.
 An unfinished or failed invocation is not a healthy duration sample.
+The three `tests/fm-branch-claude-mod*.test.sh` hints and the `tests/fm-branch-mod-bin.test.sh` hint, plus the `tests/fm-precompact-skills.test.sh`, `tests/fm-promote.test.sh`, and `tests/fm-trace-span-lib.test.sh` hints, are local measurements from 2026-09-16 doubled, pending their first green CI artifacts.
 A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
 Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
 Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
diff --git a/docs/verification/dispatch-resolve.md b/docs/verification/dispatch-resolve.md
index 5815219..4068e7b 100644
--- a/docs/verification/dispatch-resolve.md
+++ b/docs/verification/dispatch-resolve.md
@@ -61,6 +61,7 @@ It proves the absent key (environment and `.env`) prints one stderr line, nothin
 It proves absent, default-only, and empty-rules files return `no rules to match` without a model or quota request, while a broken rules-file symlink exits 2 as unreadable.
 It proves the documented starter configuration resolves its Pi default through the declared Claude provider, a `.env` key turns the tool on, and the environment wins over it.
 It proves the key is absent from child environments, never appears on `curl` argv, and arrives only as the bearer header on the descriptor.
+It proves every resolved outcome appends exactly one JSON line to the home's `data/dispatch-resolve.jsonl` carrying the outcome's own fields and never the key or the brief text, that the off path and exit-2 usage and configuration errors append nothing, and that a failed log write leaves the stdout block and the exit code untouched.
 It proves the request uses the fixed endpoint and model, carries only the project, brief, and rule Choice with one option per rule plus the fixed neutral none option, and never carries `why`, `use`, or quota.
 It proves the clear, fixed-floor ambiguous with candidate evidence, escalate (approval with candidate evidence, unverifiable rule floor, tie, nothing rankable), known rule-floor fall-through, known and unverifiable profile-floor evidence, explicit-provider and provider-ID enforcement, authoritative Agy and explicit-provider Gemini routing, partial providers, eligible unranked candidates and their clear-result note, concrete quota vetoes and profile-floor shortfalls taking precedence over uncertainty, account-wide quota veto, limiting-bound ranking, missing-curl and quota-axi failures, HTTP 429 and 500, transport failure, malformed usage, zero-mass or malformed probabilities or confidence, malformed or duplicate profile, invalid selector, removed-option rejection, and out-of-range rule ID paths behave as the contract states, with configuration errors exiting 2 before any network call.
 `tests/fm-bootstrap.test.sh` proves bootstrap ignores resolver-only fields without the typed key, validates each malformed shape when the environment or home `.env` activates typed resolution, and prevents an environment-provided key from reaching child processes.
