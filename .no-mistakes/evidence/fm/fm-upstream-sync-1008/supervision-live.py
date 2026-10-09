import os,pathlib,tempfile,subprocess,shutil,json,time,traceback,signal
root=pathlib.Path.cwd(); ev=pathlib.Path('/home/cti/.no-mistakes/evidence/01M4FC0EXAEYKAXXQKZKTGBDFH')
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-host.',dir=root/'.validation-tmp')); socket=None; results=[]
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k in ('NO_MISTAKES_GATE','TMUX','TMUX_PANE'): env.pop(k,None)
env.update(FM_HOME=str(lab),TMPDIR=str(root/'.validation-tmp'),FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false')
log=open(ev/'supervision-live.log','w')
def say(s): print(s,flush=True); print(s,file=log,flush=True)
def run(args,expected=0):
 p=subprocess.run([str(root/a) if a.startswith('bin/') else a for a in args],env=env,cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=20)
 if args[0]!='tmux' or 'capture-pane' not in args: say('$ '+' '.join(args)+'\n'+p.stdout+f'[exit={p.returncode}]')
 if p.returncode!=expected: raise AssertionError(p.stdout)
 return p.stdout

def tm(*a): return run(['tmux','-L','fm-lab',*a])
def read(p):
 try:return (lab/'state'/p).read_text()
 except FileNotFoundError:return ''
def alive(pid):
 try:os.kill(int(pid),0);return True
 except (ValueError,OSError):return False
def host_live():
 for line in read('.supervision-host').splitlines():
  if line.startswith('host\t'):return alive(line.split('\t')[1])
 return False

def wait(pred,secs):
 end=time.monotonic()+secs
 while time.monotonic()<end:
  if pred():return True
  time.sleep(.25)
 return False

def capture(label):
 s=tm('capture-pane','-p','-t','primary','-S','-200');(ev/f'claude-{label}.txt').write_text(s);say('SCREEN '+label+'\n'+s);return s
try:
 run(['bin/fm-lab-home.sh','create',str(lab)])
 socket=run(['bin/fm-lab-home.sh','tmux-dir',str(lab)]).strip();env['TMUX_TMPDIR']=socket
 (lab/'state').chmod(0o700);(lab/'config/supervision-host').touch()
 (lab/'state/demo.meta').write_text('project=demo\nwindow=fm-demo\nharness=claude\n')
 (lab/'state/demo.status').touch()
 args=['new-session','-d','-s','primary','-x','160','-y','45','-c',str(root)]
 for k in ('FM_HOME','FM_POLL','FM_SIGNAL_GRACE','FM_CHECK_INTERVAL','FM_HEARTBEAT','CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION'):args+=['-e',k+'='+env[k]]
 tm(*args,'claude');time.sleep(6)
 # Bind the lab's normal session-lock input to the actual harness pane PID.
 pid=tm('display-message','-p','-t','primary','#{pane_pid}').strip();(lab/'state/.lock').write_text(pid+'\n')
 prompt='This is an isolated Firstmate validation lab. Reply with exactly READY now and use no tools. Later whenever Stop hook feedback wakes you, run bin/fm-wake-drain.sh once, then run the exact bin/fm-wake-drain.sh --ack-through command printed in WAKE_ACK_REQUIRED, then reply ACKED. Never run any other command and never arm a watcher yourself.'
 tm('send-keys','-t','primary','-l',prompt);time.sleep(.3);tm('send-keys','-t','primary','Enter')
 if not wait(host_live,90):raise RuntimeError('The real Claude Stop hook did not park a supervision host: '+capture('host-not-started'))
 if not wait(lambda:alive(read('.watch.lock/pid').strip()),20):raise RuntimeError('No live watcher after host startup')
 capture('ready');say('Host parked on actual watcher PID '+read('.watch.lock/pid').strip())
 for episode in (1,2):
  old=read('.watch.lock/pid').strip()
  with (lab/'state/demo.status').open('a') as f:f.write(f'needs-decision [at={int(time.time())}] [key=lab-{episode}]: choose lab format {episode}\n')
  if not wait(lambda:read('.supervision-host.log').count('\tpass-through\tattended\tmain-only\t')>=episode,40):raise RuntimeError('No main-only pass-through: '+read('.supervision-host.log'))
  if not wait(lambda:read('.watch.lock/pid').strip()!=old and alive(read('.watch.lock/pid').strip()),20):raise RuntimeError('Successor watcher did not survive host hand-back')
  successor=read('.watch.lock/pid').strip();say(f'Episode {episode}: predecessor={old} successor={successor} alive after hand-back')
  if not wait(lambda:'outcome=rewake' in read('.claude-autoarm-epoch'),30):raise RuntimeError('No hook rewake receipt')
  if not wait(lambda:host_live() and 'outcome=rewake' not in read('.claude-autoarm-epoch'),90):raise RuntimeError('Primary did not acknowledge and rearm after rewake: '+capture('not-rearmed'))
  if read('.watch.lock/pid').strip()!=successor:raise AssertionError('Turn end did not adopt the surviving successor')
  capture('acked-'+str(episode))
  say(f'Episode {episode}: primary handled hook feedback and the next host adopted successor {successor}')
 for p in ('.supervision-host.log','.claude-autoarm-epoch','.watch-cycle-exits.log','.watcher-down','.wake-queue','demo.status'):
  (ev/('host-'+p.lstrip('.'))).write_text(read(p))
 results.append(dict(name='Wake an idle Claude primary twice and keep the successor watcher alive across each hook hand-back',result='pass',live=True,evidence='supervision-live.log; host-supervision-host.log; claude-acked-2.txt',reason=''))
except Exception as ex:
 say(traceback.format_exc())
 capture('diagnostic')
 for p in ('.supervision-host.log','.claude-autoarm-epoch','.watch-cycle-exits.log','.watcher-down','.wake-queue'):(ev/('host-'+p.lstrip('.'))).write_text(read(p))
 results.append(dict(name='Wake an idle Claude primary twice and keep its successor watcher alive',result='fail',live=True,evidence='supervision-live.log',reason=str(ex)))
finally:
 if socket:
  tm('kill-server');time.sleep(.5)
  for p in ('.watch.lock/pid',):
   v=read(p).strip()
   if alive(v):os.kill(int(v),signal.SIGTERM)
  for line in read('.supervision-host').splitlines():
   fields=line.split('\t')
   if len(fields)>1 and fields[0]=='host' and alive(fields[1]):os.kill(int(fields[1]),signal.SIGTERM)
  time.sleep(.5);run(['bin/fm-lab-home.sh','teardown',str(lab)])
 shutil.rmtree(lab)
 (ev/'supervision-live-results.json').write_text(json.dumps(results,indent=2)+'\n');log.close()
