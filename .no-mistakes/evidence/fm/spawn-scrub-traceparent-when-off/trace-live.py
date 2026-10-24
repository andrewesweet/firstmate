import json, os, pathlib, re, shlex, shutil, subprocess, tempfile, time, sys
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('~/.no-mistakes/evidence/01M5NZVNSVXWZ7G4SDZ9TAAX4Z')
baseline = '--baseline' in sys.argv
if baseline:
    EVIDENCE = EVIDENCE / 'baseline'
    EVIDENCE.mkdir(exist_ok=True)
SPAWN = ROOT / ('bin/.fm-trace-baseline.sh' if baseline else 'bin/fm-spawn.sh')
base = pathlib.Path(tempfile.mkdtemp(prefix='.trace-live.', dir=ROOT))
lab = base / 'home'
env = os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key in ['TMUX', 'TMUX_PANE', 'NO_MISTAKES_GATE', 'HERDR_ENV', 'REX_SESSION', 'REX_BLOCK', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND']:
        env.pop(key)
env.update(HOME=str(base/'user'), XDG_CONFIG_HOME=str(base/'user/.config'), XDG_DATA_HOME=str(base/'user/.local/share'), XDG_CACHE_HOME=str(base/'user/.cache'), SHELL='/bin/bash', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', TREEHOUSE_ROOT=str(base/'pool'), FM_HOME=str(lab), FM_BACKEND='tmux', FM_SPAWN_NO_GUARD='1', TRACEPARENT='00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01', OTEL_RESOURCE_ATTRIBUTES='service.name=trace-live,custom.test=yes', TRACE_KEEP='keep value', TRACE_DROP='drop value')
pathlib.Path(env['HOME']).mkdir()
logs=[]
ids=[]
socket_dir=None

def run(args, **kw):
    p=subprocess.run([str(a) for a in args], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=100, **kw)
    logs.append('$ '+shlex.join([str(a) for a in args])+'\n'+p.stdout)
    if p.returncode: raise RuntimeError(f'command returned {p.returncode}: {p.stdout}')
    return p.stdout.strip()

def tmux(*args):
    return run(['tmux','-L','fm-lab',*args])

try:
    run([ROOT/'bin/fm-lab-home.sh','create',lab])
    socket_dir=run([ROOT/'bin/fm-lab-home.sh','tmux-dir',lab])
    env['TMUX_TMPDIR']=socket_dir
    project=base/'project'
    project.mkdir()
    run(['git','-C',project,'init','-q','-b','main'])
    (project/'README.md').write_text('Disposable trace propagation live test.\n')
    (project/'treehouse.toml').write_text('max_trees = 8\nroot = "'+str(base/'pool')+'"\n')
    run(['git','-C',project,'add','.'])
    run(['git','-C',project,'-c','user.name=Trace Test','-c','user.email=trace@example.invalid','commit','-qm','fixture'])
    (lab/'config/backlog-backend').write_text('manual\n')
    (lab/'config/keep-ai-trailers').touch()
    (lab/'state/.lock').write_text(str(os.getpid())+'\n')
    (lab/'state/.last-watcher-beat').touch()
    probe=base/'probe.py'
    probe.write_text('import json, os, pathlib, sys\nkeys=["TRACEPARENT","OTEL_RESOURCE_ATTRIBUTES","TRACE_KEEP","TRACE_DROP","FM_TASK_ID","COMPACT_ADVISER_DISABLE"]\ndata={k:os.environ.get(k) for k in keys}\ndata["cwd"]=os.getcwd()\ntext=json.dumps(data,sort_keys=True)\npathlib.Path(sys.argv[1]).write_text(text+"\\n")\nprint(text,flush=True)\n')
    tmux('-f','/dev/null','new-session','-d','-s','fm-lab-trace','-x','140','-y','40','-c',project,'/bin/bash --noprofile --norc')
    tmux('set-option','-g','default-shell','/bin/bash')
    tmux('set-option','-g','default-command','/bin/bash --noprofile --norc')
    env['TMUX']=tmux('display-message','-p','#{socket_path},#{pid},#{session_id}').replace('$','')
    # Confirm the running destination server actually holds the stale carrier.
    ambient=tmux('show-environment','-g','TRACEPARENT')
    assert ambient=='TRACEPARENT='+env['TRACEPARENT'], ambient
    results=[]
    for mode, allow in ([('off',False)] if baseline else [('off',False),('on',False),('off',True),('on',True)]):
        case=f'{mode}-'+('allowlist' if allow else 'ambient')
        task=f'trace-{os.getpid()}-{case}'
        ids.append(task)
        if mode=='on': (lab/'config/trace-context').touch()
        else: (lab/'config/trace-context').unlink(missing_ok=True)
        allowfile=lab/'config/launch-env-allowlist'
        if allow: allowfile.write_text('TRACEPARENT\nOTEL_RESOURCE_ATTRIBUTES\nTRACE_KEEP\n')
        else: allowfile.unlink(missing_ok=True)
        run(['bash','-c','. "$1/bin/fm-trace-context-lib.sh"; unset FM_TRACE_CONTEXT; fm_trace_context_session_start "$2/config" "$2/state/.trace-context-effective"','trace-session',ROOT,lab])
        taskdata=lab/'data'/task
        taskdata.mkdir()
        (taskdata/'brief.md').write_text("# Task\n## Captain's intent\nObserve the child environment for trace propagation.\n\n## Firstmate spec\nRun the supplied disposable environment observer.\n")
        output=base/(case+'.json')
        raw='python3 '+shlex.quote(str(probe))+' '+shlex.quote(str(output))
        run([SPAWN,task,project,raw,'--mode','local-only','--yolo','off'])
        deadline=time.monotonic()+15
        while not output.exists() and time.monotonic()<deadline: time.sleep(.1)
        pane=tmux('capture-pane','-p','-t','fm-lab-trace:fm-'+task,'-S','-150')
        (EVIDENCE/(case+'-pane.txt')).write_text(pane+'\n')
        assert output.exists(), 'worker observation missing; see '+case+'-pane.txt'
        data=json.loads(output.read_text())
        meta=(lab/'state'/f'{task}.meta').read_text()
        carrier=next((line.split('=',1)[1] for line in meta.splitlines() if line.startswith('traceparent=')),None)
        if mode=='off':
            assert data['TRACEPARENT']==(env['TRACEPARENT'] if baseline else None), data
            assert carrier is None, carrier
        else:
            assert re.fullmatch(r'00-[0-9a-f]{32}-[0-9a-f]{16}-01',carrier or ''), carrier
            assert carrier!=env['TRACEPARENT'], carrier
            assert data['TRACEPARENT']==carrier, data
        assert data['OTEL_RESOURCE_ATTRIBUTES']==env['OTEL_RESOURCE_ATTRIBUTES'], data
        assert data['TRACE_KEEP']=='keep value', data
        assert data['TRACE_DROP']==(None if allow else 'drop value'), data
        assert data['COMPACT_ADVISER_DISABLE']=='1', data
        assert data['FM_TASK_ID']==task, data
        assert data['cwd']!=str(project) and str(base) in data['cwd'], data
        record={'scenario':case,'destination_server_ambient':ambient,'recorded_traceparent':carrier,'worker':data,'result':'baseline leak reproduced' if baseline else 'pass'}
        results.append(record)
        print(json.dumps(record),flush=True)
        (EVIDENCE/'trace-live-results.json').write_text(json.dumps(results,indent=2)+'\n')
finally:
    if socket_dir:
        subprocess.run(['tmux','-L','fm-lab','kill-server'],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        subprocess.run([str(ROOT/'bin/fm-lab-home.sh'),'teardown',str(lab)],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    # Product-created per-task temporary launch files are incidental test outputs.
    for task in ids:
        for candidate in pathlib.Path('/tmp').glob('fm-'+task+'*'):
            if candidate.is_dir() and not candidate.is_symlink(): shutil.rmtree(candidate)
    shutil.rmtree(base)
    logs.append('Cleanup: private fm-lab tmux server stopped; disposable home, project, pool, and per-task launch files removed.\n')
    (EVIDENCE/'trace-live-transcript.txt').write_text('\n'.join(logs))
