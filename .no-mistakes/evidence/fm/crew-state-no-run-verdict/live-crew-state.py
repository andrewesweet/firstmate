#!/usr/bin/env python3
"""Drive the real crew-state, no-mistakes CLI, and private tmux endpoint.

Oracle: the author's acceptance contract. The zero-run verdict must reach
pane/status-log without either inventory call. Mismatched or absent fields
must preserve attribution through the real inventory. SQLite rows and semantic
busy events are disposable input records; no pipeline or model is started.
The transparent CLI wrapper logs actual output and injects branch/run races.
"""
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import time

ROOT = Path.cwd()
EVIDENCE = Path('~/.no-mistakes/evidence/01M54W5CFZRN9BZXG7VFH5PBA2')
FIXTURE = ROOT / '.test-crew-state/live'
REPO = FIXTURE / 'repo'
NM = FIXTURE / 'nm'
LAB = ROOT / '.l'
BASE = ROOT / 'bin/.crew-state-live-base.sh'
REAL_NM = shutil.which('no-mistakes')
WORKER_RUN = '01A99999999999999999999999'
BRANCH = 'fm/lab-no-run'
OTHER = 'fm/lab-other'
LOG = EVIDENCE / 'live-crew-state-transcript.log'
RESULTS = []
env = os.environ.copy()
for key in ('FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE',
            'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'TMUX', 'TMUX_PANE'):
    env.pop(key, None)
env.update(NM_HOME=str(NM), FM_HOME=str(LAB), TMUX_TMPDIR=str(LAB/'tmux'))

def run(args, *, cwd=ROOT, check=True, environment=None):
    result = subprocess.run([str(a) for a in args], cwd=cwd,
                            env=environment or env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode:
        raise RuntimeError(f'{args}: {result.returncode}: {result.stderr} {result.stdout}')
    return result

def note(message):
    with LOG.open('a') as f:
        f.write(message + '\n')
    print(message, flush=True)

def seed_worker():
    with sqlite3.connect(NM/'state.sqlite') as db:
        db.execute('INSERT OR REPLACE INTO runs '
                   '(id,repo_id,branch,head_sha,base_sha,status,created_at,updated_at) '
                   'VALUES (?,?,?,?,?,?,?,?)',
                   (WORKER_RUN,'crew-state-live',BRANCH,HEAD,HEAD,'failed',NOW+100,NOW+100))

def no_worker():
    with sqlite3.connect(NM/'state.sqlite') as db:
        db.execute('DELETE FROM runs WHERE id=?',(WORKER_RUN,))

def drive(name, mode, expected, source, script=ROOT/'bin/fm-crew-state.sh', busy=False):
    calls = EVIDENCE / f'{name}-calls.jsonl'
    calls.write_text('')
    scenario_env = env | {'PATH': str(FIXTURE/'observe')+os.pathsep+env['PATH'],
                          'LAB_MODE': mode, 'LAB_CALLS': str(calls)}
    run([ROOT/'bin/fm-busy-event.sh','apply',LAB/'state','live','busy' if busy else 'idle',
         '--current-gen','--source','fm-recovery','--event','validation-record'])
    result = run([script,'live'], environment=scenario_env)
    observed = [json.loads(line) for line in calls.read_text().splitlines()]
    note(f'\n{name}\n$ {script.relative_to(ROOT)} live\n{result.stdout.strip()}')
    for call in observed:
        note(f"real no-mistakes {' '.join(call['args'])}: exit {call['exit']}\n{call['stdout'].strip()}")
    assert f'state: {expected} · source: {source}' in result.stdout, result.stdout
    return observed

LOG.write_text('Real no-mistakes v1.96.0; disposable SQLite input records; real private tmux endpoint.\n'
               'No pipeline initialization/control, real fleet state, or credentials accessed.\n'
               'Fault injection delegates every command to the genuine CLI without rewriting its output.\n')
try:
    assert REAL_NM
    if FIXTURE.exists():
        shutil.rmtree(FIXTURE)
    REPO.mkdir(parents=True)
    NM.mkdir()
    run(['git','init','-q','-b',BRANCH],cwd=REPO)
    run(['git','-c','user.name=Validation','-c','user.email=validation@example.invalid',
         'commit','-q','--allow-empty','-m','Disposable validation fixture'],cwd=REPO)
    # A read-only CLI query creates its disposable state schema, but refuses the
    # unregistered repository. Seed a repository record as test input; never init
    # or start another gate/pipeline.
    run([REAL_NM,'axi','status'],cwd=REPO,check=False)
    with sqlite3.connect(NM/'state.sqlite') as db:
        db.execute('INSERT INTO repos (id,working_path,upstream_url,created_at) VALUES (?,?,?,?)',
                   ('crew-state-live',str(REPO),'https://example.invalid/disposable/crew-state.git',int(time.time())))
    assert not LAB.exists(), 'Refuse to reuse an existing lab home'
    run([ROOT/'bin/fm-lab-home.sh','create',LAB])
    (LAB/'tmux').mkdir()
    assert len(str(LAB/'tmux'/f'tmux-{os.getuid()}'/'fm-lab')) < 108
    run(['tmux','-f','/dev/null','-L','fm-lab','new-session','-d','-s','primary','-n','fm-live',
         '-c',ROOT,'-x','120','-y','35','sleep 300'])
    endpoint = run(['tmux','-L','fm-lab','display-message','-p','-t','primary',
                    '#{socket_path} #{window_width}x#{window_height} #{pane_current_command}']).stdout.strip()
    env['TMUX'] = run(['tmux','-L','fm-lab','display-message','-p','-t','primary',
                       '#{socket_path},#{pid},0']).stdout.strip()
    note('Private tmux endpoint: '+endpoint)
    note('Inherited socket selection: '+env['TMUX'])
    # This is an input endpoint for a read-only CLI check, not an agent primary.
    # Its semantic state is supplied through the real public recovery-event writer.
    (LAB/'state/live.meta').write_text(f'window=primary:fm-live\nbackend=tmux\nworktree={REPO}\nkind=ship\nharness=claude\n')
    (LAB/'state/live.status').write_text('working: implementation continues\n')
    run([ROOT/'bin/fm-busy-event.sh','arm',LAB/'state','live','--state','idle',
         '--source','fm-recovery','--event','validation-record'])
    HEAD = run(['git','rev-parse','HEAD'],cwd=REPO).stdout.strip()
    NOW = int(time.time())
    run(['git','branch',OTHER],cwd=REPO)
    with sqlite3.connect(NM/'state.sqlite') as db:
        for i in range(47):
            db.execute('INSERT INTO runs (id,repo_id,branch,head_sha,base_sha,status,created_at,updated_at) '
                       'VALUES (?,?,?,?,?,?,?,?)',
                       (f'01A{i:023d}','crew-state-live',f'fm/unrelated-{i}',HEAD,HEAD,'cancelled',NOW-i,NOW-i))
    (FIXTURE/'observe').mkdir(exist_ok=True)
    wrapper = FIXTURE/'observe/no-mistakes'
    wrapper.write_text('''#!/usr/bin/env python3
import json, os, sqlite3, subprocess, sys
args=sys.argv[1:]
mode=os.environ['LAB_MODE']
initial=args==['axi','status']
if initial and mode=='branch-switch':
    subprocess.run(['git','checkout','-q',os.environ['LAB_OTHER']],check=True)
try:
    result=subprocess.run([os.environ['LAB_REAL_NM'],*args],stdout=subprocess.PIPE)
finally:
    if initial and mode=='branch-switch':
        subprocess.run(['git','checkout','-q',os.environ['LAB_BRANCH']],check=True)
with open(os.environ['LAB_CALLS'],'a') as f:
    f.write(json.dumps({'args':args,'exit':result.returncode,'stdout':result.stdout.decode()})+'\\n')
sys.stdout.buffer.write(result.stdout)
sys.stdout.buffer.flush()
if initial and mode=='run-arrival':
    with sqlite3.connect(os.environ['NM_HOME']+'/state.sqlite') as db:
        db.execute('INSERT INTO runs (id,repo_id,branch,head_sha,base_sha,status,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?)',
            (os.environ['LAB_RUN'],'crew-state-live',os.environ['LAB_BRANCH'],os.environ['LAB_HEAD'],os.environ['LAB_HEAD'],'failed',int(os.environ['LAB_NOW'])+100,int(os.environ['LAB_NOW'])+100))
sys.exit(result.returncode)
''')
    wrapper.chmod(0o755)
    env.update(LAB_REAL_NM=REAL_NM,LAB_BRANCH=BRANCH,LAB_OTHER=OTHER,LAB_HEAD=HEAD,
               LAB_NOW=str(NOW),LAB_RUN=WORKER_RUN)
    note('Fixtures: 47 unrelated run rows; no worker-branch row at initial status read.')
    calls=drive('matching-zero-idle','none','working','status-log')
    assert [c['args'] for c in calls] == [['axi','status']]
    RESULTS.append({'name':'Matching zero-run verdict reaches the current status log without inventory','result':'pass','live':True})
    calls=drive('matching-zero-busy','none','working','pane',busy=True)
    assert [c['args'] for c in calls] == [['axi','status']]
    RESULTS.append({'name':'Matching zero-run verdict preserves the semantic busy pane source','result':'pass','live':True})
    calls=drive('no-run-race','run-arrival','working','status-log')
    assert [c['args'] for c in calls] == [['axi','status']]
    RESULTS.append({'name':'A run arriving after the zero-run answer cannot override it through a later ledger read','result':'pass','live':True})
    ledger = run([REAL_NM,'runs','--limit','1'],cwd=REPO).stdout
    assert BRANCH in ledger and 'failed' in ledger
    note('Newly arrived conflicting row, independently read after crew-state returned:\n'
         '$ no-mistakes runs --limit 1\n'+ledger.strip())
    # Regression counterfactual: same end-user interface from the base commit.
    BASE.write_text(run(['git','show','66c300bdf5f5f338a6fc4918a89c9d1525dcb7e3:bin/fm-crew-state.sh']).stdout)
    BASE.chmod(0o755)
    no_worker()
    try:
        drive('base-counterfactual','run-arrival','working','status-log',script=BASE)
    except AssertionError:
        note('Base counterfactual rejected the required fallback, as expected; target passes the same race.')
    else:
        raise AssertionError('The regression counterfactual unexpectedly passed')
    seed_worker()
    calls=drive('mismatched-current-branch','branch-switch','failed','run-step')
    assert f'current_branch: {OTHER}' in calls[0]['stdout']
    assert 'runs_on_current_branch: 0' in calls[0]['stdout']
    assert any(c['args']==['axi'] for c in calls)
    assert any(c['args']==['axi','status','--run',WORKER_RUN] for c in calls)
    RESULTS.append({'name':'A zero-run answer for a different branch still selects the worker run from inventory','result':'pass','live':True})
    calls=drive('missing-zero-run-fields','none','failed','run-step')
    assert 'runs_on_current_branch:' not in calls[0]['stdout']
    assert any(c['args']==['axi'] for c in calls)
    RESULTS.append({'name':'A status payload without zero-run fields preserves inventory attribution','result':'pass','live':True})
    (EVIDENCE/'live-crew-state-results.json').write_text(json.dumps(RESULTS,indent=2)+'\n')
    note('\nAll live scenarios passed.')
finally:
    if LAB.exists():
        stopped=run(['tmux','-L','fm-lab','kill-server'],check=False)
        note(f'Private tmux teardown exit: {stopped.returncode}')
        shutil.rmtree(LAB)
    BASE.unlink(missing_ok=True)
