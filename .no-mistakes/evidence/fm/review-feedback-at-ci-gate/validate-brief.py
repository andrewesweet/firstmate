"""Execute the public brief generator and selected generated-output contracts.
Oracle: the supplied author intent and recorded CI fix decisions. These checks
validate the emitted worker instructions, not an agent's future interpretation.
"""
from pathlib import Path
import os, subprocess, tempfile, shutil, json, shlex
ROOT=Path('~/.no-mistakes/worktrees/0d094301c922/01M5FE5ZKVMNS3FNH1ZE8SP1TQ')
EVIDENCE=Path('~/.no-mistakes/evidence/01M5FE5ZKVMNS3FNH1ZE8SP1TQ')
fixture=Path(tempfile.mkdtemp(prefix='.gate-brief-',dir=ROOT))
env=os.environ.copy()
for key in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_CLASSIFY_PAUSED_VERB','FM_CLASSIFY_PAUSED_VERB_DEFAULT','FM_HOME','CONFIG','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:
    env.pop(key,None)
env.update(FM_HOME=str(fixture/'ambient-home'),TMPDIR=str(fixture),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
transcript=[]
results=[]
selectors=[]
def run(args, extra=None):
    actual=env| (extra or {})
    cp=subprocess.run(args,cwd=ROOT,env=actual,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
    transcript.append('$ '+(' '.join(f'{k}={shlex.quote(v)}' for k,v in (extra or {}).items()))+' '+shlex.join(args)+'\n'+cp.stdout+f'\nexit: {cp.returncode}\n')
    if cp.returncode: raise RuntimeError(cp.stdout)
    return cp.stdout

def generate(label, mode='no-mistakes',forge=None,verb=None):
    home=fixture/label
    (home/'data').mkdir(parents=True)
    extra={'FM_HOME':str(home)}
    if verb is not None: extra['FM_CLASSIFY_PAUSED_VERB']=verb
    args=['bash','bin/fm-brief.sh',label,'disposable-project','--mode',mode]
    if forge: args+=['--forge',forge]
    run(args,extra)
    output=(home/'data'/label/'brief.md').read_text()
    (EVIDENCE/(label+'.md')).write_text(output)
    return output

def require(text,*phrases):
    for phrase in phrases:
        assert phrase in text, f'Missing generated-output contract: {phrase}'

def passed(name,evidence): results.append({'name':name,'result':'pass','live':True,'evidence':evidence,'reason':''})
try:
    github=generate('github-worker-brief')
    require(github,'poll about once a minute with one poll per command',"never put a single wait longer than your harness's command bound",'`gh-axi pr checks <n>`','`gh-axi pr view <n> --comments --reviews`','review submissions, inline review comments, and issue comments','A failing review-bot check, a review-bot finding, or a maintainer comment asking for a change','never a non-required check to dismiss','feed each item to it with `no-mistakes axi respond --action fix`')
    passed('Generate a GitHub worker brief: bounded polls read all feedback and route change requests to a parked gate','github-worker-brief.md')
    require(github,'[key=pr-<n>-<comment-id>]','for this decision only in place of rule 6\'s stop','processing and acknowledging your Firstmate instruction inbox on each poll','on dismiss, reply on the PR','next parked gate or CI-ready decision point','when the run reaches CI green or its final outcome first','`branch_sync.next_action`','when it names one (an already synchronized branch needs none)','post-pipeline follow-up work on top of this same branch','with the same `--intent` to its outcome before `done:`','re-read the PR\'s reviews and comments','never append `done:` while a `pr-<n>-<comment-id>` decision you opened is still unanswered')
    passed('Generate guidance for feedback without a parked gate: keep polling, handle late fix or dismiss, and hold done until answered','github-worker-brief.md')
    require(github,'append `paused [at=<epoch>] [key=nm-<run>-ci-wait]','re-append that same keyed line after any later status event','resolved [at=<epoch>] [key=nm-<run>-ci-wait]','never report it as `blocked:` and never stop on it')
    custom=generate('holding-worker-brief',verb='holding')
    require(custom,'append `holding [at=<epoch>] [key=nm-<run>-ci-wait]')
    fallback=run(['bash','-uc','. bin/fm-dod-lib.sh; unset FM_CLASSIFY_PAUSED_VERB FM_CLASSIFY_PAUSED_VERB_DEFAULT; fm_dod_block no-mistakes fallback-worker'])
    require(fallback,'append `paused [at=<epoch>] [key=nm-<run>-ci-wait]','fm/fallback-worker')
    (EVIDENCE/'standalone-fallback.md').write_text(fallback)
    passed('Generate default and custom maintainer waits: preserve independent wait keys and safely default standalone library calls to paused','holding-worker-brief.md; standalone-fallback.md; github-worker-brief.md')
    forgejo=generate('forgejo-worker-brief',forge='forgejo')
    gate=forgejo.split('At the CI gate,',1)[1]
    require(gate,'/commits/<head.sha>/status','/pulls/<n>/reviews`','/pulls/<n>/reviews/<review-id>/comments','for each review','/issues/<n>/comments','reading every page of these API lists and commit statuses')
    assert 'gh-axi pr ' not in gate, 'Forgejo guidance leaked GitHub commands'
    assert '/pulls/<n>/comments' not in gate, 'Forgejo guidance named a nonexistent route'
    passed('Generate a Forgejo worker brief: use tea, per-review inline comments, and pagination without GitHub polling','forgejo-worker-brief.md')
    for mode in ['direct-PR','local-only']:
        other=generate(mode+'-worker-brief',mode=mode)
        assert 'At the CI gate,' not in other, 'CI-gate guidance leaked to another delivery mode'
    passed('Generate direct-PR and local-only briefs: CI-gate instructions stay confined to no-mistakes workers','direct-PR-worker-brief.md; local-only-worker-brief.md')
    selected={
      'fm-brief.test.sh': ('\ntest_worker_role_scope\n',[
        'test_forge_selection_renders_correct_cli',
        'test_no_mistakes_dod_green_detection',
        'test_no_mistakes_dod_ci_gate_feedback',
        'test_no_mistakes_dod_ci_wait_uses_configured_pause_verb',
        'test_pause_verb_override_renders_all_brief_scaffolds',
        'test_pr_based_dod_requires_non_draft']),
      'fm-contributions.test.sh': ('\nfailures=0\n',['test_arm_plumbs_a_configured_budget_into_the_check_shim'])
    }
    for source,(boundary,names) in selected.items():
        original=(ROOT/'tests'/source).read_text()
        assert boundary in original, 'Test selector boundary missing'
        target=ROOT/'tests'/('.gate-selected-'+source)
        selectors.append(target)
        target.write_text(original.split(boundary,1)[0]+'\n'+'\n'.join(names)+'\n')
        run(['bash',str(target.relative_to(ROOT))])
    (EVIDENCE/'scenario-results.json').write_text(json.dumps(results,indent=2)+'\n')
    print(json.dumps(results,indent=2))
finally:
    (EVIDENCE/'brief-cli-transcript.log').write_text('\n'.join(transcript))
    for path in selectors: path.unlink(missing_ok=True)
    shutil.rmtree(fixture)
