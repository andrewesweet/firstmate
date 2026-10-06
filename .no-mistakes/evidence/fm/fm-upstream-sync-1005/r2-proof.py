import pathlib, subprocess, os, json, time, shutil
root=pathlib.Path.cwd(); lab=root/('lab'+str(os.getpid())); evidence=pathlib.Path('/home/andre/.no-mistakes/evidence/01M47GDMMHP9GND9V4JZHAAQ9G')
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_','TASKS_AXI_','HERDR_')) or k in ['NO_MISTAKES_GATE','TMUX','TYPESAFE_API_KEY']: env.pop(k)
env.update(FM_HOME=str(lab),HOME=str(lab/'account'),NM_HOME=str(lab/'nm'),TMPDIR=str(lab),TMUX=str(root/'t/unused-private-socket')+',0,0',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_SYSTEM='/dev/null',GIT_AUTHOR_NAME='Live Test',GIT_COMMITTER_NAME='Live Test',GIT_AUTHOR_EMAIL='live@example.invalid',GIT_COMMITTER_EMAIL='live@example.invalid')
log=(evidence/'legacy-real-treehouse.log').open('w')
def run(args,cwd=root,expect=0,extra=None):
    log.write('$ '+subprocess.list2cmdline([str(a) for a in args])+'\n');log.flush()
    e=env.copy(); e.update(extra or {})
    p=subprocess.run(args,cwd=cwd,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=70)
    log.write(p.stdout+'\nexit='+str(p.returncode)+'\n');log.flush()
    if expect is not None: assert p.returncode==expect,p.stdout
    return p.stdout
try:
    run(['bin/fm-lab-home.sh','create',str(lab)])
    for p in ['account','nm','pool','project']: (lab/p).mkdir()
    project=lab/'project';run(['git','init','-q','-b','main'],cwd=project)
    (project/'treehouse.toml').write_text('root = "'+str(lab/'pool')+'"\n')
    (project/'base.txt').write_text('landed base\n')
    run(['git','add','.'],cwd=project);run(['git','commit','-qm','initial'],cwd=project)
    slot=pathlib.Path(run(['treehouse','get','--lease','--lease-holder','legacy-proof'],cwd=project).strip().splitlines()[-1]); assert str(slot).startswith(str(lab/'pool')+'/')
    epoch=int(time.time())-1000
    run(['git','checkout','-qb','fm/legacy-proof'],cwd=slot,extra={'GIT_COMMITTER_DATE':'@'+str(epoch)+' +0000'})
    (lab/'state/legacy-proof.meta').write_text('window=private:fm-legacy-proof\nendpoint_task_id=legacy-proof\nworktree='+str(slot)+'\nproject='+str(project)+'\nkind=ship\nmode=local-only\nspawn_gen=legacy-live-gen\n')
    (lab/'state/.last-watcher-beat').touch();(lab/'config/pipeline-spend').touch()
    assert not (slot.parent/'.fm-slot-owner').exists()
    before=json.loads((slot.parent.parent/'treehouse-state.json').read_text());log.write('POOL BEFORE\n'+json.dumps(before)+'\n')
    run(['bin/fm-teardown.sh','legacy-proof'])
    ledger=lab/'data/pipeline-spend.jsonl'; rec=json.loads(ledger.read_text())
    log.write('PIPELINE LEDGER\n'+json.dumps(rec)+'\n');log.flush()
    assert rec['branch']=='fm/legacy-proof' and rec['since']==time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime(epoch)),rec
    assert run(['git','symbolic-ref','--quiet','HEAD'],cwd=slot,expect=None)==''
    assert not (lab/'state/legacy-proof.meta').exists()
    assert subprocess.run(['git','show-ref','--verify','--quiet','refs/heads/fm/legacy-proof'],cwd=slot,env=env).returncode!=0
    shutil.copyfile(ledger,evidence/'legacy-pipeline-spend.jsonl')
    log.write('Verified original branch/reflog attribution survives real ownership-verified return and branch deletion.\n')
    slot2=pathlib.Path(run(['treehouse','get','--lease','--lease-holder','foreign-task'],cwd=project).strip().splitlines()[-1]); assert str(slot2).startswith(str(lab/'pool')+'/')
    run(['git','checkout','-qb','fm/lease-refusal'],cwd=slot2)
    (lab/'state/lease-refusal.meta').write_text('window=private:fm-lease-refusal\nendpoint_task_id=lease-refusal\nworktree='+str(slot2)+'\nproject='+str(project)+'\nkind=ship\nmode=local-only\nspawn_gen=refusal-live-gen\n')
    text=run(['bin/fm-teardown.sh','lease-refusal'],expect=1)
    assert (lab/'state/lease-refusal.meta').exists()
    assert len(ledger.read_text().splitlines())==1
    assert 'fm/lease-refusal' in run(['git','symbolic-ref','--short','HEAD'],cwd=slot2)
    log.write('Verified foreign lease refuses before recording spend, detaching HEAD, or removing task metadata.\n')
    run(['treehouse','return','--force','--if-lease-holder','foreign-task',str(slot2)],cwd=project)
    (evidence/'legacy-result.txt').write_text('pass: real legacy return preserves original task branch and reflog; foreign lease retains metadata, branch, and ledger.\n')
finally:
    log.close()
    if lab.exists(): shutil.rmtree(lab)
