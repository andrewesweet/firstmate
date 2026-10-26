import os, pathlib, subprocess, tempfile, json, time, shlex, shutil, re
ROOT = pathlib.Path.cwd()
EV = pathlib.Path('~/.no-mistakes/evidence/01M5WJV0PFF30JVSQ3GW5P8YPV')
LAB = pathlib.Path(tempfile.mkdtemp(prefix='.trace-live-', dir=ROOT))
SOCK = EV / 'trace-lab.sock'
STALE = '00-11111111111111111111111111111111-2222222222222222-01'
log = open(EV/'live-spawn.log', 'w', buffering=1)
env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'GIT_', 'TASKS_AXI_', 'HERDR_', 'REX_', 'CLAUDE_', 'CODEX_')) and k not in ('TMUX','TMUX_PANE','NO_MISTAKES_GATE','CLAUDECODE','PI_CODING_AGENT')}
env.update(HOME=str(LAB/'user'), SHELL='/bin/bash', XDG_CONFIG_HOME=str(LAB/'user/.config'), XDG_CACHE_HOME=str(LAB/'user/.cache'), XDG_DATA_HOME=str(LAB/'user/.local/share'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', TREEHOUSE_ROOT=str(LAB/'pool'), TRACEPARENT=STALE, OTEL_RESOURCE_ATTRIBUTES='service.name=trace-lab,custom.marker=kept', LAB_KEEP='allowed', LAB_DROP='filtered', TERM='xterm-256color')
pathlib.Path(env['HOME']).mkdir()
def run(args, *, check=True, timeout=100, work=ROOT):
    p=subprocess.run([str(a) for a in args], env=env, cwd=work, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    log.write('$ '+shlex.join(map(str,args))+'\n'+p.stdout+'\nexit='+str(p.returncode)+'\n')
    if check and p.returncode: raise RuntimeError(p.stdout)
    return p

def tmux(*args, **kwargs): return run(['tmux','-S',SOCK,*args],**kwargs)
results=[]
try:
    home=LAB/'home'
    run(['bin/fm-lab-home.sh','create',home])
    env.update(FM_HOME=str(home), FM_SPAWN_NO_GUARD='1')
    (home/'state/.lock').write_text(str(os.getpid())+'\n')
    (home/'state/.last-watcher-beat').touch()
    proj=LAB/'project'; proj.mkdir()
    run(['git','init','-q','-b','main'],work=proj)
    (proj/'README.md').write_text('Disposable live trace environment probe.\n')
    run(['git','add','.'],work=proj)
    run(['git','-c','user.name=Trace Lab','-c','user.email=trace@example.invalid','commit','-qm','seed'],work=proj)
    tmux('-f','/dev/null','new-session','-d','-s','firstmate','-x','120','-y','40','-c',ROOT,'/bin/bash --noprofile --norc')
    tmux('set-option','-g','default-shell','/bin/bash')
    tmux('set-option','-g','default-command','/bin/bash --noprofile --norc')
    env['TMUX']=tmux('display-message','-p','#{socket_path},#{pid},#{session_id}').stdout.strip().replace(',$',',')
    tmux('show-environment','-g','TRACEPARENT')
    probe=LAB/'probe.py'
    probe.write_text('import os,sys,json,pathlib\nkeys=["TRACEPARENT","OTEL_RESOURCE_ATTRIBUTES","LAB_KEEP","LAB_DROP","FM_TASK_ID","COMPACT_ADVISER_DISABLE"]\npayload={k:os.environ.get(k) for k in keys}\npayload["cwd"]=os.getcwd()\npathlib.Path(sys.argv[1]).write_text(json.dumps(payload,indent=2)+"\\n")\nprint(json.dumps(payload),flush=True)\n')
    for enabled,allowlist in [(False,False),(False,True),(True,False),(True,True),(True,False)]:
        case=f'{"on" if enabled else "off"}-{"allowlist" if allowlist else "ambient"}-{len(results)+1}'
        ident='trace-'+case
        cfg=home/'config/launch-env-allowlist'
        if allowlist: cfg.write_text('LAB_KEEP\nOTEL_RESOURCE_ATTRIBUTES\nTRACEPARENT\n')
        else: cfg.unlink(missing_ok=True)
        traceflag=home/'config/trace-context'
        if enabled: traceflag.touch()
        else: traceflag.unlink(missing_ok=True)
        run(['/bin/bash','-c','. bin/fm-trace-context-lib.sh; fm_trace_context_session_start "$FM_HOME/config" "$FM_HOME/state/.trace-context-effective"'])
        task=home/'data'/ident; task.mkdir()
        (task/'brief.md').write_text("# Task\n## Captain's intent\nObserve the environment of an isolated worker.\n\n## Firstmate spec\nRecord trace context and unrelated environment attributes.\n")
        output=EV/(case+'.json')
        output.unlink(missing_ok=True)
        raw='python3 '+shlex.quote(str(probe))+' '+shlex.quote(str(output))
        spawned=run(['bin/fm-spawn.sh',ident,proj,raw,'--backend','tmux','--mode','local-only','--yolo','off'],check=False)
        if spawned.returncode:
            for window in tmux('list-windows','-F','#{window_id}').stdout.splitlines():
                log.write(tmux('capture-pane','-p','-t',window,'-S','-80').stdout)
            raise RuntimeError('spawn failed: '+case)
        for _ in range(100):
            if output.exists(): break
            time.sleep(.1)
        child=json.loads(output.read_text())
        meta=dict(line.split('=',1) for line in (home/'state'/(ident+'.meta')).read_text().splitlines() if '=' in line)
        recorded=meta.get('traceparent')
        if enabled:
            assert re.fullmatch(r'00-[a-f0-9]{32}-[a-f0-9]{16}-01',child['TRACEPARENT']),child
            assert child['TRACEPARENT']==recorded and child['TRACEPARENT']!=STALE,(child,recorded)
        else: assert child['TRACEPARENT'] is None and recorded is None,(child,recorded)
        assert child['OTEL_RESOURCE_ATTRIBUTES']==env['OTEL_RESOURCE_ATTRIBUTES'],child
        assert child['LAB_KEEP']=='allowed',child
        assert child['LAB_DROP']==(None if allowlist else 'filtered'),child
        assert child['FM_TASK_ID']==ident and child['COMPACT_ADVISER_DISABLE']=='1',child
        assert child['cwd']!=str(proj) and str(LAB) in child['cwd'],child
        window=meta['window']
        (EV/(case+'-pane.txt')).write_text(tmux('capture-pane','-p','-t',window,'-S','-80').stdout)
        results.append(dict(case=case,traceparent=child['TRACEPARENT'],recorded=recorded,allowlist=allowlist,result='pass'))
        (EV/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
        log.write('OBSERVED '+json.dumps(results[-1])+'\n')
    carriers=[x['traceparent'] for x in results if x['traceparent']]
    assert len(carriers)==len(set(carriers)),carriers
    log.write('Independent per-task carriers confirmed.\n')
finally:
    tmux('kill-server',check=False)
    SOCK.unlink(missing_ok=True)
    for path in LAB.rglob("*"):
        if path.is_dir() and not path.is_symlink(): path.chmod(path.stat().st_mode | 0o700)
    shutil.rmtree(LAB)
    log.write('Disposed lab home, project, Treehouse pool, and private tmux server.\n')
    log.close()
print(json.dumps(results,indent=2))
