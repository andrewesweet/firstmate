#!/usr/bin/env python3
"""Drive the real crew-state CLI with disposable records and a private tmux.

Oracle: the author's exact-basename contract. Foreign records must not change
another task's reading; matching captures must remain authoritative. No product
commands, endpoint probes, or busy-state writers are mocked.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path('~/.no-mistakes/worktrees/5ac353bebe94/01M54NF7FAK33AVF9TVBAP55YG')
EVIDENCE = Path('~/.no-mistakes/evidence/01M54NF7FAK33AVF9TVBAP55YG')
LAB = ROOT / '.lv'
assert not LAB.exists(), f'Refusing existing fixture: {LAB}'
env = {k: v for k, v in os.environ.items() if not k.startswith('FM_')}
for key in ('TMUX', 'TMUX_PANE', 'HERDR_SESSION', 'GIT_DIR', 'GIT_COMMON_DIR', 'GIT_WORK_TREE'):
    env.pop(key, None)
env.update(FM_HOME=str(LAB), TMUX_TMPDIR=str(LAB / 'tmux'), HISTFILE='/dev/null', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
results = []
tmux = ['tmux', '-L', 'fm-lab']

def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], cwd=ROOT, env=env, text=True,
                          capture_output=True, timeout=20, check=True, **kwargs).stdout.strip()

def meta(path, *, missing=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    wt = LAB / ('missing-worktree' if missing else 'task-worktree')
    path.write_text(f'window=records:fm-lab-task\nworktree={wt}\nkind=scout\nharness=claude\nbackend=tmux\n')

def drive(name, task, expected, *, meta_override=None, status_override=None, cwd=None, baseline=False):
    child_env = env.copy()
    if meta_override is not None:
        child_env['FM_CREW_STATE_META_OVERRIDE'] = str(meta_override)
    if status_override is not None:
        child_env['FM_CREW_STATE_STATUS_OVERRIDE'] = str(status_override)
    command = LAB / 'baseline-bin/fm-crew-state.sh' if baseline else ROOT / 'bin/fm-crew-state.sh'
    proc = subprocess.run([str(command), task], cwd=cwd or ROOT, env=child_env,
                          text=True, capture_output=True, timeout=20)
    observed = proc.stdout.strip()
    row = {'name': name, 'task': task, 'meta_override': str(meta_override),
           'status_override': str(status_override), 'exit_code': proc.returncode,
           'expected': expected, 'observed': observed,
           'stderr': proc.stderr.strip(), 'pass': proc.returncode == 0 and observed == expected,
           'product': 'base commit' if baseline else 'target commit'}
    results.append(row)
    print(f'{name}\n  $ {command.relative_to(ROOT)} {task}\n  {observed}', flush=True)
    assert row['pass'], json.dumps(row, indent=2)
    return observed

try:
    print(run([ROOT / 'bin/fm-lab-home.sh', 'create', LAB]), flush=True)
    (LAB / 'tmux').mkdir()
    (LAB / 'task-worktree').mkdir()
    run([*tmux, '-f', '/dev/null', 'new-session', '-d', '-s', 'records', '-n', 'fm-lab-task',
         '-x', '100', '-y', '30', '-c', ROOT, 'bash --noprofile --norc'])
    env['TMUX'] = run([*tmux, 'display-message', '-p', '-t', 'records', '#{socket_path},#{pid},0'])
    print('Private tmux endpoint: ' + run([*tmux, 'display-message', '-p', '-t', 'records',
          '#{session_name}:#{window_name} #{pane_width}x#{pane_height}']), flush=True)
    state, snapshot = LAB / 'state', LAB / 'snapshot captures'
    snapshot.mkdir()
    for task in ('task-a', 'task-b'):
        meta(state / f'{task}.meta')
        (state / f'{task}.status').write_text(f'working: own {task}\n')
        run([ROOT / 'bin/fm-busy-event.sh', 'arm', state, task, '--state', 'idle',
             '--source', 'claude-hook', '--event', 'stop'])
    meta(snapshot / 'task-a.meta')
    (snapshot / 'task-a.status').write_text('paused: captured task-a\n')
    meta(snapshot / 'foreign-task.meta', missing=True)
    (snapshot / 'foreign-task.status').write_text('blocked: foreign task\n')
    own_a = 'state: working · source: status-log · own task-a'
    own_b = 'state: working · source: status-log · own task-b'
    captured = 'state: paused · source: status-log · captured task-a'
    gone = 'state: unknown · source: none · worktree gone (torn down?)'

    drive('No overrides: own records', 'task-a', own_a)
    drive('Foreign metadata alone ignored', 'task-a', own_a, meta_override=snapshot / 'foreign-task.meta')
    drive('Foreign status alone ignored', 'task-a', own_a, status_override=snapshot / 'foreign-task.status')
    drive('Both foreign overrides ignored', 'task-a', own_a,
          meta_override=snapshot / 'foreign-task.meta', status_override=snapshot / 'foreign-task.status')
    # Make the matching capture observably different from the current generation.
    meta(snapshot / 'task-a.meta', missing=True)
    drive('Matching metadata alone honoured', 'task-a', gone, meta_override=snapshot / 'task-a.meta')
    meta(snapshot / 'task-a.meta')
    drive('Matching status alone honoured', 'task-a', captured, status_override=snapshot / 'task-a.status')
    meta(state / 'task-a.meta', missing=True)
    drive('Matching captured generation overrides changed live metadata', 'task-a', captured,
          meta_override=snapshot / 'task-a.meta', status_override=snapshot / 'task-a.status')
    drive('Matching metadata and foreign status resolved independently', 'task-a', own_a,
          meta_override=snapshot / 'task-a.meta', status_override=snapshot / 'foreign-task.status')
    meta(state / 'task-a.meta')
    drive('Foreign metadata and matching status resolved independently', 'task-a', captured,
          meta_override=snapshot / 'foreign-task.meta', status_override=snapshot / 'task-a.status')
    drive('Relative matching paths honoured', 'task-a', captured,
          meta_override=Path('snapshot captures/task-a.meta'), status_override=Path('snapshot captures/task-a.status'), cwd=LAB)
    drive('Bare matching basenames honoured', 'task-a', captured,
          meta_override='task-a.meta', status_override='task-a.status', cwd=snapshot)
    for basename in ('prefix-task-a', 'task-a-extra', 'TASK-A'):
        meta(snapshot / f'{basename}.meta', missing=True)
        (snapshot / f'{basename}.status').write_text('blocked: lookalike foreign record\n')
        drive(f'Lookalike {basename} rejected', 'task-a', own_a,
              meta_override=snapshot / f'{basename}.meta', status_override=snapshot / f'{basename}.status')
    meta(snapshot / 'task-a.status', missing=True)
    drive('Wrong file extensions rejected independently', 'task-a', own_a,
          meta_override=snapshot / 'task-a.status', status_override=snapshot / 'task-a.meta')
    (snapshot / 'task-a.status').write_text('paused: captured task-a\n')
    # A later child inherits the same snapshot environment but requests a new id.
    for task, expected in [('task-a', captured), ('task-b', own_b), ('task-a', captured)]:
        drive(f'Inherited snapshot environment reads {task}', task, expected,
              meta_override=snapshot / 'task-a.meta', status_override=snapshot / 'task-a.status')
    drive('Missing own metadata never borrows foreign capture', 'absent-task',
          'state: unknown · source: none · no metadata for absent-task',
          meta_override=snapshot / 'task-a.meta', status_override=snapshot / 'task-a.status')
    drive('Matching missing metadata capture remains authoritative', 'task-a',
          'state: unknown · source: none · no metadata for task-a', meta_override=LAB / 'missing/task-a.meta')
    drive('Matching missing status capture does not use live status', 'task-a',
          'state: unknown · source: none · no current-state source available', status_override=LAB / 'missing/task-a.status')
    # Counterfactual: run the base CLI with unchanged libraries and identical data.
    baseline = LAB / 'baseline-bin'
    baseline.mkdir()
    for source in (ROOT / 'bin').iterdir():
        if source.name != 'fm-crew-state.sh':
            (baseline / source.name).symlink_to(source)
    source = run(['git', 'show', 'ce697402e662cd7f9d6ef5c367041dd51516eb49:bin/fm-crew-state.sh'])
    (baseline / 'fm-crew-state.sh').write_text(source + '\n')
    (baseline / 'fm-crew-state.sh').chmod(0o755)
    drive('Base reproduces foreign metadata poisoning', 'task-a', gone,
          meta_override=snapshot / 'foreign-task.meta', baseline=True)
    drive('Base reproduces foreign status poisoning', 'task-a',
          'state: blocked · source: status-log · foreign task',
          status_override=snapshot / 'foreign-task.status', baseline=True)
    print('All exact-basename behavioral checks passed; base reproduces both reported failures.', flush=True)
finally:
    stopped = subprocess.run([*tmux, 'kill-server'], env=env, capture_output=True, text=True)
    (EVIDENCE / 'crew-state-live-results.json').write_text(json.dumps(results, indent=2) + '\n')
    if LAB.exists():
        shutil.rmtree(LAB)
    print(f'Cleanup: private tmux stopped (exit {stopped.returncode}); disposable home removed={not LAB.exists()}', flush=True)
