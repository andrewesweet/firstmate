import os, pathlib, subprocess, tempfile, time, shutil, json, traceback
ROOT = pathlib.Path.cwd()
EVID = pathlib.Path('/home/cti/.no-mistakes/evidence/01M5CGF3ACMA45G6YFQV3T9Q56')
BASE = pathlib.Path(tempfile.mkdtemp(prefix='.l', dir=ROOT))
log = open(EVID / 'watcher-live-transcript.txt', 'a', buffering=1)
results = json.loads((EVID/'watcher-live-results.json').read_text()) if (EVID/'watcher-live-results.json').exists() else []
active = []
env = {k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','HERDR_ENV','HERDR_SESSION','CLAUDE_CODE_SESSION_ID','STATE','CONFIG')}
env.update(FM_BACKEND='tmux', TMPDIR=str(BASE))
socket = str(BASE / 's')
def say(s):
    print(s, flush=True); log.write(s+'\n')
def call(args, e=None, check=True):
    r = subprocess.run(args, cwd=ROOT, env=e or env, capture_output=True, text=True, timeout=40)
    if check and r.returncode: raise RuntimeError(f'{args}: {r.returncode}\n{r.stdout}\n{r.stderr}')
    return r

def home(label):
    p=BASE/label
    call(['bin/fm-lab-home.sh','create',str(p)])
    e=dict(env, FM_HOME=str(p), FM_POLL='1', FM_SIGNAL_GRACE='1', FM_CHECK_INTERVAL='0', FM_HEARTBEAT='0', FM_SECONDMATE_LIVENESS_SECS='99999999')
    return p, e

def read(p, name):
    q=p/'state'/name
    return q.read_text().strip() if q.exists() else '<missing>'
def snapshot(p):
    return {n:read(p,n) for n in ['.watcher-down','.watcher-down.announce-seq','.wake-queue.seq','.wake-queue','.heartbeat-streak','check-runs']}
def append(e, label):
    call(['bash','-c','. "$1"; fm_wake_append check "inbox:$2" "check: $2"','_',str(ROOT/'bin/fm-wake-lib.sh'),label],e)
def launch(e):
    p=subprocess.Popen(['bin/fm-watch.sh'],cwd=ROOT,env=e,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
    active.append(p)
    return p

def stop(p):
    if p.poll() is None: p.terminate()
    try: out,err=p.communicate(timeout=15)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, 9); out,err=p.communicate(timeout=5)
    active.remove(p)
    return out,err

def announce(p,e):
    proc=launch(e)
    try: out,err=proc.communicate(timeout=20)
    except subprocess.TimeoutExpired:
        stop(proc); raise AssertionError('watcher did not announce')
    active.remove(proc)
    say(f'fm-watch.sh exit={proc.returncode}: {out.strip()}')
    if err: say('stderr: '+err.strip())
    assert proc.returncode==0 and 'check: rearm-resurface' in out
    say(json.dumps(snapshot(p),sort_keys=True))
    return read(p,'.watcher-down')

def quiet(p,e,marker):
    before=p/'state'/'.last-check'
    hb=p/'state'/'.last-heartbeat'
    check_before=before.stat().st_mtime_ns if before.exists() else 0
    hb_before=hb.stat().st_mtime_ns if hb.exists() else 0
    runs_before=len(read(p,'check-runs').splitlines()) if (p/'state'/'check-runs').exists() else 0
    proc=launch(e)
    deadline=time.monotonic()+22
    try:
        while time.monotonic()<deadline:
            assert proc.poll() is None, 'restarted watcher exited'
            runs=len(read(p,'check-runs').splitlines()) if (p/'state'/'check-runs').exists() else 0
            if before.exists() and hb.exists() and before.stat().st_mtime_ns>check_before and hb.stat().st_mtime_ns>hb_before and runs>=runs_before+2:
                break
            time.sleep(.1)
        else: raise AssertionError('check or heartbeat cadence did not advance')
    finally: out,err=stop(proc)
    say(f'restart session={e.get("CLAUDE_CODE_SESSION_ID","absent")}: stdout={out!r}; stderr={err!r}')
    assert not out.strip(), out
    assert read(p,'.watcher-down')==marker
    say(f'.last-check mtime_ns: {check_before} -> {before.stat().st_mtime_ns}; .last-heartbeat mtime_ns: {hb_before} -> {hb.stat().st_mtime_ns}; custom-check runs: {runs_before} -> {runs}')
    say(json.dumps(snapshot(p),sort_keys=True))

def register(p,e):
    check=p/'state'/'cadence.check.sh'
    check.write_text('#!/usr/bin/env bash\nprintf "check executed\\n" >> "$FM_HOME/state/check-runs"\n')
    check.chmod(0o700)
    r=call(['bin/fm-check-register.sh','cadence'],e)
    say(r.stdout.strip())

def scenario(name,fn):
    if os.environ.get('LIVE_SCENARIO') and os.environ['LIVE_SCENARIO'] not in name: return
    results[:] = [r for r in results if r['name'] != name]
    say('\nSCENARIO: '+name)
    try:
        fn()
        results.append(dict(name=name,result='pass',live=True))
        say('Observed result: PASS')
    except Exception as ex:
        say(traceback.format_exc())
        results.append(dict(name=name,result='fail',live=True,reason=str(ex)))

try:
    # An empty private backend session is an isolation container, not an agent primary.
    call(['tmux','-S',socket,'new-session','-d','-s','fm-lab-watch','-x','120','-y','40','sleep 600'])
    context=call(['tmux','-S',socket,'display-message','-p','#{socket_path},#{pid},0']).stdout.strip()
    env['TMUX']=context
    say('Private tmux isolation container: '+context)
    def cadence():
        p,e=home('cadence'); register(p,e)
        e['CLAUDE_CODE_SESSION_ID']='supervisor-A'
        append(e,'initial work'); marker=announce(p,e)
        assert read(p,'.watcher-down.announce-seq')=='1'
        assert ((p/'state'/'.watcher-down.announce-seq').stat().st_mode & 0o777)==0o600
        for identity in ['supervisor-A','supervisor-B',None]:
            e.pop('CLAUDE_CODE_SESSION_ID',None)
            if identity: e['CLAUDE_CODE_SESSION_ID']=identity
            quiet(p,e,marker)
        assert read(p,'.wake-queue.seq')=='1' and 'initial work' in read(p,'.wake-queue')
    scenario('Unchanged unacknowledged row survives same, different, and absent session IDs while checks and heartbeats keep running',cadence)
    def later():
        p,e=home('late'); register(p,e)
        append(e,'first'); old=announce(p,e)
        append(e,'late'); new=announce(p,e)
        assert new!=old and read(p,'.watcher-down.announce-seq')=='2'
        quiet(p,e,new)
        assert 'first' in read(p,'.wake-queue') and 'late' in read(p,'.wake-queue')
    scenario('Work appended after announcement resurfaces once under a new generation and then stays quiet',later)
    def ack():
        p,e=home('ack'); register(p,e)
        append(e,'handled between restarts'); marker=announce(p,e)
        for _ in range(2): quiet(p,e,marker)
        r=call(['bin/fm-wake-drain.sh'],e)
        say('fm-wake-drain.sh stdout:\n'+r.stdout+'stderr:\n'+r.stderr)
        generation=marker.split(':')[-1]
        r=call(['bin/fm-wake-drain.sh','--ack-through','1','--recovery-generation',generation],e)
        say('ack exit=0 stdout:\n'+r.stdout+'stderr:\n'+r.stderr)
        assert read(p,'.wake-queue')==''
        assert read(p,'.watcher-down')=='acked:handling:'+generation
        say(json.dumps(snapshot(p),sort_keys=True))
    scenario('Acknowledgement using the originally presented generation succeeds after two restarts and consumes the row',ack)
    def damaged():
        for variant in ['regressed','missing-record','empty-record','invalid-record','missing-live','empty-live','invalid-live']:
            p,e=home('damage-'+variant)
            append(e,'recoverable'); old=announce(p,e)
            seq=p/'state'/'.wake-queue.seq'; rec=p/'state'/'.watcher-down.announce-seq'
            if variant=='regressed': seq.write_text('0\n')
            elif variant=='missing-record': rec.unlink()
            elif variant=='empty-record': rec.write_text('')
            elif variant=='invalid-record': rec.write_text('invalid\n')
            elif variant=='missing-live': seq.unlink()
            elif variant=='empty-live': seq.write_text('')
            elif variant=='invalid-live': seq.write_text('invalid\n')
            say('Adversarial persisted-state fault: '+variant)
            new=announce(p,e)
            assert new!=old and 'recoverable' in read(p,'.wake-queue')
            expected='' if not seq.exists() else seq.read_text().strip()
            assert read(p,'.watcher-down.announce-seq')==expected
    scenario('Regressed, missing, empty, and invalid sequence evidence conservatively resurfaces queued work',damaged)
finally:
    for p in list(active): stop(p)
    call(['tmux','-S',socket,'kill-server'],check=False)
    shutil.rmtree(BASE)
    say('Teardown: private tmux server stopped and every disposable home removed.')
    (EVID/'watcher-live-results.json').write_text(json.dumps(results,indent=2)+'\n')
    log.close()
raise SystemExit(any(r['result']=='fail' for r in results))
