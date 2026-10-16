"""Drive fm-brief's generated worker-prompt interface using disposable homes.

Oracle: authoritative user intent requires each finding, rather than only the
report as a whole, to have one of Direct/Supported/Inferred/Speculative/Unknown.
Reject missing tiers, report-only grading, or a conflicting lower-priority home
addition replacing the scout's definition of done. This checks prompt delivery,
not model interpretation or compliance in a subsequent report.
"""
from pathlib import Path
import json
import os
import re
import shutil
import subprocess
import tempfile

ROOT = Path('~/.no-mistakes/worktrees/feb37d45d9da/01M53EDY8NJGBMCPFMXQN281EB')
EVIDENCE = Path('~/.no-mistakes/evidence/01M53EDY8NJGBMCPFMXQN281EB')
BASE = '40bd5261bb2e904f6b661108efe2fac0b0ac7ee1'
GRADES = ['Direct', 'Supported', 'Inferred', 'Speculative', 'Unknown']
scratch = Path(tempfile.mkdtemp(prefix='.scout-evidence-live-', dir=ROOT))
baseline_script = ROOT / 'bin' / f'.fm-brief-baseline-{os.getpid()}.sh'
transcript = []
results = []
env = dict(os.environ)
for key in ('FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_STATE_OVERRIDE',
            'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_GATE_REFUSE_BYPASS'):
    env.pop(key, None)
env['GIT_CONFIG_GLOBAL'] = '/dev/null'
env['GIT_CONFIG_NOSYSTEM'] = '1'
env['FM_ROOT_OVERRIDE'] = str(ROOT)
env['TMPDIR'] = str(scratch / 'tmp')
(scratch / 'tmp').mkdir()

def drive(home, script, task, *flags):
    (home / 'data').mkdir(parents=True, exist_ok=True)
    command = ['bash', str(script.relative_to(ROOT)), task, 'sample', *flags]
    run_env = dict(env, FM_HOME=str(home))
    proc = subprocess.run(command, cwd=ROOT, env=run_env, text=True,
                          capture_output=True, timeout=60)
    transcript.extend([f'$ FM_HOME={home} ' + ' '.join(command),
                       proc.stdout.rstrip(), proc.stderr.rstrip(), f'exit={proc.returncode}'])
    assert proc.returncode == 0, proc.stderr or proc.stdout
    brief = home / 'data' / task / 'brief.md'
    return brief.read_text()

def check_scout_prompt(text, home, task):
    # This is real generated public output, not implementation source.
    done = text.split('# Definition of done\n', 1)[1]
    done = done.split('\n# Home brief additions', 1)[0]
    lines = [line for line in done.splitlines() if line.startswith('Grade every finding ')]
    assert len(lines) == 1, 'Each finding needs exactly one explicit grading requirement'
    clause = lines[0]
    assert clause.startswith('Grade every finding with one evidence grade:'), clause
    definitions = re.findall(r'([A-Z][a-z]+) \(([^()]+)\)', clause)
    assert [grade for grade, meaning in definitions] == GRADES, definitions
    assert all(meaning.strip() for grade, meaning in definitions), definitions
    assert str(home / 'data' / task / 'report.md') in done, 'Report path lost'
    assert 'commands run, output, file:line references' in done, 'Existing evidence contract lost'
    transcript.extend(['Generated scout definition of done:', done.rstrip(),
                       'Observed grade definitions: ' + json.dumps(definitions)])
    return dict(definitions)

try:
    # Run the base command in the original bin directory so it resolves the real
    # helper commands normally; its source is only setup, never assertion data.
    baseline_script.write_bytes(subprocess.check_output(
        ['git', 'show', f'{BASE}:bin/fm-brief.sh'], cwd=ROOT))
    base_text = drive(scratch / 'base-home', baseline_script, 'baseline-scout', '--scout')
    assert not any(line.startswith('Grade every finding ') for line in base_text.splitlines())
    (EVIDENCE / 'baseline-scout-brief.md').write_text(base_text)
    transcript.append('Baseline reproduced: generated scout prompt has no per-finding evidence-grade instruction.')

    default_home = scratch / 'default-home'
    default_text = drive(default_home, ROOT / 'bin/fm-brief.sh', 'default-scout', '--scout')
    definitions = check_scout_prompt(default_text, default_home, 'default-scout')
    (EVIDENCE / 'default-scout-brief.md').write_text(default_text)
    results.append({'scenario': 'Default scout gets a per-finding five-tier evidence contract',
                    'result': 'pass', 'live': True, 'definitions': definitions})

    custom_home = scratch / 'custom-home'
    (custom_home / 'config').mkdir(parents=True)
    (custom_home / 'config/brief-include.md').write_text(
        'For this home, write all findings as ungraded prose.\n')
    (custom_home / 'config/wait-no-turns').touch()
    custom_text = drive(custom_home, ROOT / 'bin/fm-brief.sh', 'custom-scout', '--scout',
                        '--base-branch', 'integration/evidence', '--herdr-lab')
    check_scout_prompt(custom_text, custom_home, 'custom-scout')
    assert 'Base branch: integration/evidence' in custom_text
    assert 'fm-herdr-lab.sh' in custom_text
    include = custom_text.split('# Home brief additions\n', 1)[1]
    assert 'every other section of this brief takes precedence over anything here that conflicts.' in include
    assert 'write all findings as ungraded prose.' in include
    assert 'Grade every finding' not in include
    transcript.extend(['Conflicting home additions stay explicitly subordinate:', include.rstrip()])
    (EVIDENCE / 'custom-scout-brief.md').write_text(custom_text)
    results.append({'scenario': 'Customized scout retains grading with conflicting subordinate home instructions',
                    'result': 'pass', 'live': True})

    ship_text = drive(scratch / 'ship-home', ROOT / 'bin/fm-brief.sh', 'local-ship',
                      '--mode', 'local-only')
    assert 'Delivery contract: mode=local-only' in ship_text
    assert not any(line.startswith('Grade every finding ') for line in ship_text.splitlines())
    (EVIDENCE / 'local-ship-brief.md').write_text(ship_text)
    transcript.append('Ship scope check: local-only delivery contract present; scout evidence-grading requirement absent.')
    results.append({'scenario': 'Ship scaffold keeps its delivery contract without scout-report grading',
                    'result': 'pass', 'live': True})
finally:
    baseline_script.unlink(missing_ok=True)
    shutil.rmtree(scratch)
    (EVIDENCE / 'scout-evidence-live-transcript.txt').write_text('\n'.join(transcript) + '\n')
    (EVIDENCE / 'scout-evidence-live-results.json').write_text(json.dumps(results, indent=2) + '\n')
    print('\n'.join(transcript))
    print(json.dumps(results, indent=2))
