"""Execute real brief scaffolding; inspect its intentional generated prompt contract.
Oracle: author-supplied intent, including same-round sweep and additive guidance.
Rejects: omitted/truncated sweep, forge or wait-mode drift, replacement guidance,
or leaking pipeline instructions into delivery modes without pipeline fix rounds.
No model interpretation or gate responses are simulated.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path('~/.no-mistakes/worktrees/feb37d45d9da/01M57NE6801MN1TQQ2G3XTE3P0')
EVIDENCE = Path('~/.no-mistakes/evidence/01M57NE6801MN1TQQ2G3XTE3P0')
BASE = 'e8d68752e4d393f74743f97d950ec4b0c79bb589'
SWEEP = ('Sibling-site sweep: search the repository for other occurrences of the pattern each selected '
         'finding fixes - the same call, idiom, copied block, or rule - and, in this same round, '
         'fix each occurrence or record why it differs.')
CUSTOM = 'For this task, preserve retry limits while fixing selected findings.\n'
records = []

def check_contract(text):
    dod = text.split('# Definition of done\n', 1)[1].split('\n# Home brief additions', 1)[0]
    assert dod.count(SWEEP) == 1, 'Must emit one complete fixed sweep in definition of done'
    rule = next(line for line in dod.splitlines() if SWEEP in line)
    for required in ('Every `--action fix` response', '`--instructions`',
                     'combined with any task-specific guidance you add, never replaced by it',
                     'findings the response selects with `--findings`'):
        assert required in rule, f'Missing contract clause: {required}'
    return rule

with tempfile.TemporaryDirectory(prefix='.sibling-sweep-live-', dir=ROOT) as tmp:
    home = Path(tmp) / 'home'
    (home / 'data').mkdir(parents=True)
    (home / 'config').mkdir()
    env = {k: v for k, v in os.environ.items()
           if not k.startswith('FM_') and k not in ('CONFIG', 'DATA', 'STATE')}
    env['FM_HOME'] = str(home)
    env['TMPDIR'] = tmp

    def scaffold(task, args):
        command = ['bin/fm-brief.sh', task, 'disposable-project', *args]
        run = subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True)
        assert run.returncode == 0, f'{command}: {run.stderr}'
        output = (home / 'data' / task / 'brief.md').read_text()
        (EVIDENCE / f'{task}.md').write_text(output)
        return output, run.stdout.strip(), command

    rules = []
    for wait in ('background', 'foreground'):
        flag = home / 'config' / 'wait-no-turns'
        if wait == 'foreground':
            flag.touch()
        for forge in ('none', 'gerrit', 'forgejo'):
            task = f'sweep-{forge}-{wait}'
            text, stdout, command = scaffold(task, ['--mode', 'no-mistakes', '--forge', forge])
            rule = check_contract(text)
            rules.append(rule)
            records.append(dict(scenario='no-mistakes prompt across forges and wait modes',
                                command=command, result='pass', output=stdout, emitted_rule=rule))
    assert len(set(rules)) == 1, 'Every no-mistakes ship must carry identical wording'

    (home / 'config' / 'brief-include.md').write_text(CUSTOM)
    text, stdout, command = scaffold('sweep-custom-guidance', ['--mode', 'no-mistakes'])
    check_contract(text)
    assert text.split('# Home brief additions\n', 1)[1].endswith(CUSTOM)
    records.append(dict(scenario='task guidance is additive to fixed sweep', command=command,
                        result='pass', output=stdout, emitted_additions=CUSTOM,
                        emitted_rule=check_contract(text)))
    (home / 'config' / 'brief-include.md').unlink()

    for mode, forge in [('direct-PR', 'none'), ('direct-PR', 'gerrit'),
                        ('direct-PR', 'forgejo'), ('local-only', 'none')]:
        task = f'sweep-boundary-{mode}-{forge}'
        text, stdout, command = scaffold(task, ['--mode', mode, '--forge', forge])
        assert 'Sibling-site sweep:' not in text
        records.append(dict(scenario='faster modes omit pipeline-only sweep', command=command,
                            result='pass', output=stdout,
                            delivery=next(l for l in text.splitlines() if l.startswith('Delivery contract:'))))

    # Execute the previous public renderer to establish the regression oracle.
    # The saved source is executed, never searched or asserted on as test evidence.
    previous = Path(tmp) / 'baseline-dod.sh'
    previous.write_bytes(subprocess.check_output(['git', 'show', f'{BASE}:bin/fm-dod-lib.sh'], cwd=ROOT))
    run = subprocess.run(['bash', '-c', '. "$1"; fm_dod_block no-mistakes baseline fm/baseline none',
                          'baseline', str(previous)], cwd=ROOT, env=env, text=True, capture_output=True)
    assert run.returncode == 0, run.stderr
    (EVIDENCE / 'baseline-generated-dod.md').write_text(run.stdout)
    try:
        check_contract(run.stdout)
    except AssertionError as error:
        records.append(dict(scenario='regression: previous generated contract lacks fixed sweep',
                            result='expected failure', reason=str(error)))
    else:
        raise AssertionError('Regression check did not reject the previous output')

(EVIDENCE / 'live-validation-transcript.json').write_text(json.dumps(records, indent=2) + '\n')
print(json.dumps({'result': 'pass', 'generated_briefs': 11,
                  'fixed_instruction': rules[0],
                  'custom_guidance': CUSTOM.strip(),
                  'regression': 'Previous executable renderer rejected; current CLI prompts accepted.',
                  'scope': 'Generated agent instruction contract; no gate or model behavior simulated.',
                  'cleanup': 'Disposable worktree-local home and baseline removed.'}, indent=2))
