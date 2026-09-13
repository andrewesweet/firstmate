"""Run real lifecycle scripts using existing isolated pane fixtures and a real HTTP receiver."""
import http.server
import json
import os
from pathlib import Path
import subprocess
import threading

root = Path.cwd()
evidence = Path(__file__).parent
(root / '.phase-tmp').mkdir(exist_ok=True)
requests = []
class Receiver(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append({'path': self.path, 'content_type': self.headers['Content-Type'], 'body': body})
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{}')
    def log_message(self, *_):
        pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Receiver)
threading.Thread(target=server.serve_forever, daemon=True).start()
# Reuse fixture definitions without invoking the suite's test list.
source = (root / 'tests/fm-trace-context-spawn.test.sh').read_text().split('\ntest_enabled_records_and_injects_identical_carrier_before_launch\n')[0]
runner = root / 'tests/.phase-lifecycle.sh'
runner.write_text(source + r'''
set -e
rec=$(make_spawn_case http-lifecycle)
read_case_record "$rec"
: > "$HOME_DIR/config/trace-context"
start_trace_session "$HOME_DIR"
rm "$FAKEBIN_DIR/curl"
printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
printf '$ fm-spawn.sh %s <isolated-project> --mode local-only --yolo off\n' "$CASE_ID"
FM_TEST_SPAWN_NO_MODE=1 run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR" --mode local-only --yolo off
cp "$HOME_DIR/state/$CASE_ID.meta" "$EVIDENCE/task-before-cleanup.meta"
cp "$LAUNCH_LOG" "$EVIDENCE/pane-launch.txt"
printf 'done: lifecycle evidence complete\n' > "$HOME_DIR/state/$CASE_ID.status"
printf '$ fm-teardown.sh %s\n' "$CASE_ID"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" PATH="$FAKEBIN_DIR:$PATH" "$ROOT/bin/fm-teardown.sh" "$CASE_ID"
[ ! -e "$HOME_DIR/state/$CASE_ID.meta" ]
printf 'Task metadata removed after cleanup.\n'
''')
try:
    env = dict(os.environ, TMPDIR=str(root / '.phase-tmp'), EVIDENCE=str(evidence), OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=f'http://127.0.0.1:{server.server_port}/v1/traces')
    result = subprocess.run(['bash', str(runner)], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (evidence / 'lifecycle-transcript.txt').write_text('Real fm-spawn.sh and fm-teardown.sh; fake tmux/treehouse, real git fixture and curl/HTTP receiver. No live harness or MLflow server.\n\n' + result.stdout)
    (evidence / 'otlp-requests.json').write_text(json.dumps(requests, indent=2) + '\n')
    print(result.stdout)
    assert result.returncode == 0, result.returncode
    spans = [r['body']['resourceSpans'][0]['scopeSpans'][0]['spans'][0] for r in requests]
    assert [s['name'] for s in spans] == ['firstmate.spawn', 'firstmate.task'], spans
    child, task = spans
    assert child['traceId'] == task['traceId']
    assert child['parentSpanId'] == task['spanId']
    assert 'parentSpanId' not in task
    assert task['status']['code'] == 1
    meta = dict(line.split('=', 1) for line in (evidence / 'task-before-cleanup.meta').read_text().splitlines() if '=' in line)
    assert task['spanId'] == meta['traceparent'].split('-')[2]
    assert int(task['startTimeUnixNano']) == int(meta['trace_started']) * 1000000
    assert all(r['path'] == '/v1/traces' and r['content_type'] == 'application/json' for r in requests)
    print('HTTP receiver captured linked spawn and task root; carrier identity, mint timestamp, OK status, and metadata cleanup verified.')
finally:
    runner.unlink(missing_ok=True)
    server.shutdown()
    server.server_close()
    (root / '.phase-tmp').rmdir()
