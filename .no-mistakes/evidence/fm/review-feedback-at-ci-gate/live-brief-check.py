"""Drive the public brief generator; oracle: supplied user intent and recorded decisions.
These assertions verify the emitted worker instruction contract, not model compliance.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path.cwd()
EVIDENCE = Path('~/.no-mistakes/evidence/01M53BPY6P9T8GV7XEW114R9Z0')
FIXTURE = ROOT / '.no-mistakes/test-ci-feedback/live'
FIXTURE.mkdir(parents=True, exist_ok=True)
ENV = os.environ.copy()
for key in ['FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_CLASSIFY_PAUSED_VERB', 'FM_CLASSIFY_PAUSED_VERB_DEFAULT', 'GIT_DIR', 'GIT_COMMON_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE']:
    ENV.pop(key, None)
ENV.update(TMPDIR=str(FIXTURE), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
transcript = []
results = []

def command(args, env=None, expected=0):
    run = subprocess.run(args, cwd=ROOT, env=env or ENV, text=True, capture_output=True, timeout=40)
    transcript.append('$ ' + ' '.join(args) + '\n' + run.stdout + run.stderr + f'[exit {run.returncode}]\n')
    assert run.returncode == expected, transcript[-1]
    return run.stdout

def generate(name, *args, pause=None):
    home = FIXTURE / name
    (home / 'data').mkdir(parents=True)
    (home / 'config').mkdir()
    (home / 'state').mkdir()
    env = dict(ENV, FM_HOME=str(home))
    if pause is not None:
        env['FM_CLASSIFY_PAUSED_VERB'] = pause
    command(['bash', 'bin/fm-brief.sh', name, 'isolated-project', *args], env)
    brief = home / 'data' / name / 'brief.md'
    shutil.copyfile(brief, EVIDENCE / f'{name}-brief.md')
    return brief.read_text(), home, env

def contains(text, *clauses):
    for clause in clauses:
        assert clause in text, f'Missing emitted contract: {clause}'

def passed(name, evidence):
    results.append(dict(name=name, result='pass', live=True, evidence=evidence, reason=''))

github, home, env = generate('github', '--mode', 'no-mistakes')
contains(github, 'poll about once a minute with one poll per command',
    "never put a single wait longer than your harness's command bound into one command",
    '`gh-axi pr checks <n>`', '`gh-axi pr view <n> --comments --reviews`',
    'review submissions, inline review comments, and issue comments',
    'A failing review-bot check, a review-bot finding, or a maintainer comment asking for a change',
    'never a non-required check to dismiss', '`no-mistakes axi respond --action fix`',
    'adding any finding the gate does not list yet')
passed('Generate a GitHub no-mistakes brief: each bounded CI poll reads checks and all review feedback, routing changes through a parked gate', 'github-brief.md')
contains(github, '[key=pr-<n>-<comment-id>]', "for this decision only in place of rule 6's stop",
    'processing and acknowledging your Firstmate instruction inbox on each poll as that section describes',
    'on dismiss, reply on the PR', 'next parked gate or CI-ready decision point',
    '`branch_sync.next_action`', 'when it names one (an already synchronized branch needs none)',
    'every pipeline fix commit remains present', 'same `--intent` to its outcome before `done:`',
    "Before appending `done:`, re-read the PR's reviews and comments",
    'never append `done:` while a `pr-<n>-<comment-id>` decision you opened is still unanswered')
passed('Generate a gateless-feedback contract: keyed escalation keeps polling and reading the inbox, handles post-outcome fixes, and prevents premature done', 'github-brief.md')
contains(github, '`paused [at=<epoch>] [key=nm-<run>-ci-wait]',
    're-append that same keyed line after any later status event of your own',
    '`resolved [at=<epoch>] [key=nm-<run>-ci-wait]', 'never report it as `blocked:` and never stop on it')
custom, _, _ = generate('custom-pause', '--mode', 'no-mistakes', pause='holding')
contains(custom, '`holding [at=<epoch>] [key=nm-<run>-ci-wait]')
for name, args, override, expected in [
    ('standalone-default', ['no-mistakes', 'standalone'], None, 'paused'),
    ('standalone-six-args', ['no-mistakes', 'standalone', 'custom/branch', 'none', 'release', 'example.test/o/r'], 'holding', 'holding'),
]:
    standalone_env = ENV.copy()
    if override:
        standalone_env['FM_CLASSIFY_PAUSED_VERB'] = override
    output = command(['bash', '-uc', '. bin/fm-dod-lib.sh; fm_dod_block "$@"', '_', *args], standalone_env)
    contains(output, f'`{expected} [at=<epoch>] [key=nm-<run>-ci-wait]')
    (EVIDENCE / f'{name}.md').write_text(output)
passed('Generate default, overridden, and standalone CI waits: use the configured pause verb, a distinct wait key, and explicit self-resolution', 'custom-pause-brief.md; standalone-default.md; standalone-six-args.md; github-brief.md')
forgejo, _, _ = generate('forgejo', '--mode', 'no-mistakes', '--forge', 'forgejo')
contains(forgejo, 'tea api --repo <owner>/<repo> /repos/{owner}/{repo}/commits/<head.sha>/status',
    '/pulls/<n>/reviews`', '/pulls/<n>/reviews/<review-id>/comments`', '/issues/<n>/comments`',
    'for each review', 'reading every page of these API lists and commit statuses')
assert 'gh-axi' not in forgejo
passed('Generate a Forgejo no-mistakes brief: use tea for statuses, every review, inline comments, and issue comments with pagination', 'forgejo-brief.md')
for name, arguments in [('direct', ['--mode', 'direct-PR']), ('local', ['--mode', 'local-only']), ('scout', ['--scout'])]:
    output, _, _ = generate(name, *arguments)
    assert 'At the CI gate, poll' not in output
    assert 'key=nm-<run>-ci-wait' not in output
    assert 'key=pr-<n>-<comment-id>' not in output
passed('Generate direct-PR, local-only, and scout briefs: CI-gate instructions remain confined to no-mistakes ships', 'direct-brief.md; local-brief.md; scout-brief.md')

# Read-only help confirms the GitHub wrapper flags named by the public brief.
help_output = command(['gh-axi', 'pr', 'view', '--help'])
contains(help_output, '--comments', '--reviews')
(EVIDENCE / 'gh-axi-pr-view-help.txt').write_text(help_output)
(EVIDENCE / 'live-brief-transcript.txt').write_text('\n'.join(transcript))
(EVIDENCE / 'live-brief-results.json').write_text(json.dumps(results, indent=2) + '\n')
print(json.dumps(results, indent=2))
