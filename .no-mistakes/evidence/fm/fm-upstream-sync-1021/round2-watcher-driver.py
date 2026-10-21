import pathlib, tempfile, os, subprocess, shutil, json
root=pathlib.Path.cwd(); e=pathlib.Path('/home/cti/.no-mistakes/evidence/01M5E7D4NWGSE64JVQKMS28Z5X'); lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.')); env=os.environ.copy(); transcript=[]
for k in list(env):
 if k.startswith('FM_') or k in ['TMUX','TMUX_PANE','NO_MISTAKES_GATE','CLAUDE_CODE_SESSION_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND']: env.pop(k,None)
env.update(FM_HOME=str(lab),TMUX_TMPDIR=str(lab/'tmux'),FM_POLL='0.2',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999')
result={'scenario':'A real watcher suppresses unchanged recovery rows and resurfaces newly queued work','result':'fail','live':True}
def run(args,timeout=20):
 p=subprocess.run([str(a) for a in args],cwd=root,env=env,text=True,capture_output=True,timeout=timeout)
 transcript.append('$ '+' '.join(str(a) for a in args)+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode)+'\n'); return p
try:
 assert run(['bin/fm-lab-home.sh','create',lab]).returncode==0
 (lab/'tmux').mkdir(); (lab/'config/supervision-host-off').touch(); (lab/'config/backend').write_text('tmux\n')
 assert run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','40','-c',root]).returncode==0
 socket=run(['tmux','-L','fm-lab','display-message','-p','#{socket_path}']).stdout.strip(); env['TMUX']=socket+',0,0'
 assert run(['bin/fm-inbox.sh','note','--json','First isolated recovery note']).returncode==0
 first=run(['bin/fm-watch-arm.sh','--restart','--follow-budget','2']); assert first.returncode==0 and 'check: rearm-resurface' in first.stdout, first.stdout
 marker=(lab/'state/.watcher-down').read_text(); seq=(lab/'state/.wake-queue.seq').read_text()
 second=run(['bin/fm-watch-arm.sh','--follow-budget','2']); assert second.returncode==0 and 'check: rearm-resurface' not in second.stdout and 'follow budget elapsed' in second.stdout, second.stdout
 assert (lab/'state/.watcher-down').read_text()==marker
 assert run(['bin/fm-watch-arm.sh','--stop']).returncode==0
 assert run(['bin/fm-inbox.sh','note','--json','Second isolated recovery note']).returncode==0
 third=run(['bin/fm-watch-arm.sh','--restart','--follow-budget','2']); assert third.returncode==0 and 'check: rearm-resurface' in third.stdout, third.stdout
 assert (lab/'state/.wake-queue.seq').read_text()!=seq
 transcript.append('PERSISTED QUEUE\n'+(lab/'state/.wake-queue').read_text()+'PERSISTED RECOVERY MARKER\n'+(lab/'state/.watcher-down').read_text())
 result['result']='pass'
except Exception as exc: result['reason']=str(exc)
finally:
 run(['bin/fm-watch-arm.sh','--stop']); run(['tmux','-L','fm-lab','kill-server']); shutil.rmtree(lab)
 (e/'round2-watcher-live.log').write_text('\n'.join(transcript)); (e/'round2-watcher-live-result.json').write_text(json.dumps(result,indent=2)); print(json.dumps(result))
