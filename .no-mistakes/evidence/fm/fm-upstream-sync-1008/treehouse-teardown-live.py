import os,pathlib,tempfile,subprocess,shutil,json,time,traceback
root=pathlib.Path.cwd(); ev=pathlib.Path('/home/cti/.no-mistakes/evidence/01M4FC0EXAEYKAXXQKZKTGBDFH')
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-return.',dir=root/'.validation-tmp'))
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k in ('NO_MISTAKES_GATE','TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND'): env.pop(k,None)
env.update(FM_HOME=str(lab),TMPDIR=str(root/'.validation-tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
log=open(ev/'treehouse-teardown-live.log','w'); results=[]; socket=None

def say(s): print(s,flush=True); print(s,file=log,flush=True)
def run(args,expected=0,timeout=60,e=None):
 p=subprocess.run([str(root/a) if a.startswith('bin/') else a for a in args],env=e or env,cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
 say('$ '+' '.join(args)+'\n'+p.stdout+f'[exit={p.returncode}]')
 if p.returncode!=expected: raise AssertionError(f'expected {expected} got {p.returncode}')
 return p.stdout

def brief(id,mode='no-mistakes',published=True):
 d=lab/'data'/id; d.mkdir(exist_ok=True)
 (d/'brief.md').write_text("# Task\n## Captain's intent\nValidate an isolated lab spawn; do not modify project files.\n"+("## Published intent\nValidate the lab spawn with no project modifications.\n" if published else '')+"## Firstmate spec\nThis is a disposable validation lab. Await further steering; perform no pipeline, push, PR, or CI operations.\n\n# Definition of done\nDelivery contract: mode="+mode+'\n')
def meta(id): return dict(l.split('=',1) for l in (lab/'state'/f'{id}.meta').read_text().splitlines() if '=' in l)
def spawn(id,expected=0,harness='codex --no-alt-screen'):
 return run(['bin/fm-spawn.sh',id,str(project),'--mode','no-mistakes','--yolo','off','--backend','tmux','--harness',harness],expected,90)
try:
 run(['bin/fm-lab-home.sh','create',str(lab)])
 socket=run(['bin/fm-lab-home.sh','tmux-dir',str(lab)]).strip(); env['TMUX_TMPDIR']=socket
 (lab/'state').chmod(0o700)
 run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','40','-c',str(root),'-e',f'FM_HOME={lab}','codex'])
 env['TMUX']=run(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{socket_path},#{pid},0']).strip()
 # Configure only the marked lab, with real tool binaries throughout.
 (lab/'config/backlog-backend').write_text('manual\n')
 origin=lab/'origin'; origin.mkdir(); project=lab/'projects/sample'; pool=lab/'pool'
 run(['git','-C',str(origin),'init','-q','-b','main'])
 (origin/'README.md').write_text('Disposable spawn validation project.\n')
 (origin/'treehouse.toml').write_text(f'root = "{pool}"\n')
 run(['git','-C',str(origin),'add','README.md','treehouse.toml'])
 run(['git','-C',str(origin),'-c','user.name=Firstmate Tests','-c','user.email=tests@example.invalid','commit','-qm','lab project'])
 run(['git','clone','--quiet',str(origin),str(project)])
 (lab/'config/project-capacity').write_text('sample 1\n')
 brief('landed',mode='local-only')
 run(['bin/fm-spawn.sh','landed',str(project),'--mode','local-only','--yolo','off','--backend','tmux','--harness','codex --no-alt-screen'],0,90)
 m=meta('landed'); slot=pathlib.Path(m['worktree']);assert slot.is_relative_to(pool)
 statefile=slot.parents[1]/'treehouse-state.json'
 before=json.loads(statefile.read_text());assert any(w['path']==str(slot) and w.get('lease_holder')=='landed' for w in before['worktrees'])
 run(['bin/fm-teardown.sh','landed'],0,90)
 assert not (lab/'state/landed.meta').exists()
 after=json.loads(statefile.read_text());assert not any(w['path']==str(slot) and w.get('leased') for w in after['worktrees'])
 ledger=lab/'data/spend-ledger.jsonl';assert ledger.exists()
 rows=[json.loads(l) for l in ledger.read_text().splitlines()]
 say('Recorded closure spend: '+json.dumps(rows))
 (ev/'treehouse-closure-spend.json').write_text(json.dumps(rows,indent=2)+'\n')
 results.append(dict(name='Clean up a landed local-only worker through fm-teardown, free its real Treehouse 3 lease, and record closure spend',result='pass',live=True,evidence='treehouse-teardown-live.log; treehouse-closure-spend.json',reason=''))
except Exception as ex:
 say(traceback.format_exc()); results.append(dict(name='Clean up a landed worker and release its real Treehouse lease',result='fail',live=True,evidence='treehouse-teardown-live.log',reason=str(ex)))
finally:
 if socket:
  run(['tmux','-L','fm-lab','kill-server'])
  run(['bin/fm-lab-home.sh','teardown',str(lab)])
 for current,dirs,files in os.walk(lab):
  os.chmod(current,0o700)
 shutil.rmtree(lab)
 (ev/'treehouse-teardown-live-results.json').write_text(json.dumps(results,indent=2)+'\n'); log.close()
