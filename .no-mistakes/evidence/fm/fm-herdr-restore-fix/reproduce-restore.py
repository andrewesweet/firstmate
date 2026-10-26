import os, pathlib, subprocess, json, time, shutil, sys
R=pathlib.Path.cwd(); D=R/'.restore-repro'; E=pathlib.Path('~/.no-mistakes/evidence/01M5WPVPGAQ2W73QCTVDNTVVJY'); S='fm-lab-repro'
env=dict(os.environ)
for k in ['FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','HERDR_SOCKET_PATH','HERDR_PANE_ID','HERDR_WORKSPACE_ID','HERDR_TAB_ID','TMUX','FM_TASK_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:
    env.pop(k,None)
env.update(HOME=str(D/'user'), XDG_CONFIG_HOME=str(E/'x'), TMPDIR=str(D/'tmp'), SHELL='/bin/bash', FM_HERDR_LAB_STATE_DIR=str(D/'tripwire'), HERDR_SESSION=S, FM_SPAWN_NO_GUARD='1', TREEHOUSE_ROOT=str(D/'pool'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='Lab', GIT_AUTHOR_EMAIL='lab@example.invalid', GIT_COMMITTER_NAME='Lab', GIT_COMMITTER_EMAIL='lab@example.invalid')
for p in [D/'user', E/'x/herdr', D/'tmp', D/'tripwire', D/'shim']: p.mkdir(parents=True,exist_ok=True)
# This read-only socket reference lets the stock helper verify its default-session tripwire.
if not (E/'x/herdr/herdr.sock').is_symlink(): (E/'x/herdr/herdr.sock').symlink_to('~/.config/herdr/herdr.sock')
(E/'x/herdr/config.toml').write_text('[session]\nresume_agents_on_restore = false\n')
H=str(R/'bin/fm-herdr-lab.sh'); realpath=env['PATH']
log=(E/'reproduce-restore.log').open('w',buffering=1)
def run(args,cwd=R,check=True,extra=None):
    e=env.copy(); e.update(extra or {})
    p=subprocess.run(list(map(str,args)),cwd=cwd,env=e,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=150)
    out=p.stdout
    print('$ '+' '.join(map(str,args))+'\n'+out,file=log)
    if check and p.returncode: raise RuntimeError(f'{args}: exit {p.returncode}: {out}')
    return p

def lab(*args):
    out=run([H,'run',S,*args]).stdout
    return json.loads(out) if out.strip() else {}
def field(home,task,key):
    return dict(x.split('=',1) for x in (home/'state'/f'{task}.meta').read_text().splitlines() if '=' in x)[key]
def make_home(name,pref):
    home=D/name
    run([R/'bin/fm-lab-home.sh','create',home])
    (home/'config/crew-harness').write_text('codex\n'); (home/'config/herdr-presentation-spaces').write_text(pref+'\n')
    (home/'state/.last-watcher-beat').touch()
    return home

def brief(home,task):
    p=home/'data'/task; p.mkdir(parents=True,exist_ok=True)
    (p/'brief.md').write_text("# Task\n## Captain's intent\nExercise isolated Herdr shell and restore behavior.\n\n## Published intent\nRestore workers in their own isolated copy.\n\n## Firstmate spec\nUse a sleeping foreground process; do not invoke model work or publish anything.\n")
def spawn(home,task,proj=None,relaunch=False,check=True):
    args=[R/'bin/fm-spawn.sh',task]
    if relaunch: args+=['--relaunch','--harness','sleep 600']
    else: args += [proj,'sleep 600','--backend','herdr','--mode','local-only','--yolo','off']
    return run(args,extra={'FM_HOME':str(home),'PATH':str(D/'shim')+':'+realpath},check=check)
# A transparent transport shim enforces the helper for every product CLI call.
(D/'shim/herdr').write_text('''#!/usr/bin/env python3
import os,sys
args=sys.argv[1:]; out=[]; i=0
while i<len(args):
    if args[i]=='--session':
        assert args[i+1]==os.environ['HERDR_SESSION']; i+=2
    else: out.append(args[i]); i+=1
os.environ['PATH']=os.environ['LAB_REAL_PATH']
os.execv(os.environ['LAB_HELPER'],[os.environ['LAB_HELPER'],'run',os.environ['HERDR_SESSION'],*out])
'''); (D/'shim/herdr').chmod(0o755)
env.update(LAB_REAL_PATH=realpath,LAB_HELPER=H)
def wait_pane(pane,wt):
    for _ in range(30):
        info=lab('pane','get',pane)['result']['pane']
        if info.get('foreground_cwd',info.get('cwd'))==wt: return info
        time.sleep(.2)
    raise AssertionError(info)
def shape(home,task):
    pane=field(home,task,'herdr_pane_id'); wt=field(home,task,'worktree')
    info=wait_pane(pane,wt)
    proc=lab('pane','process-info','--pane',pane)['result']['process_info']
    top=proc['shell_pid']; topcwd=os.readlink(f'/proc/{top}/cwd')
    assert topcwd==str(project), (task,topcwd)
    assert any(x.get('cwd')==wt for x in proc['foreground_processes']), proc
    print(f'PROOF {task}: top shell {top} cwd={topcwd}; foreground cwd={wt}',file=log)
    return pane,wt,top


failures=[]
try:
    run([H,'provision',S]); lab('status','--json')
    project=D/"project's space"; project.mkdir()
    run(['git','init','-q','-b','main',project]); (project/'seed').write_text('lab\n')
    run(['git','add','seed'],cwd=project); run(['git','commit','-qm','seed'],cwd=project)
    flat=make_home('flat','off'); brief(flat,'flat-task'); spawn(flat,'flat-task',project)
    flatwt=field(flat,'flat-task','worktree')
    control=lab('workspace','create','--cwd',flatwt,'--label','no-unwind-control','--no-focus')['result']['root_pane']['pane_id']
    proj=make_home('projection','on'); brief(proj,'proj-task'); spawn(proj,'proj-task',project)
    for home,task in [(flat,'flat-task'),(proj,'proj-task')]:
        pane=field(home,task,'herdr_pane_id'); expected=field(home,task,'worktree')
        live=lab('pane','get',pane)['result']['pane']['foreground_cwd']
        assert live==expected,(task,live,expected)
        print(f'PASS fresh {task}: foreground cwd={live}',file=log)
    run([H,'stop',S])
    shutil.copy2(E/'x/herdr/sessions'/S/'session.json',E/'repro-session.json')
    run([H,'provision',S]); time.sleep(.5)
    for home,task in [(flat,'flat-task'),(proj,'proj-task')]:
        pane=field(home,task,'herdr_pane_id'); expected=field(home,task,'worktree')
        info=lab('pane','get',pane)['result']['pane']
        proc=lab('pane','process-info','--pane',pane)['result']['process_info']
        actual=os.readlink(f"/proc/{proc['shell_pid']}/cwd")
        failures.append(dict(task=task,expected=expected,actual=actual,result='pass' if expected==actual else 'fail'))
        print(f"{'PASS' if expected==actual else 'FAIL'} restored {task}: expected={expected}; actual={actual}",file=log)
    controlcwd=lab('pane','get',control)['result']['pane']['foreground_cwd']
    assert controlcwd==flatwt,(controlcwd,flatwt)
    print('PASS control: pane created in the identical copy without the project unwind restores in that copy',file=log)
    (E/'repro-results.json').write_text(json.dumps(failures,indent=2))
    print(json.dumps(failures,indent=2),flush=True)
finally:
    result=run([H,'teardown',S],check=False)
    print(f'lab teardown exit={result.returncode}; default-session tripwire verified',file=log)
    assert result.returncode==0
    log.close()
    for root,dirs,files in os.walk(D,followlinks=False): os.chmod(root,0o700)
    shutil.rmtree(D)
if any(x['result']=='fail' for x in failures): sys.exit(1)
