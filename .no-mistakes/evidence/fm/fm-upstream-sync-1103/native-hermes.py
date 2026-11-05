import html, json, os, pathlib, shlex, shutil, subprocess, time
root=pathlib.Path.cwd()
evidence=pathlib.Path('~/.no-mistakes/evidence/01M6PPNG6H1R7WRHVY6CWGFJXH')
lab=root/'.test-phase-tmp/native-hermes'
lab.mkdir()
profile=lab/'hermes/profiles/worker'
profile.mkdir(parents=True)
(profile/'config.yaml').write_text(json.dumps({'model':{'default':'gpt-6-astra','provider':'openai-codex'},'telemetry':{'shared_metrics':{'enabled':False,'send':False,'offer_version':2}}}))
for d in ('work','user','xdg-state','xdg-config','xdg-data','xdg-cache'):
 (lab/d).mkdir()
env=dict(os.environ, HERMES_HOME=str(lab/'hermes'), HOME=str(lab/'user'), XDG_STATE_HOME=str(lab/'xdg-state'), XDG_CONFIG_HOME=str(lab/'xdg-config'), XDG_DATA_HOME=str(lab/'xdg-data'), XDG_CACHE_HOME=str(lab/'xdg-cache'), TERM='xterm-256color')
for key in list(env):
 if key.startswith(('HERDR_','FM_','CODEX_','CLAUDE_')) or key in ('TMUX','TMUX_PANE','PYTHONPATH','PYTHONHOME'):
  env.pop(key,None)
tmux=shutil.which('tmux'); hermes=shutil.which('hermes')
def run(args,**kw):
 return subprocess.run(args,cwd=lab,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,**kw)
def mux(*args):
 return run([tmux,'-S','./native.sock',*args],check=True).stdout
try:
 print(run([hermes,'--version'],check=True).stdout,flush=True)
 command=shlex.join([hermes,'-p','worker','chat','--tui','--yolo'])
 mux('-f','/dev/null','new-session','-d','-s','native','-x','140','-y','44','-c',str(lab/'work'),command+'; sleep 60')
 screen=''
 for i in range(90):
  screen=mux('capture-pane','-p','-e','-t','native')
  if 'worker ❯' in screen and 'ready' in screen: break
  time.sleep(.5)
 else:
  (evidence/'native-hermes-startup-error.txt').write_text(screen)
  raise RuntimeError('native Hermes did not reach ready: '+screen)
 (evidence/'native-hermes.txt').write_text(screen)
 (evidence/'native-hermes.html').write_text('<!doctype html><meta charset="utf-8"><title>Actual Hermes terminal capture</title><style>body{background:#15171b;color:#eee;padding:24px}pre{font:14px/1.4 monospace;white-space:pre-wrap}</style><h1>Actual Hermes TUI, isolated uncredentialed profile</h1><pre>'+html.escape(screen)+'</pre>')
 probe='''. "$1/bin/fm-hermes-lib.sh"
. "$1/bin/fm-composer-lib.sh"
screen=$(cat "$2")
printf 'startup=%s\\n' "$(fm_hermes_startup_screen "$screen")"
printf 'composer=%s\\n' "$(fm_composer_classify_screen "$(printf 'identity=1\nstyled=1\n')" "$screen" '' hermes)"
'''
 result=run(['bash','-c',probe,'_',str(root),str(evidence/'native-hermes.txt')],check=True).stdout
 print(result,flush=True)
 assert 'startup=ready' in result, result
 assert 'composer=empty' in result, result
 mux('send-keys','-t','native','-l','unsent draft preserved')
 time.sleep(.5)
 draft=mux('capture-pane','-p','-e','-t','native')
 (evidence/'native-hermes-draft.txt').write_text(draft)
 result=run(['bash','-c',probe,'_',str(root),str(evidence/'native-hermes-draft.txt')],check=True).stdout
 print(result,flush=True)
 assert 'composer=pending' in result,result
 print('Live native Hermes ready/empty and unsent-draft/pending confirmed. No model prompt submitted.',flush=True)
finally:
 run([tmux,'-S','./native.sock','kill-server'])
 time.sleep(1)
 shutil.rmtree(lab)
