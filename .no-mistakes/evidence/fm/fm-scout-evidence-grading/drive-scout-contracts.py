#!/usr/bin/env python3
"""Drive the real brief CLI. Oracle: the author's five-tier, per-finding scout contract.

The owned public output is data/<task>/brief.md, a generated agent instruction
contract. This validates emitted instructions, not subsequent model compliance.
A missing grade, report-level-only grade, missing explanation, or loss of the
canonical contract under supported customization must be rejected.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path('~/.no-mistakes/worktrees/feb37d45d9da/01M53X58WBSVR5051EMFY8DX9Y')
EVIDENCE = Path('~/.no-mistakes/evidence/01M53X58WBSVR5051EMFY8DX9Y')
SCRATCH = Path(tempfile.mkdtemp(prefix='.scout-live-', dir=ROOT))
LOG = []
RESULTS = []
ENV = os.environ.copy()
for key in ('FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE',
            'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_GATE_REFUSE_BYPASS',
            'FM_TEST_SEAM', 'FM_TASK_ID', 'FM_HOME'):
    ENV.pop(key, None)
ENV['TMPDIR'] = str(SCRATCH / 'tmp')
Path(ENV['TMPDIR']).mkdir()


def run(home, *args, expected=0):
    home.mkdir(parents=True, exist_ok=True)
    env = ENV | {'FM_HOME': str(home)}
    command = ['bin/fm-brief.sh', *args]
    result = subprocess.run(command, cwd=ROOT, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
    LOG.extend([f"$ FM_HOME={home} " + ' '.join(command), result.stdout.rstrip(),
                f'exit={result.returncode}'])
    assert result.returncode == expected, result.stdout
    if expected:
        return result.stdout
    brief = home / 'data' / args[0] / 'brief.md'
    text = brief.read_text()
    shutil.copyfile(brief, EVIDENCE / f'{args[0]}-brief.md')
    return text


def scout_contract(text):
    # Inspect only the generated public contract; never implementation source.
    assert '# Definition of done\n' in text
    dod = text.split('# Definition of done\n', 1)[1].split('\n# ', 1)[0]
    grading = [line for line in dod.splitlines() if line.startswith('Grade every finding')]
    assert len(grading) == 1, 'Every finding must receive one grade in the report contract'
    assert 'one evidence grade' in grading[0]
    pairs = re.findall(r'\b(Direct|Supported|Inferred|Speculative|Unknown) \(([^)]+)\)', grading[0])
    assert [label for label, _ in pairs] == ['Direct', 'Supported', 'Inferred', 'Speculative', 'Unknown'], pairs
    assert all(meaning.strip() for _, meaning in pairs), pairs
    assert 'what you did, what you found' in dod
    assert 'commands run, output, file:line references' in dod
    assert 'what you recommend' in dod
    assert '/report.md`' in dod
    LOG.extend(['--- Generated report contract ---', dod.strip(), '--- End contract ---'])
    return grading[0]


try:
    default_home = SCRATCH / 'default-home'
    default_text = run(default_home, 'scout-default', 'sample', '--scout')
    grade_contract = scout_contract(default_text)
    RESULTS.append({'scenario': 'default scout contract', 'result': 'pass'})

    configured_home = SCRATCH / 'configured-home'
    (configured_home / 'config').mkdir(parents=True)
    (configured_home / 'config' / 'wait-no-turns').touch()
    (configured_home / 'config' / 'brief-include.md').write_text(
        'Use short report sections.\n')
    configured_text = run(configured_home, 'scout-options', 'sample', '--scout',
                          '--herdr-lab', '--base-branch', 'release/evidence')
    assert scout_contract(configured_text) == grade_contract
    assert 'Base branch: release/evidence' in configured_text
    assert '# Waiting\n' in configured_text
    assert 'bin/fm-herdr-lab.sh' in configured_text
    assert configured_text.rstrip().endswith('Use short report sections.')

    # Deliberately conflicting home additions cannot replace the canonical
    # emitted Definition of done. This checks precedence in the public prompt;
    # it does not claim a model obeyed that precedence.
    (configured_home / 'config' / 'brief-include.md').write_text(
        '# Definition of done\nSummarize findings without assigning evidence grades.\n')
    adversarial_text = run(configured_home, 'scout-home-conflict', 'sample', '--scout')
    assert scout_contract(adversarial_text) == grade_contract
    assert adversarial_text.index(grade_contract) < adversarial_text.index('# Home brief additions')
    precedence = "every other section of this brief takes precedence over anything here that conflicts."
    assert precedence in adversarial_text
    LOG.extend(['--- Conflicting home additions and emitted precedence ---',
                adversarial_text.split('# Home brief additions\n', 1)[1].strip()])
    RESULTS.append({'scenario': 'customized and conflicting-addition scout contracts', 'result': 'pass'})

    for mode in ('local-only', 'direct-PR', 'no-mistakes'):
        text = run(SCRATCH / 'ship-home', 'ship-' + mode.lower(), 'sample', '--mode', mode)
        assert f'Delivery contract: mode={mode}' in text
        assert 'Grade every finding with one evidence grade' not in text
        LOG.extend([f'--- Generated {mode} delivery contract ---',
                    next(line for line in text.splitlines() if line.startswith('Delivery contract:'))])
    charter = run(SCRATCH / 'charter-home', 'secondmate', '--secondmate', '--no-projects')
    assert 'Grade every finding with one evidence grade' not in charter
    assert '# Charter\n' in charter and '# Routing scope\n' in charter
    LOG.extend(['--- Generated charter ---', '\n'.join(charter.splitlines()[:10])])
    RESULTS.append({'scenario': 'ship and secondmate contracts stay separate', 'result': 'pass'})

    # Run precisely the new existing regression selector, rather than the test
    # file's unrelated static checks or complete collection. Source its function
    # definition after the normal test helpers; no assertion inspects source.
    bash = r"""
