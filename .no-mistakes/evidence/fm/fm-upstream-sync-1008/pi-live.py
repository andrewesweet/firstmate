import os,pathlib,tempfile,subprocess,shutil,json,time,traceback,html
root=pathlib.Path.cwd(); ev=pathlib.Path('/home/cti/.no-mistakes/evidence/01M4FC0EXAEYKAXXQKZKTGBDFH')
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-pi.',dir=root/'.validation-tmp')); socket=None; results=[]
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k in ('NO_MISTAKES_GATE','TMUX','TMUX_PANE'): env.pop(k,None)
env.update(FM_HOME=str(lab),TMPDIR=str(root/'.validation-tmp'))
log=open(ev/'pi-live.log','w')
def say(s): print(s,flush=True); print(s,file=log,flush=True)
def run(args,expected=0):
 p=subprocess.run([str(root/a) if a.startswith('bin/') else a for a in args],env=env,cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=20)
 say('$ '+' '.join(args)+'\n'+p.stdout+f'[exit={p.returncode}]')
 if p.returncode!=expected: raise AssertionError(p.stdout)
 return p.stdout

def tm(*a): return run(['tmux','-L','fm-lab',*a])
def screen(label):
 s=tm('capture-pane','-p','-t','primary')
 (ev/f'pi-{label}.txt').write_text(s)
 (ev/f'pi-{label}.html').write_text('<!doctype html><meta charset="utf-8"><title>Live Pi '+label+'</title><style>body{background:#15191f;color:#d7dde4;padding:24px}pre{font:16px/1.4 monospace;white-space:pre}</style><pre>'+html.escape(s)+'</pre>')
 return s

def send(s): tm('send-keys','-t','primary','-l',s); time.sleep(.2); tm('send-keys','-t','primary','Enter')
try:
 run(['bin/fm-lab-home.sh','create',str(lab)])
 socket=run(['bin/fm-lab-home.sh','tmux-dir',str(lab)]).strip(); env['TMUX_TMPDIR']=socket
 (lab/'config/calm').write_text('on\n')
 observe=lab/'observe.ts'
 observe.write_text('''import {writeFileSync} from 'node:fs';
export default function(pi:any) {
 const save=(stage:string)=>writeFileSync(process.env.FM_HOME+'/registry-'+stage+'.json',JSON.stringify({stage,all:pi.getAllTools().map((t:any)=>t.name),active:pi.getActiveTools()},null,2));
 pi.on('session_start',()=>save('start'));
 pi.on('agent_start',()=>save('busy'));
 pi.on('agent_settled',()=>save('settled'));
 pi.registerCommand('lab-observe',{description:'Capture the current runtime tool registry',handler:async()=>save('command')});
}
''')
 args=['pi','--offline','--no-session','--no-context-files','--no-skills','--no-prompt-templates','--no-extensions','--approve','--tui-mode','regular','--provider','openai-codex','--model','gpt-6-luna','--thinking','low','-e',str(root/'.pi/extensions/fm-calm.ts'),'-e',str(observe),'--exclude-tools','write,fm_branch_outcomes,fm_branch_processed,fm_watch_arm_pi']
 import shlex
 tm('new-session','-d','-s','primary','-x','120','-y','40','-c',str(root),'-e',f'FM_HOME={lab}',shlex.join(args))
 for _ in range(100):
  if (lab/'registry-start.json').exists(): break
  time.sleep(.1)
 else: raise AssertionError('Pi failed to reach session_start: '+screen('startup-failure'))
 registry=json.loads((lab/'registry-start.json').read_text())
 say('Live runtime registry: '+json.dumps(registry))
 assert 'write' not in registry['active'] and 'bash' in registry['active']
 (ev/'pi-active-tools.json').write_text(json.dumps(registry,indent=2)+'\n')
 screen('idle-calm-on')
 send('This is a disposable validation lab. Use the bash tool exactly once to run sleep 4, then reply LAB_DONE. Do not read or modify files or run any other command.')
 for _ in range(400):
  if (lab/'registry-busy.json').exists(): break
  time.sleep(.1)
 else: raise AssertionError('No real model run started: '+screen('no-model-turn'))
 time.sleep(1)
 working=screen('working-calm-on')
 # Toggle during a real run, then observe settling and a second genuine run.
 send('/calm')
 for _ in range(700):
  if (lab/'registry-settled.json').exists(): break
  time.sleep(.1)
 else: raise AssertionError('Model run did not settle: '+screen('unsettled'))
 settled=screen('settled-calm-off')
 assert (lab/'config/calm').read_text()=='off\n'
 assert 'LAB_DONE' in settled and 'Error in' not in settled
 (lab/'registry-busy.json').unlink(); (lab/'registry-settled.json').unlink()
 send('/calm'); time.sleep(.4)
 assert (lab/'config/calm').read_text()=='on\n'
 send('Reply SECOND_DONE using no tools.')
 for _ in range(600):
  if (lab/'registry-settled.json').exists(): break
  time.sleep(.1)
 else: raise AssertionError('Second model run did not settle: '+screen('second-unsettled'))
 final=screen('second-settled-calm-on'); assert 'SECOND_DONE' in final and 'Error in' not in final
 results.append(dict(name='Use Pi 1.1 with Calm, toggle during a live model turn, and finish a second turn without stale widgets',result='pass',live=True,evidence='pi-working-calm-on.html; pi-settled-calm-off.html; pi-second-settled-calm-on.html; pi-live.log',reason=''))
 results.append(dict(name='Run Pi with a combined tool denylist and observe the configured tool missing from its active runtime registry',result='pass',live=True,evidence='pi-active-tools.json; pi-live.log',reason=''))
except Exception as ex:
 say(traceback.format_exc()); results.append(dict(name='Use Pi 1.1 with Calm and a combined tool denylist across live model turns',result='fail',live=True,evidence='pi-live.log',reason=str(ex)))
finally:
 if socket:
  tm('kill-server'); run(['bin/fm-lab-home.sh','teardown',str(lab)])
 shutil.rmtree(lab)
 (ev/'pi-live-results.json').write_text(json.dumps(results,indent=2)+'\n'); log.close()
