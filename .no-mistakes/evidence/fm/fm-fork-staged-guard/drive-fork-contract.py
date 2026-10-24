from pathlib import Path
import os, tempfile, subprocess, shutil, json, re, shlex
root=Path.cwd()
evidence=Path('/home/cti/.no-mistakes/evidence/01M5Q76AW9BSCFW8MNGY4HGXG9')
lab=Path(tempfile.mkdtemp(prefix='.fm-live-fork-',dir=root))
env=os.environ.copy()
for key in list(env):
    if key.endswith('_OVERRIDE') or key in ('FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','FM_TASK_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND','NM_HOME'):
        env.pop(key,None)
env.update(FM_HOME=str(lab),FM_BACKEND='tmux',TMUX=str(lab/'unused-private-socket')+',0,0',GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_AUTHOR_NAME='Live validation',GIT_AUTHOR_EMAIL='validation@example.invalid',GIT_COMMITTER_NAME='Live validation',GIT_COMMITTER_EMAIL='validation@example.invalid')
log=[]
results=[]
def run(*args,expected=0):
    cp=subprocess.run(list(map(str,args)),cwd=root,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=45)
    log.append('$ '+shlex.join(list(map(str,args)))+'\n'+cp.stdout+f'[exit {cp.returncode}]\n')
    assert (cp.returncode == 0) if expected == 0 else (cp.returncode != 0),cp.stdout
    return cp.stdout

def scaffold(task,mode='no-mistakes',fork='Acme/Widgets',base=None,scout=False):
    args=[root/'bin/fm-brief.sh',task,'proj']
    args += ['--scout'] if scout else ['--mode',mode]
    if fork is not None: args+=['--fork-staged',fork]
    if base: args+=['--base-branch',base]
    run(*args)
    path=lab/'data'/task/'brief.md'
    text=path.read_text().replace('{TASK}','Deliver the requested change on the selected fork.').replace('{PUBLISHED_INTENT}','Deliver the requested change on the selected fork.').replace('{FIRSTMATE_SPEC}','Preserve the explicit per-task publication contract.')
    path.write_text(text)
    return path

