from pathlib import Path
import os, subprocess, tempfile, time, shutil, json
ROOT=Path.cwd()
E=Path('/home/cti/.no-mistakes/evidence/01M5C3GEKDK8HPR2Q6E8D3M0DF')
lab=Path(tempfile.mkdtemp(prefix='.fm-lab-',dir=ROOT))
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_', 'HERDR_')) or k in ['CLAUDE_CODE_SESSION_ID','TMUX','TMUX_PANE']:
        env.pop(k,None)
env.update(FM_HOME=str(lab),FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='0',FM_HEARTBEAT='0',FM_HEARTBEAT_MAX='0',CLAUDE_CODE_SESSION_ID='lab-session-a',TMUX=str(E/'absent-lab-socket')+',0,0')
active=[]
log=open(E/'live-recovery.log','w',buffering=1)
def note(s):
    print(s,flush=True); print(s,file=log,flush=True)
def run(args, check=True):
    p=subprocess.run(args,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30,cwd=ROOT)
    note('$ '+' '.join(map(str,args))+'\n'+p.stdout+f'[exit {p.returncode}]')
    if check: assert p.returncode==0,p.stdout
    return p
state=lab/'state'
def read(name):
    p=state/name
    return p.read_text().strip() if p.exists() else ''
def snapshot(label):
    note(label+': '+json.dumps({n:read(n) for n in ['.watcher-down','.watcher-down.announce-seq','.wake-queue.seq','.wake-queue']}))
def append(key):
    run(['bash','-c','. bin/fm-wake-lib.sh; fm_wake_append check "$1" "check: $1"','_',key])
def start(label):
    out=open(E/(label+'.log'),'w')
    p=subprocess.Popen(['bin/fm-watch.sh'],env=env,cwd=ROOT,stdout=out,stderr=subprocess.STDOUT)
    active.append((p,out)); return p

def surfaced(label):
    p=start(label); p.wait(timeout=20)
    text=(E/(label+'.log')).read_text()
    note(label+': '+text.strip()+f' [exit {p.returncode}]')
    assert p.returncode==0 and 'check: rearm-resurface' in text,text
    return read('.watcher-down')

def quiet(label,expected):
    check=state/'.last-check'; heart=state/'.last-heartbeat'
    oldc=check.stat().st_mtime_ns if check.exists() else 0
    oldh=heart.stat().st_mtime_ns if heart.exists() else 0
    before=len(read('check-runs').splitlines())
    p=start(label)
    deadline=time.monotonic()+20
    while time.monotonic()<deadline:
        assert p.poll() is None,(E/(label+'.log')).read_text()
        if (check.exists() and heart.exists() and check.stat().st_mtime_ns>oldc and heart.stat().st_mtime_ns>oldh and len(read('check-runs').splitlines())>=before+2): break
        time.sleep(.2)
    else: raise AssertionError('check/heartbeat cadence failed to advance')
    assert read('.watcher-down')==expected,(expected,read('.watcher-down'))
    p.terminate(); p.wait(timeout=10)
    text=(E/(label+'.log')).read_text()
    note(label+': '+json.dumps({'output':text,'marker':read('.watcher-down'),'check_mtime_ns':check.stat().st_mtime_ns,'heartbeat_mtime_ns':heart.stat().st_mtime_ns,'registered_check_runs':len(read('check-runs').splitlines())}))
    assert not text.strip(),text
    assert read('.watcher-down')==expected

try:
    run(['bin/fm-lab-home.sh','create',str(lab)])
    c=state/'cadence.check.sh'
    c.write_text('#!/usr/bin/env bash\nprintf "check executed\\n" >> "$FM_HOME/state/check-runs"\n')
    c.chmod(0o700)
    run(['bin/fm-check-register.sh','cadence'])
    append('original-work')
    first=surfaced('initial-announce')
    snapshot('initial announcement sidecar')
    record=(state/'.watcher-down.announce-seq').read_text().splitlines()
    assert record==[read('.wake-queue.seq'),'lab-session-a'],record
    assert ((state/'.watcher-down.announce-seq').stat().st_mode & 0o777)==0o600
    quiet('same-session-restart-1',first)
    quiet('same-session-restart-2',first)
    note('PASS same-session restarts retain generation and execute real registered checks and heartbeat scans')
    # Ack exactly the generation announced before both restarts, using public drain.
    generation=first.rsplit(':',1)[1]
    run(['bin/fm-wake-drain.sh'])
    run(['bin/fm-wake-drain.sh','--ack-through','1','--recovery-generation',generation])
    assert read('.watcher-down') in ['acked:downtime:'+generation,'acked:handling:'+generation]
    assert not read('.wake-queue')
    snapshot('acknowledgement after two restarts')
    note('PASS between-restart acknowledgement consumes original row and retires original generation')
    # Append genuine new work after the previous announcement/acknowledgement.
    append('late-work')
    late_initial=surfaced('post-ack-new-work')
    append('after-announcement-work')
    late=surfaced('late-row-resurface')
    assert late!=late_initial and late!=first
    quiet('late-row-repeat-restart',late)
    snapshot('late work surfaced once')
    note('PASS appended work resurfaces under a fresh generation once')
    env['CLAUDE_CODE_SESSION_ID']='lab-session-b'
    replay=surfaced('new-session-replay')
    assert replay!=late
    quiet('new-session-repeat-restart',replay)
    snapshot('new session replayed once')
    note('PASS new session replays unhandled work once and later same-session restarts remain quiet')
    # Old presentations must not retire the replayed generation.
    stale=run(['bin/fm-wake-drain.sh','--ack-through','1','--recovery-generation',generation],check=False)
    assert 'newer recovery episode is pending' in stale.stdout
    assert read('.watcher-down')==replay
    assert 'late-work' in read('.wake-queue')
    note('PASS stale acknowledgement cannot retire the newer recovery or late queued work')
    # Migration record missing: one conservative replay, then stable.
    (state/'.watcher-down.announce-seq').unlink()
    migrated=surfaced('missing-sidecar-replay')
    assert migrated!=replay
    quiet('missing-sidecar-repeat-restart',migrated)
    note('PASS missing legacy announce record replays once then stabilizes')
    note('ALL LIVE WATCHER SCENARIOS PASSED')
finally:
    for p,out in active:
        if p.poll() is None:
            p.terminate()
            try: p.wait(timeout=10)
            except subprocess.TimeoutExpired: p.kill(); p.wait()
        out.close()
    # Detached summary writer is bounded; wait for its pid if it remains.
    time.sleep(1)
    shutil.rmtree(lab)
    note('Disposable lab removed; no default backend session used.')
    log.close()
