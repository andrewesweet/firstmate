"""Exercise emitted brief and backlog refusal interfaces with real CLIs.
Oracle: supplied author intent and recorded hold-kind/home-aware-remedy decisions.
No harness, tasks-axi, tmux, treehouse, or product implementation is replaced.
"""
import json, os, pathlib, re, shlex, shutil, subprocess, traceback
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('~/.no-mistakes/evidence/01M6WQ9Y0RTHQGB86GCH0D2517')
SCRATCH = ROOT / '.live-validation' / 'matrix'
SCRATCH.mkdir(parents=True)
ENV = os.environ.copy()
for key in list(ENV):
    if key.startswith(('FM_', 'TASKS_AXI_', 'CLAUDE_', 'TREEHOUSE_')) or key in ('TMUX','HERDR_ENV','CODEX_HOME'):
        ENV.pop(key, None)
for name in ('user', 'tmp', 'cache', 'config', 'local-data'):
    (SCRATCH / name).mkdir()
ENV.update(HOME=str(SCRATCH/'user'), TMPDIR=str(SCRATCH/'tmp'), XDG_CACHE_HOME=str(SCRATCH/'cache'), XDG_CONFIG_HOME=str(SCRATCH/'config'), XDG_DATA_HOME=str(SCRATCH/'local-data'), TMUX=str(SCRATCH/'absent-socket')+',999,0')
LOG = (EVIDENCE/'live-cli-transcript.log').open('w')
RESULTS=[]
def run(args, home=None, cwd=ROOT, expected=0, record=True):
    env=ENV.copy()
    if home: env['FM_HOME']=str(home)
    p=subprocess.run([str(x) for x in args], cwd=cwd, env=env, text=True, capture_output=True, timeout=45)
    if record:
        LOG.write(f'cwd: {cwd}\nFM_HOME: {home}\n$ {shlex.join([str(x) for x in args])}\nexit: {p.returncode}\n{p.stdout}{p.stderr}\n')
        LOG.flush()
    if expected is not None:
        assert p.returncode == expected, f'{args}: expected {expected}, got {p.returncode}: {p.stdout}{p.stderr}'
    return p.stdout+p.stderr

