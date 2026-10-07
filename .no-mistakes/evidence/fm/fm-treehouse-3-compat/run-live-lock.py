import os,pathlib,subprocess,json,threading
root=pathlib.Path.cwd();base=root/'.v';ev=pathlib.Path('/home/cti/.no-mistakes/evidence/01M4A57VKWXAXVVTYZ7H6SP6T0')
env=os.environ.copy()
for key in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','TREEHOUSE_ROOT','FM_TASK_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:env.pop(key,None)
env.update(TMPDIR=str(base/'tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',TMUX=str(base/'s')+',0,0',XDG_STATE_HOME=str(base/'xdg'),FM_TREEHOUSE_RETURN_LOCK_RETRIES='3',FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='1')
with (ev/'live-lock-retry.log').open('w') as log:
 def run(args,cwd=root):
  p=subprocess.run(args,cwd=cwd,env=env,input='',text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
  log.write('$ '+subprocess.list2cmdline(args)+'\n'+p.stdout+f'[exit {p.returncode}]\n');log.flush()
  assert p.returncode==0,p.stdout
  return p
 run(['tmux','-S',str(base/'s'),'new-session','-d','-s','fm-lab-cleanup','sleep 300'])
 try:
  for version in ['v2','v3']:
   lab=base/version/'lab';project=lab/'projects'/'sample';task='live-'+version+'-lock'
   env.update(PATH=str(base/version)+':'+str(base/'tools')+':/usr/bin:/bin',FM_HOME=str(lab))
   run(['treehouse','--version'])
   p=run(['treehouse','get','--lease','--lease-holder',task],project)
   slot=pathlib.Path(p.stdout.strip().splitlines()[-1]);assert slot.is_relative_to(lab)
   meta=lab/'state'/f'{task}.meta';meta.write_text(f'window=fm-lab-cleanup:fm-{task}\nendpoint_task_id={task}\nworktree={slot}\nproject={project}\nkind=ship\nmode=local-only\nspawn_gen=live-validation-{task}\n')
   lock=pathlib.Path(run(['git','rev-parse','--git-path','index.lock'],slot).stdout.strip())
   if not lock.is_absolute():lock=slot/lock
   assert lock.is_relative_to(lab)
   lock.touch()
   p=subprocess.Popen(['bin/fm-teardown.sh',task],cwd=root,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
   log.write('$ bin/fm-teardown.sh '+task+'\n');log.flush()
   output=[]
   timer=threading.Timer(25,p.kill);timer.start()
   try:
    for line in p.stdout:
     log.write(line);log.flush();output.append(line)
     if 'waiting 1s and retrying' in line and lock.exists():
      lock.unlink();log.write('LAB: released our transient index.lock after the real return failed\n');log.flush()
    rc=p.wait()
   finally:timer.cancel()
   text=''.join(output);log.write(f'[exit {rc}]\n')
   assert rc==0 and 'return succeeded on retry' in text and not meta.exists(),text
   state=json.loads((slot.parent.parent/'treehouse-state.json').read_text());entry=next(x for x in state['worktrees'] if x['path']==str(slot))
   assert not entry.get('leased',False)
   log.write('POOL AFTER '+json.dumps(state)+'\nOBSERVED real lock failure retried successfully; lease released and metadata removed\n')
 finally:run(['tmux','-S',str(base/'s'),'kill-server'])
print('Real lock-retry transcript:',ev/'live-lock-retry.log')
