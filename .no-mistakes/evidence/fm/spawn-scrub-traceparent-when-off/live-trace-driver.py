import hashlib, json, os, pathlib, re, shlex, shutil, subprocess, sys, time
root = pathlib.Path.cwd()
work = root / '.test-runtime/live'
evidence = pathlib.Path('~/.no-mistakes/evidence/01M54R9YEHJ6EPAQ78ZYQS4VRY')
work.mkdir(parents=True, exist_ok=True)
env = {k: v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_', 'TASKS_AXI_', 'TREEHOUSE_', 'GIT_CONFIG_')) and k not in ('TMUX','TMUX_PANE','TRACEPARENT','FM_HOME','CLAUDE_CONFIG_DIR')}
env.update(HOME=str(work/'user-home'), SHELL='/bin/bash', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='Live fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid', GIT_COMMITTER_NAME='Live fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid', TREEHOUSE_ROOT=str(work/'pool'), TRACEPARENT='00-11111111111111111111111111111111-2222222222222222-01', OTEL_RESOURCE_ATTRIBUTES='service.name=ambient-pane,lab.marker=preserve', LAB_KEEP='pane-kept', LAB_DROP='pane-dropped', TERM='xterm-256color')
(work/'user-home').mkdir(exist_ok=True)
# The private socket is toolchain temp space, as specified by the lab runbook.
lab = pathlib.Path(subprocess.check_output(['mktemp','-d','/tmp/fm-lab.XXXXXX'], text=True).strip())
subprocess.run([str(root/'bin/fm-lab-home.sh'),'create',str(lab)],env=env,check=True,stdout=subprocess.DEVNULL)
(lab/'tmux').mkdir()
env['TMUX_TMPDIR']=str(lab/'tmux')
tmux=['tmux','-L','fm-lab']
def run(args, **kw):
    return subprocess.run(args,env=env,text=True,capture_output=True,**kw)
def tm(*args):
    r=run(tmux+list(args));
    if r.returncode: raise RuntimeError(f'tmux {args}: {r.stderr}')
    return r.stdout
repo=work/'project'
repo.mkdir(exist_ok=True)
for args in (['git','-C',str(repo),'init','-q','-b','main'],):
    r=run(args); assert r.returncode == 0, r.stderr
(repo/'fixture.txt').write_text('Disposable project for a real Firstmate spawn.\n')
for args in (['git','-C',str(repo),'add','fixture.txt'], ['git','-C',str(repo),'commit','-qm','Initial fixture']):
    r=run(args); assert r.returncode == 0, r.stderr
probe=work/'observe-env.py'
probe.write_text('''import json, os, pathlib, sys\nkeys = ['TRACEPARENT', 'OTEL_RESOURCE_ATTRIBUTES', 'LAB_KEEP', 'LAB_DROP', 'FM_TASK_ID', 'COMPACT_ADVISER_DISABLE']\ndata = {'pid': os.getpid(), 'parent_pid': os.getppid(), 'cwd': os.getcwd(), 'environment': {k: os.environ.get(k) for k in keys}}\npathlib.Path(sys.argv[1]).write_text(json.dumps(data, indent=2) + '\\n')\nprint('WORKER_ENV ' + json.dumps(data), flush=True)\n''')
results=[]
case_ids=[]
try:
    tm('-f','/dev/null','new-session','-d','-s','primary','-x','120','-y','40','-c',str(root),'/bin/bash --noprofile --norc')
    tm('set-option','-g','default-shell','/bin/bash')
    tm('set-option','-g','default-command','/bin/bash --noprofile --norc')
    ambient_out=evidence/'ambient-pane.worker.json'
    tm('new-window','-d','-t','primary:','-n','ambient-pane','-c',str(repo))
    tm('send-keys','-t','primary:ambient-pane','-l',shlex.join([sys.executable,str(probe),str(ambient_out)]))
    tm('send-keys','-t','primary:ambient-pane','Enter')
    limit=time.monotonic()+10
    while not ambient_out.exists() and time.monotonic()<limit: time.sleep(.1)
    ambient_data=json.loads(ambient_out.read_text())
    assert ambient_data['environment']['TRACEPARENT']==env['TRACEPARENT'],ambient_data
    print('DAEMON_AMBIENT',json.dumps(ambient_data),flush=True)
    tm('kill-window','-t','primary:ambient-pane')
    cases=[('off-no-allowlist','off',None),('on-no-allowlist','on',None),('off-allowlisted-carrier','off','TRACEPARENT\nOTEL_RESOURCE_ATTRIBUTES\nLAB_KEEP\n'),('on-allowlisted-carrier','on','TRACEPARENT\nOTEL_RESOURCE_ATTRIBUTES\nLAB_KEEP\n'),('off-empty-allowlist','off','')]
    if len(sys.argv)>1: cases=cases[:int(sys.argv[1])]
    for name,mode,allow in cases:
        case_id='lab-tp-'+name
        case_ids.append(case_id)
        home=work/name
        r=run([str(root/'bin/fm-lab-home.sh'),'create',str(home)]); assert r.returncode==0,r.stderr
        brief=home/'data'/case_id/'brief.md'; brief.parent.mkdir()
        brief.write_text("# Setup\nDelivery contract: mode=no-mistakes\n\n# Task\n## Captain's intent\nObserve trace context in a freshly launched worker.\n\n## Firstmate spec\nRecord only selected fixture environment variables.\n")
        if allow is not None: (home/'config/launch-env-allowlist').write_text(allow)
        if mode=='on': (home/'config/trace-context').touch()
        (home/'config/keep-ai-trailers').touch()
        out=evidence/(name+'.worker.json')
        raw=shlex.join([sys.executable,str(probe),str(out)])
        cmd=shlex.join([str(root/'bin/fm-spawn.sh'),case_id,str(repo),raw,'--mode','no-mistakes','--yolo','off','--backend','tmux'])
        driver=work/(name+'.sh')
        driver.write_text(f'''#!/bin/bash
export FM_HOME={shlex.quote(str(home))}
export TRACEPARENT=00-33333333333333333333333333333333-4444444444444444-01
unset FM_TRACE_CONTEXT FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE
printf '%s\\n' "$$" > "$FM_HOME/state/.lock"
touch "$FM_HOME/state/.last-watcher-beat"
. {shlex.quote(str(root/'bin/fm-trace-context-lib.sh'))}
fm_trace_context_session_start "$FM_HOME/config" "$FM_HOME/state/.trace-context-effective"
{cmd} > {shlex.quote(str(evidence/(name+'.spawn.txt')))} 2>&1
printf '%s\\n' "$?" > {shlex.quote(str(work/(name+'.status')))}
''')
        tm('send-keys','-t','primary','-l',shlex.join(['/bin/bash',str(driver)]))
        tm('send-keys','-t','primary','Enter')
        deadline=time.monotonic()+85
        status=work/(name+'.status')
        while not status.exists() and time.monotonic()<deadline: time.sleep(.2)
        assert status.exists(),f'{name}: spawn timed out'
        transcript=(evidence/(name+'.spawn.txt')).read_text()
        print(name,transcript,flush=True)
        assert status.read_text().strip()=='0',f'{name}: spawn failed'
        while not out.exists() and time.monotonic()<deadline: time.sleep(.2)
        meta=dict(line.split('=',1) for line in (home/'state'/(case_id+'.meta')).read_text().splitlines() if '=' in line)
        pane=tm('capture-pane','-p','-t',meta['window'],'-S','-100')
        (evidence/(name+'.pane.txt')).write_text(pane)
        assert out.exists(),f'{name}: worker observation missing\n{pane}'
        observed=json.loads(out.read_text())
        values=observed['environment']
        tp=values['TRACEPARENT']
        if mode=='off':
            assert tp is None, f'{name}: ambient trace leaked: {tp}'
            assert 'traceparent' not in meta,f'{name}: off metadata contains carrier'
        else:
            assert re.fullmatch(r'00-[0-9a-f]{32}-[0-9a-f]{16}-01',tp or ''),f'{name}: invalid fresh carrier: {tp}'
            assert tp not in (env['TRACEPARENT'],'00-33333333333333333333333333333333-4444444444444444-01'),f'{name}: stale carrier reused'
            assert meta.get('traceparent')==tp,f'{name}: worker and metadata disagree'
        expected_otel=None if allow=='' else env['OTEL_RESOURCE_ATTRIBUTES']
        assert values['OTEL_RESOURCE_ATTRIBUTES']==expected_otel,(name,values)
        assert values['LAB_KEEP']==(None if allow=='' else 'pane-kept'),(name,values)
        assert values['LAB_DROP']==('pane-dropped' if allow is None else None),(name,values)
        assert values['FM_TASK_ID']==case_id and values['COMPACT_ADVISER_DISABLE']=='1',(name,values)
        assert pathlib.Path(observed['cwd'])!=repo and str(work/'pool') in observed['cwd'],f'{name}: worker did not enter isolated worktree'
        selected={k:meta[k] for k in ('window','worktree','harness','kind','mode','traceparent') if k in meta}
        (evidence/(name+'.meta.json')).write_text(json.dumps(selected,indent=2)+'\n')
        results.append({'case':name,'mode':mode,'allowlist':allow,'worker':observed,'metadata':selected,'result':'pass'})
        print('OBSERVED',json.dumps(results[-1]),flush=True)
    enabled=[x['worker']['environment']['TRACEPARENT'] for x in results if x['mode']=='on']
    assert len(enabled)==len(set(enabled)), 'unrelated enabled tasks share a carrier'
    (evidence/'live-trace-results.json').write_text(json.dumps(results,indent=2)+'\n')
finally:
    r=run(tmux+['kill-server'])
    for name,_,_ in locals().get('cases',[]):
        home=work/name
        ident='lab-tp-'+name
        launch=pathlib.Path('/tmp')/(f'fm-{ident}+'+hashlib.sha256(str(home).encode()).hexdigest())
        if launch.exists(): shutil.rmtree(launch)
        meta_path=home/'state'/(ident+'.meta')
        if meta_path.exists():
            for line in meta_path.read_text().splitlines():
                if line.startswith('tasktmp=/tmp/'):
                    tasktmp=pathlib.Path(line.split('=',1)[1])
                    if tasktmp.name.startswith('fm-'+ident): shutil.rmtree(tasktmp,ignore_errors=True)
    shutil.rmtree(lab)
    print('CLEANUP: private fm-lab tmux server and lab socket removed',flush=True)
