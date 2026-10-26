import os, pathlib, subprocess, json, time, shutil, signal, sys
R=pathlib.Path.cwd(); D=R/'.h'; E=pathlib.Path('~/.no-mistakes/evidence/01M5WPVPGAQ2W73QCTVDNTVVJY'); S='fm-lab-r5d'
assert not D.exists()
env=dict(os.environ)
for k in ['FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','HERDR_SOCKET_PATH','HERDR_PANE_ID','HERDR_WORKSPACE_ID','HERDR_TAB_ID','TMUX','FM_TASK_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:
    env.pop(k,None)
env.update(HOME=str(D/'user'), XDG_CONFIG_HOME='.h/x', TMPDIR=str(D/'tmp'), SHELL='/bin/bash', FM_HERDR_LAB_STATE_DIR=str(D/'tripwire'), HERDR_SESSION=S, FM_SPAWN_NO_GUARD='1', TREEHOUSE_ROOT=str(D/'pool'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='Lab', GIT_AUTHOR_EMAIL='lab@example.invalid', GIT_COMMITTER_NAME='Lab', GIT_COMMITTER_EMAIL='lab@example.invalid')
for p in [D/'user',D/'x/herdr',D/'tmp',D/'tripwire',D/'shim']: p.mkdir(parents=True,exist_ok=True)
(D/'x/herdr/herdr.sock').symlink_to('~/.config/herdr/herdr.sock')
(D/'x/herdr/config.toml').write_text('[session]\nresume_agents_on_restore = false\n')
H=str(R/'bin/fm-herdr-lab.sh'); realpath=env['PATH']; log=(E/'round5d-live-transcript.log').open('w',buffering=1); results=[]
def run(args,cwd=R,check=True,extra=None):
    e=env.copy(); e.update(extra or {})
    p=subprocess.run(list(map(str,args)),cwd=cwd,env=e,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=150)
    print('$ '+' '.join(map(str,args))+'\n'+p.stdout+p.stderr,file=log)
    if pathlib.Path(str(args[0])).name in ['fm-spawn.sh','fm-teardown.sh']: p.stdout+=p.stderr
    if check and p.returncode: raise RuntimeError(f'{args}: exit {p.returncode}: {p.stdout}')
    return p

def lab(*args,check=True):
    p=run([H,'run',S,*args],check=check)
    return json.loads(p.stdout) if p.stdout.strip() else {}
def field(home,task,key):
    return dict(x.split('=',1) for x in (home/'state'/f'{task}.meta').read_text().splitlines() if '=' in x)[key]
def make_home(name,pref):
    home=D/name; run([R/'bin/fm-lab-home.sh','create',home])
    (home/'config/crew-harness').write_text('codex\n'); (home/'config/herdr-presentation-spaces').write_text(pref+'\n'); (home/'state/.last-watcher-beat').touch()
    return home
def brief(home,task):
    run([R/'bin/fm-brief.sh',task,str(project),'--mode','local-only','--herdr-lab'],extra={'FM_HOME':str(home)})
    p=home/'data'/task/'brief.md'
    s=p.read_text().replace('{TASK}','Exercise isolated Herdr shell and restore behavior.').replace('{PUBLISHED_INTENT}','Restore workers in their isolated copy.').replace('{FIRSTMATE_SPEC}','Use a sleeping foreground process; invoke no model work and publish nothing.')
    p.write_text(s)

def spawn(home,task,proj=None,relaunch=False,check=True,extra=None):
    args=[R/'bin/fm-spawn.sh',task]
    if relaunch: args+=['--relaunch','--harness','sleep 600']
    else: args += [proj,'sleep 600','--backend','herdr','--mode','local-only','--yolo','off']
    return run(args,extra={'FM_HOME':str(home),'PATH':str(D/'shim')+':'+realpath,**(extra or {})},check=check)
(D/'shim/herdr').write_text('''#!/usr/bin/env python3
import os,sys,subprocess,pathlib
args=sys.argv[1:]; out=[]; i=0
while i<len(args):
    if args[i]=='--session':
        assert args[i+1]==os.environ['HERDR_SESSION']; i+=2
    else: out.append(args[i]); i+=1
os.environ['PATH']=os.environ['LAB_REAL_PATH']
os.chdir(os.environ['LAB_CODE_ROOT'])
h=os.environ['LAB_HELPER']; s=os.environ['HERDR_SESSION']
if out[:2]==['pane','close']:
    import json
    p=subprocess.run([h,'run',s,'pane','process-info','--pane',out[2]],capture_output=True,text=True)
    if p.returncode==0:
        info=json.loads(p.stdout)['result']['process_info']
        with open(os.environ['LAB_BOUNDARY_LOG'],'a') as f:
            f.write(json.dumps({'event':'before-real-pane-close','pane':out[2],'process_info':info})+'\\n')
if out[:2]==['pane','run'] and os.environ.get('LAB_DROP_SEND'):
    count=pathlib.Path(os.environ['LAB_DROP_COUNTER']); n=int(count.read_text())+1 if count.exists() else 1; count.write_text(str(n))
    if n==int(os.environ['LAB_DROP_SEND']):
        subprocess.run([h,'run',s,'pane','close',out[2]],check=True,stdout=subprocess.DEVNULL)
# Relative XDG keeps Unix socket addresses under Linux's length limit.
# Normalize its real socket paths for Firstmate's absolute-path identity API.
if out[:2]==['session','list']:
    import json
    p=subprocess.run([h,'run',s,*out],capture_output=True,text=True)
    if p.returncode: sys.stderr.write(p.stderr); sys.exit(p.returncode)
    value=json.loads(p.stdout)
    for row in value['sessions']:
        for key in ['socket_path','session_dir']:
            if key in row: row[key]=str(pathlib.Path(row[key]).absolute())
    print(json.dumps(value)); sys.exit(0)
os.execv(h,[h,'run',s,*out])
'''); (D/'shim/herdr').chmod(0o755)
env.update(LAB_REAL_PATH=realpath,LAB_HELPER=H,LAB_CODE_ROOT=str(R),LAB_BOUNDARY_LOG=str(E/'round5d-close-boundary.jsonl'))
def scenario(name,fn):
    try:
        detail=fn(); result='pass'
    except Exception as ex:
        import traceback
        detail=traceback.format_exc(); result='fail'
    row=dict(name=name,result=result,live=True,evidence='round5d-live-transcript.log',reason='' if result=='pass' else detail)
    results.append(row); (E/'round5d-results.json').write_text(json.dumps(results,indent=2))
    print(result.upper()+': '+name+': '+str(detail),flush=True); print(result.upper()+': '+name+': '+str(detail),file=log)

def shape(home,task):
    if task=='proj-task':
        assert (home/'state'/f'{task}.herdr-presentation').exists(), 'Projected journal missing; flat fallback is not projection evidence'
    pane=field(home,task,'herdr_pane_id'); wt=field(home,task,'worktree')
    for _ in range(30):
        info=lab('pane','get',pane)['result']['pane']
        if info.get('foreground_cwd',info.get('cwd'))==wt: break
        time.sleep(.2)
    assert info.get('foreground_cwd',info.get('cwd'))==wt,info
    proc=lab('pane','process-info','--pane',pane)['result']['process_info']; top=proc['shell_pid']; topcwd=os.readlink(f'/proc/{top}/cwd')
    assert topcwd==wt,(task,topcwd,wt)
    assert any(x.get('cwd')==wt for x in proc['foreground_processes']),proc
    return dict(pane=pane,worktree=wt,top=top,topcwd=topcwd)

def restore_check(home,task):
    pane=field(home,task,'herdr_pane_id'); expected=field(home,task,'worktree')
    info=lab('pane','get',pane)['result']['pane']; proc=lab('pane','process-info','--pane',pane)['result']['process_info']; actual=os.readlink(f"/proc/{proc['shell_pid']}/cwd")
    assert actual==expected,f'expected isolated copy={expected}; restored shell cwd={actual}; pane={info}'
    return actual

def restart(tag):
    run([H,'stop',S]); shutil.copy2(D/'x/herdr/sessions'/S/'session.json',E/f'round5d-{tag}-session.json'); run([H,'provision',S]); time.sleep(.5)

try:
    run([H,'provision',S]); lab('status','--json')
    project=D/"project's space"; project.mkdir(); run(['git','init','-q','-b','main',project]); (project/'seed').write_text('lab\n'); run(['git','add','seed'],cwd=project); run(['git','commit','-qm','seed'],cwd=project)
    lab('workspace','create','--cwd',str(project),'--label','firstmate','--no-focus')
    home=make_home('projection','on'); task='proj-task'; brief(home,task); spawn(home,task,project)
    run([H,'viewer','start',S]); lab('tab','focus',field(home,task,'herdr_tab_id'))
    def active():
        proof=shape(home,task); meta=home/'state'/f'{task}.meta'; original=meta.read_bytes()
        def leases():
            return [{k:v for k,v in row.items() if k!='processes'} for row in json.loads(run(['treehouse','status','--json'],cwd=project).stdout)]
        before=leases()
        processes=lab('pane','process-info','--pane',proof['pane'])['result']['process_info']['foreground_processes']
        assert any(x['name']=='sleep' for x in processes), processes
        out=run([R/'bin/fm-teardown.sh',task],check=False,extra={'FM_HOME':str(home),'PATH':str(D/'shim')+':'+realpath})
        assert out.returncode!=0 and 'not confirmed gone' in out.stdout,out.stdout
        lab('pane','get',proof['pane']); os.kill(proof['top'],0)
        for entry in processes: os.kill(entry['pid'],0)
        assert os.readlink(f"/proc/{proof['top']}/cwd")==proof['worktree']
        assert meta.read_bytes()==original and (home/'state'/f'{task}.herdr-presentation').exists()
        assert leases()==before, 'lease identity or ownership changed'
        return {'pane':proof['pane'],'top_shell':proof['top'],'foreground_processes':processes,'preserved':'pane, shell, sleep, metadata, journal, lease'}
    scenario('Active viewer blocks projected teardown before any worktree process is killed',active)
    run([H,'viewer','stop',S])
    def detached():
        proof=shape(home,task)
        run([R/'bin/fm-teardown.sh',task],extra={'FM_HOME':str(home),'PATH':str(D/'shim')+':'+realpath})
        assert not (home/'state'/f'{task}.meta').exists()
        assert not (home/'state'/f'{task}.herdr-presentation').exists()
        assert run([H,'run',S,'pane','get',proof['pane']],check=False).returncode!=0
        leases=json.loads(run(['treehouse','status','--json'],cwd=project).stdout)
        assert not any(x['path']==proof['worktree'] and x['status']=='leased' for x in leases)
        return 'after viewer detaches: projected endpoint and journal retired, owned lease returned'
    scenario('Detached projected teardown closes endpoint and retires journal before returning owned copy',detached)

finally:
    result=run([H,'teardown',S],check=False); print(f'Lab teardown exit={result.returncode}; default-session tripwire verified',file=log); print('Teardown exit',result.returncode,flush=True)
    log.close()
    if result.returncode==0:
        for root,dirs,files in os.walk(D,followlinks=False): os.chmod(root,0o700)
        shutil.rmtree(D)
        # Lab configuration removed with disposable lab.
    else: raise RuntimeError('Lab teardown failed; retain isolated lab for recovery')
if any(x['result']=='fail' for x in results): sys.exit(1)
