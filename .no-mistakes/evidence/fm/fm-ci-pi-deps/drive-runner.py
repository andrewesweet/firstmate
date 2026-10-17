import json, os, pathlib, shutil, subprocess

root = pathlib.Path.cwd()
evidence = pathlib.Path('~/.no-mistakes/evidence/01M53Q0RK2MPN19NNQ90V2JFV1')
repo = root / '.test-live-ci-pi/runner-world'
(repo / 'bin').mkdir(parents=True, exist_ok=True)
(repo / 'tests').mkdir(exist_ok=True)
shutil.copy2(root / 'bin/fm-test-run.sh', repo / 'bin/fm-test-run.sh')
shutil.copy2(root / 'tests/git-config-helpers.sh', repo / 'tests/git-config-helpers.sh')
env = dict(os.environ, TMPDIR=str(root / '.test-live-ci-pi/tmp'), FM_TEST_FAILURE_TAIL_LINES='100')
env.pop('FM_TASK_ID', None)
runner = repo / 'bin/fm-test-run.sh'
passing = 'tests/fm-brief.test.sh'
failing = 'tests/fm-composer-lib.test.sh'

def fixture(name, content):
    path = repo / name
    path.write_text('#!/usr/bin/env bash\n' + content)
    path.chmod(0o755)

fixture(passing, 'echo PASSING_OUTPUT_MUST_NOT_REPLAY\n')
fixture(failing, "for i in $(seq 1 50); do printf 'failure evidence line %02d of 50\\n' \"$i\"; done\nprintf 'stderr diagnostic preserved\\n' >&2\nexit 7\n")

def run(label, args):
    cmd = [str(runner), *args]
    cp = subprocess.run(cmd, cwd=repo, env=env, capture_output=True, text=True, timeout=30)
    (evidence / (label + '.log')).write_text('$ FM_TEST_FAILURE_TAIL_LINES=100 ' + ' '.join(cmd) + '\n' + cp.stdout + cp.stderr + f'\nprocess_exit={cp.returncode}\n')
    return cp

results = []
for jobs in (1, 2):
    label = f'runner-failure-jobs-{jobs}'
    cp = run(label, ['--jobs', str(jobs), passing, failing])
    assert cp.returncode == 1, cp
    summary = cp.stdout.split('FM_TEST_SUMMARY ', 1)[1]
    start = f'FM_TEST_FAILED script={failing} exit=7\n'
    end = f'FM_TEST_FAILURE_END script={failing}\n'
    assert summary.count(start) == 1 and summary.count(end) == 1, summary
    replay = summary.split(start, 1)[1].split(end, 1)[0].splitlines()
    # Independent oracle: final 30 of 51 emitted lines are numbered 22..50 plus stderr.
    assert replay == [f'failure evidence line {i:02d} of 50' for i in range(22, 51)] + ['stderr diagnostic preserved'], replay
    assert 'PASSING_OUTPUT_MUST_NOT_REPLAY' not in summary, summary
    results.append({'scenario': label, 'exit': cp.returncode, 'replayed_lines': len(replay), 'failure_exit': 7})

cp = run('runner-pass-only', ['--jobs', '1', passing])
assert cp.returncode == 0 and 'FM_TEST_FAILED ' not in cp.stdout, cp
results.append({'scenario': 'runner-pass-only', 'exit': cp.returncode, 'failure_section': False})
fixture(failing, 'exit 9\n')
cp = run('runner-silent-failure', ['--jobs', '1', failing])
assert cp.returncode == 1, cp
assert f'FM_TEST_FAILED script={failing} exit=9\n(no captured output)\nFM_TEST_FAILURE_END' in cp.stdout, cp
results.append({'scenario': 'runner-silent-failure', 'exit': cp.returncode, 'fallback': '(no captured output)'})
fixture(failing, 'echo TIMEOUT_DIAGNOSTIC >&2\nsleep 8\n')
cp = run('runner-timeout', ['--jobs', '1', '--per-script-timeout-secs', '1', failing])
assert cp.returncode == 1 and f'FM_TEST_FAILED script={failing} exit=124' in cp.stdout, cp
assert 'TIMEOUT_DIAGNOSTIC' in cp.stdout.split('FM_TEST_SUMMARY ', 1)[1], cp
results.append({'scenario': 'runner-timeout', 'exit': cp.returncode, 'failure_exit': 124})

# Replay same real interface with the base runner; old summary omits failure evidence.
base = subprocess.check_output(['git', 'show', '40bd5261bb2e904f6b661108efe2fac0b0ac7ee1:bin/fm-test-run.sh'], cwd=root)
runner.write_bytes(base)
fixture(failing, 'echo BASELINE_FAILURE_DIAGNOSTIC >&2\nexit 7\n')
cp = run('runner-base-regression', ['--jobs', '1', passing, failing])
assert cp.returncode == 1 and 'FM_TEST_FAILED ' not in cp.stdout, cp
assert 'BASELINE_FAILURE_DIAGNOSTIC' not in cp.stdout.split('FM_TEST_SUMMARY ', 1)[1], cp
results.append({'scenario': 'runner-base-regression', 'exit': cp.returncode, 'diagnostic_missing_after_summary': True})
shutil.copy2(root / 'bin/fm-test-run.sh', runner)
(evidence / 'runner-observations.json').write_text(json.dumps(results, indent=2) + '\n')
print(json.dumps(results, indent=2))
