import pathlib,os,subprocess,selectors,json,time,shutil,shlex
root=pathlib.Path.cwd(); lab=root/('p'+str(os.getpid())); ev=pathlib.Path('/home/andre/.no-mistakes/evidence/01M47GDMMHP9GND9V4JZHAAQ9G');env=os.environ.copy()
for k in list(env):
 if k.startswith(('FM_','TASKS_AXI_')) or k in ['NO_MISTAKES_GATE','TMUX']:env.pop(k)
env.update(FM_HOME=str(lab),TMPDIR=str(lab),PI_CODING_AGENT_SESSION_DIR=str(lab/'sessions'),FM_PROCEVENT_CLAIM_ROOT=str(lab/'claims'),TMUX_TMPDIR=str(lab/'tmux'))
log=(ev/'pi-tmux-flow.log').open('w');p=None
try:
 subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],env=env,stdout=subprocess.DEVNULL,check=True)
 (lab/'tmux').mkdir()
 def tmux(args):
  return subprocess.run(['tmux','-L','fm-lab']+args,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,check=True).stdout
 command=shlex.join(['pi','--mode','rpc','--approve','--session-dir',str(lab/'sessions'),'--offline'])+' > '+shlex.quote(str(lab/'rpc.log'))+' 2>&1'
 tmux(['new-session','-d','-s','primary','-c',str(root),'-x','120','-y','40','-e','FM_HOME='+str(lab),command])
 readpos=0;pending=''
 def send(obj):
  tmux(['send-keys','-t','primary','-l',json.dumps(obj)]);tmux(['send-keys','-t','primary','Enter']);log.write('REQUEST '+json.dumps(obj)+'\n');log.flush()
 def capture(seconds):
  global readpos,pending
  end=time.time()+seconds;events=[]
  while time.time()<end:
   if (lab/'rpc.log').exists():
    with (lab/'rpc.log').open() as f:f.seek(readpos);chunk=f.read();readpos=f.tell()
    log.write(chunk);log.flush();pending+=chunk
    lines=pending.split('\n');pending=lines.pop()
    for line in lines:
     try:events.append(json.loads(line))
     except ValueError:pass
   time.sleep(.1)
  return events
 send({'id':'state','type':'get_state'});events=capture(8)
 send({'id':'models','type':'get_available_models'});events+=capture(4)
 send({'id':'watch','type':'prompt','message':'This is an isolated outcome-processing test in the marked FM_HOME. Run bin/fm-session-start.sh exactly once to claim this home primary lock, then reply Captain, READY. Do not arm the watcher or call any other tool or change project files.'});events+=capture(50)
 oldpid=(lab/'state/.watch.lock/pid').read_text().strip() if (lab/'state/.watch.lock/pid').exists() else None
 # A real persisted captain outcome drives the native processing callback.
 seed=subprocess.run(['bin/fm-branch-outcome.sh','append','--task','native-proof','--verdict','captain','--summary','Disposable native retry test: captain approval is required.','--wake','native-proof'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,check=True)
 log.write('OUTCOME APPEND '+seed.stdout);log.flush()
 send({'id':'retry','type':'prompt','message':'For this isolated test, reply exactly Captain, NATIVE_REPEAT to this message and to every automatic supervision processing request. Do not call any tool, including fm_branch_processed. Keep the outcome unacknowledged until my next human message.'});events+=capture(65)
 send({'id':'human','type':'prompt','message':'This is a fresh human message. Reply exactly Captain, HUMAN_VISIBLE. Do not call any tool.'});events+=capture(30)
 newpid=(lab/'state/.watch.lock/pid').read_text().strip() if (lab/'state/.watch.lock/pid').exists() else None
 finals=[]
 for event in events:
  if event.get('type')=='message_end' and event.get('message',{}).get('role')=='assistant':
   msg=event['message'];finals.append({'text':'\n'.join(x.get('text','') for x in msg.get('content',[]) if x.get('type')=='text'),'toolCalls':[x.get('name') for x in msg.get('content',[]) if x.get('type')=='toolCall'],'stopReason':msg.get('stopReason'),'usage':msg.get('usage')})
 state={'runtime_alive':bool(tmux(['list-sessions'])),'old_watcher_pid':oldpid,'new_watcher_pid':newpid,'finals':finals,'processed_marker':(lab/'state/.branch-outcomes-processed').read_text() if (lab/'state/.branch-outcomes-processed').exists() else None}
 (ev/'pi-tmux-flow.json').write_text(json.dumps(state,indent=2));print(json.dumps(state))
 send({'id':'watch-boundary','type':'prompt','message':'Now call fm_watch_arm_pi exactly once, then report its returned status. Do not call other tools or retry this test.'});boundary=capture(25);log.write('NATIVE_WATCH_BOUNDARY_COMPLETE\n');log.flush()
 if (lab/'sessions').exists():
  for transcript in (lab/'sessions').glob('**/*.jsonl'):
   if transcript.stat().st_size<2000000:shutil.copyfile(transcript,ev/('pi-session-'+transcript.name))

finally:
 if (lab/'tmux').exists():subprocess.run(['tmux','-L','fm-lab','kill-server'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 subprocess.run(['bin/fm-watch-arm.sh','--stop'],env=env,stdout=log,stderr=subprocess.STDOUT)
 log.close()
 if lab.exists():shutil.rmtree(lab)
