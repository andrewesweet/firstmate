import os,pathlib,tempfile,subprocess,shutil,json,time,traceback
root=pathlib.Path.cwd();ev=pathlib.Path('/home/cti/.no-mistakes/evidence/01M4FC0EXAEYKAXXQKZKTGBDFH')
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-pending.',dir=root/'.validation-tmp'));socket=None;results=[]
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k in ('NO_MISTAKES_GATE','TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND'):env.pop(k,None)
env.update(FM_HOME=str(lab),TMPDIR=str(root/'.validation-tmp'),FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999')
log=open(ev/'pending-live.log','w')
def say(s):print(s,flush=True);print(s,file=log,flush=True)
def run(args):
 p=subprocess.run([str(root/a) if a.startswith('bin/') else a for a in args],env=env,cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
 say('$ '+' '.join(args)+'\n'+p.stdout+f'[exit={p.returncode}]');assert p.returncode==0,p.stdout;return p.stdout

def tm(*args):return run(['tmux','-L','fm-lab',*args])
def state(rec):return dict(l.split('=',1) for l in rec.read_text().splitlines() if '=' in l)

def tick(label):
 with (ev/f'pending-watcher-{label}.log').open('w') as out:
  p=subprocess.Popen([str(root/'bin/fm-watch.sh')],cwd=root,env=env,stdout=out,stderr=subprocess.STDOUT)
  try:
   time.sleep(2)
  finally:
   if p.poll() is None:p.terminate()
   p.wait(timeout=4)
try:
 run(['bin/fm-lab-home.sh','create',str(lab)])
 socket=run(['bin/fm-lab-home.sh','tmux-dir',str(lab)]).strip();env['TMUX_TMPDIR']=socket
 tm('new-session','-d','-s','primary','-x','120','-y','40','-c',str(root),'-e',f'FM_HOME={lab}','claude')
 tm('new-window','-d','-t','primary:','-n','fm-mate','-c',str(root),'-e',f'FM_HOME={lab}','-e','FM_TASK_ID=mate','claude')
 tm('set-option','-w','-t','primary:fm-mate','automatic-rename','off');tm('set-option','-w','-t','primary:fm-mate','allow-rename','off');time.sleep(4)
 env['TMUX']=tm('display-message','-p','-t','primary','#{socket_path},#{pid},0').strip()
 owner=tm('display-message','-p','-t','primary','#{pane_pid}').strip();(lab/'state/.lock').write_text(owner+'\n')
 # Record the actual isolated endpoint for the public send and watcher consumers.
 (lab/'state/mate.meta').write_text(f'window=primary:fm-mate\nendpoint_task_id=mate\nproject={root}\nworktree={root}\nkind=secondmate\nharness=claude\nspawn_gen=lab-mate\n')
 run(['bin/fm-send.sh','mate','This is a disposable correlation validation lab. Wait silently for the next instruction. Use no tools and write no status yet.'])
 recs=[p for p in (lab/'state/pending-replies').iterdir() if p.is_file() and not p.name.startswith('.')]
 assert len(recs)==1;rec=recs[0];data=state(rec);corr=data['corr_id']
 assert data['phase']!='resolved';snapshots={'after-delivery':data}
 # These are manual status-channel inputs, consumed by the running watcher.
 (lab/'state/other.status').write_text(f'done: corr={corr} unrelated task echoed this token\n')
 tick('foreign');snapshots['foreign-log']=state(rec);assert snapshots['foreign-log']['phase']!='resolved'
 (lab/'state/mate.status').write_text(f'done: corr={corr}ff a different correlation token\n')
 tick('suffix');snapshots['suffix-token']=state(rec);assert snapshots['suffix-token']['phase']!='resolved'
 with (lab/'state/mate.status').open('a') as f:f.write(f'done: corr={corr} actual matching task status\n')
 tick('exact');snapshots['exact-own-log']=state(rec);assert snapshots['exact-own-log']['phase']=='resolved'
 (ev/'pending-reply-state.json').write_text(json.dumps(snapshots,indent=2)+'\n')
 say('Observed: real fm-send creates and delivers a pending request; the real watcher ignores a foreign log and a longer token, then resolves only the exact token on the asked task log.')
 results.append(dict(name='Deliver a pending secondmate request and resolve it only from its own log with an exact correlation token',result='pass',live=True,evidence='pending-live.log; pending-reply-state.json',reason=''))
except Exception as ex:
 say(traceback.format_exc());results.append(dict(name='Deliver a pending request and enforce task-log and exact-token boundaries',result='fail',live=True,evidence='pending-live.log',reason=str(ex)))
finally:
 if socket:tm('kill-server');run(['bin/fm-lab-home.sh','teardown',str(lab)])
 shutil.rmtree(lab)
 (ev/'pending-live-results.json').write_text(json.dumps(results,indent=2)+'\n');log.close()
