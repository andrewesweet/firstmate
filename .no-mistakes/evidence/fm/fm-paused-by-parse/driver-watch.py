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
OUT=json.loads((EV/'live-results.json').read_text())[:6]
try:
 run(TM+['new-session','-d','-s','fm-lab','-n','fm-wait','-x','120','-y','40','bash --noprofile --norc'])
 ENV['TMUX']=str(SOCKET)+',0,0'
 # Real watcher against real private tmux pane. Each case owns a separate home.
 for name,line,age,cadence,due in [
  ('by-expired','paused: drive return by 2026-10-24T23:02:30Z',60,999,True),
  ('until-expired','paused: drive return until 2026-10-24T23:02Z',60,999,True),
  ('BY-future','paused: drive return BY 2099-10-24T23:02Z',60,999,False),
  ('until-priority','paused: drive by 2026-10-24T23:02Z, until 2099-10-24T23:02Z',60,999,False),
  ('malformed','paused: drive return by 2026-13-99T99:99Z',60,999,False),
  ('malformed-cadence','paused: drive return by tomorrow',300,240,True),
  ('far-future-bounded','paused: drive return by 2099-10-24T23:02Z',300,240,True),
 ]:
  wh=LAB/('watch-'+name);run([ROOT/'bin/fm-lab-home.sh','create',wh]); st=wh/'state';(st/'wait.meta').write_text(f'window=fm-lab:fm-wait\nkind=secondmate\nharness=claude\nbackend=tmux\n')
  (st/'.secondmate-liveness-tick').touch(); sf=st/'wait.status';sf.write_text(line+'\n');os.utime(sf,(time.time()-age,)*2)
  we=ENV.copy();we.update(FM_HOME=str(wh),FM_SECONDMATE_LIVENESS_SECS='99999999',FM_POLL='1',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_PAUSE_RESURFACE_SECS=str(cadence),FM_WATCH_TRIAGE_LOG=str(st/'.watch-triage.log'))
  # Mark existing declaration seen through the library's owned serialization contract.
  run(['bash','-c','. "$1/bin/fm-wake-lib.sh"; fm_wake_status_mark_current "$3" "$2"','_',ROOT,sf,st],env=we)
  # Warm real pane stale counting; no mock backend, time, or crew-state seam.
  with (EV/(name+'-watch.txt')).open('w') as log:
   p=subprocess.Popen([str(ROOT/'bin/fm-watch.sh')],cwd=ROOT,env=we,stdout=log,stderr=subprocess.STDOUT)
   deadline=time.time()+11
   while time.time()<deadline and p.poll() is None:time.sleep(.2)
   if p.poll() is None:p.terminate()
   try:p.wait(timeout=3)
   except subprocess.TimeoutExpired:p.kill();p.wait()
  output=(EV/(name+'-watch.txt')).read_text()
  triage=(st/'.watch-triage.log').read_text() if (st/'.watch-triage.log').exists() else ''
  output+='\nTRIAGE:\n'+triage
  (EV/(name+'-watch.txt')).write_text(output)
  record('Real watcher '+name,dict(status=line,status_age=age,cadence=cadence),output,'stale: fm-lab:fm-wait' if due else 'absorbed stale')
  if not due: assert 'stale: fm-lab:fm-wait' not in output,(name,output)
  if name in ('by-expired','until-expired'):assert 'declared clearing time has passed' in output,(name,output)
finally:
 run(TM+['kill-server'],check=False)
 (EV/'live-results.json').write_text(json.dumps(OUT,indent=2)+'\n')
 (EV/'live-transcript.txt').write_text('\n\n'.join(x['name']+'\n'+json.dumps(x['inputs'])+'\n'+x['output'] for x in OUT)+'\n')
