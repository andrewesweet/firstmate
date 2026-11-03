#!/usr/bin/env bash
# tests/jev-fake-helpers.sh - the canned-answer TypeSafe shim the crew-wiki suites
# point FM_WIKI_JEV at, so no crew-wiki Jev test reaches the network or a live
# model. Sourced after tests/lib.sh.

unset FM_WIKI_JEV

# fm_fake_jev <fakebin> drops the canned-answer TypeSafe shim the crew-wiki
# tests point FM_WIKI_JEV at. It reads one request on stdin and answers the
# question it was asked, so no test reaches the network or a live model:
#   FM_FAKE_JEV_LOG=<file>      append "<question>\t<state-bytes>" per call
#   FM_FAKE_JEV_MODE=unavailable  the shim's own unavailable answer
#   FM_FAKE_JEV_MODE=error        no output and a non-zero exit
#   FM_FAKE_JEV_CHOICE=<id>     the choice to return (default: first criterion)
#   FM_FAKE_JEV_P=<probability> the noul answer (default 0.4)
# One fake serves every crew-wiki Jev test, so the shim's request and answer
# shapes stay the only ones under test.
fm_fake_jev() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/fm-jev-fake" <<'SH'
#!/usr/bin/env python3
"""Fake TypeSafe call shim for tests: answers the question it is asked."""
import json
import os
import sys
import time

try:
    request = json.load(sys.stdin)
except ValueError:
    request = {}
request_log = os.environ.get("FM_FAKE_JEV_REQUEST_LOG")
if request_log:
    with open(request_log, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(request) + "\n")
questions = request.get("questions") or {}
name = next(iter(questions), "")
log = os.environ.get("FM_FAKE_JEV_LOG")
if log:
    state = json.dumps(request.get("state") or {})
    with open(log, "a", encoding="utf-8") as handle:
        handle.write("%s\t%d\n" % (name, len(state)))
lock = os.environ.get("FM_FAKE_JEV_LOCK")
if lock:
    import fcntl
    with open(lock, "a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_SH | fcntl.LOCK_NB)
            status = "free"
        except BlockingIOError:
            status = "held"
    with open(lock + ".observed", "a") as handle:
        handle.write(status + "\n")
time.sleep(float(os.environ.get("FM_FAKE_JEV_DELAY", "0")))
mode = os.environ.get("FM_FAKE_JEV_MODE", "answer")
if mode == "unavailable":
    print(json.dumps({"ok": False, "unavailable": "no key", "model": "jev"}))
    sys.exit(0)
if mode == "error":
    sys.exit(3)
question = questions.get(name) or {}
criteria = question.get("criteria") or {}
if question.get("type") == "choice":
    choice = os.environ.get("FM_FAKE_JEV_CHOICE") or next(iter(criteria), "")
    others = max(1, len(criteria) - 1)
    probabilities = {key: (0.8 if key == choice else 0.2 / others) for key in criteria}
    answer = {"choice": choice, "probabilities": probabilities, "confidence": 0.6}
else:
    answer = {"noul": float(os.environ.get("FM_FAKE_JEV_P", "0.4"))}
print(json.dumps({"ok": True, "model": "jev", "answers": {name: answer},
                  "usage": {"input_tokens": 900}}))
SH
  chmod +x "$fakebin/fm-jev-fake"
}
