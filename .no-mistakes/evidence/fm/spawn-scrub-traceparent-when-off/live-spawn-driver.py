import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time

ROOT = Path.cwd()
EVIDENCE = Path('~/.no-mistakes/evidence/01M5NZVNSVXWZ7G4SDZ9TAAX4Z')
AMBIENT = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'
RESOURCE = 'service.name=trace-live,custom.attribute=preserved'
BASE = Path(tempfile.mkdtemp(prefix='.trace-live-', dir=ROOT))
env = os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key.startswith('TASKS_AXI_') or key in ('TMUX', 'TMUX_PANE', 'HERDR_ENV', 'HERDR_SESSION', 'HERDR_SOCKET_PATH', 'CLAUDECODE', 'CODEX_THREAD_ID', 'TREEHOUSE_ROOT', 'TREEHOUSE_WORKTREE_PATH'):
        env.pop(key, None)
env.update(HOME=str(BASE / 'user'), XDG_CONFIG_HOME=str(BASE / 'user/config'), XDG_DATA_HOME=str(BASE / 'user/data'), XDG_CACHE_HOME=str(BASE / 'user/cache'), SHELL='/bin/bash', TRACEPARENT=AMBIENT, OTEL_RESOURCE_ATTRIBUTES=RESOURCE, TRACE_LIVE_SECRET='must-not-cross-allowlist', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
Path(env['HOME']).mkdir()
log = (EVIDENCE / 'live-spawn-transcript.log').open('w')
results = []

def run(args, *, check=True, current=None, extra=None):
    actual_env = env | (extra or {})
    p = subprocess.run([str(a) for a in args], cwd=current or ROOT, env=actual_env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=100)
    log.write('$ ' + shlex.join([str(a) for a in args]) + '\n' + p.stdout + f'\nexit={p.returncode}\n')
    log.flush()
    if check and p.returncode:
        raise RuntimeError(p.stdout)
    return p.stdout

try:
    for decision, allowlist in [('off', False), ('off', True), ('on', False), ('on', True)]:
        label = f'{decision}-allowlist-{int(allowlist)}'
        case = BASE / label
        case.mkdir()
        lab = case / 'home'
        run(['bin/fm-lab-home.sh', 'create', lab])
        socketdir = run(['bin/fm-lab-home.sh', 'tmux-dir', lab]).strip()
        env.update(FM_HOME=str(lab), TMUX_TMPDIR=socketdir, TREEHOUSE_ROOT=str(case / 'pool'))
        if allowlist:
            (lab / 'config/launch-env-allowlist').write_text('OTEL_RESOURCE_ATTRIBUTES\nTRACEPARENT\n')
        (lab / 'config/backlog-backend').write_text('manual\n')
        (lab / 'state/.lock').write_text(str(os.getpid()) + '\n')
        (lab / 'state/.trace-context-effective').write_text(f'{os.getpid()} {decision}\n')
        (lab / 'state/.last-watcher-beat').touch()
        project = case / 'project'
        run(['git', 'init', '-b', 'main', project])
        (project / 'README.md').write_text('Disposable live trace test project.\n')
        run(['git', 'add', 'README.md'], current=project)
        run(['git', '-c', 'user.name=Live Test', '-c', 'user.email=live@example.invalid', 'commit', '-m', 'fixture'], current=project)
        probe = case / 'observe.py'
        probe.write_text("import json,os,pathlib,time\np=pathlib.Path(" + repr(str(case / 'observations.jsonl')) + ")\nr={k:os.environ.get(k) for k in ['TRACEPARENT','OTEL_RESOURCE_ATTRIBUTES','TRACE_LIVE_SECRET','COMPACT_ADVISER_DISABLE','FM_TASK_ID']}\nr['pid']=os.getpid()\nr['cwd']=os.getcwd()\nwith p.open('a') as f:f.write(json.dumps(r)+'\\n')\nprint('WORKER_ENV '+json.dumps(r),flush=True)\n")
        launch = shlex.join([shutil.which('python3'), str(probe)])
        run(['tmux', '-L', 'fm-lab', '-f', '/dev/null', 'new-session', '-d', '-s', 'firstmate', '-x', '120', '-y', '40', '-c', project, '/bin/bash --noprofile --norc'])
        try:
            run(['tmux', '-L', 'fm-lab', 'show-environment', '-g', 'TRACEPARENT'])
            run(['tmux', '-L', 'fm-lab', 'set-option', '-g', 'default-shell', '/bin/bash'])
            run(['tmux', '-L', 'fm-lab', 'set-option', '-g', 'default-command', '/bin/bash --noprofile --norc'])
            tmux_value = run(['tmux', '-L', 'fm-lab', 'display-message', '-p', '-t', 'firstmate:0', '#{socket_path},#{pid},#{session_id}']).strip().replace(',$', ',')
            env['TMUX'] = tmux_value
            task = f'trace-live-{os.getpid()}-{label}'
            brief_dir = lab / 'data' / task
            brief_dir.mkdir()
            (brief_dir / 'brief.md').write_text("# Task\n## Captain's intent\nObserve the launched process environment.\n\n## Firstmate spec\nRecord trace and resource attributes, then exit.\n")
            run(['bin/fm-spawn.sh', task, project, '--mode', 'local-only', '--yolo', 'off', '--backend', 'tmux', launch])
            observations = case / 'observations.jsonl'
            deadline = time.monotonic() + 15
            while not observations.exists() and time.monotonic() < deadline:
                time.sleep(0.2)
            if not observations.exists():
                run(['tmux', '-L', 'fm-lab', 'capture-pane', '-p', '-t', f'firstmate:fm-{task}', '-S', '-100'])
                raise RuntimeError('worker observation missing')
            observed = json.loads(observations.read_text().splitlines()[0])
            meta = (lab / 'state' / f'{task}.meta').read_text()
            carrier = next((x.split('=', 1)[1] for x in meta.splitlines() if x.startswith('traceparent=')), None)
            assert observed['TRACEPARENT'] == carrier, (observed, carrier)
            assert (carrier is None) == (decision == 'off'), carrier
            if carrier:
                assert carrier != AMBIENT
                assert carrier.split('-')[1] != AMBIENT.split('-')[1]
            assert observed['OTEL_RESOURCE_ATTRIBUTES'] == RESOURCE, observed
            assert observed['TRACE_LIVE_SECRET'] == (None if allowlist else 'must-not-cross-allowlist'), observed
            assert observed['COMPACT_ADVISER_DISABLE'] == '1', observed
            run(['tmux', '-L', 'fm-lab', 'capture-pane', '-p', '-t', f'firstmate:fm-{task}', '-S', '-100'])
            results.append(dict(scenario=label, ambient=AMBIENT, recorded_carrier=carrier, worker=observed, result='pass'))
            # Re-enter an already stopped task through the real relaunch interface.
            if decision == 'off' and not allowlist:
                run(['tmux', '-L', 'fm-lab', 'send-keys', '-t', f'firstmate:fm-{task}', f'export TRACEPARENT={AMBIENT}', 'Enter'])
                run(['bin/fm-spawn.sh', task, '--relaunch', '--harness', launch])
                deadline = time.monotonic() + 10
                while len(observations.read_text().splitlines()) < 2 and time.monotonic() < deadline:
                    time.sleep(0.2)
                replay = json.loads(observations.read_text().splitlines()[1])
                assert replay['TRACEPARENT'] is None, replay
                results.append(dict(scenario='off-relaunch', worker=replay, result='pass'))
        finally:
            run(['tmux', '-L', 'fm-lab', 'kill-server'], check=False)
            env.pop('TMUX', None)
            run(['bin/fm-lab-home.sh', 'teardown', lab])
        print(label + ': pass', flush=True)
finally:
    (EVIDENCE / 'live-worker-environments.json').write_text(json.dumps(results, indent=2) + '\n')
    log.close()
    for directory, _, _ in os.walk(BASE):
        os.chmod(directory, 0o700)
    shutil.rmtree(BASE)
