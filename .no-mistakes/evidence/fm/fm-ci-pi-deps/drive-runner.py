"""Exercise the actual runner CLI against disposable executable test inputs.
Oracle: accepted fixed 30-line replay, failing-script attribution, and nonzero
exit status. Fifty numbered output rows plus one stderr row must retain rows
22 through 50 and the error; older rows and passing output must be absent.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess

root = Path.cwd()
evidence = Path('~/.no-mistakes/evidence/01M53Q0RK2MPN19NNQ90V2JFV1')
fixture = root / '.pi-ci-validation' / 'runner-fixture'
(fixture / 'bin').mkdir(parents=True)
(fixture / 'tests').mkdir()
runner = fixture / 'bin/fm-test-run.sh'
shutil.copy2(root / 'bin/fm-test-run.sh', runner)
shutil.copy2(root / 'tests/git-config-helpers.sh', fixture / 'tests/git-config-helpers.sh')
scripts = {
    'fm-brief.test.sh': '#!/bin/bash\necho PASS_ONLY_SENTINEL\n',
    'fm-composer-lib.test.sh': '#!/bin/bash\nfor n in {1..50}; do printf "failure evidence %02d\\n" "$n"; done\necho FAILURE_STDERR_SENTINEL >&2\nexit 7\n',
    'fm-ask-user-authority.test.sh': '#!/bin/bash\nexit 9\n',
}
for name, body in scripts.items():
    path = fixture / 'tests' / name
    path.write_text(body)
    path.chmod(0o755)
environment = dict(os.environ, TMPDIR=str(root / '.pi-ci-validation/tmp'), FM_TEST_FAILURE_TAIL_LINES='100')
environment.pop('FM_TASK_ID', None)
results = []
for jobs in (1, 2):
    command = [str(runner), '--jobs', str(jobs), *('tests/' + name for name in scripts)]
    proc = subprocess.run(command, cwd=fixture, env=environment, capture_output=True, text=True, timeout=60)
    (evidence / f'runner-failures-jobs-{jobs}.log').write_text(proc.stdout + proc.stderr)
    assert proc.returncode == 1, (jobs, proc.returncode, proc.stderr)
    summary = proc.stdout[proc.stdout.index('FM_TEST_SUMMARY '):]
    assert 'total=3 failed=2 skipped_gate=0' in summary, summary
    marker = 'FM_TEST_FAILED script=tests/fm-composer-lib.test.sh exit=7\n'
    closing = 'FM_TEST_FAILURE_END script=tests/fm-composer-lib.test.sh'
    actual = summary.split(marker, 1)[1].split(closing, 1)[0].splitlines()
    expected = [f'failure evidence {n:02d}' for n in range(22, 51)] + ['FAILURE_STDERR_SENTINEL']
    assert actual == expected, (jobs, actual)
    assert 'FM_TEST_FAILED script=tests/fm-ask-user-authority.test.sh exit=9\n(no captured output)\nFM_TEST_FAILURE_END script=tests/fm-ask-user-authority.test.sh' in summary
    assert 'PASS_ONLY_SENTINEL' not in summary
    assert summary.count('FM_TEST_FAILED ') == 2
    results.append({'jobs': jobs, 'exit': proc.returncode, 'verbose_tail_lines': len(actual), 'first_replayed_row': actual[0], 'last_replayed_row': actual[-1], 'silent_failure': 'exit=9, (no captured output)', 'passing_output_replayed': False})

# A subsequent successful run must not retain old failure records.
proc = subprocess.run([str(runner), '--jobs', '1', 'tests/fm-brief.test.sh'], cwd=fixture, env=environment, capture_output=True, text=True, timeout=60)
(evidence / 'runner-success.log').write_text(proc.stdout + proc.stderr)
assert proc.returncode == 0 and 'FM_TEST_FAILED ' not in proc.stdout

# Counterfactual: the original executable does not replay failure evidence.
runner.write_bytes(subprocess.check_output(['git', 'show', '7e22f2adc8e15f7548288980e5cf7f4d3129821a:bin/fm-test-run.sh'], cwd=root))
proc = subprocess.run([str(runner), '--jobs', '1', 'tests/fm-composer-lib.test.sh'], cwd=fixture, env=environment, capture_output=True, text=True, timeout=60)
(evidence / 'runner-baseline-failure.log').write_text(proc.stdout + proc.stderr)
assert proc.returncode == 1
baseline_summary = proc.stdout[proc.stdout.index('FM_TEST_SUMMARY '):]
assert 'FM_TEST_FAILED ' not in baseline_summary and 'FAILURE_STDERR_SENTINEL' not in baseline_summary
report = {'oracle': 'Accepted fixed 30-line failure replay, stderr capture, attribution, and nonzero failure propagation', 'current': results, 'subsequent_success_has_no_failure_section': True, 'base_commit_omits_failure_replay': True}
(evidence / 'runner-behavior.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
