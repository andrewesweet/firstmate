import os, pathlib, subprocess, json, shutil
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/cti/.no-mistakes/evidence/01M4A57VKWXAXVVTYZ7H6SP6T0')
base=root/'.v'
env=os.environ.copy()
for key in ['FM_HOME','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','TASKS_AXI_FILE','TASKS_AXI_BACKEND','TREEHOUSE_ROOT','TREEHOUSE_WORKTREE_PATH','TREEHOUSE_UNIQUE_LEAF','FM_TASK_ID']:
    env.pop(key,None)
env.update(TMPDIR=str(base/'tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Live Validation',GIT_AUTHOR_EMAIL='validation@example.invalid',GIT_COMMITTER_NAME='Live Validation',GIT_COMMITTER_EMAIL='validation@example.invalid',XDG_STATE_HOME=str(base/'xdg'),NM_HOME=str(base/'nm-empty'),TMUX=str(base/'s')+',0,0')
(base/'v2').mkdir(exist_ok=True)
(base/'tools').mkdir(exist_ok=True)
if not (base/'tools'/'tasks-axi').exists(): (base/'tools'/'tasks-axi').symlink_to(shutil.which('tasks-axi'))
if not (base/'v2'/'treehouse').exists(): (base/'v2'/'treehouse').symlink_to(shutil.which('treehouse'))
with (evidence/'live-cleanup.log').open('w') as log:
 def run(args,cwd=root,check=True,input=None):
    log.write('$ '+subprocess.list2cmdline([str(x) for x in args])+'\n'); log.flush()
    p=subprocess.run(args,cwd=cwd,env=env,text=True,input=input,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
    log.write(p.stdout+f'[exit {p.returncode}]\n'); log.flush()
    if check and p.returncode: raise RuntimeError(p.stdout)
    return p
 run(['tmux','-S',str(base/'s'),'new-session','-d','-s','fm-lab-cleanup','sleep 300'])
 try:
  for version in ['v2','v3']:
   env['PATH']=str(base/version)+':'+str(base/'tools')+':/usr/bin:/bin'
   run(['treehouse','--version'])
   lab=base/version/'lab'
   run(['bin/fm-lab-home.sh','create',str(lab)])
   env['FM_HOME']=str(lab)
   (lab/'config'/'backlog-backend').write_text('manual\n')
   project=lab/'projects'/'sample'; project.mkdir()
   pool=lab/'pool'; pool.mkdir()
   run(['git','init','-q','-b','main',str(project)])
   (project/'tracked.txt').write_text('baseline\n')
   (project/'treehouse.toml').write_text(f'root = "{pool}"\n')
   run(['git','add','.'],cwd=project); run(['git','commit','-qm','seed'],cwd=project)
   for case in ['leased-clean','unleased-dirty','absent-copy','foreign-lease','dirty-ship']:
    task='live-'+version+'-'+case
    p=run(['treehouse','get','--lease','--lease-holder',task],cwd=project)
    slot=pathlib.Path(p.stdout.strip().splitlines()[-1]); assert slot.is_relative_to(pool)
    assert slot.is_dir()
    meta=lab/'state'/f'{task}.meta'
    meta.write_text(f'window=fm-lab-cleanup:fm-{task}\nendpoint_task_id={task}\nworktree={slot}\nproject={project}\nkind=ship\nmode=local-only\nspawn_gen=live-validation-{task}\n')
    if case=='unleased-dirty':
     run(['treehouse','return','--force',str(slot)],cwd=project)
     (slot/'untracked.txt').write_text('disposable scout dirt\n')
     (slot/'tracked.txt').write_text('disposable edit\n')
     run(['git','checkout','-qb',task],cwd=slot)
     meta.write_text(meta.read_text().replace('kind=ship','kind=scout'))
     (lab/'data'/task).mkdir()
     (lab/'data'/task/'report.md').write_text('No changes needed.\n')
     run(['bin/fm-captain-hold.sh','complete',task,'--none'])
    elif case=='absent-copy':
     shutil.rmtree(slot)
    elif case=='foreign-lease':
     run(['treehouse','return','--force',str(slot)],cwd=project)
     p=run(['treehouse','get','--lease','--lease-holder','different-task'],cwd=project)
     assert p.stdout.strip().splitlines()[-1]==str(slot)
    elif case=='dirty-ship':
     (slot/'untracked.txt').write_text('preserve this work\n')
    before=json.loads((slot.parent.parent/'treehouse-state.json').read_text())
    log.write('POOL BEFORE '+json.dumps(before)+'\n')
    result=run(['bin/fm-teardown.sh',task],check=False)
    after=json.loads((slot.parent.parent/'treehouse-state.json').read_text())
    log.write('POOL AFTER '+json.dumps(after)+'\n')
    log.write('META PRESENT '+str(meta.exists())+'\n')
    entry=next(x for x in after['worktrees'] if x['path']==str(slot))
    if case in ['foreign-lease','dirty-ship']:
     assert result.returncode!=0 and meta.exists() and entry['leased']
     assert entry.get('lease_holder')==('different-task' if case=='foreign-lease' else task)
     if case=='foreign-lease': assert 'lease holder does not match' in result.stdout
     if case=='dirty-ship':
      assert (slot/'untracked.txt').read_text()=='preserve this work\n'
      assert 'uncommitted changes present' in result.stdout
     run(['treehouse','return','--force',str(slot)],cwd=project)
     meta.unlink()
    else:
     assert result.returncode==0 and not meta.exists() and not entry.get('leased',False)
     if case=='unleased-dirty':
      assert not (slot/'untracked.txt').exists()
      assert (slot/'tracked.txt').read_text()=='baseline\n'
      assert run(['git','rev-parse','--abbrev-ref','HEAD'],cwd=slot).stdout.strip()=='HEAD'
     if case=='absent-copy':
      p=run(['treehouse','get','--lease','--lease-holder','reuse-'+task],cwd=project)
      assert p.stdout.strip().splitlines()[-1]==str(slot)
      run(['treehouse','return','--force',str(slot)],cwd=project)
    log.write('OBSERVED '+version+' '+case+' satisfied\n');log.flush()
 finally:
  run(['tmux','-S',str(base/'s'),'kill-server'],check=False)
print('Live cleanup transcript:',evidence/'live-cleanup.log')
