"""Run matched, unchanged behavior cases under base and target test teardown.
Only the dispatch list is shortened; every selected case's assertions execute.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

ROOT = Path('/home/cti/.no-mistakes/worktrees/f9a83591f83e/01M4HEBAYE6CFDB95S5V1EST5V')
EVIDENCE = Path('/home/cti/.no-mistakes/evidence/01M4HEBAYE6CFDB95S5V1EST5V')
TMP = ROOT / '.nm-supervision-benchmark-tmp'
CASES = [
    'test_attended_routine_wake_is_handled_on_the_engine_and_stays_off_main',
    'test_attended_captain_outcome_reaches_main_through_branch_outcomes',
    'test_captain_leaving_mid_turn_keeps_its_captain_outcome_for_the_return',
    'test_quiet_record_without_its_daemon_is_a_present_captain',
    'test_claude_stop_hook_runs_the_host_without_the_file_and_off_opts_out',
    'test_away_wake_is_handled_on_the_engine_and_never_reaches_main',
]

def snapshot(label, case, tmp):
    processes = []
    table = subprocess.check_output(['ps', '-eo', 'pid=,ppid=,stat='], text=True)
    for row in table.splitlines():
        pid, ppid, state = row.split()
        if state.startswith('Z'):
            continue
        try:
            environ = (Path('/proc') / pid / 'environ').read_bytes().split(b'\0')
            home = next((entry[8:].decode() for entry in environ if entry.startswith(b'FM_HOME=')), '')
            if not home.startswith(tmp + '/fm-supervision-host.'):
                continue
            args = (Path('/proc') / pid / 'cmdline').read_bytes().split(b'\0')
            names = [Path(arg.decode(errors='replace')).name for arg in args]
            programs = [name for name in names if name in ('fm-supervision-host.sh', 'fm-watch.sh', 'fm-watch-arm.sh', 'fm-claude-stop-autoarm.sh')]
            if not programs and names[0] != 'claude':
                continue
            processes.append({'pid': int(pid), 'ppid': int(ppid), 'program': programs[0] if programs else 'claude', 'home': home})
        except OSError:
            continue
    result = {'version': label, 'completed_case': case, 'active_home_count': len({p['home'] for p in processes}),
              'active_helper_count': len(processes), 'active_helpers': processes}
    with (EVIDENCE / 'cleanup-comparison.jsonl').open('a') as output:
        output.write(json.dumps(result) + '\n')
    print('CLEANUP_CHECKPOINT ' + json.dumps(result), flush=True)

if len(sys.argv) > 1 and sys.argv[1] == 'snapshot':
    snapshot(*sys.argv[2:])
    raise SystemExit(0)

TMP.mkdir()
(EVIDENCE / 'cleanup-comparison.jsonl').write_text('')
results = []
for label in ('base', 'target'):
    source = subprocess.check_output(['git', 'show', 'cccc756f28cf67396963143a5aadc07e4559a4de:tests/fm-supervision-host.test.sh'], cwd=ROOT, text=True) if label == 'base' else (ROOT / 'tests/fm-supervision-host.test.sh').read_text()
    first_dispatch = re.search(r'^((?:run_case )?test_claude_stop_hook_restores_handoff_when_successor_closed_before_exit_to_main)$', source, re.M)
    if first_dispatch is None:
        raise RuntimeError('Cannot locate executable dispatch boundary')
    body = source[:first_dispatch.start()]
    temp_script = ROOT / f'tests/.nm-cleanup-{label}.test.sh'
    temp_root = TMP / label
    temp_root.mkdir()
    dispatch = []
    for case in CASES:
        dispatch.extend([('run_case ' if label == 'target' else '') + case,
                         'sleep 0.5',
                         f'python3 {EVIDENCE / "benchmark-cleanup.py"} snapshot {label} {case} {temp_root}'])
    temp_script.write_text(body + '\n'.join(dispatch) + '\n')
    env = dict(os.environ)
    for key in list(env):
        if key.startswith('FM_') or key in ('TMUX', 'TMUX_PANE', 'BASH_ENV'):
            del env[key]
    env['TMPDIR'] = str(temp_root)
    command = ['bin/fm-test-run.sh', '--jobs', '1', '--json', str(EVIDENCE / f'cleanup-{label}-timing.json'), str(temp_script.relative_to(ROOT))]
    started = time.monotonic()
    try:
        with (EVIDENCE / f'cleanup-{label}.log').open('w') as log:
            proc = subprocess.Popen(command, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            for line in proc.stdout:
                log.write(f'[{time.monotonic() - started:8.3f}s] {line}')
                log.flush()
                if not line.startswith('CLEANUP_CHECKPOINT '):
                    print(label + ': ' + line.rstrip(), flush=True)
            code = proc.wait()
        results.append({'version': label, 'exit_code': code, 'elapsed_seconds': round(time.monotonic() - started, 3), 'command': command})
    finally:
        temp_script.unlink()
    if code:
        break
(EVIDENCE / 'cleanup-comparison-summary.json').write_text(json.dumps(results, indent=2) + '\n')
print(json.dumps(results, indent=2), flush=True)
# Registered fixtures perform their own teardown; remove the now-empty scratch parent.
if not any(TMP.rglob('*')):
    TMP.rmdir()
raise SystemExit(1 if any(r['exit_code'] for r in results) else 0)
