"""Drive real public brief generators; oracle: branch's required CI guidance contract.

Checks emitted worker instructions, not source or model interpretation. A checks-only
brief, omitted routing path, wrong forge CLI, or ignored pause override must fail.
"""
from pathlib import Path
import os
import shutil
import subprocess

root = Path.cwd()
evidence = Path('~/.no-mistakes/evidence/01M5NDG7A89JX5FJNB7V36WM66')
fixtures = root / '.test-phase-tmp' / 'live-briefs'
fixtures.mkdir(parents=True, exist_ok=True)
base_env = {k: v for k, v in os.environ.items() if not k.startswith('FM_')}
base_env['TMPDIR'] = str(root / '.test-phase-tmp')
transcript = []

def run(args, env, label):
    result = subprocess.run(args, cwd=root, env=env, text=True, capture_output=True, timeout=30)
    transcript.append(f'$ {" ".join(args)}\nFM_HOME={env["FM_HOME"]}\nexit={result.returncode}\n{result.stdout}{result.stderr}')
    assert result.returncode == 0, transcript[-1]
    return result.stdout

def require(text, phrases):
    for phrase in phrases:
        assert phrase in text, f'Missing required emitted contract: {phrase}'

try:
    generated = {}
    for label, mode, forge, verb in [
        ('github', 'no-mistakes', None, None),
        ('forgejo', 'no-mistakes', 'forgejo', None),
        ('custom-pause', 'no-mistakes', None, 'holding'),
        ('direct-pr', 'direct-PR', None, None),
        ('local-only', 'local-only', None, None),
    ]:
        home = fixtures / label
        (home / 'data').mkdir(parents=True)
        env = dict(base_env, FM_HOME=str(home))
        if verb:
            env['FM_CLASSIFY_PAUSED_VERB'] = verb
        args = ['bin/fm-brief.sh', f'live-{label}', 'disposable-project', '--mode', mode]
        if forge:
            args += ['--forge', forge]
        run(args, env, label)
        brief = home / 'data' / f'live-{label}' / 'brief.md'
        generated[label] = brief.read_text()
        shutil.copyfile(brief, evidence / f'{label}-brief.md')

    github = generated['github']
    require(github, [
        'poll about once a minute with one poll per command',
        "never put a single wait longer than your harness's command bound into one command",
        '`gh-axi pr checks <n>`', '`gh-axi pr view <n> --comments --reviews`',
        'review submissions, inline review comments, and issue comments',
        'A failing review-bot check, a review-bot finding, or a maintainer comment asking for a change',
        'never a non-required check to dismiss',
        '`no-mistakes axi respond --action fix`',
        'adding any finding the gate does not list yet',
    ])
    transcript.append('PASS GitHub brief: bounded polling, all feedback channels, parked-gate fix routing.\n')
    require(github, [
        'needs-decision [at=<epoch>] [key=pr-<n>-<comment-id>]',
        'keep polling about once a minute and wait for firstmate',
        'processing and acknowledging your Firstmate instruction inbox on each poll',
        'on dismiss, reply on the PR; on fix, feed it to the next parked gate or CI-ready decision point',
        'when the run reaches CI green or its final outcome first',
        '`branch_sync.next_action`',
        'when it names one (an already synchronized branch needs none)',
        'so every pipeline fix commit remains present',
        'drive a new `no-mistakes` run with the same `--intent`',
        're-read the PR\'s reviews and comments and route any unactioned feedback',
        'never append `done:` while a `pr-<n>-<comment-id>` decision you opened is still unanswered',
    ])
    transcript.append('PASS Adversarial no-parked-gate/early-green brief: escalation, replies, conditional sync, follow-up run, done guard.\n')
    require(github, [
        'fork-workflow approval', 'rerun of a flaky job',
        'paused [at=<epoch>] [key=nm-<run>-ci-wait]',
        're-append that same keyed line after any later status event',
        'resolved [at=<epoch>] [key=nm-<run>-ci-wait]',
        'never report it as `blocked:` and never stop on it',
    ])
    require(generated['custom-pause'], ['holding [at=<epoch>] [key=nm-<run>-ci-wait]'])
    transcript.append('PASS Maintainer waits: independent keyed pause/resolution, configured holding verb, no blocker.\n')
    forgejo = generated['forgejo']
    require(forgejo, [
        'tea api --repo <owner>/<repo> /repos/{owner}/{repo}/pulls/<n>',
        '/commits/<head.sha>/status', '/pulls/<n>/reviews`',
        '/pulls/<n>/reviews/<review-id>/comments', 'for each review',
        '/issues/<n>/comments', 'reading every page of these API lists and commit statuses',
    ])
    assert 'gh-axi pr checks' not in forgejo
    assert 'gh-axi pr view' not in forgejo
    transcript.append('PASS Forgejo brief: tea checks, per-review inline comments, all feedback/status pages; no GitHub read commands.\n')
    for label in ['direct-pr', 'local-only']:
        assert 'At the CI gate, poll about once a minute' not in generated[label]
    for label, verb in [('standalone-default', None), ('standalone-override', 'holding')]:
        home = fixtures / label
        home.mkdir()
        env = dict(base_env, FM_HOME=str(home))
        if verb:
            env['FM_CLASSIFY_PAUSED_VERB'] = verb
        text = run(['bash', '-eu', '-c', '. bin/fm-dod-lib.sh; fm_dod_block no-mistakes live-standalone'], env, label)
        (evidence / f'{label}-dod.md').write_text(text)
        require(text, [f'{verb or "paused"} [at=<epoch>] [key=nm-<run>-ci-wait]'])
    transcript.append('PASS Existing library signature: two-argument caller gets fallback/default or configured pause; other delivery modes stay scoped.\n')
finally:
    (evidence / 'live-brief-transcript.log').write_text('\n'.join(transcript))
    shutil.rmtree(fixtures)
print('\n'.join(line for line in transcript if line.startswith('PASS')))
