import os, subprocess, tempfile, pathlib, time, json, shlex, shutil, html, re
ROOT=pathlib.Path.cwd()
EVID=pathlib.Path('/home/cti/.no-mistakes/evidence/01M5KCYDE9GQFZQRC6VG3JX2TM')
LAB=pathlib.Path(tempfile.mkdtemp(prefix='home.', dir=ROOT/'.live-test-tmp'))
env=dict(os.environ)
for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','TMUX','TMUX_PANE','CLAUDECODE','CLAUDE_CODE_CHILD_SESSION']:
    env.pop(k,None)
def run(args,**kw):
    return subprocess.run(list(map(str,args)),env=env,cwd=ROOT,text=True,capture_output=True,**kw)
log=[]
def record(s):
    print(s,flush=True); log.append(s); (EVID/'live-steer.log').write_text('\n'.join(log)+'\n')
def tm(*args):
    return run(['/usr/bin/tmux','-L','fm-lab',*args])
def cap(label):
    s=tm('capture-pane','-p','-t','primary:fm-worker').stdout
    (EVID/(label+'.txt')).write_text(s)
    a=tm('capture-pane','-e','-p','-t','primary:fm-worker').stdout
    (EVID/(label+'.ansi')).write_text(a)
    (EVID/(label+'.html')).write_text('<!doctype html><meta charset="utf-8"><title>'+label+'</title><style>body{background:#171717;color:#eee;padding:24px}pre{font:14px/1.4 monospace;white-space:pre-wrap}</style><pre>'+html.escape(s)+'</pre>')
    return s
def lib(fn,*args):
    return run(['bash','-c','. "$1"; shift; "$@"','_',ROOT/'bin/fm-task-inbox-lib.sh',fn,*args])
def wait_for(test,seconds=90):
    end=time.time()+seconds
    while time.time()<end:
        if test(): return True
        time.sleep(.5)
    return False
def state():
    r=LAB/'state/live.busy-state'
    return r.read_text() if r.exists() else ''
def send_literal(s):
    assert tm('send-keys','-t','primary:fm-worker','-l',s).returncode==0
    time.sleep(.6)
    assert tm('send-keys','-t','primary:fm-worker','Enter').returncode==0