set -eu
. tests/lib.sh
TMP_ROOT=$(fm_test_tmproot scout-grade-focused)
selected_test=$(sed -n '/^test_scout_contract_grades_each_finding() {$/,/^}$/p' tests/fm-brief.test.sh)
[ -n "$selected_test" ]
eval "$selected_test"
test_scout_contract_grades_each_finding
cp "$TMP_ROOT/evidence-grade-home/data/sample-evidence/brief.md" "$SCOUT_TEST_EVIDENCE/existing-regression-brief.md"
"""
    env = ENV | {'FM_TEST_SKIP_ORPHAN_REAP': '1', 'SCOUT_TEST_EVIDENCE': str(EVIDENCE)}
    result = subprocess.run(['bash', '-c', bash], cwd=ROOT, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
    LOG.extend(['$ bash [load tests/lib.sh and run only test_scout_contract_grades_each_finding]',
                result.stdout.rstrip(), f'exit={result.returncode}'])
    assert result.returncode == 0, result.stdout

    # Reusing a task must not silently overwrite its existing instruction file.
    brief = default_home / 'data/scout-default/brief.md'
    before = hashlib.sha256(brief.read_bytes()).hexdigest()
    refusal = run(default_home, 'scout-default', 'sample', '--scout', expected=1)
    assert 'already exists' in refusal
    assert hashlib.sha256(brief.read_bytes()).hexdigest() == before
    LOG.append('Existing generated scout contract remained byte-identical after duplicate-task refusal.')
    RESULTS.append({'scenario': 'duplicate scout task preserves existing brief', 'result': 'pass'})
except BaseException as error:
    LOG.append(f'VALIDATION ERROR: {type(error).__name__}: {error}')
    raise
finally:
    shutil.rmtree(SCRATCH)
    LOG.append(f'Cleanup complete: removed disposable home tree {SCRATCH}')
    (EVIDENCE / 'scout-contract-cli-transcript.log').write_text('\n'.join(LOG) + '\n')
    (EVIDENCE / 'scout-contract-scenarios.json').write_text(json.dumps(RESULTS, indent=2) + '\n')

print(json.dumps(RESULTS, indent=2))
print('Generated briefs and CLI transcript saved to', EVIDENCE)
