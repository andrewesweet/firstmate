import os, subprocess, tempfile, pathlib, json, time, shutil
root=pathlib.Path.cwd(); evidence=pathlib.Path('/home/cti/.no-mistakes/evidence/01M5E7D4NWGSE64JVQKMS28Z5X')
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.')); env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k in ['TMUX','TMUX_PANE','NO_MISTAKES_GATE','CLAUDECODE','CLAUDE_CODE_SESSION_ID','PI_CODING_AGENT','TASKS_AXI_FILE','TASKS_AXI_BACKEND']: env.pop(k,None)
env['TMUX_TMPDIR']=str(lab/'tmux')
result={'scenario':'Pi 1.2 native session activation and replacement','result':'untested'}
def tm(*args,check=True):
 return subprocess.run(['tmux','-L','fm-lab',*args],env=env,text=True,capture_output=True,check=check)
def capture(name):
 cap=tm('capture-pane','-p','-S','-250','-t','primary',check=False).stdout
 (evidence/name).write_text(cap)
 return cap
def state():
 return {str(p.relative_to(lab)):p.read_text(errors='replace') for p in (lab/'state').rglob('*') if p.is_file() and (p.name.startswith('.lock') or 'pi-primary-watch' in str(p) or p.name in ['.pi-turnend-guard','.branch-session','.pi-watch-extension-loaded','.pi-turnend-extension-loaded'])}
def send(prompt):
 tm('send-keys','-t','primary','-l',prompt); time.sleep(.3); tm('send-keys','-t','primary','Enter')
try:
 subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],check=True,capture_output=True)
 (lab/'tmux').mkdir()
 args=['pi','--approve','--model','openai-codex/gpt-5.6-sol','--thinking','low','--session-dir',str(lab/'sessions'),'--no-mcp','--no-context-files','--no-skills','--no-extensions']
 for ext in ['fm-primary-turnend-guard.ts','fm-primary-pi-watch.ts','fm-branch-supervision.ts']: args+=['-e',str(root/'.pi/extensions'/ext)]
 tm('new-session','-d','-s','primary','-x','120','-y','40','-c',str(root),'-e','FM_HOME='+str(lab),*args)
 time.sleep(4)
 capture('round2-pi-primary-startup.txt')
 prompt='Isolated product validation only. Run bin/fm-lock.sh and bin/fm-lock.sh status using bash, then reply PI_LOCK_COMPLETE. Do not edit files, dispatch, publish, or run any other commands.'
 send(prompt)
 for i in range(140):
  time.sleep(.5); cap=capture('round2-pi-primary-before-new.txt')
  if (lab/'state/.lock').exists() and 'PI_LOCK_COMPLETE' in cap and 'lock: held by live harness' in cap:
   time.sleep(2); before=state(); result['before']=before
   send('/new'); time.sleep(4)
   send(prompt.replace('PI_LOCK_COMPLETE','PI_NEW_COMPLETE'))
   for j in range(140):
    time.sleep(.5); cap=capture('round2-pi-primary-after-new.txt')
    after=state()
    if 'PI_NEW_COMPLETE' in cap and 'lock: held by live harness' in cap and after.get('state/.pi-watch-extension-loaded') != before.get('state/.pi-watch-extension-loaded') and after.get('state/.lock') == before.get('state/.lock'):
     result.update(result='pass',after=after); break
   else: result['reason']='Pi did not complete lock re-anchoring after /new within 70 seconds; inspect native TUI captures.'
   break
 else:
  result['reason']='Pi did not complete the initial native lock check within 70 seconds; inspect native TUI capture.'
except Exception as e: result['reason']=str(e)
finally:
 capture('round2-pi-primary-final.txt')
 tm('kill-server',check=False)
 shutil.rmtree(lab)
 result['teardown']='Private tmux server stopped and marked lab removed.'
 (evidence/'round2-pi-primary-result.json').write_text(json.dumps(result,indent=2))
 print(json.dumps(result,indent=2))
