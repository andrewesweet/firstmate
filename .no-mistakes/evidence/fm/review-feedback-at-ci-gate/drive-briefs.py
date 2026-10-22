"""Exercise the generated worker brief contract through the real public CLI.
Oracle: supplied author intent and recorded narrow fix decisions, not source text.
Wrong behaviors rejected: missing feedback reads/routing, early done, lost pause
vocabulary, hardcoded GitHub reads in Forgejo, or CI rules leaking to other modes.
"""
import json
import os
from pathlib import Path
import subprocess

root = Path.cwd()
evidence = Path('~/.no-mistakes/evidence/01M5J29E59AGB87CCA3JKPNAA3')
scratch = root / '.phase-live-validation'
env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_'))}
env['TMPDIR'] = str(scratch / 'tmp')
results = []
transcript = []

def require(text, phrases):
    for phrase in phrases:
        assert phrase in text, f'Missing generated contract: {phrase}'

def scaffold(name, mode='no-mistakes', forge=None, pause=None):
    home = scratch / name
    (home / 'data').mkdir(parents=True, exist_ok=True)
    local = env | {'FM_HOME': str(home)}
    if pause is not None:
        local['FM_CLASSIFY_PAUSED_VERB'] = pause
    command = ['bin/fm-brief.sh', name, 'disposable-project', '--mode', mode]
    if forge:
        command += ['--forge', forge]
    proc = subprocess.run(command, env=local, text=True, capture_output=True, timeout=30)
    transcript.extend(['$ FM_HOME=<worktree-disposable-home> '+ ' '.join(command), proc.stdout, proc.stderr, 'exit='+str(proc.returncode)])
    assert proc.returncode == 0, proc.stderr
    brief = (home / 'data' / name / 'brief.md').read_text()
    (evidence / (name+'.md')).write_text(brief)
    return brief

github = scaffold('github-ci-feedback')
require(github, [
    'poll about once a minute with one poll per command',
    "never put a single wait longer than your harness's command bound",
    '`gh-axi pr checks <n>`', '`gh-axi pr view <n> --comments --reviews`',
    'review submissions, inline review comments, and issue comments',
    'A failing review-bot check, a review-bot finding, or a maintainer comment asking for a change',
    'never a non-required check to dismiss',
    'feed each item to it with `no-mistakes axi respond --action fix`',
    'adding any finding the gate does not list yet',
])
results.append('PASS: GitHub brief requires bounded checks plus all feedback reads and routes parked-gate feedback as fix work.')
require(github, [
    '[key=pr-<n>-<comment-id>]', "for this decision only in place of rule 6's stop, keep polling",
    'processing and acknowledging your Firstmate instruction inbox on each poll',
    'on dismiss, reply on the PR; on fix, feed it to the next parked gate or CI-ready decision point',
    'when the run reaches CI green or its final outcome first', '`branch_sync.next_action`',
    'when it names one (an already synchronized branch needs none)',
    'so every pipeline fix commit remains present',
    'drive a new `no-mistakes` run with the same `--intent` to its outcome before `done:`',
    "Before appending `done:`, re-read the PR's reviews and comments",
    'never append `done:` while a `pr-<n>-<comment-id>` decision you opened is still unanswered',
])
assert github.index('Before appending `done:`, re-read') < github.index('Then append `done [at=<epoch>]: PR')
results.append('PASS: No parked gate, late answers after green, synchronized branches, and final feedback reread are covered before done.')
require(github, [
    'append `paused [at=<epoch>] [key=nm-<run>-ci-wait]',
    're-append that same keyed line after any later status event',
    'resolved [at=<epoch>] [key=nm-<run>-ci-wait]',
    'never report it as `blocked:` and never stop on it',
])
custom = scaffold('custom-pause-ci-feedback', pause='holding')
wait = next(line for line in custom.splitlines() if line.startswith('A wait only a maintainer can clear'))
require(wait, ['append `holding [at=<epoch>] [key=nm-<run>-ci-wait]'])
assert 'append `paused ' not in wait
results.append('PASS: Maintainer-only waits use separate pause/resolution keys and honor the holding override.')
forgejo = scaffold('forgejo-ci-feedback', forge='forgejo')
poll = next(line for line in forgejo.splitlines() if line.startswith('Every poll reads'))
require(poll, ['/pulls/<n>`', '/commits/<head.sha>/status`', '/pulls/<n>/reviews`',
    '/pulls/<n>/reviews/<review-id>/comments` for each review', '/issues/<n>/comments`',
    'reading every page of these API lists and commit statuses'])
assert 'gh-axi' not in poll
results.append('PASS: Forgejo brief uses tea reads, per-review inline comments, and pagination rather than GitHub polling.')
for mode in ('direct-PR', 'local-only'):
    brief = scaffold('boundary-'+mode.lower(), mode=mode)
    assert 'At the CI gate, poll about once a minute' not in brief
    assert '[key=pr-<n>-<comment-id>]' not in brief
results.append('PASS: CI feedback guidance stays scoped to no-mistakes delivery.')
for label, pause in [('unset', None), ('empty', ''), ('custom', 'holding')]:
    local = env | {'FM_HOME': str(scratch / 'library-home')}
    if pause is not None:
        local['FM_CLASSIFY_PAUSED_VERB'] = pause
    command = ['bash', '-uc', '. bin/fm-dod-lib.sh; fm_dod_block no-mistakes fallback-task']
    proc = subprocess.run(command, env=local, text=True, capture_output=True, timeout=30)
    assert proc.returncode == 0, proc.stderr
    expected = pause or 'paused'
    require(proc.stdout, [f'append `{expected} [at=<epoch>] [key=nm-<run>-ci-wait]'])
    (evidence / ('library-fallback-'+label+'.md')).write_text(proc.stdout)
    transcript.extend([f'$ FM_CLASSIFY_PAUSED_VERB={label} bash -uc \'. bin/fm-dod-lib.sh; fm_dod_block no-mistakes fallback-task\'', f'exit={proc.returncode}; emitted CI wait verb={expected}'])
results.append('PASS: Existing fm_dod_block calling convention works outside fm-brief with unset, empty, and custom pause verbs.')
(evidence / 'public-cli-transcript.log').write_text('\n'.join(transcript)+'\n\n'+'\n'.join(results)+'\n')
(evidence / 'scenario-checks.json').write_text(json.dumps(results, indent=2)+'\n')
print('\n'.join(results))
