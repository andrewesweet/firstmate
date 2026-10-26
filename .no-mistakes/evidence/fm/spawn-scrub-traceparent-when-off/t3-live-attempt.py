import os,pathlib,subprocess,tempfile,shutil
root=pathlib.Path.cwd()
evidence=pathlib.Path('~/.no-mistakes/evidence/01M5WJV0PFF30JVSQ3GW5P8YPV/t3-live-attempt.log')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.t3-trace-live-',dir=root))
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','CODEX_','CLAUDE_','GIT_','HERDR_')) and k not in ('NO_MISTAKES_GATE','TMUX','TMUX_PANE')}
env.update(HOME=str(lab/'user'),CODEX_HOME=str(lab/'user/.codex'),FM_HOME=str(lab/'home'),FM_SPAWN_NO_GUARD='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',TRACEPARENT='00-11111111111111111111111111111111-2222222222222222-01')
(lab/'user/.codex').mkdir(parents=True)
with evidence.open('w') as out:
    def run(args,cwd=root):
        p=subprocess.run(args,env=env,cwd=cwd,capture_output=True,text=True,timeout=40)
        out.write('$ '+' '.join(map(str,args))+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode)+'\n')
        return p
    try:
        run(['bin/fm-lab-home.sh','create',str(lab/'home')])
        project=lab/'project';project.mkdir()
        run(['git','init','-q','-b','main'],cwd=project)
        (project/'README.md').write_text('Disposable T3 live probe\n')
        run(['git','add','.'],cwd=project)
        run(['git','-c','user.name=Trace Lab','-c','user.email=trace@example.invalid','commit','-qm','seed'],cwd=project)
        brief=lab/'home/data/trace-t3-probe/brief.md';brief.parent.mkdir(parents=True)
        brief.write_text("# Task\n## Captain's intent\nObserve T3 trace suppression.\n\n## Firstmate spec\nRead the spawned worker environment.\n")
        run(['bin/fm-spawn.sh','trace-t3-probe',str(project),'--scout','--harness','codex','--backend','t3code'])
        out.write('T3 CLI on PATH: '+str(shutil.which('t3'))+'\n')
        out.write('Repository-supplied T3 server: none; only client and explicitly fake test server are present.\n')
        out.write('No production credentials or services accessed. Signing in or minting a credential is forbidden by this test prompt.\n')
    finally:
        shutil.rmtree(lab)
        out.write('Disposable lab removed.\n')
print(evidence.read_text())
