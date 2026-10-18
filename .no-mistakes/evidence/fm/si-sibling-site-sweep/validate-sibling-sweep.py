#!/usr/bin/env python3
"""Exercise the public generated worker-prompt contract, not implementation source.
Oracle: the supplied author intent requires a repository-wide same-pattern sweep
for every selected fix, fix-or-explain in the same round, --instructions transport,
and additive task guidance. Reject omitted, truncated, or mode-leaked guidance.
This does not evaluate model compliance or start/control a no-mistakes run.
"""
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path('~/.no-mistakes/worktrees/feb37d45d9da/01M581D5JN1R6DWPGCP7EJ4TEH')
EVIDENCE = Path('~/.no-mistakes/evidence/01M581D5JN1R6DWPGCP7EJ4TEH')
BASE = 'e8d68752e4d393f74743f97d950ec4b0c79bb589'
SWEEP = ('Sibling-site sweep: search the repository for other occurrences of the pattern each selected finding fixes '
         '- the same call, idiom, copied block, or rule - and, in this same round, fix each occurrence or record why it differs.')
TASK_GUIDANCE = 'For token-parser fixes, preserve empty-token rejection and explain any intentionally different parser.'
REQUIRED_RULE = ('Every `--action fix` response passes `--instructions` carrying this fixed sweep text, '
                 'combined with any task-specific guidance you add, never replaced by it; '
                 'the guidance attaches to the findings the response selects with `--findings`: ')
records = []
transcript = []

def record(message):
    print(message, flush=True)
    transcript.append(message)

def environment(home):
    env = {k:v for k,v in os.environ.items() if not k.startswith('FM_')}
    env['FM_HOME'] = str(home)
    return env

def emit(code, home, label, args):
    (home / 'config').mkdir(parents=True)
    (home / 'data').mkdir()
    (home / 'config' / 'brief-include.md').write_text(TASK_GUIDANCE + '\n')
    if label.endswith('foreground'):
        (home / 'config' / 'wait-no-turns').touch()
    command = [str(code / 'bin/fm-brief.sh'), label, 'disposable-example', *args]
    result = subprocess.run(command, cwd=ROOT, env=environment(home), text=True, capture_output=True)
    record('$ FM_HOME=<disposable-home> ' + ' '.join(['bin/fm-brief.sh', label, 'disposable-example', *args]))
    record(result.stdout.rstrip())
    if result.stderr:
        record('stderr: ' + result.stderr.rstrip())
    assert result.returncode == 0, (label, result.returncode, result.stderr)
    output = (home / 'data' / label / 'brief.md').read_text()
    (EVIDENCE / (label + '.md')).write_text(output)
    return output

with tempfile.TemporaryDirectory(prefix='.sibling-sweep-live-', dir=ROOT) as scratch_name:
    scratch = Path(scratch_name)
    # Run the real baseline generator from a disposable export. No stubs.
    base_dir = scratch / 'baseline'
    base_dir.mkdir()
    archive = subprocess.run(['git', 'archive', BASE, 'bin'], cwd=ROOT, capture_output=True, check=True).stdout
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        source.extractall(base_dir, filter='data')
    before = emit(base_dir, scratch / 'before-home', 'baseline-no-mistakes', ['--mode', 'no-mistakes'])
    assert SWEEP not in before and REQUIRED_RULE not in before
    record('BASELINE REPRODUCED: the emitted no-mistakes brief lacks the required sibling-site sweep contract.')
    records.append({'name':'baseline-regression', 'result':'expected-absence', 'artifact':'baseline-no-mistakes.md'})

    for forge in ['none', 'gerrit', 'forgejo']:
        for drive in ['background', 'foreground']:
            label = 'no-mistakes-' + forge + '-' + drive
            text = emit(ROOT, scratch / label, label, ['--mode', 'no-mistakes', '--forge', forge])
            assert text.count(SWEEP) == 1, label + ': missing, changed, or duplicated fixed instruction'
            rule_lines = [line for line in text.splitlines() if line.startswith('- Every `--action fix`')]
            assert rule_lines == ['- ' + REQUIRED_RULE + '`' + SWEEP + '`'], label + ': incorrect fix response transport/composition contract'
            assert TASK_GUIDANCE in text, label + ': task guidance lost'
            assert 'every other section of this brief takes precedence over anything here that conflicts.' in text
            assert 'ask-user findings are never yours to answer' in text
            assert 'NEVER pass `--yes` (or `-y`)' in text
            record('EMITTED FIX RULE: ' + rule_lines[0])
            record('EMITTED TASK GUIDANCE: ' + TASK_GUIDANCE)
            record('PASS: fixed sweep emitted once; additive guidance and selected-findings scope retained; existing gate guards retained.')
            records.append({'name':label, 'result':'pass', 'artifact':label+'.md'})

    for forge in ['none', 'gerrit', 'forgejo']:
        label = 'direct-PR-' + forge
        text = emit(ROOT, scratch / label, label, ['--mode','direct-PR','--forge',forge])
        assert 'Sibling-site sweep:' not in text and REQUIRED_RULE not in text
        assert TASK_GUIDANCE in text
        record('PASS: direct-PR emitted its own contract without pipeline fix-round guidance.')
        records.append({'name':label, 'result':'pass', 'artifact':label+'.md'})
    for label, args in [('local-only',['--mode','local-only']), ('scout',['--scout'])]:
        text = emit(ROOT, scratch / label, label, args)
        assert 'Sibling-site sweep:' not in text and REQUIRED_RULE not in text
        assert TASK_GUIDANCE in text
        record('PASS: ' + label + ' did not inherit pipeline fix-round guidance.')
        records.append({'name':label,'result':'pass','artifact':label+'.md'})
record('CLEANUP: disposable source export, generated homes, and working-tree scratch directory removed.')
(EVIDENCE / 'sibling-sweep-results.json').write_text(json.dumps(records, indent=2)+'\n')
(EVIDENCE / 'sibling-sweep-transcript.log').write_text('\n'.join(transcript)+'\n')
