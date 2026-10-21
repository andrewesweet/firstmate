import json, os, pathlib, re, shlex, shutil, subprocess, time
root=pathlib.Path.cwd()
lab=root/'.l'
evidence=pathlib.Path('~/.no-mistakes/evidence/01M5F15B7RERRAM3S6V266QF0T')
assert not lab.exists()
log=[]
def record(s):
    print(s,flush=True); log.append(s)
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_', 'HERDR_', 'TREEHOUSE_', 'TASKS_AXI_')) or k in ['TMUX','TMUX_PANE','GIT_DIR','GIT_COMMON_DIR','GIT_WORK_TREE','GIT_INDEX_FILE']:
        env.pop(k,None)
env.update(FM_HOME=str(lab),HOME=str(lab/'u'),XDG_CONFIG_HOME=str(lab/'u/config'),XDG_DATA_HOME=str(lab/'u/data'),XDG_CACHE_HOME=str(lab/'u/cache'),TMPDIR=str(root/'.test-tmp'),TMUX_TMPDIR=str(lab),SHELL='/bin/bash',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',TREEHOUSE_ROOT=str(lab/'pool'),TRACEPARENT='00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01',OTEL_RESOURCE_ATTRIBUTES='service.name=trace-lab,scenario=ambient',LAB_ALLOW='retained value',LAB_BLOCK='must disappear',HISTFILE='/dev/null',FM_SPAWN_NO_GUARD='1')
def run(args,check=True,**kw):
    p=subprocess.run([str(a) for a in args],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,**kw)
    if p.returncode and check: raise RuntimeError(f'{args}: exit {p.returncode}\n{p.stdout}')
    return p

def tmux(*args,check=True): return run(['tmux','-L','fm-lab',*args],check)
try:
    run([root/'bin/fm-lab-home.sh','create',lab])
    (lab/'u').mkdir()
    (lab/'config/backlog-backend').write_text('manual\n')
    (lab/'config/keep-ai-trailers').touch()
    conf=lab/'tmux.conf'
    conf.write_text('set -g default-shell /bin/bash\nset -g default-command "/bin/bash --noprofile --norc"\nset -g remain-on-exit on\n')
    tmux('-f',str(conf),'new-session','-d','-s','primary','-x','120','-y','40','-c',str(root),'/bin/bash --noprofile --norc')
    pane=tmux('display-message','-p','-t','primary','#{socket_path},#{pid},0').stdout.strip()
    env['TMUX']=pane
    ambient=tmux('show-environment','-g','TRACEPARENT').stdout.strip()
    record('Real private tmux daemon before spawn: '+ambient)
    record('Grid: '+tmux('display-message','-p','-t','primary','#{pane_width}x#{pane_height}').stdout.strip())
    project=lab/'project'; project.mkdir()
    run(['git','init','-q','-b','main',project])
    run(['git','-C',project,'-c','user.name=Trace Lab','-c','user.email=trace@example.invalid','commit','--allow-empty','-qm','Initial lab commit'])
    run(['treehouse','init'],cwd=project)
    record('Tools: '+run(['treehouse','--version']).stdout.strip()+'; '+run(['tmux','-V']).stdout.strip())
    owner=str(os.getpid())
    (lab/'state/.lock').write_text(owner+'\n')
    cases=[('off-ambient',False,None),('off-allowlist',False,['TRACEPARENT','OTEL_RESOURCE_ATTRIBUTES','LAB_ALLOW']),('on-ambient',True,None),('on-allowlist',True,['OTEL_RESOURCE_ATTRIBUTES','LAB_ALLOW']),('off-empty-allowlist',False,[])]
    results=[]
    for label,on,allowed in cases:
        flag=lab/'config/trace-context'
        if on: flag.touch()
        else: flag.unlink(missing_ok=True)
        allow=lab/'config/launch-env-allowlist'
        if allowed is None: allow.unlink(missing_ok=True)
        else: allow.write_text('\n'.join(allowed)+'\n')
        run(['bash','-c','. bin/fm-trace-context-lib.sh; unset FM_TRACE_CONTEXT; fm_trace_context_session_start "$FM_HOME/config" "$FM_HOME/state/.trace-context-effective"'])
        task=f'tr{os.getpid()}-{label}'
        data=lab/'data'/task; data.mkdir()
        (data/'brief.md').write_text('# Task\n## Captain\'s intent\nObserve the launched environment.\n\n## Firstmate spec\nReport the trace carrier and environmental controls.\n')
        observe=lab/(label+'.json')
        code='import json,os,pathlib; d={k:os.environ.get(k) for k in ["TRACEPARENT","OTEL_RESOURCE_ATTRIBUTES","LAB_ALLOW","LAB_BLOCK","FM_TASK_ID","COMPACT_ADVISER_DISABLE"]}; d["cwd"]=os.getcwd(); pathlib.Path('+repr(str(observe))+').write_text(json.dumps(d)); print(json.dumps(d),flush=True)'
        command=shlex.join(['/usr/bin/env','python3','-c',code])
        record('\nCASE '+label+'; trace='+('on' if on else 'off')+'; allowlist='+repr(allowed))
        p=run([root/'bin/fm-spawn.sh',task,project,command,'--mode','local-only','--yolo','off','--backend','tmux'],check=False,timeout=100)
        record(p.stdout.strip())
        assert p.returncode==0, f'spawn {label} exited {p.returncode}'
        for _ in range(50):
            if observe.exists(): break
            time.sleep(.2)
        assert observe.exists(), 'worker did not produce observation: '+tmux('capture-pane','-p','-t','primary:fm-'+task,'-S','-60').stdout
        observed=json.loads(observe.read_text())
        meta=(lab/'state'/f'{task}.meta').read_text()
        expected=next((s.split('=',1)[1] for s in meta.splitlines() if s.startswith('traceparent=')),None)
        record('Actual child environment: '+json.dumps(observed,sort_keys=True))
        record('Recorded traceparent: '+repr(expected))
        if on:
            assert re.fullmatch(r'00-[0-9a-f]{32}-[0-9a-f]{16}-01',observed['TRACEPARENT'])
            assert observed['TRACEPARENT']==expected
            assert observed['TRACEPARENT'].split('-')[1]!=env['TRACEPARENT'].split('-')[1]
        else: assert observed['TRACEPARENT'] is None and expected is None
        assert observed['OTEL_RESOURCE_ATTRIBUTES']==(None if allowed==[] else env['OTEL_RESOURCE_ATTRIBUTES'])
        assert observed['LAB_ALLOW']==(None if allowed==[] else env['LAB_ALLOW'])
        assert observed['LAB_BLOCK']==(env['LAB_BLOCK'] if allowed is None else None)
        assert observed['FM_TASK_ID']==task
        assert observed['COMPACT_ADVISER_DISABLE']=='1'
        assert observed['cwd']!=str(project) and observed['cwd'].startswith(str(lab/'pool')+'/')
        (evidence/(label+'.json')).write_text(json.dumps({'scenario':label,'daemon_ambient':env['TRACEPARENT'],'observed_child':observed,'recorded_traceparent':expected},indent=2)+'\n')
        tail=tmux('capture-pane','-p','-t','primary:fm-'+task,'-S','-45').stdout
        (evidence/(label+'-pane.txt')).write_text(tail)
        record('PASS: observed child carrier, task metadata, allowlist, OTEL attributes, task marker, and isolated cwd satisfy independent intent.')
        results.append(label)
    record('\nAll five real spawn scenarios passed: '+', '.join(results))
finally:
    p=tmux('kill-server',check=False)
    record('Private tmux cleanup exit='+str(p.returncode))
    # Product-created /tmp launch namespaces are ephemeral toolchain files;
    # ask the product cleanup API to remove these, rather than broad host cleanup.
    if (lab/'state').exists():
        for f in (lab/'state').glob('*.meta'):
            task=f.stem
            # All fixture project commits remain on main, with no worker edits.
            p=run([root/'bin/fm-teardown.sh',task],check=False,timeout=45)
            record('Product cleanup '+task+' exit='+str(p.returncode)+'\n'+p.stdout.strip())
    shutil.rmtree(lab,ignore_errors=True)
    record('Disposable lab removed: '+str(not lab.exists()))
    (evidence/'live-trace-spawns.log').write_text('\n'.join(log)+'\n')
