import json,os,re,shlex,subprocess,time
from pathlib import Path
root=Path.cwd(); lab=root/'.b'; state=lab/'state'; evidence=Path('~/.no-mistakes/evidence/01M54P4C0CEWF8GWG85R4BMWKB')
env=os.environ.copy();env['TMUX_TMPDIR']=str(lab/'tmux')
for k in ('NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE'):env.pop(k,None)
log=(evidence/'live-bridge.jsonl').open('w')
os.mkfifo(lab/'input.fifo');fd=os.open(lab/'input.fifo',os.O_RDWR)
def record(event,**data):
 x={'event':event,**data};log.write(json.dumps(x)+'\n');log.flush();print(json.dumps(x),flush=True)
def tmux(*a,check=True):return subprocess.run(['tmux','-L','fm-lab',*a],env=env,text=True,capture_output=True,check=check)
def read(p):
 try:return p.read_text()
 except OSError:return ''
def fields():
 x=read(state/'.claude-autoarm-epoch').splitlines()
 return dict(re.findall(r'(\w+)=([^ ]+)',x[0])) if x else {}
def alive(p):
 x=subprocess.run(['ps','-o','stat=','-p',str(p)],text=True,capture_output=True)
 return x.returncode==0 and bool(x.stdout.strip()) and not x.stdout.strip().startswith('Z')
def wait(label,predicate,seconds=35):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  if predicate():return
  time.sleep(.1)
 raise AssertionError(label)
def snap(label):
 f=fields();watch=read(state/'.watch.lock'/'pid').strip();anchor=read(state/'.lock').strip()
 processes=subprocess.run(['ps','-o','pid=,ppid=,stat=,comm=','-p',','.join(filter(None,[anchor,f.get('owner_pid'),watch]))],capture_output=True,text=True).stdout
 record(label,ledger=f,anchor=anchor,session_id=read(state/'.lock-session').strip(),watcher=watch,processes=processes,feedback=read(state/'stop-feedback.log'))
 return f,watch,anchor
def submit(text):os.write(fd,(json.dumps({'type':'user','message':{'role':'user','content':text}})+'\n').encode())
def command(output,resume=None):
 a=['claude','-p','--input-format','stream-json','--output-format','stream-json','--verbose','--setting-sources','','--settings','.test-validation/claude-settings.json','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--tools','','--system-prompt','Isolated supervision validation. Reply only to the user request. Do not use tools or delegate. When a watcher hook wakes you, reply LAB_WAKE_ACK and stop.']
 if resume:a+=['--resume',resume]
 return shlex.join(a)+' < "$FM_HOME/input.fifo" > "$FM_HOME/'+output+'" 2> "$FM_HOME/'+output+'.stderr"'
try:
 tmux('new-session','-d','-s','primary','-c',str(root),'-x','110','-y','32','-e','FM_HOME='+str(lab),'-e','DISABLE_AUTOUPDATER=1','-e','CLAUDE_CODE_DISABLE_AUTO_UPDATE=1',command('before.jsonl'))
 tmux('set-option','-g','remain-on-exit','on')
 submit('Reply exactly RESUME_LAB_READY.')
 wait('first claim and watcher ready',lambda:fields().get('outcome')=='arming' and alive(read(state/'.watch.lock'/'pid').strip()))
 f,watch,anchor=snap('original-session-arming')
 owner=f['owner_pid'];gen=int(f['epoch'])
 initial=read(state/'.claude-autoarm-epoch')
 (state/'probe-next-stop').write_text('before')
 submit('Reply exactly BEFORE_BRIDGE.')
 wait('ancestry guard probe completed',lambda:'probe_rc=0' in read(state/'hooks.log'))
 assert read(state/'.claude-autoarm-epoch')==initial
 parent=subprocess.check_output(['ps','-o','ppid=','-p',owner],text=True).strip()
 record('recycling-intermediate-shell',owner_pid=owner,bridge_pid=parent,anchor=anchor)
 tmux('run-shell','kill -KILL '+str(int(parent)))
 wait('claim owner reparented',lambda:subprocess.check_output(['ps','-o','ppid=','-p',owner],text=True).strip()!=parent)
 assert alive(owner) and alive(anchor) and alive(watch)
 snap('live-session-claim-with-broken-ancestry')
 (state/'probe-next-stop').write_text('after')
 submit('Reply exactly AFTER_BRIDGE.')
 wait('boundary guard probes completed',lambda:read(state/'hooks.log').count('probe_rc=0')==2,seconds=45)
 assert read(state/'.claude-autoarm-epoch')==initial
 assert alive(owner) and alive(anchor) and read(state/'.watch.lock'/'pid').strip()==watch
 snap('recycled-bridge-concurrent-stop-preserved-claim')
 record('PASS',scenario='live same-session claim survives broken ancestry; real guard blocks invalid locks, sidecars and holder identities')

except BaseException as e:
 snap('failure-state');record('ERROR',error=repr(e));raise
finally:
 for name in ('hooks.log','stop-feedback.log','start.log'):
  (evidence/('bridge-'+name)).write_text(read(state/name))
 for name in ('before.jsonl','resumed.jsonl'):
  events=[]
  for line in read(lab/name).splitlines():
   try:x=json.loads(line)
   except ValueError:continue
   if x.get('type') in ('assistant','result') or x.get('subtype') in ('hook_started','hook_response'):events.append(x)
  (evidence/('bridge-'+name)).write_text('\n'.join(json.dumps(x) for x in events)+'\n')
 tmux('kill-server',check=False)
 os.close(fd);log.close()
