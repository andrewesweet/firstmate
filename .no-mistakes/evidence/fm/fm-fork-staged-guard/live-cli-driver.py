from pathlib import Path
import json, os, shlex, shutil, subprocess
root=Path.cwd()
evidence=Path('/home/cti/.no-mistakes/evidence/01M5QCM6HM4AJNV77EXMD4E8RR')
lab=root/'.test-phase/live-home'
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','TMUX_PANE','HERDR_SESSION','HERDR_ENV')}
env.update(FM_HOME=str(lab), FM_BACKEND='tmux', TMUX=str(lab/'fm-lab')+',0,0', TMPDIR=str(root/'.test-phase/tmp'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
transcript=[]
results=[]
def run(args, expected=0):
    args=[str(x) for x in args]
    p=subprocess.run(args,env=env,cwd=root,capture_output=True,text=True,timeout=45)
    transcript.append('$ '+shlex.join(args)+'\n'+p.stdout+p.stderr+'\nexit: '+str(p.returncode)+'\n')
    if expected is not None: assert p.returncode==expected, transcript[-1]
    return p

def brief(id, mode='no-mistakes', fork='Acme/Widgets', base=None):
    args=['bash','bin/fm-brief.sh',id,'proj','--mode',mode]
    if fork is not None: args+=['--fork-staged',fork]
    if base: args+=['--base-branch',base]
    run(args)
    file=lab/'data'/id/'brief.md'
    text=file.read_text().replace('{TASK}','Publish this task only through its selected fork.').replace('{FIRSTMATE_SPEC}','Exercise delivery contract boundaries.').replace('{PUBLISHED_INTENT}','Deliver the fork change safely.')
    file.write_text(text)
    return file

def spawn(id, mode='no-mistakes', fork='acme/widgets', extra=()):
    args=['bash','bin/fm-spawn.sh',id,lab/'projects/proj','claude','--mode',mode,'--yolo','off']
    if fork is not None: args+=['--fork-staged',fork]
    return run(args+list(extra),None)
try:
    run(['bash','bin/fm-lab-home.sh','create',lab])
    project=lab/'projects/proj'
    project.mkdir()
    run(['git','-C',project,'init','-q'])
    run(['git','-C',project,'-c','user.name=Test','-c','user.email=test@example.invalid','commit','--allow-empty','-m','lab initial','-q'])
    run(['git','-C',project,'remote','add','origin','https://github.com/upstream/widgets.git'])
    (lab/'data/projects.md').write_text('- proj [no-mistakes] - fixture (added 2026-01-01)\n')
    for mode in ['no-mistakes','direct-PR']:
        id='live-'+mode
        file=brief(id,mode,base='release')
        body=file.read_text()
        commands=[shlex.split(x) for x in body.split('`')[1::2] if x.startswith('gh pr create ')]
        assert commands and all(c[c.index('-R')+1]=='acme/widgets' and c[c.index('--base')+1]=='release' for c in commands)
        if mode=='no-mistakes':
            slot=[shlex.split(x) for x in body.split('`')[1::2] if '/fm-nm-slot.sh no-mistakes axi run' in x]
            assert len(slot)==1 and slot[0][-4:]==['--wait','10s','--skip','pr,ci']
        shutil.copyfile(file,evidence/(id+'-brief.md'))
        results.append({'case':'generated '+mode+' fork and release-base instructions','result':'pass'})
    file=brief('live-inference',fork=None)
    assert 'fork-staged=' not in file.read_text()
    results.append({'case':'upstream origin plus registry does not infer a fork','result':'pass'})
    for name, args in [
        ('local-only',['bad-local','proj','--mode','local-only','--fork-staged','acme/widgets']),
        ('scout',['bad-scout','proj','--scout','--fork-staged','acme/widgets']),
        ('forge',['bad-forge','proj','--mode','no-mistakes','--forge','gerrit','--fork-staged','acme/widgets']),
        ('empty',['bad-empty','proj','--mode','no-mistakes','--fork-staged=']),
        ('malformed',['bad-format','proj','--mode','no-mistakes','--fork-staged','acme'])]:
        p=run(['bash','bin/fm-brief.sh']+args,None)
        assert p.returncode and '--fork-staged' in p.stderr
        assert not (lab/'data'/args[0]/'brief.md').exists()
        results.append({'case':name+' refused by scaffold','result':'pass'})
    for mutation in ['missing-skip','intent-only','stale-target','missing-command','conflicting-contracts','missing-flag','wrong-flag']:
        id='live-'+mutation
        file=brief(id)
        text=file.read_text()
        if mutation=='missing-skip': text=text.replace('--wait 10s --skip pr,ci','--wait 10s')
        if mutation=='intent-only': text=text.replace('--intent "<the intent string>" --wait 10s --skip pr,ci','--intent "Add --skip pr,ci to starts" --wait 10s')
        if mutation=='stale-target': text=text.replace('-R acme/widgets','-R upstream/widgets')
        if mutation=='missing-command': text=text.replace('gh pr create','open the PR')
        if mutation=='conflicting-contracts': text+='\nDelivery contract: mode=no-mistakes fork-staged=other/widgets\n'
        file.write_text(text)
        fork=None if mutation=='missing-flag' else 'other/widgets' if mutation=='wrong-flag' else 'acme/widgets'
        p=spawn(id,fork=fork)
        assert p.returncode and ('fork-staged' in p.stderr or 'fork-staged' in p.stdout),transcript[-1]
        assert not (lab/'state'/(id+'.meta')).exists()
        assert not (lab/'data'/id/'launch-brief.md').exists()
        results.append({'case':mutation+' refused before launch or task registration','result':'pass'})
    for mutation in ['stale-target','missing-command','prefix-target']:
        id='live-direct-'+mutation
        file=brief(id,'direct-PR')
        text=file.read_text()
        if mutation=='stale-target': text=text.replace('-R acme/widgets','-R upstream/widgets')
        if mutation=='missing-command': text=text.replace('gh pr create','open the PR')
        if mutation=='prefix-target': text=text.replace('-R acme/widgets','-R acme/widgets-extra')
        file.write_text(text)
        p=spawn(id,'direct-PR')
        assert p.returncode and 'carries no rider that re-targets' in p.stderr,transcript[-1]
        assert not (lab/'state'/(id+'.meta')).exists()
        assert not (lab/'data'/id/'launch-brief.md').exists()
        results.append({'case':'direct-PR '+mutation+' refused before launch or task registration','result':'pass'})
    p=run(['bash','bin/fm-spawn.sh','live-relaunch',project,'claude','--relaunch','--fork-staged','other/widgets'],None)
    assert p.returncode and 'cannot override' in p.stderr,transcript[-1]
    results.append({'case':'relaunch cannot override recorded fork','result':'pass'})
    # Promotion is a public persisted-contract operation; no worker is launched or steered.
    id='live-promote'
    run(['bash','bin/fm-brief.sh',id,'proj','--scout'])
    f=lab/'data'/id/'brief.md'
    text=f.read_text().replace('{TASK}','Publish only to the chosen fork.').replace('{FIRSTMATE_SPEC}','Investigate safe delivery.')
    text=text.replace('## Firstmate spec','## Published intent\nDeliver the fork change safely.\n\n## Firstmate spec')
    f.write_text(text)
    (lab/'state'/(id+'.meta')).write_text('kind=scout\nwindow=fm-lab:scout\nworktree='+str(project)+'\nproject='+str(project)+'\nbase_branch=release\n')
    run(['bash','bin/fm-promote.sh',id,'--mode','no-mistakes','--yolo','off','--fork-staged','Acme/Widgets'])
    meta=(lab/'state'/(id+'.meta')).read_text()
    assert 'fork_staged=acme/widgets\n' in meta and 'kind=ship\n' in meta
    instructions=lab/'data'/id/'ship-instructions.md'
    assert instructions.exists()
    shutil.copyfile(instructions,evidence/'live-promoted-instructions.md')
    (evidence/'live-promoted-task.meta').write_text(meta)
    results.append({'case':'promotion persists normalized fork and generates ship delivery instructions','result':'pass'})
finally:
    (evidence/'live-cli-transcript.log').write_text('\n'.join(transcript))
    (evidence/'live-cli-results.json').write_text(json.dumps(results,indent=2)+'\n')
    shutil.rmtree(lab,ignore_errors=True)
print(json.dumps(results,indent=2))
