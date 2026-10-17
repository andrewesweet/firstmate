import os, pathlib, shutil, subprocess
root = pathlib.Path.cwd()
repo = root / '.pi-ci-validation/changed-world-2'
evidence = pathlib.Path('~/.no-mistakes/evidence/01M53Q0RK2MPN19NNQ90V2JFV1/round3')
(repo / 'bin').mkdir(parents=True)
(repo / 'tests').mkdir()
(repo / 'etc/ci-pi').mkdir(parents=True)
shutil.copy2(root / 'bin/fm-test-run.sh', repo / 'bin/fm-test-run.sh')
consumers = ['fm-install-pi.test.sh', 'fm-calm-pi-extension.test.sh', 'fm-pi-branch-extension.test.sh', 'fm-pi-primary-types.test.sh', 'fm-harness-adapter-instructions-live-e2e.test.sh']
for name in consumers + ['fm-brief.test.sh']:
    (repo / 'tests' / name).write_text('#!/usr/bin/env bash\nexit 0\n')
inputs = ['bin/fm-install-pi.sh', 'etc/ci-pi/package.json', 'etc/ci-pi/package-lock.json']
for path in inputs:
    shutil.copy2(root / path, repo / path)
env = dict(os.environ, GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', TMPDIR=str(root / '.pi-ci-validation/tmp'))
env.pop('FM_TASK_ID', None)
for args in [['init', '-q'], ['add', '.'], ['-c', 'user.name=test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'isolated-selection-baseline']]:
    subprocess.run(['git', *args], cwd=repo, env=env, check=True)
with (evidence / 'changed-pi-consumers.log').open('w') as log:
    for path in inputs:
        source = repo / path
        original = source.read_bytes()
        source.write_bytes(original + b'\n')
        cp = subprocess.run(['bin/fm-test-run.sh', '--list', '--changed', '--base', 'HEAD'], cwd=repo, env=env, capture_output=True, text=True)
        log.write(f'Changed only: {path}\n$ bin/fm-test-run.sh --list --changed --base HEAD\n{cp.stdout}{cp.stderr}process_exit={cp.returncode}\n\n')
        assert cp.returncode == 0, cp
        selected = cp.stdout.splitlines()
        assert all('tests/' + name in selected for name in consumers), selected
        assert 'tests/fm-brief.test.sh' not in selected, selected
        source.write_bytes(original)
print((evidence / 'changed-pi-consumers.log').read_text())
