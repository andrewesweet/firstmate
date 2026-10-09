import os,pathlib,tempfile,subprocess,shutil,json,time,traceback
root=pathlib.Path.cwd(); ev=pathlib.Path('/home/cti/.no-mistakes/evidence/01M4FC0EXAEYKAXXQKZKTGBDFH')
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-capacity.',dir=root/'.validation-tmp'))
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k in ('NO_MISTAKES_GATE','TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND'): env.pop(k,None)
env.update(FM_HOME=str(lab),TMPDIR=str(root/'.validation-tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
log=open(ev/'capacity-live.log','w'); results=[]; socket=None

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
 # Bad brief and unsupported exclusion guards run before any endpoint or slot exists.
 brief('missing-intent',published=False); spawn('missing-intent',1)
 assert not (lab/'state/missing-intent.meta').exists()
 brief('mode-drift',mode='direct-PR'); spawn('mode-drift',1)
 assert not (lab/'state/mode-drift.meta').exists()
 (lab/'config/crew-exclude-tools').write_text('write\n')
 brief('cannot-hide'); spawn('cannot-hide',1,harness='codex')
 assert not (lab/'state/cannot-hide.meta').exists()
 (lab/'config/crew-exclude-tools').write_text('invalid tool name\n')
 brief('malformed-tools'); spawn('malformed-tools',1,harness='pi')
 assert not (lab/'state/malformed-tools.meta').exists()
 (lab/'config/crew-exclude-tools').unlink()
 results.append(dict(name='Reject missing published intent, delivery-mode drift, and unsupported or malformed tool exclusions before provisioning',result='pass',live=True,evidence='capacity-live.log',reason=''))
 brief('holder'); spawn('holder')
 m=meta('holder'); slot=pathlib.Path(m['worktree']); assert slot.is_relative_to(pool)
 state=slot.parents[1]/'treehouse-state.json'
 leased=json.loads(state.read_text()); holder=[w for w in leased['worktrees'] if w['path']==str(slot)][0]
 assert holder['leased'] and holder['lease_holder']=='holder'
 say('Treehouse durable holder: '+json.dumps(holder))
 before=run(['tmux','-L','fm-lab','list-windows','-a','-F','#{window_id}:#{window_name}'])
 brief('queued'); spawn('queued',75)
 assert not (lab/'state/queued.meta').exists() and not (lab/'data/queued/launch-brief.md').exists()
 after=run(['tmux','-L','fm-lab','list-windows','-a','-F','#{window_id}:#{window_name}']); assert before==after
 # Record the ready-PR handoff as the product's capacity contract specifies.
 with (lab/'state/holder.meta').open('a') as f: f.write('pr=https://github.com/example/lab/pull/1\n')
 spawn('queued'); assert (lab/'state/queued.meta').exists()
 say('Observed: one real Codex endpoint holds a leased slot; a second spawn exits 75 with no new endpoint, brief overlay, or record; recorded PR handoff permits the second real launch.')
 (ev/'capacity-task-records.json').write_text(json.dumps({'holder':meta('holder'),'queued':meta('queued'),'lease':holder},indent=2)+'\n')
 results.append(dict(name='Spawn a worker at capacity one, defer the next worker, and admit it after a PR handoff',result='pass',live=True,evidence='capacity-live.log; capacity-task-records.json',reason=''))
 # Both clean slots belong only to this throwaway lab. Release exact owner leases.
 for id in ('holder','queued'):
  m=meta(id); run(['treehouse','return','--force','--if-lease-holder',id,m['worktree']])
except Exception as ex:
 say(traceback.format_exc()); results.append(dict(name='Spawn a worker at capacity one, defer the next worker, and admit it after a PR handoff',result='fail',live=True,evidence='capacity-live.log',reason=str(ex)))
finally:
 if socket:
  run(['tmux','-L','fm-lab','kill-server'])
  run(['bin/fm-lab-home.sh','teardown',str(lab)])
 for current,dirs,files in os.walk(lab):
  os.chmod(current,0o700)
 shutil.rmtree(lab)
 (ev/'capacity-live-results.json').write_text(json.dumps(results,indent=2)+'\n'); log.close()
