import json
import os
from pathlib import Path
import re
import subprocess

root = Path.cwd()
scratch = root / '.test-ci-feedback'
evidence = Path('~/.no-mistakes/evidence/01M5WT1TP1D85GPYCYJBW4XTNM')
env = os.environ.copy()
for name in ('FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_CLASSIFY_PAUSED_VERB', 'FM_CLASSIFY_PAUSED_VERB_DEFAULT'):
    env.pop(name, None)
env['TMPDIR'] = str(scratch / 'tmp')
outputs = {}
commands = []

def run(args, scenario_env=None):
    result = subprocess.run(args, cwd=root, env=scenario_env or env, text=True, capture_output=True)
    commands.append({'command': args, 'exit_code': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr})
    assert result.returncode == 0, result.stderr
    return result.stdout

def scaffold(name, mode='no-mistakes', forge=None, verb=None):
    home = scratch / name
    (home / 'data').mkdir(parents=True)
    case_env = env | {'FM_HOME': str(home)}
    if verb:
        case_env['FM_CLASSIFY_PAUSED_VERB'] = verb
    args = ['bin/fm-brief.sh', name, 'disposable-project', '--mode', mode]
    if forge:
        args += ['--forge', forge]
    run(args, case_env)
    text = (home / 'data' / name / 'brief.md').read_text()
    outputs[name] = text
    (evidence / f'{name}.md').write_text(text)
    return text

# Oracle: authoritative user intent and accepted follow-up decisions, applied
# to the generated worker-facing text contract, not implementation source.
github = scaffold('github-ci-feedback')
required = [
    'poll about once a minute with one poll per command',
    "never put a single wait longer than your harness's command bound",
    '`gh-axi pr checks <n>`', '`gh-axi pr view <n> --comments --reviews`',
    'A failing review-bot check, a review-bot finding, or a maintainer comment asking for a change',
    '`no-mistakes axi respond --action fix`',
    'never a non-required check to dismiss',
    '[key=pr-<n>-<comment-id>]',
    'processing and acknowledging your Firstmate instruction inbox on each poll',
    'on dismiss, reply on the PR',
    'next parked gate or CI-ready decision point',
    '`branch_sync.next_action`',
    'when it names one (an already synchronized branch needs none)',
    'so every pipeline fix commit remains present',
    'same `--intent` to its outcome before `done:`',
    "Before appending `done:`, re-read the PR's reviews and comments",
    'never append `done:` while a `pr-<n>-<comment-id>` decision you opened is still unanswered',
    'never report it as `blocked:` and never stop on it',
]
for phrase in required:
    assert phrase in github, phrase

forgejo = scaffold('forgejo-ci-feedback', forge='forgejo')
for route in ('/pulls/<n>/reviews`', '/pulls/<n>/reviews/<review-id>/comments`', '/issues/<n>/comments`', '/commits/<head.sha>/status`'):
    assert route in forgejo, route
assert 'reading every page of these API lists and commit statuses' in forgejo
assert '/pulls/<n>/comments' not in forgejo
assert 'gh-axi pr' not in forgejo

custom = scaffold('holding-ci-feedback', verb='holding')
assert 'append `holding [at=<epoch>] [key=nm-<run>-ci-wait]' in custom

# Public callable renderer used by promotion: no fm-brief.sh globals or
# classifier default are present. Preserve its existing one-argument contract.
standalone_env = env | {'FM_HOME': str(scratch / 'standalone')}
(scratch / 'standalone').mkdir()
standalone = run(['bash', '-c', '. bin/fm-dod-lib.sh; fm_dod_block no-mistakes standalone'], standalone_env)
assert 'append `paused [at=<epoch>] [key=nm-<run>-ci-wait]' in standalone
(evidence / 'standalone-dod.md').write_text(standalone)

for name, mode, forge in [('direct-pr-boundary', 'direct-PR', None), ('local-only-boundary', 'local-only', None), ('gerrit-boundary', 'no-mistakes', 'gerrit')]:
    text = scaffold(name, mode=mode, forge=forge)
    assert 'At the CI gate, poll about once a minute' not in text
    assert f'Delivery contract: mode={mode}' in text
    if mode == 'local-only':
        assert 'no push, no PR' in text or 'Do NOT push' in text
    if forge == 'gerrit':
        assert '--skip push,pr,ci' in text

# Drive the actual classifier with the emitted status template. A regression
# that shares a key, ignores the configured pause verb, or closes a review
# decision when only the external wait clears must be rejected.
status_template = re.search(r'append `(holding \[at=<epoch>\] \[key=nm-<run>-ci-wait\]: <what must happen>)`', custom).group(1)
wait = status_template.replace('<epoch>', '100').replace('<run>', 'lab').replace('<what must happen>', 'maintainer approves fork workflow')
status_path = scratch / 'holding-ci-feedback' / 'state' / 'key-isolation.status'
status_path.parent.mkdir(exist_ok=True)
status_path.write_text(wait + '\nneeds-decision [at=101] [key=pr-42-9]: review feedback: disposable comment asks for a change\n' + wait.replace('100', '102') + '\n')
classifier_script = '''
. bin/fm-classify-lib.sh
status_is_paused "$1" || exit 21
printf 'declared wait: '; status_declared_wait_line "$2"
printf 'open decisions before clearing wait:\n'; status_open_decisions "$2"
printf '%s\n' 'resolved [at=103] [key=nm-lab-ci-wait]: maintainer approved fork workflow' >> "$2"
printf 'declared wait after clearing: '; status_declared_wait_line "$2"
printf '\nopen decisions after clearing wait:\n'; status_open_decisions "$2"
'''
classified = run(['bash', '-c', classifier_script, '_', wait, str(status_path)], env | {'FM_CLASSIFY_PAUSED_VERB': 'holding'})
after = classified.split('open decisions after clearing wait:\n', 1)[1]
assert 'pr-42-9' in after
assert 'nm-lab-ci-wait' not in after
assert 'declared wait after clearing: \n' in classified
(evidence / 'keyed-wait-classification.log').write_text(classified)

# Rendered text is itself the changed product interface. This does not claim
# that an LLM enacted the instructions or that a live pipeline was driven.
report = ['# Generated CI-feedback instructions: live CLI evidence', '',
          'Oracle: the supplied user intent and accepted follow-up decisions. The real fm-brief.sh command generated every brief in an isolated home. Assertions inspect the generated public instruction contract. No model interpretation or pipeline actions were exercised.', '',
          'Plausible regressions rejected: checks-only polling; omitted inline feedback; premature done; lost pipeline fixes after green; incorrect Forgejo routes; default-only pause verb; CI-wait resolution closing a separate review decision; CI guidance leaking into local-only delivery.', '']
for name, text in outputs.items():
    report += [f'## {name}', '', 'CLI invocation: `' + ' '.join(next(c['command'] for c in commands if len(c['command']) > 1 and c['command'][1] == name)) + '`', '']
    if name in ('github-ci-feedback', 'forgejo-ci-feedback', 'holding-ci-feedback'):
        first = text.index('At the CI gate,')
        last = text.index('After /no-mistakes reports CI green', first)
        report += [text[first:last], '']
    else:
        first = text.index('# Definition of done')
        report += [text[first:first+1300], '']
report += ['## Real status-classifier output', '', '```text', classified.rstrip(), '```', '']
(evidence / 'live-cli-evidence.md').write_text('\n'.join(report))
(evidence / 'live-cli-commands.json').write_text(json.dumps(commands, indent=2))
print(classified)
print('Generated public contract and delivery-boundary assertions passed.')
