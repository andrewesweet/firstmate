import json
import os
from pathlib import Path
import signal
import subprocess
import threading
import time

ROOT = Path('/home/cti/.no-mistakes/worktrees/f9a83591f83e/01M4HEBAYE6CFDB95S5V1EST5V')
EVIDENCE = Path('/home/cti/.no-mistakes/evidence/01M4HEBAYE6CFDB95S5V1EST5V')
TMP = ROOT / '.nm-supervision-test-tmp'
TMP.mkdir()

def active_fixture_processes():
    processes = []
    table = subprocess.check_output(['ps', '-eo', 'pid=,ppid=,stat='], text=True)
    for row in table.splitlines():
        pid, ppid, state = row.split()
        if state.startswith('Z'):
            continue
        try:
            env = (Path('/proc') / pid / 'environ').read_bytes().split(b'\0')
            home = next((item[8:].decode() for item in env if item.startswith(b'FM_HOME=')), '')
            if not home.startswith(str(TMP) + '/fm-supervision-host.'):
                continue
            args = (Path('/proc') / pid / 'cmdline').read_bytes().split(b'\0')
            scripts = [Path(a.decode(errors='replace')).name for a in args if a.endswith(b'.sh')]
            processes.append({'pid': int(pid), 'ppid': int(ppid), 'state': state, 'home': home,
                              'program': scripts[0] if scripts else Path(args[0].decode(errors='replace')).name})
        except (OSError, StopIteration):
            continue
    return processes

env = dict(os.environ)
for key in list(env):
    if key.startswith('FM_') or key in ('TMUX', 'TMUX_PANE', 'BASH_ENV'):
        del env[key]
env['TMPDIR'] = str(TMP)
command = ['bin/fm-test-run.sh', '--jobs', '1', '--json', str(EVIDENCE / 'supervision-host-timing.json'),
           'tests/fm-supervision-host.test.sh']
start = time.monotonic()
proc = subprocess.Popen(command, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
lines = []
def record_output():
    with (EVIDENCE / 'supervision-host-suite.log').open('w') as log:
        for line in proc.stdout:
            elapsed = round(time.monotonic() - start, 3)
            lines.append({'elapsed_seconds': elapsed, 'output': line.rstrip()})
            log.write(f'[{elapsed:8.3f}s] {line}')
            log.flush()
            print(line.rstrip(), flush=True)
thread = threading.Thread(target=record_output)
thread.start()
samples = []
with (EVIDENCE / 'supervision-host-processes.jsonl').open('w') as output:
    while proc.poll() is None:
        registered = []
        for registry in TMP.glob('fm-supervision-host.*/homes'):
            try:
                registered.extend(registry.read_text().splitlines())
            except OSError:
                pass
        active = active_fixture_processes()
        sample = {'elapsed_seconds': round(time.monotonic() - start, 3), 'registered_homes': registered,
                  'active_processes': active, 'active_home_count': len({p['home'] for p in active})}
        samples.append(sample)
        output.write(json.dumps(sample) + '\n')
        output.flush()
        time.sleep(1)
thread.join()
time.sleep(3)
remaining = active_fixture_processes()
summary = {'command': command, 'exit_code': proc.returncode, 'elapsed_seconds': round(time.monotonic() - start - 3, 3),
           'case_passes': sum(line['output'].startswith('ok - ') for line in lines),
           'max_active_home_count': max((s['active_home_count'] for s in samples), default=0),
           'remaining_active_processes_after_exit': remaining}
(EVIDENCE / 'supervision-host-observation.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2), flush=True)
# Cleanup is deliberately limited to the exact process identities observed in this run.
for process in remaining:
    try:
        os.kill(process['pid'], signal.SIGTERM)
    except ProcessLookupError:
        pass
raise SystemExit(proc.returncode)
