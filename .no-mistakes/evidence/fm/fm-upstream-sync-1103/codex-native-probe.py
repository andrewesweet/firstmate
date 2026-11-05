from pathlib import Path
import os,shutil,subprocess,time
root=Path.cwd();lab=root/'.test-phase-tmp/codex-primary-trusted';ev=Path('~/.no-mistakes/evidence/01M6PPNG6H1R7WRHVY6CWGFJXH')
subprocess.run([str(root/'bin/fm-lab-home.sh'),'create',str(lab)],check=True,stdout=subprocess.DEVNULL)
for d in ['tmux','codex','user']: (lab/d).mkdir()
(lab/'config/codex-stop-park').touch()
(lab/'codex/config.toml').write_text('[projects."'+str(root)+'"]\ntrust_level = "trusted"\n')
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','CODEX_','OPENAI_','CLAUDE_','HERDR_')) and k not in ['NO_MISTAKES_GATE','TMUX','TMUX_PANE']}
env.update(FM_HOME=str(lab),CODEX_HOME=str(lab/'codex'),HOME=str(lab/'user'),TMUX_TMPDIR='./tmux',TERM='xterm-256color',PATH=str(root/'.test-phase-tmp/codex-native/node_modules/.bin')+':'+env['PATH'])
cli=str(root/'.test-phase-tmp/codex-native/node_modules/.bin/codex')
def mux(*args,check=True):
 return subprocess.run(['tmux','-S','./fm-lab.sock',*args],cwd=lab,env=env,capture_output=True,text=True,check=check)
try:
 mux('-f','/dev/null','new-session','-d','-s','primary','-x','140','-y','44','-c',str(root),'-e','FM_HOME='+str(lab),cli+' --no-daemon --no-alt-screen --dangerously-bypass-hook-trust; sleep 60')
 screen=''
 for _ in range(40):
  time.sleep(.5)
  screen=mux('capture-pane','-p','-t','primary').stdout
  if screen.strip():
   time.sleep(2)
   break
 (ev/'codex-native-screen.txt').write_text(screen)
 print(screen,flush=True)
 print('Park registration files:',[p.name for p in (lab/'state').iterdir()],flush=True)
finally:
 mux('kill-server',check=False)
 time.sleep(.5)
 shutil.rmtree(lab)
