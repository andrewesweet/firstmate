import os, subprocess, pathlib, json, sqlite3, time, shutil, hashlib, signal
ROOT=pathlib.Path.cwd()
EVIDENCE=pathlib.Path('/home/andre/.no-mistakes/evidence/01M47GDMMHP9GND9V4JZHAAQ9G')
BASE=ROOT/'t'/'live'
BASE.mkdir(exist_ok=True)
HOME=BASE/'home'
baseenv=os.environ.copy()
for k in list(baseenv):
    if k.startswith(('FM_', 'HERDR_', 'TASKS_AXI_')) or k in ['NO_MISTAKES_GATE','TYPESAFE_API_KEY','TMUX']:
        baseenv.pop(k)
baseenv.update(FM_HOME=str(HOME), HOME=str(BASE/'account'), NM_HOME=str(BASE/'nm'), TMPDIR=str(BASE), XDG_CONFIG_HOME=str(BASE/'config'), XDG_RUNTIME_DIR=str(BASE/'runtime'), FM_HERDR_LAB_STATE_DIR=str(BASE/'herdr-state'))
for key in ['HOME','NM_HOME','XDG_CONFIG_HOME','XDG_RUNTIME_DIR']:
    pathlib.Path(baseenv[key]).mkdir(exist_ok=True)
LOG=(EVIDENCE/'live-cli.log').open('w')
results=[]
processes=[]
def log(s):
    print(s,flush=True); LOG.write(s+'\n'); LOG.flush()
