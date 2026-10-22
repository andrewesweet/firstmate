import os,pathlib,tempfile,subprocess,shutil,time,shlex,re,html
root=pathlib.Path.cwd(); ev=pathlib.Path(__file__).parent
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.',dir='/tmp'))
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ['TMUX','TMUX_PANE','NO_MISTAKES_GATE','NM_HOME']}
env.update(FM_HOME=str(lab),TMUX_TMPDIR=str(lab/'tmux'),NM_HOME=str(lab/'nm'))
def run(a,check=True):
 p=subprocess.run(a,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
 if check: assert p.returncode==0,(a,p.stdout)
 return p.stdout
def tm(*a): return run(['tmux','-L','fm-lab',*a])
def drain():
 out=run(['bin/fm-wake-drain.sh'],False)
 m=re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)',out)
 if m: run(['bin/fm-wake-drain.sh','--ack-through',m[1],'--recovery-generation',m[2]])
def cycle(label):
 beat=lab/'state/.last-watcher-beat'; beat.unlink(missing_ok=True)
 p=subprocess.Popen(['bin/fm-watch.sh'],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
 for i in range(500):
  if p.poll() is not None: break
  count=lab/'state/.count-primary_worker'
  if i>=200 and count.exists() and int(count.read_text().strip() or 0)>=3: break
  time.sleep(.1)
 if p.poll() is None: p.terminate()
 out=p.communicate(timeout=10)[0]
 print(label+': '+(out.strip() or '(no alert)'),flush=True)
 drain(); return out
try:
 run(['bin/fm-lab-home.sh','create',str(lab)])
 for d in ['tmux','home','codex','nm','work']: (lab/d).mkdir()
 auth=pathlib.Path(os.environ['HOME'])/'.codex/auth.json'
 if auth.is_file(): shutil.copyfile(auth,lab/'codex/auth.json')
 command=['env','HOME='+str(lab/'home'),'CODEX_HOME='+str(lab/'codex'),'codex','--no-alt-screen']
 tm('new-session','-d','-s','primary','-n','worker','-x','120','-y','40','-c',str(root),'-e','FM_HOME='+str(lab),shlex.join(command))
 time.sleep(8)
 screen=tm('capture-pane','-p','-t','primary')
 print('Real Codex pane (120x40):\n'+screen,flush=True)
 if 'trust' in screen.lower():
  tm('send-keys','-t','primary','Enter'); time.sleep(3)
 if 'Hooks need review' in tm('capture-pane','-p','-t','primary'):
  tm('send-keys','-t','primary','Down','Down','Enter'); time.sleep(5)
 print('Current pane after trust:\n'+tm('capture-pane','-p','-t','primary'),flush=True)
 print('Actual tmux windows:\n'+tm('list-windows','-t','primary','-F','#{window_index} #{window_name} #{pane_current_command}'),flush=True)
 socket=tm('display-message','-p','-t','primary','#{socket_path}').strip(); env['TMUX']=socket+',0,0'
 (lab/'state/worker.meta').write_text(f'kind=scout\nbackend=tmux\nharness=codex\nwindow=primary:worker\nworktree={lab}/work\n')
 (lab/'state/worker.status').write_text('working: validating a progressing viewport\n')
 out=run(['bash','-c','. bin/fm-tmux-lib.sh; . bin/fm-backend.sh; . bin/fm-busy-lib.sh; fm_busy_classify_meta "$FM_HOME/state/worker.meta" worker "$FM_HOME/state"'])
 print('Real semantic classification: '+out,flush=True); assert out.startswith('unknown')
 out=run(['bash','-c','. bin/fm-tmux-lib.sh; . bin/fm-backend.sh; fm_backend_agent_alive tmux primary:worker'])
 print('Real endpoint classification: '+out,flush=True); assert out.strip()=='alive'
 env.update(FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_STALE_ESCALATE_SECS='180',FM_PAUSE_RESURFACE_SECS='300')
 # Acknowledge the ordinary initial status notification, then the first stale sight.
 a=cycle('initial notification')
 a=cycle('first inconclusive stale sight')
 assert 'stale: primary:worker' in a
 tm('send-keys','-t','primary','-l','unsent progressing viewport')
 time.sleep(1)
 assert 'unsent progressing viewport' in tm('capture-pane','-p','-t','primary'), 'typed input never reached the composer'
 (lab/'state/worker.status').touch()
 # The status content remains unchanged; only its progress timestamp moves.
 b=cycle('changed viewport with recent progress')
 assert 'stale:' not in b and not b.strip(),b
 # Age progress evidence and force another genuinely changed pane.
 old=time.time()-1000
 os.utime(lab/'state/worker.status',(old,old))
 os.utime(lab/'work',(old,old))
 tm('send-keys','-t','primary','-l',' without progress')
 c=cycle('changed viewport without progress')
 assert 'stale: primary:worker' in c,c
 screen=tm('capture-pane','-p','-t','primary')
 (ev/'progress-live-screen.html').write_text('<!doctype html><meta charset="utf-8"><title>Live Codex monitoring scenario</title><pre style="background:#111;color:#eee;padding:20px;font:15px monospace">'+html.escape(screen)+'</pre>')
 print('PASS: recent progress bounds the repeat; liveness alone does not silence a changed pane.',flush=True)
finally:
 run(['tmux','-L','fm-lab','kill-server'],False)
 shutil.rmtree(lab)
 print('Private Codex server stopped; disposable lab removed.',flush=True)
