import json, os, pathlib, shutil, subprocess, tempfile, time
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('~/.no-mistakes/evidence/01M5C9TKX989GA6P9TQ8D20JT6')
AMBIENT = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'
OTEL = 'service.name=trace-lab,deployment.environment=disposable'
lab = pathlib.Path(tempfile.mkdtemp(prefix='.trace-lab-', dir=ROOT))
socket = ROOT / ('.trace-socket-' + str(os.getpid()))
env = dict(os.environ)
for key in list(env):
    if key.startswith('FM_') or key in ('TMUX', 'TMUX_PANE', 'HERDR_ENV', 'HERDR_SESSION', 'HERDR_SOCKET_PATH', 'ZELLIJ', 'CLAUDE_CONFIG_DIR'):
        env.pop(key, None)
env.update(HOME=str(lab/'user'), SHELL='/bin/bash', TRACEPARENT=AMBIENT,
           OTEL_RESOURCE_ATTRIBUTES=OTEL, TRACE_LAB_DROP='must-not-pass-allowlist',
           TREEHOUSE_ROOT=str(lab/'pool'), TMPDIR=str(lab/'tmp'),
           XDG_CONFIG_HOME=str(lab/'user/config'), XDG_DATA_HOME=str(lab/'user/data'),
           XDG_CACHE_HOME=str(lab/'user/cache'), GIT_CONFIG_GLOBAL='/dev/null',
           GIT_AUTHOR_NAME='Trace Lab', GIT_AUTHOR_EMAIL='trace-lab@example.invalid',
           GIT_COMMITTER_NAME='Trace Lab', GIT_COMMITTER_EMAIL='trace-lab@example.invalid')
(lab/'user').mkdir(); (lab/'tmp').mkdir()

def run(args, check=True, **kwargs):
    p = subprocess.run([str(a) for a in args], env=kwargs.pop('env', env), text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, **kwargs)
    if check and p.returncode:
        raise RuntimeError(f'{args}: exit {p.returncode}\n{p.stdout}')
    return p

def tmux(*args, **kwargs):
    return run(['tmux', '-S', socket, *args], **kwargs)

results=[]; ids=[]
BASELINE = os.environ.get('TRACE_LAB_BASELINE') == '1'
if BASELINE:
    EVIDENCE = EVIDENCE / 'baseline'
    EVIDENCE.mkdir(exist_ok=True)
