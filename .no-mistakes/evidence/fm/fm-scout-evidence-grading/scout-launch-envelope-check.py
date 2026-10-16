"""Exercise real role rendering and operational launch-prompt consumers.

The independent oracle is the author's five named grades for each finding.
The observable contract is the generated worker prompt, not agent behavior.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path('~/.no-mistakes/worktrees/feb37d45d9da/01M53EDY8NJGBMCPFMXQN281EB')
EVIDENCE = Path('~/.no-mistakes/evidence/01M53EDY8NJGBMCPFMXQN281EB')
home = Path(tempfile.mkdtemp(prefix='.scout-envelope-live-', dir=ROOT))
env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(ROOT),
           GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', TMPDIR=str(home))
for key in ('FM_DATA_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE',
            'FM_PROJECTS_OVERRIDE', 'FM_GATE_REFUSE_BYPASS'):
    env.pop(key, None)
transcript = []

def run(args, body=None):
    proc = subprocess.run(args, cwd=ROOT, env=env, input=body, text=True,
                          capture_output=True, timeout=60)
    transcript.extend(['$ ' + ' '.join(args), f'exit={proc.returncode}'])
    assert proc.returncode == 0, proc.stderr or proc.stdout
    return proc.stdout

try:
    (home / 'data').mkdir()
    scaffold = run(['bash', 'bin/fm-brief.sh', 'envelope-scout', 'sample', '--scout'])
    transcript.append(scaffold.rstrip())
    brief = (home / 'data/envelope-scout/brief.md').read_text()
    brief = brief.replace('{TASK}', 'Inspect the disposable sample and report findings.').replace(
        '{FIRSTMATE_SPEC}', 'Use only the disposable sample; make no external changes.')
    role = run(['bash', '-c', '. "$1"; fm_brief_worker_role "$2" "$3" "$4"', '_',
                str(ROOT / 'bin/fm-dod-lib.sh'), str(home / 'state'), 'envelope-scout', str(ROOT)])
    prompt = (role + '\n' + brief).rstrip('\n')
    protocol = ['bash', 'bin/fm-operational-input.sh']
    encoded = run(protocol + ['encode', 'launch-brief'], prompt)
    kind = run(protocol + ['kind'], encoded).strip()
    decoded = run(protocol + ['body'], encoded)
    assert kind == 'launch-brief'
    assert decoded == prompt, 'Inline launch envelope altered the generated prompt'
    doorbell = run(protocol + ['record', 'launch-brief'], prompt).rstrip('\n')
    assert run(protocol + ['doorbell-kind'], doorbell).strip() == 'launch-brief'
    records = list((home / 'state/operational-inbox').glob('*.msg'))
    assert len(records) == 1, records
    opened = run(protocol + ['open', str(records[0])])
    assert opened == prompt, 'Record-backed launch input altered the generated prompt'
    grade_line = next(line for line in opened.splitlines() if line.startswith('Grade every finding '))
    for grade in ('Direct', 'Supported', 'Inferred', 'Speculative', 'Unknown'):
        assert grade + ' (' in grade_line, grade
    transcript.extend(['Inline envelope kind: ' + kind,
                       'Record-backed envelope kind: launch-brief',
                       'Opened worker prompt includes:', grade_line,
                       'Both real protocol consumers returned the complete generated prompt unchanged.'])
    (EVIDENCE / 'scout-launch-brief.md').write_text(prompt + '\n')
    (EVIDENCE / 'scout-launch-envelope.txt').write_text(encoded)
    (EVIDENCE / 'scout-launch-record.msg').write_bytes(records[0].read_bytes())
finally:
    shutil.rmtree(home)
    (EVIDENCE / 'scout-launch-envelope-transcript.txt').write_text('\n'.join(transcript) + '\n')
    print('\n'.join(transcript))
