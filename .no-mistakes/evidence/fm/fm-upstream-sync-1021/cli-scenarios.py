import os,subprocess,pathlib,tempfile,json,shutil,tomllib
root=pathlib.Path.cwd(); evidence=pathlib.Path('/home/cti/.no-mistakes/evidence/01M5E7D4NWGSE64JVQKMS28Z5X')
lab=pathlib.Path(tempfile.mkdtemp(prefix='manual-',dir=root/'.live-validation-tmp'))
home=lab/'home'; results=[]; transcript=[]
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k in ['TMUX','NM_HOME','NO_MISTAKES_GATE','TASKS_AXI_FILE','TASKS_AXI_BACKEND']: env.pop(k,None)
env.update(FM_HOME=str(home),TMPDIR=str(lab),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
def run(args,expected=0,extra=None):
 p=subprocess.run([str(a) for a in args],cwd=root,env=env| (extra or {}),text=True,capture_output=True,timeout=25)
 transcript.append('$ '+' '.join(str(a) for a in args)+'\n'+p.stdout+p.stderr+'\nexit='+str(p.returncode)+'\n')
 if expected is not None: assert p.returncode==expected, transcript[-1]
 return p

def scenario(name,fn):
 try: fn(); results.append(dict(name=name,result='pass',live=True))
 except Exception as e: results.append(dict(name=name,result='fail',live=True,reason=str(e)))
try:
 run(['bin/fm-lab-home.sh','create',home])
 repo=lab/'repo'; repo.mkdir(); run(['git','init','-q','-b','main',repo]); run(['git','-C',repo,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-q','--allow-empty','-m','initial'])
 def briefs():
  run(['bin/fm-brief.sh','ship',repo,'--mode','no-mistakes','--herdr-lab'])
  run(['bin/fm-brief.sh','scout',repo,'--scout','--herdr-lab'])
  ship=(home/'data/ship/brief.md').read_text(); scout=(home/'data/scout/brief.md').read_text()
  assert ship.index("## Captain's intent") < ship.index('## Published intent') < ship.index('## Firstmate spec')
  assert 'Never start a shell command with `cd`' in ship and 'Never start a shell command with `cd`' in scout
  assert 'fm-herdr-lab.sh' in ship and 'fm-lab-' in ship
  shutil.copyfile(home/'data/ship/brief.md',evidence/'generated-ship-brief.md'); shutil.copyfile(home/'data/scout/brief.md',evidence/'generated-scout-brief.md')
 scenario('Scaffold ship and scout briefs with the required intent sections and leading-cd prohibition',briefs)
 def unborn_spawn():
  unborn=lab/'unborn'; unborn.mkdir(); run(['git','init','-q',unborn])
  run(['bin/fm-brief.sh','unborn',unborn,'--mode','local-only'])
  brief=home/'data/unborn/brief.md'
  brief.write_text(brief.read_text().replace('{TASK}','Validate refusal of an unborn repository.').replace('{PUBLISHED_INTENT}','Refuse spawn until a first commit exists.').replace('{FIRSTMATE_SPEC}','Run no implementation; this is an isolated validation.'))
  socketdir=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab-sock.'))
  tm_env={'TMUX_TMPDIR':str(socketdir)}
  try:
   run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','40','-c',root],extra=tm_env)
   socket=run(['tmux','-L','fm-lab','display-message','-p','#{socket_path}'],extra=tm_env).stdout.strip()
   p=run(['bin/fm-spawn.sh','unborn',unborn,'--mode','local-only','--harness','claude','--backend','tmux','--yolo','off'],expected=1,extra=tm_env|{'TMUX':socket+',0,0'})
   assert 'unborn HEAD' in p.stderr and 'make one commit' in p.stderr
   assert not (home/'state/unborn.meta').exists()
   assert not run(['git','-C',unborn,'rev-list','--all']).stdout
  finally:
   run(['tmux','-L','fm-lab','kill-server'],expected=None,extra=tm_env); shutil.rmtree(socketdir)
 scenario('Refuse an unborn-HEAD spawn immediately without creating metadata or committing the project',unborn_spawn)
 def review():
  meta=home/'state/review.meta'; meta.write_text(f'kind=ship\nmode=direct-PR\nforge=external\nworktree={repo}\nproject={repo}\nbranch=main\nyolo=off\n')
  run(['bin/fm-review-check.sh','review','https://review.example.test/r/123'])
  value=meta.read_text(); assert 'review=https://review.example.test/r/123\n' in value and 'review_head=' in value
  assert not (home/'state/review.check.sh').exists() and not (home/'state/review.pr-poll').exists()
  for bad in ['https://github.com/o/r/pull/1','http://review.example.test/r/1','https://review.example.test/r/1?x=1']:
   p=run(['bin/fm-review-check.sh','review',bad],expected=None); assert p.returncode!=0; assert meta.read_text()==value
  transcript.append('PERSISTED EXTERNAL REVIEW CONTRACT\n'+value+'No merge-watch or PR-poll file was created.\n')
 scenario('Record an external review and refuse forge PR, insecure and query-bearing URLs without arming a merge watch',review)
 def busy():
  state=home/'state'; writer='bin/fm-busy-event.sh'
  gen=run([writer,'arm',state,'busy']).stdout.strip()
  run([writer,'apply',state,'busy','busy','--gen',gen,'--source','polytoken-hook','--event','pre_model_turn'])
  newer=(state/'busy.busy-state').read_text()
  p=run([writer,'apply',state,'busy','idle','--gen',gen,'--source','fm-interrupt','--event','interrupt','--if-seq','1'],expected=None)
  assert p.returncode!=0 and (state/'busy.busy-state').read_text()==newer
  run([writer,'apply',state,'busy','idle','--gen',gen,'--source','fm-interrupt','--event','interrupt','--if-seq','2'])
  transcript.append('PERSISTED IDLE CONTRACT\n'+(state/'busy.busy-state').read_text())
  newgen=run([writer,'arm',state,'busy']).stdout.strip(); newer=(state/'busy.busy-state').read_text()
  p=run([writer,'apply',state,'busy','idle','--gen',gen,'--source','fm-interrupt','--event','interrupt','--if-seq','1'],expected=None)
  assert p.returncode!=0 and (state/'busy.busy-state').read_text()==newer and gen!=newgen
  transcript.append('PRESERVED NEW INCARNATION\n'+newer)
 scenario('Reject stale interrupt closes after a new busy event or replacement generation; allow an unchanged close',busy)
 def groups():
  config=home/'config/herdr-project-groups'; config.write_text('Backend task:api\nWeb repo:repo\nOther *\n')
  for task,status in [('api-one','needs-decision [key=x]: choose'),('web-one','done: complete')]:
   (home/f'state/{task}.meta').write_text(f'kind=scout\nbackend=herdr\nproject={repo}\nherdr_session=fm-lab-preview\nherdr_workspace_id=workspace-{task}\nherdr_pane_id=pane-{task}\nwindow=fm-{task}\n')
   (home/f'state/{task}.status').write_text(status+'\n')
  p=run(['bin/fm-herdr-groups.sh','plan']); rows={r.split('\t')[0]:r.split('\t') for r in p.stdout.strip().splitlines()}
  assert rows['api-one'][1:3]==['Backend','needs-captain'] and rows['web-one'][1:3]==['Web','done']
  cfg=lab/'herdr.toml'; cfg.write_text('[ui]\nagent_panel_sort="default"\n')
  run(['bin/fm-herdr-groups.sh','sidebar-config','--apply',cfg]); parsed=tomllib.loads(cfg.read_text())
  assert parsed['ui']['sidebar']['agents']['rows'][0][-1]=='$fm_task'
  before=cfg.read_bytes(); run(['bin/fm-herdr-groups.sh','sidebar-config','--apply',cfg],expected=1); assert cfg.read_bytes()==before
  shutil.copyfile(cfg,evidence/'generated-herdr-sidebar.toml')
 scenario('Preview Herdr group precedence and task statuses; apply sidebar configuration once and refuse overwrite',groups)
 def role():
  run(['git','-C',repo,'remote','add','origin','https://github.com/fork-owner/firstmate']); run(['git','-C',repo,'remote','add','upstream','https://github.com/kunchenguid/firstmate'])
  extra={'FM_ROOT_OVERRIDE':str(repo)}
  target=home/'config/firstmate-pub-target'; target.write_text('github.com/fork-owner/firstmate\n')
  run(['bin/fm-role.sh','check',repo],expected=1,extra=extra)
  p=run(['bin/fm-role.sh','check',repo,'upstream-consent','github.com/fork-owner/firstmate'],extra=extra)
  assert "GH_REPO='github.com/fork-owner/firstmate'" in p.stdout
  target.unlink(); p=run(['bin/fm-role.sh','check',repo,'upstream-consent','github.com/fork-owner/firstmate'],expected=1,extra=extra)
  assert 'github.com/kunchenguid/firstmate' in p.stdout
  run(['git','-C',repo,'config','remote.origin.gh-resolved','base'])
  p=run(['bin/fm-role.sh','check',repo,'upstream-consent','github.com/fork-owner/firstmate'],extra=extra)
  assert "GH_REPO='github.com/fork-owner/firstmate'" in p.stdout
 scenario('Resolve declared fork and gh-resolved publication targets while refusing an ungranted or mismatched target',role)
 def resolver():
  resolved=lab/'resolved-home'; resolved.mkdir(); hook=lab/'resolver'; hook.write_text('#!/bin/sh\nprintf "%s\\n" "'+str(resolved)+'"\n'); hook.chmod(0o700)
  (home/'config/nm-home-resolver').write_text(str(hook)+'\n')
  command='. bin/fm-nm-run-lib.sh; fm_nm_home_resolver_home "$1"'
  p=run(['bash','-c',command,'_',repo]); assert p.stdout.strip()==str(resolved)
  p=run(['bash','-c',command,'_',repo],extra={'NM_HOME':str(home)}); assert not p.stdout
  hook.write_text('#!/bin/sh\nprintf "/nonexistent-fm-lab-home\\n/second-line\\n"\n')
  p=run(['bash','-c',command,'_',repo]); assert not p.stdout
  transcript.append('Invalid multi-line resolver output was ignored; no directory or daemon was created.\n')
 scenario('Use an opt-in home resolver, preserve explicit NM_HOME, and ignore invalid resolver output',resolver)
finally:
 shutil.rmtree(lab)
 (evidence/'cli-transcript.log').write_text('\n'.join(transcript))
 (evidence/'cli-results.json').write_text(json.dumps(results,indent=2))
 print(json.dumps(results,indent=2))
