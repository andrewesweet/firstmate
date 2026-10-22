import json, os, pathlib, shutil, subprocess, time
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M5F15B7RERRAM3S6V266QF0T/test-oct22')
E.mkdir(exist_ok=True)
LAB=ROOT/'.test-trace-live'
log=[]
sock=None
env=os.environ.copy()
for k in list(env):
    if k.endswith('_OVERRIDE') or k in ['FM_GATE_REFUSE_BYPASS','TMUX','TMUX_PANE','FM_HOME','FM_BACKEND','FM_TRACE_CONTEXT','CLAUDE_CONFIG_DIR','TREEHOUSE_ROOT']:
        env.pop(k,None)
def run(args,check=True,**kw):
    p=subprocess.run([str(x) for x in args],env=kw.pop('env',env),text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,**kw)
    log.append('$ '+' '.join(str(x) for x in args)+'\n'+p.stdout)
    if check and p.returncode: raise RuntimeError(f'command exit {p.returncode}: {args}\n{p.stdout}')
    return p.stdout.strip()
def tm(*args,check=True): return run(['tmux','-S',sock,*args],check=check)
try:
    run(['bin/fm-lab-home.sh','create',LAB])
    for d in ['user-home','cache','xdg-config','xdg-data','pool','temp']:(LAB/d).mkdir()
    env.update(FM_HOME=str(LAB),HOME=str(LAB/'user-home'),XDG_CACHE_HOME=str(LAB/'cache'),XDG_CONFIG_HOME=str(LAB/'xdg-config'),XDG_DATA_HOME=str(LAB/'xdg-data'),TREEHOUSE_ROOT=str(LAB/'pool'),SHELL='/bin/bash',TMPDIR=str(LAB/'temp'),TRACEPARENT='00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01',OTEL_RESOURCE_ATTRIBUTES='service.name=trace-lab,deployment.environment=disposable',TRACE_ALLOWED_SENTINEL='keep-me',TRACE_BLOCKED_SENTINEL='drop-me',FM_SPAWN_NO_GUARD='1')
    # Stock helper owns the short private socket directory; needed for AF_UNIX's path limit.
    socketdir=run(['bin/fm-lab-home.sh','tmux-dir',LAB])
    sock=socketdir+'/tmux-'+str(os.getuid())+'/fm-lab'
    env['TMUX_TMPDIR']=socketdir
    run(['tmux','-f','/dev/null','-L','fm-lab','new-session','-d','-s','fm-lab-trace','-x','120','-y','35','-c',ROOT,'bash --noprofile --norc'])
    tm('set-option','-g','default-shell','/bin/bash')
    tm('set-option','-g','default-command','bash --noprofile --norc')
    env['TMUX']=tm('display-message','-p','#{socket_path},#{pid},0')
    proj=LAB/'projects'/'trace-project';proj.mkdir()
    run(['git','init','-q','-b','main',proj])
    (proj/'README.md').write_text('Disposable trace environment verification.\n')
    run(['git','-C',proj,'add','README.md'])
    run(['git','-C',proj,'-c','user.name=Trace Lab','-c','user.email=trace-lab@example.invalid','commit','-qm','Initial fixture'])
    probe=LAB/'observe.py'
    probe.write_text('import json,os,pathlib,sys\nkeys=["TRACEPARENT","OTEL_RESOURCE_ATTRIBUTES","TRACE_ALLOWED_SENTINEL","TRACE_BLOCKED_SENTINEL","COMPACT_ADVISER_DISABLE","GOTMPDIR"]\ndata={k:os.environ.get(k) for k in keys}\nprint(json.dumps(data,sort_keys=True),flush=True)\npathlib.Path(sys.argv[1]).write_text(json.dumps(data,sort_keys=True)+"\\n")\n')
    python=shutil.which('python3')
    (LAB/'state'/'.lock').write_text(str(os.getpid())+'\n')
    results=[]
    for enabled,allowlist in [(False,False),(True,False),(False,True),(True,True)]:
        name=('on' if enabled else 'off')+('-allowlist' if allowlist else '-ambient')
        config=LAB/'config'
        flag=config/'trace-context'
        if enabled:flag.touch()
        elif flag.exists():flag.unlink()
        allow=config/'launch-env-allowlist'
        if allowlist:allow.write_text('TRACEPARENT\nOTEL_RESOURCE_ATTRIBUTES\nTRACE_ALLOWED_SENTINEL\n')
        elif allow.exists():allow.unlink()
        run(['bash','-c','. bin/fm-trace-context-lib.sh; fm_trace_context_session_start "$FM_HOME/config" "$FM_HOME/state/.trace-context-effective"'])
        task='trace-live-'+str(os.getpid())+'-'+name
        brief=LAB/'data'/task/'brief.md';brief.parent.mkdir()
        brief.write_text('# Task\n## Captain\'s intent\nObserve the child environment of a disposable command.\n\n## Firstmate spec\nPrint the selected environment values.\n')
        output=E/(name+'-worker.json')
        import shlex
        command=shlex.join([python,str(probe),str(output)])
        run(['bin/fm-spawn.sh',task,proj,command,'--backend','tmux','--mode','local-only','--yolo','off'],timeout=100)
        for _ in range(50):
            if output.exists():break
            time.sleep(.2)
        if not output.exists():
            log.append(tm('capture-pane','-p','-t','fm-lab-trace:fm-'+task,'-S','-80'))
            raise RuntimeError('worker did not publish '+name)
        data=json.loads(output.read_text())
        meta=dict(line.split('=',1) for line in (LAB/'state'/(task+'.meta')).read_text().splitlines() if '=' in line)
        recorded=meta.get('traceparent')
        capture=tm('capture-pane','-p','-t','fm-lab-trace:fm-'+task,'-S','-80')
        (E/(name+'-pane.txt')).write_text(capture+'\n')
        if enabled:
            import re
            assert recorded and re.fullmatch(r'00-[0-9a-f]{32}-[0-9a-f]{16}-01',recorded),recorded
            assert data['TRACEPARENT']==recorded,(data,recorded)
            assert data['TRACEPARENT']!=env['TRACEPARENT'],data
        else:
            assert data['TRACEPARENT'] is None,data
            assert recorded is None,recorded
        assert data['OTEL_RESOURCE_ATTRIBUTES']==env['OTEL_RESOURCE_ATTRIBUTES'],data
        assert data['TRACE_ALLOWED_SENTINEL']=='keep-me',data
        assert data['TRACE_BLOCKED_SENTINEL']==(None if allowlist else 'drop-me'),data
        assert data['COMPACT_ADVISER_DISABLE']=='1',data
        results.append({'scenario':name,'result':'pass','worker':data,'recorded_traceparent':recorded})
    (E/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
    print(json.dumps(results,indent=2))
finally:
    if sock:
        tm('kill-server',check=False)
        run(['bin/fm-lab-home.sh','teardown',LAB],check=False)
    # Product's fixed /tmp staging directories are incidental test artifacts.
    if LAB.exists():
        import hashlib
        token=hashlib.sha256(str(LAB).encode()).hexdigest()
        for p in (LAB/'state').glob('trace-live-*.meta'):
            stage=pathlib.Path('/tmp')/('fm-'+p.stem+'+'+token)
            if stage.is_dir():shutil.rmtree(stage)
            tasktemp=pathlib.Path('/tmp')/('fm-'+p.stem)
            if tasktemp.is_dir():shutil.rmtree(tasktemp)
        for current, dirs, files in os.walk(LAB): os.chmod(current,0o700)
        shutil.rmtree(LAB)
    (E/'live-transcript.log').write_text('\n'.join(log)+'\n')