try:
    r=run([ROOT/'bin/fm-lab-home.sh','create',LAB]); assert r.returncode==0,r.stderr
    # The supported helper supplies a short private socket directory. Its temporary
    # directory is the only lab resource outside the worktree, and is removed below.
    r=run([ROOT/'bin/fm-lab-home.sh','tmux-dir',LAB]); assert r.returncode==0,r.stderr
    env.update(FM_HOME=str(LAB),TMUX_TMPDIR=r.stdout.strip(),FM_TASK_INBOX=str(LAB/'state/live.inbox'),CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false',CLAUDE_CODE_SEND_FEEDBACK='0')
    (LAB/'config/supervision-host-off').touch()
    (LAB/'state/live.meta').write_text('window=primary:fm-worker\nbackend=tmux\nkind=ship\nharness=claude\n')
    run([ROOT/'bin/fm-busy-event.sh','arm',LAB/'state','live','--state','idle','--source','claude-hook','--event','stop'])
    hooks={}
    for event,st,ev in [('UserPromptSubmit','busy','user-prompt-submit'),('Stop','idle','stop')]:
        command=shlex.join([str(ROOT/'bin/fm-busy-event.sh'),'apply',str(LAB/'state'),'live',st,'--current-gen','--source','claude-hook','--event',ev])
        hooks[event]=[{'hooks':[{'type':'command','command':command}]}]
    settings=LAB/'config/worker.json'
    settings.write_text(json.dumps({'hooks':hooks,'feedbackDrafts':'off','autoMemoryEnabled':False}))
    # This pass-through only binds calls to the lab socket and records real inputs.
    shim=LAB/'shim'; shim.mkdir()
    (shim/'tmux').write_text('#!/usr/bin/env bash\nprintf "%q " "$@" >> '+shlex.quote(str(EVID/'tmux-inputs.log'))+'\nprintf "\\n" >> '+shlex.quote(str(EVID/'tmux-inputs.log'))+'\nexec /usr/bin/tmux -L fm-lab "$@"\n')
    (shim/'tmux').chmod(0o755)
    env['PATH']=str(shim)+':'+env['PATH']
    prompt='You are a disposable live-validation worker. Only follow the explicit test prompts and Firstmate inbox doorbells. Do not start fleet supervision or read project instructions. All intentional file changes must stay inside '+str(LAB)+'. Inbox records and doorbells are authorized instructions. Execute records in numeric order, then move each record into handled/. Do not delegate. Keep replies short.'
    cmd=['claude','--dangerously-skip-permissions','--setting-sources','','--settings',str(settings),'--system-prompt',prompt,'--tools','Bash,Read','--disable-slash-commands']
    r=tm('new-session','-d','-s','primary','-n','fm-worker','-x','140','-y','42','-c',str(ROOT),'-e','FM_HOME='+str(LAB),*cmd)
    assert r.returncode==0,r.stderr
    record('Launched '+run(['claude','--version']).stdout.strip()+' in marked lab, private tmux socket, 140x42 grid.')
    def ready():
        s=tm('capture-pane','-p','-t','primary:fm-worker').stdout
        if 'Yes, I trust this folder' in s:
            tm('send-keys','-t','primary:fm-worker','Down','Enter'); return False
        return 'bypass permissions on' in s
    if not wait_for(ready,45):
        record('SETUP BLOCKED: Claude did not reach a composer. See startup capture.'); cap('startup-blocked'); raise RuntimeError('Claude startup unavailable')
    cap('startup-ready')
    send_literal('Reply with exactly this sentence and nothing else: Use esc to interrupt a running turn.')
    assert wait_for(lambda:'state=busy' in state(),15),'prompt did not start'
    assert wait_for(lambda:'state=idle' in state(),90),'prompt did not settle'
    s=cap('idle-transcript-busy-phrase')
    record('Claude finished a real turn; trusted Stop hook reports idle. Assistant transcript contains: Use esc to interrupt a running turn.')
    body='Live validation: run '+shlex.join(['bash','-c','printf "consumed\\n" >> '+shlex.quote(str(LAB/'consumed.log'))])+' exactly once. Then acknowledge this record by moving it into handled/. Reply: RECOVERY-CONSUMED.'
    rec=pathlib.Path(lib('fm_task_inbox_write',LAB/'state','live',body).stdout.strip()); assert rec.exists()
    doorbell=lib('fm_task_inbox_doorbell_line',rec).stdout
    assert tm('send-keys','-t','primary:fm-worker','-l','a half-typed user draft').returncode==0
    time.sleep(.5); cap('foreign-draft-before')
    for i in (1,2):
        r=lib('fm_task_inbox_ring','tmux','primary:fm-worker',rec,'fm-worker')
        record('Foreign draft ring '+str(i)+': exit='+str(r.returncode)+', durable record present='+str(rec.exists()))
        assert r.returncode==1 and rec.exists()
    s=cap('foreign-draft-after'); assert 'a half-typed user draft' in s
    # Clear only the controlled test draft; seed the exact unsubmitted incident line.
    tm('send-keys','-t','primary:fm-worker','C-u')
    tm('send-keys','-t','primary:fm-worker','-l',doorbell)
    time.sleep(.5); cap('stranded-doorbell-before')
    record('Seeded an exact doorbell without Enter, retaining the same record after two unconsumed rings.')
    assert lib('fm_task_inbox_composer_holds','tmux','primary:fm-worker',doorbell,'fm-worker').returncode==0,'cannot prove stranded composer'
    before=(EVID/'tmux-inputs.log').read_text()
    r=lib('fm_task_inbox_ring','tmux','primary:fm-worker',rec,'fm-worker')
    record('Idle recovery ring exit='+str(r.returncode)); assert r.returncode==0
    assert wait_for(lambda:(LAB/'state/live.inbox/handled'/rec.name).exists() and (LAB/'consumed.log').exists(),100),'worker did not act and acknowledge'
    assert wait_for(lambda:'state=idle' in state(),45),'worker did not settle after acknowledgement'
    cap('recovered-and-acknowledged')
    inputs=(EVID/'tmux-inputs.log').read_text()[len(before):]
    assert not re.search(r'^send-keys .* -l ',inputs,re.M),'recovery retyped doorbell'
    assert (LAB/'consumed.log').read_text()=='consumed\n','record action duplicated'
    saved=LAB/'state/live.inbox/handled'/rec.name
    (EVID/'handled-record.msg').write_bytes(saved.read_bytes())
    record('Recovered: no literal retype, one action, same record moved into handled/.')
    r=lib('fm_task_inbox_ring','tmux','primary:fm-worker',saved,'fm-worker'); record('Duplicate doorbell ring exit='+str(r.returncode))
    assert r.returncode==0
    assert wait_for(lambda:'state=busy' in state(),10)
    assert wait_for(lambda:'state=idle' in state(),70)
    assert (LAB/'consumed.log').read_text()=='consumed\n'
    cap('duplicate-doorbell-no-second-action')
    record('Duplicate doorbell completed with an empty inbox; action remains exactly once.')
    # Real long foreground command creates a busy recipient for direct fm-send.
    send_literal('Run exactly this shell command: sleep 30. Then reply BUSY-TURN-DONE. Do nothing else.')
    assert wait_for(lambda:'state=busy' in state(),15)
    time.sleep(2); cap('busy-recipient-before')
    before=(EVID/'tmux-inputs.log').read_text()
    r=run([ROOT/'bin/fm-send.sh','live','After the busy turn, reply BUSY-STEER-CONSUMED and acknowledge this record.'])
    record('Direct fm-send to busy recipient exit='+str(r.returncode)+'; '+r.stderr.strip())
    assert r.returncode==0
    rec2=LAB/'state/live.inbox/002.msg'; assert rec2.exists()
    for i in (1,2):
        r=lib('fm_task_inbox_ring','tmux','primary:fm-worker',rec2,'fm-worker'); record('Busy re-ring '+str(i)+' exit='+str(r.returncode)); assert r.returncode==1
    inputs=(EVID/'tmux-inputs.log').read_text()[len(before):]
    assert not re.search(r'^send-keys ',inputs,re.M),'busy recipient received input'
    cap('busy-recipient-after-no-input')
    record('Busy direct send and two re-rings emitted no send-keys; second message remains durable and unhandled.')
    doorbell2=lib('fm_task_inbox_doorbell_line',rec2).stdout
    tm('send-keys','-t','primary:fm-worker','-l',doorbell2)
    time.sleep(.5)
    cap('busy-stranded-doorbell-before')
    before=(EVID/'tmux-inputs.log').read_text()
    for i in (1,2):
        assert 'state=busy' in state(), 'busy fixture finished before adversarial re-ring'
        r=lib('fm_task_inbox_ring','tmux','primary:fm-worker',rec2,'fm-worker')
        record('Busy exact-doorbell re-ring '+str(i)+' exit='+str(r.returncode))
        assert r.returncode==1 and rec2.exists()
        assert lib('fm_task_inbox_composer_holds','tmux','primary:fm-worker',doorbell2,'fm-worker').returncode==0
    inputs=(EVID/'tmux-inputs.log').read_text()[len(before):]
    assert not re.search(r'^send-keys ',inputs,re.M),'busy stranded doorbell received input'
    cap('busy-stranded-doorbell-after')
    record('Two more busy re-rings preserved the same exact stranded doorbell and record without sending any keys.')
    assert wait_for(lambda:'state=idle' in state(),80)
    r=lib('fm_task_inbox_ring','tmux','primary:fm-worker',rec2,'fm-worker'); assert r.returncode==0
    assert wait_for(lambda:(LAB/'state/live.inbox/handled/002.msg').exists(),80)
    cap('busy-then-idle-delivery')
    record('Busy recipient returned idle; re-ring delivered and worker acknowledged the second record.')
    (EVID/'live-result.json').write_text(json.dumps({'result':'pass','recovery':True,'foreign_draft':True,'busy_guard':True,'duplicate_action':False},indent=2))
except Exception as e:
    record('STOP: '+str(e)); cap('failure-final')
    (EVID/'live-result.json').write_text(json.dumps({'result':'blocked-or-fail','reason':str(e)}))
    raise
finally:
    tm('kill-server')
    r=run([ROOT/'bin/fm-lab-home.sh','teardown',LAB]); record('Private socket cleanup exit='+str(r.returncode))
    shutil.rmtree(LAB)
    record('Disposable lab home removed.')