def record(name): results.append({'name':name,'result':'pass','live':True}); log.append('SCENARIO PASS: '+name+'\n')
try:
    run(root/'bin/fm-lab-home.sh','create',lab)
    proj=lab/'projects/proj'
    proj.mkdir()
    run('git','-C',proj,'init','-q','-b','main')
    run('git','-C',proj,'commit','-q','--allow-empty','-m','Live validation fixture')
    run('git','-C',proj,'remote','add','origin','https://github.com/upstream/widgets.git')
    (lab/'data/projects.md').write_text('- proj [no-mistakes] - upstream project, fork-staged=registry/ignored\n')
    for mode in ('no-mistakes','direct-PR'):
        path=scaffold('render-'+mode,mode,base='release/1.2')
        text=path.read_text()
        (evidence/('generated-'+mode+'.md')).write_text(text)
        assert 'Delivery contract: mode='+mode+' fork-staged=acme/widgets' in text
        commands=[shlex.split(c) for c in re.findall(r'`([^`\n]+)`',text) if c.startswith('gh pr create ')]
        assert commands and all(c[c.index('-R')+1]=='acme/widgets' and c[c.index('--base')+1]=='release/1.2' for c in commands)
        if mode=='no-mistakes':
            starts=[shlex.split(c) for c in re.findall(r'`([^`\n]+)`',text) if 'fm-nm-slot.sh no-mistakes axi run' in c]
            assert len(starts)==1 and starts[0][starts[0].index('--skip')+1]=='pr,ci'
            assert 'pass `--base-branch release/1.2` on every' in text
            assert 'so the pipeline rebases onto that branch.' in text
            assert 'pipeline rebases onto, opens its PR against' not in text
    record('Scaffold fork-staged validation and direct delivery with the named fork and release base')
    plain=scaffold('plain',fork=None).read_text()
    assert 'fork-staged=' not in plain and '--wait 10s --skip pr,ci' not in plain
    (evidence/'generated-unflagged.md').write_text(plain)
    record('Omit the per-task flag despite upstream origin and registry fork text; receive ordinary delivery instructions')
    invalid=[['--mode','local-only','--fork-staged','acme/widgets'],['--mode','no-mistakes','--fork-staged','acme'],['--scout','--fork-staged','acme/widgets'],['--mode','no-mistakes','--forge','gerrit','--fork-staged','acme/widgets'],['--mode','direct-PR','--forge','forgejo','--fork-staged','acme/widgets']]
    for i,args in enumerate(invalid):
        task='invalid-'+str(i)
        run(root/'bin/fm-brief.sh',task,'proj',*args,expected=1)
        assert not (lab/'data'/task/'brief.md').exists()
    record('Reject malformed forks and fork flags on scout, local-only, or bound-forge instructions without creating a brief')
    for mutation in ('missing-flag','different-fork','missing-token','missing-skip','quoted-intent','missing-pr','wrong-pr'):
        task='guard-'+mutation
        path=scaffold(task)
        text=path.read_text()
        if mutation=='missing-token': text=text.replace(' fork-staged=acme/widgets','')
        if mutation=='missing-skip': text=text.replace('--wait 10s --skip pr,ci','--wait 10s')
        if mutation=='quoted-intent': text=text.replace('--intent "<the intent string>" --wait 10s --skip pr,ci','--intent "Add --skip pr,ci to starts" --wait 10s')
        if mutation=='missing-pr': text=text.replace('gh pr create','create the pull request')
        if mutation=='wrong-pr': text=text.replace('-R acme/widgets','-R upstream/widgets')
        path.write_text(text)
        args=[root/'bin/fm-spawn.sh',task,proj,'claude','--mode','no-mistakes','--yolo','off','--backend','tmux']
        if mutation!='missing-flag':args+=['--fork-staged','other/widgets' if mutation=='different-fork' else 'acme/widgets']
        out=run(*args,expected=1)
        assert ('fork-staged mismatch' in out or 'records no fork-staged rider' in out or 'carries no rider that re-targets' in out),out
        assert not (lab/'state'/f'{task}.meta').exists()
        assert not (lab/'data'/task/'launch-brief.md').exists()
    record('Spawn refuses missing or conflicting fork tokens, missing skip or PR command, stale target, and quoted-intent bypass before launching')
    for mode in ('no-mistakes','direct-PR'):
        task='promote-'+mode
        path=scaffold(task,fork=None,scout=True)
        text=path.read_text().replace('## Firstmate spec','## Published intent\nDeliver the investigated change on the fork.\n\n## Firstmate spec')
        path.write_text(text)
        meta=lab/'state'/f'{task}.meta'
        meta.write_text(f'window=fm-{task}\nkind=scout\nworktree={proj}\nproject={proj}\nbase_branch=release/1.2\n')
        run(root/'bin/fm-promote.sh',task,'--mode',mode,'--yolo','off','--fork-staged','Acme/Widgets')
        values=dict(line.split('=',1) for line in meta.read_text().splitlines() if '=' in line)
        assert values['kind']=='ship' and values['fork_staged']=='acme/widgets' and values['mode']==mode
        instructions=(lab/'data'/task/'ship-instructions.md').read_text()
        assert 'Delivery contract: mode='+mode+' fork-staged=acme/widgets' in instructions
        assert 'gh pr create -R acme/widgets --base release/1.2' in instructions
        if mode=='no-mistakes': assert '--wait 10s --skip pr,ci' in instructions
        (evidence/('promotion-'+mode+'.md')).write_text(instructions)
        (evidence/('promotion-'+mode+'.meta')).write_text(meta.read_text())
    record('Promote a scout in both delivery modes; persist the normalized fork and generate superseding instructions for the release base')
finally:
    shutil.rmtree(lab)
    log.append('Disposable home and fixture repository removed. No runtime endpoint was created.\n')
    (evidence/'live-cli-transcript.log').write_text('\n'.join(log))
    (evidence/'live-cli-results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
