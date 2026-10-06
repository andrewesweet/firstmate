import pathlib,os,subprocess,json,time,shutil
root=pathlib.Path.cwd(); lab=root/('ns'+str(os.getpid())); ev=pathlib.Path('/home/andre/.no-mistakes/evidence/01M47GDMMHP9GND9V4JZHAAQ9G'); env=os.environ.copy()
for k in list(env):
 if k.startswith(('FM_','HERDR_','TASKS_AXI_')) or k in ['TMUX','NO_MISTAKES_GATE','TYPESAFE_API_KEY']:env.pop(k)
env.update(FM_HOME=str(lab),NM_HOME=str(lab/'nm'),TMPDIR=str(lab),FM_HERDR_LAB_STATE_DIR=str(lab/'herdr-state'),PI_CODING_AGENT_SESSION_DIR=str(lab/'sessions'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_SYSTEM='/dev/null',GIT_AUTHOR_NAME='Live Test',GIT_COMMITTER_NAME='Live Test',GIT_AUTHOR_EMAIL='live@example.invalid',GIT_COMMITTER_EMAIL='live@example.invalid')
log=(ev/'named-base-spawn.log').open('w');session=None;slot=None

def run(args,cwd=root,expect=0,timeout=80):
 log.write('$ '+subprocess.list2cmdline([str(x) for x in args])+'\n');log.flush()
 p=subprocess.run(args,cwd=cwd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout);log.write(p.stdout+'\nexit='+str(p.returncode)+'\n');log.flush()
 if expect is not None:assert p.returncode==expect,p.stdout
 return p.stdout
try:
 run(['bin/fm-lab-home.sh','create',str(lab)])
 for x in ['pool','project','nm']: (lab/x).mkdir()
 project=lab/'project';run(['git','init','-q','-b','main'],cwd=project)
 (project/'treehouse.toml').write_text('root = "'+str(lab/'pool')+'"\n');(project/'base.txt').write_text('default branch\n')
 run(['git','add','.'],cwd=project);run(['git','commit','-qm','default'],cwd=project)
 run(['git','checkout','-qb','release/next'],cwd=project);(project/'base.txt').write_text('named branch sentinel\n')
 run(['git','commit','-qam','named release sentinel'],cwd=project); expected=run(['git','rev-parse','HEAD'],cwd=project).strip()
 run(['git','checkout','-q','main'],cwd=project);run(['git','clone','-q','--bare',str(project),str(lab/'origin.git')]);run(['git','remote','add','origin',str(lab/'origin.git')],cwd=project)
 run(['bin/fm-brief.sh','named-live','sandbox','--scout','--base-branch','release/next','--herdr-lab'])
 brief=lab/'data/named-live/brief.md';s=brief.read_text().replace('{TASK}','This is a disposable spawn verification only. Read base.txt and git rev-parse HEAD. Write the exact observed starting commit and sentinel text to the report, then stop. No source edits, installs, web access, pushes, PRs or pipeline actions.').replace('{FIRSTMATE_SPEC}','Inspect only this disposable worktree and write the authorized report and status. Never access operator files or perform any fleet or pool administration.')
 brief.write_text(s)
 session=run(['bin/fm-herdr-lab.sh','name','named-base']).strip();run(['bin/fm-herdr-lab.sh','provision',session]);env['HERDR_SESSION']=session
 run(['bin/fm-spawn.sh','named-live',str(project),'--scout','--harness','pi','--effort','low','--backend','herdr','--base-branch','release/next'],timeout=110)
 meta=lab/'state/named-live.meta';row=dict(x.split('=',1) for x in meta.read_text().splitlines() if '=' in x);slot=pathlib.Path(row['worktree']); assert str(slot).startswith(str(lab/'pool')+'/')
 assert row['base_branch']=='release/next' and row['herdr_session']==session
 actual=run(['git','rev-parse','HEAD'],cwd=slot).strip();assert actual==expected,(actual,expected)
 assert (slot/'base.txt').read_text()=='named branch sentinel\n';assert row['harness']=='pi'
 pool=json.loads((slot.parent.parent/'treehouse-state.json').read_text());lease=[x for x in pool['worktrees'] if x['path']==str(slot)][0];assert lease['leased'] and lease['lease_holder']=='named-live'
 log.write('OBSERVED START: '+json.dumps({'actual_head':actual,'named_base_head':expected,'sentinel':(slot/'base.txt').read_text(),'lease_holder':lease['lease_holder'],'harness':row['harness'],'session':session})+'\n');log.flush()
 shutil.copyfile(meta,ev/'named-base-task.meta')
 run(['bin/fm-herdr-lab.sh','run',session,'pane','list'])
 report=lab/'data/named-live/report.md'
 for _ in range(80):
  if report.exists():break
  time.sleep(.5)
 if report.exists():
  shutil.copyfile(report,ev/'named-base-scout-report.md');log.write('SCOUT REPORT\n'+report.read_text()+'\n')
 else:log.write('Report not yet written; start commit and real leased endpoint already verified.\n')
 (ev/'named-base-spawn-result.json').write_text(json.dumps({'result':'pass','head':actual,'base_branch':'release/next','lease_holder':'named-live','real_harness':'pi','report_written':report.exists()},indent=2))
finally:
 if session:
  run(['bin/fm-herdr-lab.sh','teardown',session],expect=None)
 if slot and slot.exists() and str(slot).startswith(str(lab/'pool')+'/'):
  run(['treehouse','return','--force','--if-lease-holder','named-live',str(slot)],cwd=lab/'project',expect=None)
 log.close()
 if lab.exists():
  for directory in [lab]+[x for x in lab.rglob('*') if x.is_dir() and not x.is_symlink()]:directory.chmod(directory.stat().st_mode | 0o700)
  shutil.rmtree(lab)
