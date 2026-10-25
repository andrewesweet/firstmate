from pathlib import Path
import os, subprocess, sqlite3, time, json, shutil, datetime
ROOT=Path.cwd(); LAB=ROOT/'.test-live'; EV=Path('~/.no-mistakes/evidence/01M5TGPKQG05DTN4S16W4Y3YY3')
ENV=os.environ.copy()
for k in list(ENV):
 if k.startswith(('FM_', 'HERDR_')) or k in ('TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND'): ENV.pop(k,None)
ENV.update(NM_HOME=str(LAB/'nm'),TMPDIR=str(LAB/'tmp'),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_AUTHOR_NAME='Lab',GIT_AUTHOR_EMAIL='lab@example.invalid',GIT_COMMITTER_NAME='Lab',GIT_COMMITTER_EMAIL='lab@example.invalid',FM_CREW_STATE_NO_FORGE='1',FM_BACKEND='tmux')
OUT=[]
def run(args, cwd=ROOT, env=None, check=True):
 p=subprocess.run([str(x) for x in args],cwd=cwd,env=env or ENV,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=25)
 if check and p.returncode: raise RuntimeError(f'{args}: {p.returncode}\n{p.stdout}')
 return p.stdout.strip()
def git(*args):return run(['git','-C',LAB/'wt',*args])
def record(name, inputs, output, expected):
 OUT.append(dict(name=name,inputs=inputs,output=output,expected=expected,pass_=expected in output))
 print(name,output,flush=True)
 assert expected in output,(name,output)
def dbmut(sql,args=()):
 with sqlite3.connect(LAB/'nm/state.sqlite') as d:d.execute(sql,args)
def cli(*args):return run(['no-mistakes',*args],cwd=LAB/'wt')
SOCKET=ROOT/'.s'
TM=['tmux','-f','/dev/null','-S',SOCKET]

results=[]
try:
 run(TM+['new-session','-d','-s','fm-lab','-n','fm-wait','-x','120','-y','40','bash --noprofile --norc'])
 ENV['TMUX']=str(SOCKET)+',0,0'
 for name,command,future in [('baseline-by-expired',LAB/'baseline/bin/fm-watch.sh',False),('by-live-transition',ROOT/'bin/fm-watch.sh',True)]:
  wh=LAB/name;run([ROOT/'bin/fm-lab-home.sh','create',wh]);st=wh/'state'
  (st/'wait.meta').write_text('window=fm-lab:fm-wait\nkind=secondmate\nharness=claude\nbackend=tmux\n')
  when=int(time.time())+8 if future else int(time.time())-60
  iso=datetime.datetime.fromtimestamp(when,datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
  sf=st/'wait.status';sf.write_text('paused: drive return By '+iso+'\n');os.utime(sf,(time.time()-60,)*2)
  we=ENV.copy();we.update(FM_HOME=str(wh),FM_SECONDMATE_LIVENESS_SECS='99999999',FM_POLL='1',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_PAUSE_RESURFACE_SECS='999')
  run(['bash','-c','. "$1/bin/fm-wake-lib.sh"; fm_wake_status_mark_current "$3" "$2"','_',ROOT,sf,st],env=we)
  start=time.time()
  with (EV/(name+'.txt')).open('w') as log:
   p=subprocess.Popen([str(command)],cwd=ROOT,env=we,stdout=log,stderr=subprocess.STDOUT)
   deadline=time.time()+14
   while time.time()<deadline and p.poll() is None:time.sleep(.1)
   stopped_at=time.time()
   if p.poll() is None:p.terminate()
   p.wait(timeout=4)
  output=(EV/(name+'.txt')).read_text()
  triage=(st/'.watch-triage.log').read_text() if (st/'.watch-triage.log').exists() else ''
  evidence=f'status: {sf.read_text().strip()}\nstarted_epoch: {start}\ndeadline_epoch: {when}\nexit_observed_epoch: {stopped_at}\n'+output+'\nTRIAGE:\n'+triage
  (EV/(name+'.txt')).write_text(evidence)
  if future:
   assert stopped_at>=when and 'declared clearing time has passed' in output and 'declared time not reached' in triage,evidence
  else:
   assert 'stale: fm-lab:fm-wait' not in output and 'paused, awaiting external' in triage,evidence
  results.append({'name':name,'pass':True,'evidence':evidence})
  print(evidence,flush=True)
finally:
 run(TM+['kill-server'],check=False)
 (EV/'deadline-regression-results.json').write_text(json.dumps(results,indent=2)+'\n')
