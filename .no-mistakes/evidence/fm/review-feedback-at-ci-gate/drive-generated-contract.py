from pathlib import Path
import os, subprocess, json, shutil
root=Path.cwd()
work=root/'.no-mistakes/test-phase/manual'
evidence=Path('~/.no-mistakes/evidence/01M5NDG7A89JX5FJNB7V36WM66')
work.mkdir(parents=True,exist_ok=True)
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k.startswith('TASKS_AXI_'))}
env['TMPDIR']=str(root/'.no-mistakes/test-phase/tmp')
transcript=[]
def invoke(args, home, extra=None):
    e=dict(env,FM_HOME=str(home),FM_ROOT_OVERRIDE=str(root))
    e.update(extra or {})
    p=subprocess.run(args,cwd=root,env=e,text=True,capture_output=True,timeout=40)
    transcript.append('$ '+ ' '.join(args)+'\nFM_HOME='+str(home)+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode))
    if p.returncode: raise RuntimeError(transcript[-1])
    return p.stdout

def brief(label,mode='no-mistakes',forge=None,pause=None):
    home=work/label
    (home/'data').mkdir(parents=True,exist_ok=True)
    args=['bin/fm-brief.sh',label,'isolated-product','--mode',mode]
    if forge: args+=['--forge',forge]
    invoke(args,home,{'FM_CLASSIFY_PAUSED_VERB':pause} if pause else {})
    output=(home/'data'/label/'brief.md').read_text()
    (evidence/(label+'.md')).write_text(output)
    return output

results=[]
def check(name,conditions,artifact):
    failures=[detail for detail,ok in conditions if not ok]
    results.append({'name':name,'result':'fail' if failures else 'pass','live':True,'evidence':artifact,'reason':'; '.join(failures)})
    if failures: raise AssertionError(results[-1])
try:
    github=brief('github-worker')
    check('Generate GitHub worker instructions: bounded minute polling reads checks, reviews, inline comments and issue comments',[
        ('minute cadence','poll about once a minute with one poll per command' in github),
        ('command bound',"never put a single wait longer than your harness's command bound" in github),
        ('check read','`gh-axi pr checks <n>`' in github),
        ('review/comment read','`gh-axi pr view <n> --comments --reviews`' in github),
        ('inline and issue comments', 'inline review comments, and issue comments' in github),
    ],'github-worker.md')
    check('Generate review-routing instructions: parked gates receive fix work; absent gates retain keyed decisions through CI green',[
        ('bot failure cannot be dismissed','A failing review-bot check, a review-bot finding, or a maintainer comment asking for a change' in github and 'never a non-required check to dismiss' in github),
        ('parked fix path','`no-mistakes axi respond --action fix`' in github),
        ('keyed escalation','[key=pr-<n>-<comment-id>]' in github),
        ('inbox handling', 'processing and acknowledging your Firstmate instruction inbox on each poll' in github),
        ('after-green fix preserves pushed commits','branch_sync.next_action' in github and 'when it names one (an already synchronized branch needs none)' in github and 'post-pipeline follow-up work' in github and 'same `--intent`' in github),
        ('unanswered decision blocks done','never append `done:` while a `pr-<n>-<comment-id>` decision you opened is still unanswered' in github),
        ('final reread', "Before appending `done:`, re-read the PR's reviews and comments" in github),
    ],'github-worker.md')
    check('Generate maintainer-wait instructions: use a separate external-wait key, keep polling, and resolve without reporting a blocker',[
        ('maintainer examples', 'fork-workflow approval' in github and 'rerun of a flaky job' in github),
        ('default pause','append `paused [at=<epoch>] [key=nm-<run>-ci-wait]' in github),
        ('renew wait after decisions','re-append that same keyed line after any later status event' in github),
        ('own resolution','resolved [at=<epoch>] [key=nm-<run>-ci-wait]' in github),
        ('no stop or blocker','never report it as `blocked:` and never stop on it' in github),
    ],'github-worker.md')
    forgejo=brief('forgejo-worker',forge='forgejo')
    polling=next(x for x in forgejo.splitlines() if x.startswith('Every poll reads'))
    check('Generate Forgejo worker instructions: use tea, read each review’s inline comments, and exhaust list/status pages',[
        ('no GitHub poll','gh-axi' not in polling),
        ('head and statuses','/pulls/<n>` for `head.sha`' in polling and '/commits/<head.sha>/status' in polling),
        ('per-review inline reads','/pulls/<n>/reviews/<review-id>/comments' in polling and 'for each review' in polling),
        ('issue comments','/issues/<n>/comments' in polling),
        ('pagination','reading every page of these API lists and commit statuses' in polling),
        ('no nonexistent route','/pulls/<n>/comments' not in polling),
    ],'forgejo-worker.md')
    custom=brief('custom-wait-worker',pause='holding')
    check('Configure a custom pause verb: fresh worker instructions use holding for the maintainer-only CI wait',[
        ('custom verb','append `holding [at=<epoch>] [key=nm-<run>-ci-wait]' in custom),
        ('no hardcoded pause','append `paused [at=<epoch>] [key=nm-<run>-ci-wait]' not in custom),
    ],'custom-wait-worker.md')
    for pause in (None,'holding'):
        label='promoted-'+('default' if pause is None else 'custom')
        home=work/label
        (home/'state').mkdir(parents=True,exist_ok=True)
        (home/'data'/label).mkdir(parents=True,exist_ok=True)
        (home/'state'/(label+'.meta')).write_text('kind=scout\nwindow=fm-'+label+'\nworktree='+str(work)+'\n')
        (home/'data'/label/'brief.md').write_text('# Task\n## Captain\'s intent\nValidate generated instructions.\n\n## Firstmate spec\nKeep the scope narrow.\n\n# Setup\nThis is a SCOUT task.\n')
        invoke(['bin/fm-promote.sh',label,'--mode','no-mistakes','--yolo','off'],home,{'FM_CLASSIFY_PAUSED_VERB':pause} if pause else {})
        output=(home/'data'/label/'ship-instructions.md').read_text()
        (evidence/(label+'.md')).write_text(output)
        check('Promote a scout: '+('default paused fallback' if pause is None else 'custom holding verb')+' survives the alternate caller',[
            ('alternate caller has feedback policy','Every poll reads the PR itself' in output),
            ('correct verb','append `'+(pause or 'paused')+' [at=<epoch>] [key=nm-<run>-ci-wait]' in output),
        ],label+'.md')
    out=invoke(['bash','-eu','-c','. bin/fm-dod-lib.sh; fm_dod_block no-mistakes standalone'],work)
    (evidence/'standalone-dod.md').write_text(out)
    check('Call fm_dod_block with its existing minimal signature: default paused fallback renders under nounset',[
        ('default fallback','append `paused [at=<epoch>] [key=nm-<run>-ci-wait]' in out),
    ],'standalone-dod.md')
    direct=brief('direct-pr-worker',mode='direct-PR')
    local=brief('local-only-worker',mode='local-only')
    check('Generate non-pipeline deliveries: direct-PR and local-only omit CI-gate feedback instructions',[
        ('no CI-gate contract','At the CI gate, poll' not in direct and 'At the CI gate, poll' not in local),
    ],'direct-pr-worker.md; local-only-worker.md')
finally:
    (evidence/'generated-contract-scenarios.json').write_text(json.dumps(results,indent=2)+'\n')
    (evidence/'generation-transcript.log').write_text('\n\n'.join(transcript)+'\n')
    shutil.rmtree(work)
print(json.dumps(results,indent=2))