def make_home(name):
    home=SCRATCH/name
    run([ROOT/'bin/fm-lab-home.sh','create',home])
    (home/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\ndone_keep = 100\n')
    return home

def task(home,*args,cwd=ROOT):
    return run([ROOT/'bin/fm-tasks-axi.sh',*args],home,cwd)

def show(home,id):
    out=task(home,'show',id)
    return {k: v.strip().strip('"') for k,v in re.findall(r'^  ([a-z_]+): (.*)$',out,re.M)}

def add(home,id,state='queued',blocker=None,hold=None):
    args=['add',id,'Disposable validation work','--kind','ship']
    if blocker: args+=['--blocked-by',blocker]
    task(home,*args)
    if state=='in_flight': task(home,'start',id)
    if state=='done': task(home,'done',id)
    if hold: task(home,'hold',id,'--kind',hold,'--reason','Disposable validation condition')
    run([ROOT/'bin/fm-brief.sh',id,'sample','--mode','no-mistakes'],home)
    brief=home/'data'/id/'brief.md'
    brief.write_text(brief.read_text().replace('{TASK}','Validate isolated backlog refusals.').replace('{PUBLISHED_INTENT}','Explain backlog refusals in words.').replace('{FIRSTMATE_SPEC}','Refuse without launching a worker.'))

def refuse(home,id,base=False):
    before=show(home,id)
    worktrees=run(['git','-C',PROJECT,'worktree','list','--porcelain'],record=False)
    entry=ROOT/'bin'/('.live-base-spawn.sh' if base else 'fm-spawn.sh')
    out=run([entry,id,PROJECT,'--mode','no-mistakes','--yolo','off','--backend','tmux','--harness','claude'],home,expected=1)
    assert 'not dispatchable' in out
    assert not (home/'state'/f'{id}.meta').exists(), 'Refusal published worker metadata'
    assert not (SCRATCH/'absent-socket').exists(), 'Refusal created an endpoint'
    assert run(['git','-C',PROJECT,'worktree','list','--porcelain'],record=False)==worktrees, 'Refusal created a worktree'
    assert show(home,id)==before, 'Refusal changed task data'
    LOG.write(f'Observed: {id} task data unchanged; no worker metadata, endpoint socket, or additional git worktree.\n\n')
    return out

def scenario(name,fn):
    try:
        fn()
        RESULTS.append(dict(name=name,result='pass',live=True,evidence='live-cli-transcript.log',reason=''))
        print('PASS:',name,flush=True)
    except Exception as e:
        LOG.write(traceback.format_exc()); LOG.flush()
        RESULTS.append(dict(name=name,result='fail',live=True,evidence='live-cli-transcript.log',reason=str(e)))
        print('FAIL:',name,str(e),flush=True)

HOME=make_home('home')
OTHER=make_home('other-home')
PROJECT=SCRATCH/'project'; PROJECT.mkdir()
run(['git','-C',PROJECT,'init','-q','-b','main'])
run(['git','-C',PROJECT,'-c','user.name=Validation','-c','user.email=validation@example.invalid','commit','-q','--allow-empty','-m','Disposable validation fixture'])

# These are the two historical entrypoints, loaded by git from the stated base.
# Their dependency libraries are unchanged between base and target.
BASE_FILES=[]
for stem in ('spawn','brief'):
    file=ROOT/'bin'/f'.live-base-{stem}.sh'; BASE_FILES.append(file)
    file.write_text(subprocess.check_output(['git','show',f'77fcdf09a5e50906f32dc98de14fc55d40badd7f:bin/fm-{stem}.sh'],text=True))
    file.chmod(0o700)
try:
    def briefs():
        required=('Check your own background job by its PID (`kill -0 <pid>`)','its exit status','a file it writes when done','never by `pgrep -f` or `pkill -f` on a pattern your polling command also contains',"including inside `ssh host '...'`",'the polling shell matches itself')
        run([ROOT/'bin/.live-base-brief.sh','base-brief','sample','--mode','no-mistakes'],HOME)
        baseline=(HOME/'data/base-brief/brief.md').read_text()
        assert required[0] not in baseline
        LOG.write('Base regression reproduced: emitted ship brief lacks the background-job ownership instruction.\n')
        for wait in (False,True):
            flag=HOME/'config/wait-no-turns'
            if wait: flag.touch()
            else: flag.unlink(missing_ok=True)
            for mode in ('no-mistakes','direct-PR','local-only','direct-push','scout'):
                id=f'brief-{mode.lower()}-wait-{int(wait)}'
                args=['--scout'] if mode=='scout' else ['--mode',mode]
                run([ROOT/'bin/fm-brief.sh',id,'sample',*args],HOME)
                text=(HOME/'data'/id/'brief.md').read_text()
                for phrase in required:
                    assert phrase in text, f'{mode}, wait={wait}: missing {phrase}'
                line=next(line for line in text.splitlines() if required[0] in line)
                LOG.write(f'Emitted public instruction ({mode}, wait-no-turns={wait}):\n{line}\n\n')
                if mode in ('no-mistakes','scout'):
                    shutil.copyfile(HOME/'data'/id/'brief.md',EVIDENCE/f'{id}.md')
        # Apply the three documented ownership-based checks to actual short jobs.
        shell='''set -eu
sleep 0.2 & job_pid=$!
while kill -0 "$job_pid" 2>/dev/null; do sleep 0.05; done
wait "$job_pid"
printf 'PID check: owned job %s exited; polling ended\\n' "$job_pid"
(set +e; exit 7) & job_pid=$!
set +e
wait "$job_pid"; job_status=$?
set -e
[ "$job_status" -eq 7 ]
printf 'Exit status check: owned job returned %s\\n' "$job_status"
(sleep 0.2; printf 'completed\\n' > "$1") & job_pid=$!
while [ ! -f "$1" ]; do sleep 0.05; done
wait "$job_pid"
printf 'Completion file check: '; cat "$1"
'''
        run(['bash','-c',shell,'owned-jobs',SCRATCH/'job-completion'],HOME)
    scenario('Generated ship/scout instructions cover PID, exit status, and completion files across delivery modes and wait settings',briefs)

    def captain():
        for state in ('queued','in_flight'):
            id=f'captain-{state}'; add(HOME,id,state,hold='captain')
            if state=='queued':
                baseline=refuse(HOME,id,base=True)
                assert 'state queued yes no' in baseline and 'fm-captain-hold.sh answer' not in baseline
                LOG.write('Base regression reproduced: captain-held row emits a raw tuple and no remedy.\n')
            out=refuse(HOME,id)
            assert 'held for the captain' in out
            match=re.search(r'with (bin/fm-captain-hold.sh answer .*? --decision-file <path> --release) to release',out)
            assert match, 'Missing captain remedy'
            decision=SCRATCH/f'{id}-decision.txt'; decision.write_text('Release this disposable validation item.\n')
            args=shlex.split(match[1].replace('<path>',str(decision))); args[0]=str(ROOT/args[0])
            run(args,HOME)
            row=show(HOME,id)
            assert row['held']=='no' and row['state']==state
            assert 'Release this disposable validation item.' in row['body']
    scenario('Captain-held queued and in-flight work refuses safely and the emitted answer/release remedy works',captain)

    def holds():
        for kind in ('external','load','parked','future'):
            for state in ('queued','in_flight'):
                id=f'{kind}-{state}'
                blocker=f'{id}-blocker' if state=='queued' else None
                if blocker: add(HOME,blocker)
                add(HOME,id,state,blocker=blocker,hold=kind)
                out=refuse(HOME,id)
                assert f'hold of kind {kind}' in out
                assert 'fm-captain-hold.sh answer' not in out
                if blocker: assert f'bin/fm-tasks-axi.sh unblock {id} --by <blocker>' in out
                add(OTHER,id,state,hold=kind)
                match=re.search(r'release it with (bin/fm-tasks-axi.sh unhold [a-z_-]+)',out)
                assert match
                args=shlex.split(match[1]); args[0]=str(ROOT/args[0])
                run(args,HOME,cwd=OTHER)
                row=show(HOME,id); other=show(OTHER,id)
                assert row['held']=='no' and row['state']==state
                assert other['held']=='yes' and other['hold_kind']==kind
                assert row['blocked']==('yes' if blocker else 'no')
                LOG.write(f'Observed: suggested unhold releases only {kind}/{state} in FM_HOME; same-ID task in caller home remains held; dependency preserved.\n\n')
    scenario('External/load/parked/future holds identify their kind in both states and unhold only the selected home, preserving blockers',holds)

    def blocked():
        id='dependency-work'; blocker='dependency-blocker'
        for home in (HOME,OTHER):
            add(home,blocker); add(home,id,blocker=blocker)
        out=refuse(HOME,id)
        assert 'blocked by its blocked_by dependency' in out
        match=re.search(r'for example (bin/fm-tasks-axi.sh unblock .*? --by <blocker>)',out)
        assert match
        args=shlex.split(match[1].replace('<blocker>',blocker)); args[0]=str(ROOT/args[0])
        run(args,HOME,cwd=OTHER)
        row=show(HOME,id); other=show(OTHER,id)
        assert row['blocked']=='no' and row['state']=='queued'
        assert other['blocked']=='yes' and other['blocked_by']==blocker
        LOG.write('Observed: suggested unblock clears only FM_HOME dependency; same-ID task in caller home remains blocked.\n\n')
    scenario('Dependency-blocked dispatch explains the blocker and its suggested remedy targets FM_HOME from another home',blocked)

    def done():
        id='finished-work'; add(HOME,id,state='done')
        out=refuse(HOME,id)
        assert 'it is done (there is nothing left to dispatch)' in out
    scenario('Dispatching completed work says nothing remains to dispatch and creates no worker resources',done)
finally:
    for file in BASE_FILES: file.unlink(missing_ok=True)
    LOG.write('Cleanup: historical entrypoints removed; isolated matrix fixtures removed.\n')
    LOG.close()
    shutil.rmtree(SCRATCH)
    (EVIDENCE/'live-results.json').write_text(json.dumps(RESULTS,indent=2)+'\n')
print(json.dumps(RESULTS,indent=2))
raise SystemExit(any(result['result']!='pass' for result in RESULTS))