try:
    code=ROOT
    if BASELINE:
        code=lab/'baseline'
        shutil.copytree(ROOT/'bin',code/'bin')
        previous=run(['git','show','a65dceee3992ec9d98811a454eb0820bcf068f0e:bin/fm-spawn.sh']).stdout
        (code/'bin/fm-spawn.sh').write_text(previous)
    project=lab/'project'
    run(['git','init','-q','-b','main',project])
    (project/'seed.txt').write_text('disposable trace propagation lab\n')
    run(['git','-C',project,'add','seed.txt'])
    run(['git','-C',project,'commit','-qm','seed'])
    run(['git','clone','-q','--bare',project,lab/'origin.git'])
    run(['git','-C',project,'remote','add','origin',str(lab/'origin.git')])
    run(['git','-C',project,'fetch','-q','origin'])
    run(['git','-C',project,'remote','set-head','origin','main'])
    probe=lab/'worker.py'
    probe.write_text('import json,os,pathlib,sys\np={k:os.environ.get(k) for k in ("TRACEPARENT","OTEL_RESOURCE_ATTRIBUTES","TRACE_LAB_DROP","FM_TASK_ID","GOTMPDIR")}\np["cwd"]=os.getcwd()\npathlib.Path(sys.argv[1]).write_text(json.dumps(p,indent=2)+"\\n")\nprint(json.dumps(p),flush=True)\n')
    tmux('-f','/dev/null','new-session','-d','-s','fm-lab-trace','-x','120','-y','40','-c',str(ROOT),'/bin/bash --noprofile --norc')
    tmux('set-option','-g','default-shell','/bin/bash')
    tmux('set-option','-g','default-command','/bin/bash --noprofile --norc')
    tmux_identity=tmux('display-message','-p','#{socket_path},#{pid},0').stdout.strip()
    print('Real tmux, 120x40 panes; real Treehouse; public fm-spawn raw-command worker.', flush=True)
    cases=[('off',False)] if BASELINE else [('off',False),('on',False),('off',True),('on',True)]
    for decision,allowlist in cases:
        label=f'{decision}-allowlist-{str(allowlist).lower()}'
        task=f'tclive-{os.getpid()}-{len(results)}'; ids.append(task)
        home=lab/label
        run([ROOT/'bin/fm-lab-home.sh','create',home])
        (home/'config/backlog-backend').write_text('manual\n')
        (home/'config/keep-ai-trailers').touch()
        (home/'state/.lock').write_text(str(os.getpid())+'\n')
        (home/'state/.last-watcher-beat').touch()
        (home/'data'/task).mkdir()
        (home/'data'/task/'brief.md').write_text("# Task\n## Captain's intent\nObserve the environment of a freshly spawned worker.\n\n## Firstmate spec\nWrite the trace carrier and telemetry attributes to the lab output.\n")
        if allowlist:
            # Adversarial: explicitly request ambient TRACEPARENT forwarding.
            (home/'config/launch-env-allowlist').write_text('TRACEPARENT\nOTEL_RESOURCE_ATTRIBUTES\n')
        caseenv=dict(env,FM_HOME=str(home),TMUX=tmux_identity,FM_TRACE_CONTEXT=decision)
        run(['bash','-c','. "$1/bin/fm-trace-context-lib.sh"; fm_trace_context_session_start "$FM_HOME/config" "$FM_HOME/state/.trace-context-effective"','bash',ROOT],env=caseenv)
        output=home/'worker.json'
        command=f"{shutil.which('python3')} '{probe}' '{output}'"
        print(f'\nScenario {label}: TRACEPARENT ambient={AMBIENT}; OTEL={OTEL}',flush=True)
        spawn=run([code/'bin/fm-spawn.sh',task,project,command,'--mode','no-mistakes','--yolo','off','--backend','tmux'],env=caseenv,check=False,timeout=100)
        print(spawn.stdout,flush=True)
        (EVIDENCE/f'{label}-spawn.log').write_text(spawn.stdout)
        for i in range(100):
            if output.exists(): break
            time.sleep(.1)
        panes=tmux('list-panes','-a','-F','#{pane_id} #{window_name} #{pane_current_path}').stdout
        captures=[]
        for line in panes.splitlines():
            captures.append(line+'\n'+tmux('capture-pane','-p','-t',line.split()[0],'-S','-100').stdout)
        (EVIDENCE/f'{label}-panes.txt').write_text('\n'.join(captures))
        if spawn.returncode or not output.exists():
            raise RuntimeError(f'{label}: spawn exit={spawn.returncode}; worker output exists={output.exists()}\n'+ '\n'.join(captures))
        child=json.loads(output.read_text())
        meta=(home/'state'/f'{task}.meta').read_text()
        trace=[x.split('=',1)[1] for x in meta.splitlines() if x.startswith('traceparent=')]
        (EVIDENCE/f'{label}-worker.json').write_text(output.read_text())
        (EVIDENCE/f'{label}-task.meta').write_text(meta)
        assert child['OTEL_RESOURCE_ATTRIBUTES']==OTEL,child
        assert child['TRACE_LAB_DROP']==(None if allowlist else 'must-not-pass-allowlist'),child
        assert child['FM_TASK_ID']==task,child
        assert child['cwd']!=str(project) and child['cwd'].startswith(str(lab/'pool')),child
        if decision=='off':
            if BASELINE:
                assert child['TRACEPARENT']==AMBIENT and not trace,(child,trace)
                print('BASELINE DEFECT REPRODUCED: stale ambient carrier reached trace-off worker.',flush=True)
            else:
                assert child['TRACEPARENT'] is None and not trace,(child,trace)
        else:
            assert len(trace)==1 and child['TRACEPARENT']==trace[0] and child['TRACEPARENT']!=AMBIENT,(child,trace)
        result=dict(scenario=label,result='pass',child=child,recorded_traceparent=trace)
        results.append(result)
        print(json.dumps(result,indent=2),flush=True)
    (EVIDENCE/'live-trace-results.json').write_text(json.dumps(results,indent=2)+'\n')
finally:
    tmux('kill-server',check=False)
    socket.unlink(missing_ok=True)
    for attempt in range(30):
        try:
            shutil.rmtree(lab)
            break
        except FileNotFoundError:
            break
        except OSError:
            if attempt==29: raise
            time.sleep(.2)
    # These private per-task temp roots are incidental outputs of fm-spawn.
    for task in ids:
        shutil.rmtree('/tmp/fm-'+task,ignore_errors=True)
    print('Private tmux server stopped; disposable lab and task temp roots removed.',flush=True)
