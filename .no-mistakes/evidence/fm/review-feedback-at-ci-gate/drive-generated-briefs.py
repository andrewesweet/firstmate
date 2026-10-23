"""Drive the public brief CLI; oracle: supplied CI-feedback intent and accepted decisions.
Generated Markdown is the product's delivered instruction contract. No agent or
pipeline execution is claimed by this check.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path.cwd()
evidence = Path('~/.no-mistakes/evidence/01M5J29E59AGB87CCA3JKPNAA3')
lab = Path(tempfile.mkdtemp(prefix='brief-live-', dir=root/'.no-mistakes/phase-test-tmp'))
env = os.environ.copy()
for key in ('FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE',
            'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_CLASSIFY_PAUSED_VERB',
            'FM_CLASSIFY_PAUSED_VERB_DEFAULT', 'FM_HOME', 'FM_GATE_REFUSE_BYPASS'):
    env.pop(key, None)
env['FM_HOME'] = str(lab)
env['TMPDIR'] = str(lab)
results = []
transcript = []

def run(args, extra=None):
    active = env | (extra or {})
    transcript.append('$ ' + ' '.join(args))
    done = subprocess.run(args, env=active, text=True, capture_output=True, cwd=root, timeout=30)
    transcript.append(done.stdout + done.stderr)
    if done.returncode:
        raise AssertionError(f'{args}: exit {done.returncode}: {done.stderr}')
    return done.stdout

def generate(name, *args, extra=None):
    run(['bin/fm-brief.sh', name, 'sample-project', *args], extra)
    text = (lab/'data'/name/'brief.md').read_text()
    (evidence/f'{name}.md').write_text(text)
    return text

def require(text, *clauses):
    for clause in clauses:
        assert clause in text, f'Missing delivered instruction: {clause}'

def record(name, artifact):
    results.append({'name': name, 'result': 'pass', 'artifact': artifact})

try:
    github = generate('github-ci', '--mode', 'no-mistakes')
    require(github, 'poll about once a minute with one poll per command',
            "never put a single wait longer than your harness's command bound into one command",
            '`gh-axi pr checks <n>`', '`gh-axi pr view <n> --comments --reviews`',
            'review submissions, inline review comments, and issue comments')
    record('Generate GitHub CI instructions with bounded polling and all feedback reads', 'github-ci.md')
    require(github, 'A failing review-bot check, a review-bot finding, or a maintainer comment asking for a change',
            'never a non-required check to dismiss', 'shows a parked gate',
            '`no-mistakes axi respond --action fix`', 'adding any finding the gate does not list yet',
            'let the fix round commit and push')
    record('Generate fix routing for failed bot checks and requested changes at a parked gate', 'github-ci.md')
    require(github, 'shows no parked gate', '[key=pr-<n>-<comment-id>]',
            'keep polling about once a minute and wait for firstmate',
            'processing and acknowledging your Firstmate instruction inbox on each poll',
            'on dismiss, reply on the PR', 'next parked gate or CI-ready decision point',
            'when the run reaches CI green or its final outcome first', '`branch_sync.next_action`',
            'when it names one (an already synchronized branch needs none)',
            'every pipeline fix commit remains present', 'same `--intent`',
            're-read the PR\'s reviews and comments and route any unactioned feedback',
            'decision you opened is still unanswered')
    record('Generate the no-gate and green-before-reply paths without allowing premature done', 'github-ci.md')
    require(github, 'fork-workflow approval', 'rerun of a flaky job', 'external wait under rule 4, not a blocker',
            '`paused [at=<epoch>] [key=nm-<run>-ci-wait]',
            're-append that same keyed line after any later status event',
            '`resolved [at=<epoch>] [key=nm-<run>-ci-wait]', 'never report it as `blocked:` and never stop on it')
    holding = generate('holding-ci', '--mode', 'no-mistakes', extra={'FM_CLASSIFY_PAUSED_VERB': 'holding'})
    wait_line = next(line for line in holding.splitlines() if line.startswith('A wait only a maintainer can clear'))
    require(wait_line, '`holding [at=<epoch>] [key=nm-<run>-ci-wait]')
    assert '`paused [at=<epoch>]' not in wait_line
    standalone = run(['bash', '-uc', '. "$1"; fm_dod_block no-mistakes standalone', '_', 'bin/fm-dod-lib.sh'])
    (evidence/'standalone-dod.md').write_text(standalone)
    require(standalone, '`paused [at=<epoch>] [key=nm-<run>-ci-wait]')
    record('Generate keyed maintainer waits with default/custom verbs and standalone fallback', 'holding-ci.md; standalone-dod.md')
    forgejo = generate('forgejo-ci', '--mode', 'no-mistakes', '--forge', 'forgejo')
    ci_line = next(line for line in forgejo.splitlines() if line.startswith('Every poll reads'))
    for endpoint in ('/pulls/<n>`', '/commits/<head.sha>/status`', '/pulls/<n>/reviews`',
                     '/pulls/<n>/reviews/<review-id>/comments`', '/issues/<n>/comments`'):
        require(ci_line, 'tea api --repo <owner>/<repo> /repos/{owner}/{repo}' + endpoint)
    require(ci_line, 'for each review', 'reading every page of these API lists and commit statuses')
    assert 'gh-axi pr checks' not in forgejo
    assert 'gh-axi pr view' not in forgejo
    assert '/pulls/<n>/comments' not in ci_line
    record('Generate Forgejo polling with paginated per-review comments and no GitHub reads', 'forgejo-ci.md')
    for name, mode in [('direct-pr', 'direct-PR'), ('local-only', 'local-only')]:
        brief = generate(name, '--mode', mode)
        assert 'At the CI gate, poll' not in brief
        assert 'Delivery contract: mode=' + mode in brief
    record('Generate direct-PR and local-only briefs without no-mistakes CI instructions', 'direct-pr.md; local-only.md')
finally:
    shutil.rmtree(lab)
    (evidence/'brief-cli-transcript.log').write_text('\n'.join(transcript))
    (evidence/'brief-live-results.json').write_text(json.dumps(results, indent=2)+'\n')
print(json.dumps(results, indent=2))
