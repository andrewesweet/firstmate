import os, pathlib, tempfile, subprocess, shutil
root=pathlib.Path.cwd()
lab=pathlib.Path(tempfile.mkdtemp(prefix='.gate-public-',dir=root))
env={k:v for k,v in os.environ.items() if not k.startswith('FM_')}
env.update(FM_HOME=str(lab),NM_HOME=str(lab/'nm'))
def run(args, expected=0,cwd=root):
    p=subprocess.run(args,cwd=cwd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
    print('$ '+' '.join(map(str,args)),flush=True); print(p.stdout,flush=True)
    assert p.returncode==expected,(args,p.returncode)
    return p.stdout
try:
    for d in ['state','config','nm','project']: (lab/d).mkdir()
    run(['bin/fm-capacity.sh'])
    (lab/'state/ship.meta').write_text('kind=ship\n')
    (lab/'state/scout.meta').write_text('kind=scout\n')
    (lab/'state/mate.meta').write_text('kind=secondmate\n')
    (lab/'config/lane-capacity').write_text('5\n')
    out=run(['bin/fm-capacity.sh']); assert 'lanes=2 target=5 secondmates=1' in out
    (lab/'config/lane-capacity').write_text('1\n')
    out=run(['bin/fm-capacity.sh']); assert 'free_lanes=0' in out
    (lab/'config/lane-capacity').write_text('2\n3\n')
    out=run(['bin/fm-capacity.sh'],1); assert 'reason=invalid-target' in out
    (lab/'config/crew-harness').write_text('claude\n')
    (lab/'config/secondmate-harness').write_text('codex gpt-5 high\nmate alpha: grok grok-4 low\n')
    for mode,value in [('secondmate','grok'),('secondmate-model','grok-4'),('secondmate-effort','low')]: assert run(['bin/fm-harness.sh',mode,'alpha']).strip()==value
    assert run(['bin/fm-harness.sh','secondmate','beta']).strip()=='codex'
    assert run(['bin/fm-harness.sh','crew']).strip()=='claude'
    (lab/'config/secondmate-harness').write_text('claude\nmate alpha: grok grok-4 low\n')
    assert run(['bin/fm-harness.sh','secondmate','alpha']).strip()=='grok'
    (lab/'config/secondmate-harness').write_text('codex\nmate alpha: grok\nmate bad/id: grok\n')
    out=run(['bin/fm-harness.sh','secondmate','alpha'],1); assert 'line 3' in out
    out=run(['bin/fm-supervision-instructions.sh','--harness','omp']); assert 'fm <project>' in out
    run(['git','init','-q','-b','fm/live-no-run',str(lab/'project')])
    run(['git','-C',str(lab/'project'),'-c','user.name=Live Test','-c','user.email=live@example.invalid','commit','--allow-empty','-qm','fixture'])
    out=run(['no-mistakes','axi','status'],expected=1,cwd=lab/'project')
    print('UNTESTED: explicit no-run live response requires initializing a disposable no-mistakes repository; this assigned phase forbids init.',flush=True)
finally:
    shutil.rmtree(lab)
