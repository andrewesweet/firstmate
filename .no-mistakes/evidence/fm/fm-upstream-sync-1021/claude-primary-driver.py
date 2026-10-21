import os,subprocess,tempfile,time,pathlib,json
root=pathlib.Path.cwd(); evidence=pathlib.Path('/home/cti/.no-mistakes/evidence/01M5E7D4NWGSE64JVQKMS28Z5X')
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.'))
env=os.environ.copy()
for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','CLAUDECODE','CLAUDE_CODE_SESSION_ID']:
 env.pop(k,None)
env['TMUX_TMPDIR']=str(lab/'tmux'); env['CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION']='false'
def tm(*args,check=True):
 return subprocess.run(['tmux','-L','fm-lab',*args],env=env,capture_output=True,text=True,check=check)
result={'scenario':'Real Claude primary session lock across /clear','result':'untested'}
try:
 subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],check=True,capture_output=True)
 (lab/'tmux').mkdir(); (lab/'config/supervision-host-off').touch()
 tm('new-session','-d','-s','primary','-x','120','-y','40','-c',str(root),'-e','FM_HOME='+str(lab),'claude','--permission-mode','auto')
 for i in range(40):
  time.sleep(.5)
  cap=tm('capture-pane','-p','-t','primary',check=False).stdout
  (evidence/'claude-primary-pane.txt').write_text(cap)
  if any(s in cap.lower() for s in ['quick safety check','trust this folder','is this a project','external claude.md','sign in','select login method','ready to code','yes, i trust']):
   result['reason']='Claude interactive startup is gated by a trust/import/onboarding dialog; answering it or editing global trust configuration is outside this phase.'
   break
  if '❯' in cap:
   tm('send-keys','-t','primary','-l','This is an isolated validation lab. Do not dispatch, publish, or supervise anything. Run only bin/fm-lock.sh and bin/fm-lock.sh status using Bash, then say LOCK_CHECK_COMPLETE. Do not edit files or run any other commands.')
   time.sleep(1)
   tm('send-keys','-t','primary','Enter')
   for j in range(80):
    time.sleep(.5); cap=tm('capture-pane','-p','-S','-200','-t','primary',check=False).stdout
    (evidence/'claude-primary-pane.txt').write_text(cap)
    if (lab/'state/.lock-session').exists():
     before=(lab/'state/.lock-session').read_text(); lock=(lab/'state/.lock').read_text()
     result.update(before_session=before,before_lock=lock)
    if 'LOCK_CHECK_COMPLETE' in cap and 'lock: held by live harness' in cap:
     result['result']='pass'; result['scope']='Real Claude acquired and inspected its own lock.'
     time.sleep(2)
     tm('send-keys','-t','primary','-l','/clear'); time.sleep(1); tm('send-keys','-t','primary','Enter'); time.sleep(4)
     tm('send-keys','-t','primary','-l','This is still the isolated lab. Run only bin/fm-lock.sh and bin/fm-lock.sh status using Bash, then stop. Do not edit, dispatch, publish, or run other commands.')
     time.sleep(1); tm('send-keys','-t','primary','Enter')
     for k in range(80):
      time.sleep(.5)
      cap=tm('capture-pane','-p','-S','-200','-t','primary',check=False).stdout
      (evidence/'claude-primary-after-clear.txt').write_text(cap)
      if (lab/'state/.lock-session').exists():
       after=(lab/'state/.lock-session').read_text()
       if after != before and 'lock:' in cap:
        result.update(after_session=after,after_lock=(lab/'state/.lock').read_text(),scope='Real Claude reacquired its lock after /clear with a new session id.'); break
     else:
      result.update(result='untested',reason='Initial lock acquisition passed, but reacquisition after /clear did not complete within the bounded window.')
     break
   break
 else: result['reason']='Claude never exposed a ready composer within the startup window.'
 if result['result']=='untested' and 'reason' not in result: result['reason']='The primary did not finish the lock command within the bounded window; see pane capture.'
except Exception as e: result['reason']=str(e)
finally:
 tm('kill-server',check=False)
 subprocess.run(['rm','-rf',str(lab)],check=True)
 result['teardown']='private tmux server stopped and disposable lab removed'
 (evidence/'claude-primary-result.json').write_text(json.dumps(result,indent=2))
 print(json.dumps(result))
