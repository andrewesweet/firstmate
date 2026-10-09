import os,pathlib,tempfile,subprocess,shutil,json,time,signal,ctypes,select,struct,traceback
root=pathlib.Path.cwd();ev=pathlib.Path('/home/cti/.no-mistakes/evidence/01M4FC0EXAEYKAXXQKZKTGBDFH')
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-watch.',dir=root/'.validation-tmp'));socket=None;watch=None;server=None;fd=None;results=[]
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k in ('NO_MISTAKES_GATE','TMUX','TMUX_PANE'):env.pop(k,None)
env.update(FM_HOME=str(lab),TMPDIR=str(root/'.validation-tmp'),FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999')
log=open(ev/'watcher-live.log','w')
def say(s):print(s,flush=True);print(s,file=log,flush=True)
def run(args):
 p=subprocess.run([str(root/a) if a.startswith('bin/') else a for a in args],env=env,cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=10)
 say('$ '+' '.join(args)+'\n'+p.stdout+f'[exit={p.returncode}]');assert p.returncode==0,p.stdout;return p.stdout

def tm(*args):return run(['tmux','-L','fm-lab',*args])
try:
 run(['bin/fm-lab-home.sh','create',str(lab)])
 socket=run(['bin/fm-lab-home.sh','tmux-dir',str(lab)]).strip();env['TMUX_TMPDIR']=socket
 tm('new-session','-d','-s','primary','-x','120','-y','40','-c',str(root),'-e',f'FM_HOME={lab}','claude');time.sleep(3)
 tm('new-window','-d','-t','primary:','-n','fm-probe','-c',str(root),'-e',f'FM_HOME={lab}','-e','FM_TASK_ID=probe','claude');tm('set-option','-w','-t','primary:fm-probe','automatic-rename','off');tm('set-option','-w','-t','primary:fm-probe','allow-rename','off');tm('list-windows','-a','-F','#{session_name}:#{window_name}')
 server=int(tm('display-message','-p','-t','primary','#{pid}').strip())
 owner=tm('display-message','-p','-t','primary','#{pane_pid}').strip();(lab/'state/.lock').write_text(owner+'\n')
 env['TMUX']=tm('display-message','-p','-t','primary','#{socket_path},#{pid},0').strip()
 (lab/'state/probe.meta').write_text('window=primary:fm-probe\nproject=lab\nkind=ship\nharness=claude\n')
 # No status stream exists yet, so the first cycle reaches pane staleness.
 libc=ctypes.CDLL(None);fd=libc.inotify_init1(os.O_NONBLOCK|os.O_CLOEXEC);assert fd>=0
 wd=libc.inotify_add_watch(fd,os.fsencode(lab/'state'),0x100);assert wd>=0
 output=open(ev/'watcher-product.log','w')
 watch=subprocess.Popen([str(root/'bin/fm-watch.sh')],env=env,cwd=root,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
 until=time.monotonic()+30;captured=False
 while time.monotonic()<until:
  if not select.select([fd],[],[],.5)[0]:continue
  events=os.read(fd,65536);pos=0
  while pos<len(events):
   w,m,c,n=struct.unpack_from('iIII',events,pos);name=events[pos+16:pos+16+n].split(b'\0')[0].decode();pos+=16+n
   if name.startswith('.fm-capture-output.'):
    os.kill(server,signal.SIGSTOP);captured=True;say('Paused only the lab tmux server at actual pane-capture staging '+name);break
  if captured:break
 if not captured:
  say('watcher poll='+str(watch.poll()))
  say('STATE '+str(list((lab/'state').iterdir())))
  diagnostic=subprocess.check_output(['ps','-eo','pid,ppid,wchan,args'],text=True)
  say('Relevant watcher process tree:\n'+'\n'.join(l for l in diagnostic.splitlines() if str(watch.pid) in l or str(lab) in l or 'tmux list' in l))
  raise RuntimeError('Real watcher never entered pane capture; '+(ev/'watcher-product.log').read_text())
 time.sleep(.4)
 ps=subprocess.check_output(['ps','-eo','pid,ppid,pgid,args'],text=True)
 own=[line for line in ps.splitlines() if ('tmux capture-pane' in line or 'fm-watch' in line) and (str(watch.pid) in line or (socket or 'never-match') in line)]
 say('Blocked-read process evidence:\n'+'\n'.join(own))
 # Resolve descendants through PPIDs and require the actual capture client.
 rows=[line.split(None,3) for line in ps.splitlines()[1:] if len(line.split(None,3))==4]
 descendants={watch.pid};changed=True
 while changed:
  changed=False
  for p,pp,g,a in rows:
   if int(pp) in descendants and int(p) not in descendants:descendants.add(int(p));changed=True
 clients=[int(p) for p,pp,g,a in rows if int(p) in descendants and 'tmux capture-pane' in a]
 assert clients,'No actual tmux capture client blocked beneath the watcher'
 say('Actual blocked capture client PID(s): '+str(clients))
 started=time.monotonic();watch.terminate();rc=watch.wait(timeout=3);elapsed=time.monotonic()-started
 time.sleep(.2)
 for p in clients:
  try:os.kill(p,0)
  except ProcessLookupError:continue
  stat=pathlib.Path(f'/proc/{p}/stat').read_text().split(') ',1)[1].split()[0]
  assert stat=='Z',f'capture client {p} survived watcher stop'
 say(f'Observed watcher exit={rc} within {elapsed:.3f}s; blocked real capture clients were reaped or dead.')
 results.append(dict(name='Stop a watcher during a real blocked tmux pane read and reap the read process promptly',result='pass',live=True,evidence='watcher-live.log; watcher-product.log',reason=''))
except Exception as ex:
 say(traceback.format_exc());results.append(dict(name='Stop a watcher during a real blocked tmux pane read',result='fail',live=True,evidence='watcher-live.log',reason=str(ex)))
finally:
 if server:
  try:os.kill(server,signal.SIGCONT)
  except ProcessLookupError:pass
 if watch and watch.poll() is None:
  watch.terminate()
  try:watch.wait(timeout=3)
  except subprocess.TimeoutExpired:os.killpg(watch.pid,signal.SIGKILL);watch.wait()
 if socket:tm('kill-server');run(['bin/fm-lab-home.sh','teardown',str(lab)])
 if fd is not None:os.close(fd)
 shutil.rmtree(lab)
 (ev/'watcher-live-results.json').write_text(json.dumps(results,indent=2)+'\n');log.close()