def run(args, expected=0, env=None, cwd=ROOT, input=None, timeout=45):
    log('$ '+subprocess.list2cmdline([str(a) for a in args]))
    p=subprocess.run(args,cwd=cwd,env=env or baseenv,input=input,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    log(p.stdout.rstrip()); log('exit='+str(p.returncode))
    if expected is not None: assert p.returncode==expected, p.stdout
    return p

def check(name, fn):
    log('\nSCENARIO: '+name)
    try: fn(); result='pass'; reason=''
    except Exception as e: result='fail'; reason=str(e); log('CHECK FAILURE: '+reason)
    results.append(dict(name=name,result=result,reason=reason))
run(['bin/fm-lab-home.sh','create',str(HOME)])
(HOME/'data'/'backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')

def briefs():
    run(['bin/fm-brief.sh','base-proof','sandbox','--mode','no-mistakes','--base-branch','release/next'])
    f=HOME/'data/base-proof/brief.md'; body=f.read_text()
    assert 'Base branch: release/next' in body
    assert 'release/next' in body
    log("Named-base output:\n"+"\n".join(line for line in body.splitlines() if "release/next" in line or "merge " in line))
    body=body.replace('{TASK}', 'Private request: preserve internal billing notes.').replace('{FIRSTMATE_SPEC}','Preserve existing ledger schema.').replace('{PUBLISHED_INTENT}','Start this task from release/next and preserve spend attribution.')
    f.write_text(body)
    run(['git','init','-q','-b','main',str(BASE/'project')])
    shutil.copyfile(f,EVIDENCE/'named-base-brief.md')
    log('\n'.join(line for line in body.splitlines() if 'Base branch:' in line or 'git merge ' in line or 'Published intent' in line or 'private file' in line))
    p=run(['bin/fm-brief.sh','invalid-base','sandbox','--mode','local-only','--base-branch','release/next'],expected=None)
    assert p.returncode!=0 and not (HOME/'data/invalid-base/brief.md').exists()
    p=run(['bin/fm-spawn.sh','base-proof',str(BASE/'project'), '--mode','no-mistakes','--yolo','off','--base-branch','main'],expected=None)
    assert p.returncode!=0 and 'must record Base branch: main' in p.stdout
check('Named base brief preserves private/published sections and rejects an unsupported delivery',briefs)

def holds():
    reason='Choose release (billing)\nKeep the original reason & evidence.'
    run(['bin/fm-captain-hold.sh','hold','hold-proof','--title','Release choice','--reason',reason])
    run(['bin/fm-captain-hold.sh','hold','hold-proof','--reason',reason])
    before=run(['bin/fm-tasks-axi.sh','show','hold-proof']).stdout
    log('Serialized held backlog:\n'+(HOME/'data/backlog.md').read_text())
    assert 'billing' in before
    answer=BASE/'answer.txt'; answer.write_text('Use release/next; retain the ledger.\n')
    run(['bin/fm-captain-hold.sh','answer','hold-proof','--decision-file',str(answer)])
    after=run(['bin/fm-tasks-axi.sh','show','hold-proof']).stdout
    assert 'Use release/next; retain the ledger.' in after
    assert 'billing' in after
    run(['bin/fm-captain-hold.sh','answer','hold-proof','--decision-file',str(answer)])
    shutil.copyfile(HOME/'data/backlog.md',EVIDENCE/'hold-backlog.md')
check('Hold with parentheses and newline survives answer-close and exact retry',holds)

def spend():
    run(['bin/fm-pipeline-spend.sh','record','not-a-task'])
    assert not (HOME/'data/pipeline-spend.jsonl').exists()
    (HOME/'config/pipeline-spend').touch()
    (HOME/'state/spend-proof.meta').write_text('kind=ship\nharness=codex\nspawn_gen=live-spend-gen\nworktree='+str(BASE/'gone')+'\n')
    run(['bin/fm-pipeline-spend.sh','record','spend-proof','fm/spend-proof'])
    run(['bin/fm-pipeline-spend.sh','record','spend-proof','fm/spend-proof'])
    ledger=HOME/'data/pipeline-spend.jsonl'; rows=ledger.read_text().splitlines(); assert len(rows)==1
    rec=json.loads(rows[0]); assert rec['source']=='unavailable' and rec['total'] is None
    log('Pipeline ledger:\n'+ledger.read_text())
    run(['bin/fm-spend-ledger-append.sh','spend-proof'])
    run(['bin/fm-spend-ledger-append.sh','spend-proof'])
    files=list((HOME/'data').glob('*spend*')); log('Independent spend records: '+str([p.name for p in files]))
    shutil.copyfile(ledger,EVIDENCE/'pipeline-spend-unavailable.jsonl')
check('Opt-in spend records missing inventory truthfully once, preserving independent worker ledger',spend)

def slots():
    config=pathlib.Path(baseenv['XDG_CONFIG_HOME'])/'firstmate'; config.mkdir()
    limit=config/'nm-max-concurrent-validations'; limit.write_text('1\n')
    db=sqlite3.connect(pathlib.Path(baseenv['NM_HOME'])/'state.sqlite')
    db.executescript('CREATE TABLE runs (id TEXT,status TEXT,awaiting_agent_since INTEGER); CREATE TABLE step_results (run_id TEXT,step_name TEXT,status TEXT);')
    db.execute("INSERT INTO runs VALUES ('busy-other-home','running',NULL)"); db.execute("INSERT INTO step_results VALUES ('busy-other-home','review','running')"); db.commit()
    run(['bin/fm-nm-slot.sh','bash','-c','printf admitted'],expected=75)
    db.execute("UPDATE runs SET awaiting_agent_since=123"); db.commit()
    assert 'admitted' in run(['bin/fm-nm-slot.sh','bash','-c','printf admitted']).stdout
    limit.write_text('bogus\n'); run(['bin/fm-nm-slot.sh','bash','-c','printf should-not-run'],expected=78)
    db.close()
check('Host cap blocks an executing run, admits a parked gate, and refuses malformed cap',slots)

def delta():
    path=HOME/'state/remote.status'; path.write_text('first\n')
    cursor=hashlib.sha256(path.read_bytes()).hexdigest()
    path.write_text('first\nsecond\n')
    p=run(['bin/fm-remote-delta-read.sh','state/remote.status','6',cursor,'0'])
    assert 'second' in p.stdout
    path.write_text('other\nsecond\n')
    p=run(['bin/fm-remote-delta-read.sh','state/remote.status','6',cursor,'0'])
    assert 'continuity' in p.stdout or 'break' in p.stdout
    p=run(['bin/fm-remote-delta-read.sh','../secret','0',hashlib.sha256(b'').hexdigest(),'0'],expected=None)
    assert p.returncode!=0
check('Remote delta returns complete appended line and detects prefix replacement and traversal',delta)

def remote_worker():
    env=baseenv.copy(); env.update(FM_REMOTE_JOB_STATE_ROOT=str(BASE/'queue'), FM_ROOT_OVERRIDE=str(ROOT), FM_REMOTE_JOB_POLL_SECONDS='0.1')
    code='. bin/fm-remote-job-lib.sh; fm_remote_job_stage "$HOME" "$PWD" "$FM_HOME" fm-remote-delta-read.sh state/remote.status 0 '+hashlib.sha256(b'').hexdigest()+' 0'
    ident=run(['bash','-c',code],env=env).stdout.strip().splitlines()[-1]
    job=BASE/'queue/jobs'/ident
    out=(EVIDENCE/'remote-worker.log').open('w')
    worker=subprocess.Popen(['bin/fm-remote-job-worker.sh','--serve'],env=env,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
    processes.append(worker)
    try:
        for _ in range(180):
            if (job/'state').exists() and (job/'state').read_text().strip()=='done': break
            time.sleep(.1)
        assert (job/'state').read_text().strip()=='done'
        assert (job/'exit').read_text().strip()=='0'
        log('Published remote job state='+ (job/'state').read_text().strip()+' exit='+ (job/'exit').read_text().strip())
        log('Remote job stdout:\n'+(job/'stdout').read_text())
        assert 'second' in (job/'stdout').read_text()
        log('Worker remained alive after completion: '+str(worker.poll() is None)); assert worker.poll() is None
    finally:
        worker.terminate(); worker.wait(timeout=15); out.close()
check('Real remote worker stages and publishes an isolated delta job without turning over',remote_worker)

def watcher():
    (HOME/'state/remote.status').unlink()
    env=baseenv.copy(); env.update(FM_POLL='0.2',FM_SIGNAL_GRACE='0', FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999')
    (HOME/'state/watch-proof.meta').write_text('kind=ship\nwindow=private:fm-watch-proof\nbackend=tmux\nendpoint_task_id=watch-proof\nspawn_gen=watch-gen\n')
    (HOME/'state/watch-proof.status').write_text('')
    env['TMUX']=str(ROOT/'t/private-socket')+',0,0'
    log('$ bin/fm-watch-arm.sh (tracked process)')
    out=(EVIDENCE/'watch-owner.log').open('w')
    arm=subprocess.Popen(['bin/fm-watch-arm.sh'],env=env,stdout=out,stderr=subprocess.STDOUT,start_new_session=True); processes.append(arm)
    try:
        for _ in range(150):
            if (HOME/'state/.last-watcher-beat').exists(): break
            if arm.poll() is not None: break
            time.sleep(.1)
        assert arm.poll() is None, (EVIDENCE/'watch-owner.log').read_text()
        log('$ bin/fm-watch-arm.sh (attached tracked process)')
        attached=subprocess.Popen(['bin/fm-watch-arm.sh'],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True); processes.append(attached)
        time.sleep(.5)
        (HOME/'state/watch-proof.status').write_text('needs-decision: release approval required\n')
        second=attached.communicate(timeout=20)[0]; log(second)
        arm.wait(timeout=20); out.flush()
        owner=(EVIDENCE/'watch-owner.log').read_text(); log(owner)
        assert arm.returncode==0 and attached.returncode==0
        assert 'watch-proof.status' in owner and 'watch-proof.status' in second
        queue=HOME/'state/.wake-queue'; log('Durable wake queue:\n'+queue.read_text())
        assert any('watch-proof.status' in line for line in queue.read_text().splitlines())
    finally:
        run(['bin/fm-watch-arm.sh','--stop'],env=env,expected=None)
        if arm.poll() is None: arm.terminate(); arm.wait(timeout=10)
        out.close()
check('Two watcher arms return the same status wake without a false empty-cycle failure',watcher)

def exclusion():
    (HOME/'state/.branch-mod-mode').write_text('on\n')
    (HOME/'config/supervision-host').touch()
    env=baseenv.copy(); env.update(FM_POLL='0.2',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_SIGNAL_GRACE='0',TMUX=str(ROOT/'t/private-socket')+',0,0')
    out=(EVIDENCE/'supervision-exclusion.log').open('w')
    host=subprocess.Popen(['bin/fm-supervision-host.sh','park'],env=env,stdout=out,stderr=subprocess.STDOUT,start_new_session=True); processes.append(host)
    try:
        for _ in range(150):
            if 'steps aside' in (EVIDENCE/'supervision-exclusion.log').read_text(): break
            time.sleep(.1)
        assert 'steps aside' in (EVIDENCE/'supervision-exclusion.log').read_text()
        (HOME/'state/watch-proof.status').write_text('needs-decision: host must leave this wake to the mod\n')
        host.wait(timeout=25); out.flush(); log((EVIDENCE/'supervision-exclusion.log').read_text())
        assert host.returncode==0
        assert not (HOME/'state/.supervision-host-engine').exists()
    finally:
        run(['bin/fm-watch-arm.sh','--stop'],env=env,expected=None)
        if host.poll() is None: host.terminate(); host.wait(timeout=10)
        out.close()
check('Enabling branch mod makes supervision host step aside into one ordinary watcher',exclusion)

try:
    for p in processes:
        if p.poll() is None: p.terminate(); p.wait(timeout=15)
finally:
    (EVIDENCE/'live-results.json').write_text(json.dumps(results,indent=2))
    shutil.rmtree(BASE)
    LOG.close()
