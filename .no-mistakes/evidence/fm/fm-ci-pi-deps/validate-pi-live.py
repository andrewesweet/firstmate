#!/usr/bin/env python3
"""Disposable product checks; output contracts are the test oracle."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path('~/.no-mistakes/worktrees/feb37d45d9da/01M53Q0RK2MPN19NNQ90V2JFV1')
EVIDENCE = Path('~/.no-mistakes/evidence/01M53Q0RK2MPN19NNQ90V2JFV1')
STATE = EVIDENCE / 'live-check-state.json'
if STATE.exists():
    state = json.loads(STATE.read_text())
    scratch = Path(state['scratch'])
else:
    scratch = Path(tempfile.mkdtemp(prefix='.fm-ci-pi-live-', dir=ROOT))
    state = {'scratch': str(scratch), 'results': []}
    STATE.write_text(json.dumps(state, indent=2))

env = os.environ.copy()
for key in list(env):
    if key.startswith(('npm_config_', 'NPM_CONFIG_')) or key in (
        'FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE',
        'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_TASK_ID', 'TASKS_AXI_FILE',
        'TASKS_AXI_BACKEND', 'FM_PI_PACKAGE_DIR'):
        env.pop(key, None)
for name in ('tmp', 'npm-cache', 'global-prefix', 'pi-config', 'tmux'):
    (scratch / name).mkdir(exist_ok=True)
for name in ('npm-user.conf', 'npm-global.conf'):
    (scratch / name).touch()
env.update({
    'TMPDIR': str(scratch / 'tmp'),
    'TMUX_TMPDIR': str(scratch / 'tmux'),
    'PI_CODING_AGENT_DIR': str(scratch / 'pi-config'),
    'npm_config_userconfig': str(scratch / 'npm-user.conf'),
    'npm_config_globalconfig': str(scratch / 'npm-global.conf'),
    'npm_config_cache': str(scratch / 'npm-cache'),
    'npm_config_prefix': str(scratch / 'global-prefix'),
    'NO_COLOR': '1',
})

def run(label, args, *, cwd=ROOT, extra=None, expected=0, timeout=300):
    run_env = dict(env, **(extra or {}))
    log = EVIDENCE / (label + '.log')
    with log.open('w') as stream:
        stream.write('$ ' + subprocess.list2cmdline([str(x) for x in args]) + '\n')
        stream.flush()
        result = subprocess.run(args, cwd=cwd, env=run_env, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=timeout)
        stream.write(f'\nObserved exit status: {result.returncode}\n')
    print(f'{label}: exit={result.returncode}; evidence={log.name}', flush=True)
    if expected is not None:
        assert result.returncode == expected, log.read_text()[-5000:]
    return result.returncode, log.read_text()

def record(name, **details):
    state.update(json.loads(STATE.read_text()))
    state['results'].append({'name': name, 'result': 'pass', **details})
    STATE.write_text(json.dumps(state, indent=2))

def install():
    destination = scratch / 'pinned-pi'
    run('fresh-pi-install', ['bash', 'bin/fm-install-pi.sh', str(destination)])
    inspect = r'''
import {createRequire} from 'node:module';
import {pathToFileURL} from 'node:url';
const root = process.argv[1];
const require = createRequire(pathToFileURL(root + '/package.json'));
const names = ['pi-agent-core','pi-ai','pi-codemode','pi-coding-agent','pi-mcp','pi-telemetry','pi-tui'];
for (const name of names) {
  const pkg = require(root + '/node_modules/@earendil-works/' + name + '/package.json');
  if (pkg.version !== '1.2.0') throw Error(name + ' floated to ' + pkg.version);
  console.log('@earendil-works/' + name + '=' + pkg.version);
}
const runtime = await import(pathToFileURL(root + '/node_modules/@earendil-works/pi-coding-agent/dist/index.js'));
if (typeof runtime.createAgentSession !== 'function') throw Error('public SDK unavailable');
console.log('Pi public runtime imported; createAgentSession is callable');
'''
    run('fresh-pi-runtime', ['node', '--input-type=module', '-e', inspect, str(destination)])
    run('fresh-pi-cli', [str(destination / 'node_modules/.bin/pi'), '--version'])
    run('fresh-pi-dependencies', ['npm', 'ls', '--prefix', str(destination), '--all', '--json'])
    manifest = (destination / 'package-lock.json').read_bytes()
    installed = (destination / 'node_modules/.package-lock.json').read_bytes()
    (destination / 'node_modules/unwanted-package').mkdir()
    (destination / 'node_modules/unwanted-package/package.json').write_text('{"name":"unwanted-package","version":"9.9.9"}')
    run('repeat-pi-install', ['bash', 'bin/fm-install-pi.sh', str(destination)])
    assert manifest == (destination / 'package-lock.json').read_bytes()
    assert installed == (destination / 'node_modules/.package-lock.json').read_bytes()
    assert not (destination / 'node_modules/unwanted-package').exists()
    run('repeat-pi-runtime', ['node', '--input-type=module', '-e', inspect, str(destination)])
    record('Fresh and repeated locked install', dependency_lock_sha256=hashlib.sha256(installed).hexdigest())

def guards():
    run('global-install-regression', ['bash', 'tests/fm-install-pi.test.sh'])
    physical = scratch / 'guard-prefix'
    prefix_alias = scratch / 'guard-prefix-link'
    physical.mkdir(exist_ok=True)
    prefix_alias.symlink_to(physical, target_is_directory=True)
    global_root = physical / 'lib/node_modules'
    sentinel = global_root / 'pre-existing-package/package.json'
    sentinel.parent.mkdir(parents=True)
    sentinel.write_text('{"name":"pre-existing-package","version":"1.0.0"}\n')
    observations = []
    for prefix in (physical, prefix_alias):
        for destination in (global_root.parent, global_root):
            originals = {}
            for name in ('package.json', 'package-lock.json'):
                path = destination / name
                path.write_text('{"name":"pre-existing-manifest","version":"1.0.0"}\n')
                originals[path] = path.read_bytes()
            originals[sentinel] = sentinel.read_bytes()
            label = 'guard-' + ('symlink' if prefix == prefix_alias else 'physical') + '-' + ('parent' if destination == global_root.parent else 'root')
            rc, output = run(label, ['bash', 'bin/fm-install-pi.sh', str(destination)],
                             extra={'npm_config_prefix': str(prefix)}, expected=None)
            assert rc != 0 and 'refusing to install into the global npm root' in output
            for path, before in originals.items():
                assert path.read_bytes() == before, f'global package or manifest changed: {path}'
            observations.append({'prefix': str(prefix), 'destination': str(destination), 'exit': rc,
                                 'preexisting_package_unchanged': True, 'both_manifests_unchanged': True})
    (EVIDENCE / 'global-protection-observations.json').write_text(json.dumps(observations, indent=2))
    record('Global root and parent refusal through physical and symlinked npm prefixes')

def runner():
    fixture = scratch / 'runner-repo'
    (fixture / 'bin').mkdir(parents=True, exist_ok=True)
    (fixture / 'tests').mkdir(exist_ok=True)
    shutil.copy2(ROOT / 'bin/fm-test-run.sh', fixture / 'bin/fm-test-run.sh')
    shutil.copy2(ROOT / 'tests/git-config-helpers.sh', fixture / 'tests/git-config-helpers.sh')
    bodies = {
        'fm-brief.test.sh': "echo 'passing fixture unique output'\nexit 0\n",
        'fm-composer-lib.test.sh': "for n in $(seq 1 50); do printf 'failure evidence line %02d of 50\\n' \"$n\"; done\nprintf 'distinctive stderr failure\\n' >&2\nexit 7\n",
        'fm-ask-user-authority.test.sh': 'exit 9\n',
        'fm-documentation-audiences.test.sh': "echo 'short failure details'\nexit 3\n",
    }
    for name, body in bodies.items():
        path = fixture / 'tests' / name
        path.write_text('#!/usr/bin/env bash\n' + body)
        path.chmod(0o755)
    for jobs in (1, 2):
        timing = EVIDENCE / f'failure-jobs-{jobs}.json'
        args = ['bash', str(fixture / 'bin/fm-test-run.sh'), '--jobs', str(jobs), '--json', str(timing)]
        args.extend('tests/' + name for name in bodies)
        rc, output = run(f'failure-jobs-{jobs}', args, cwd=fixture,
                         extra={'FM_TEST_FAILURE_TAIL_LINES': '100'}, expected=None)
        assert rc == 1
        assert 'FM_TEST_SUMMARY total=4 failed=3' in output
        section = output[output.index('FM_TEST_SUMMARY '):]
        blocks = re.findall(r'^FM_TEST_FAILED script=(\S+) exit=(\d+)\n(.*?)^FM_TEST_FAILURE_END script=\1$',
                            section, re.M | re.S)
        assert len(blocks) == 3, blocks
        by_name = {Path(name).name: (int(code), body.rstrip('\n').splitlines()) for name, code, body in blocks}
        code, tail = by_name['fm-composer-lib.test.sh']
        assert code == 7 and len(tail) == 30
        assert tail[0] == 'failure evidence line 22 of 50'
        assert tail[-1] == 'distinctive stderr failure'
        assert by_name['fm-ask-user-authority.test.sh'] == (9, ['(no captured output)'])
        assert by_name['fm-documentation-audiences.test.sh'] == (3, ['short failure details'])
        assert 'passing fixture unique output' not in section
        doc = json.loads(timing.read_text())
        assert doc['summary']['failed'] == 3 and doc['summary']['total'] == 4
        assert {Path(row['path']).name: row['exit'] for row in doc['scripts']} == {
            'fm-brief.test.sh': 0, 'fm-composer-lib.test.sh': 7,
            'fm-ask-user-authority.test.sh': 9, 'fm-documentation-audiences.test.sh': 3}
        record(f'Failure logs with jobs={jobs}: attribution, fixed 30-line mixed-output tail, short and silent failures')
    for name in bodies:
        (fixture / 'tests' / name).write_text('#!/usr/bin/env bash\necho "passing output"\nexit 0\n')
    for jobs in (1, 2):
        args = ['bash', str(fixture / 'bin/fm-test-run.sh'), '--jobs', str(jobs)]
        args.extend('tests/' + name for name in bodies)
        _, output = run(f'passing-jobs-{jobs}', args, cwd=fixture)
        assert 'FM_TEST_SUMMARY total=4 failed=0' in output
        assert 'FM_TEST_FAILED ' not in output and 'FM_TEST_FAILURE_END ' not in output
    record('All-passing serial and parallel runs emit no failure section')

def mapping():
    # Isolate changed-file discovery from this run's untracked dependency tree.
    fixture = scratch / 'selection-repo'
    (fixture / 'bin').mkdir(parents=True, exist_ok=True)
    (fixture / 'tests').mkdir(exist_ok=True)
    (fixture / 'etc/ci-pi').mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / 'bin/fm-test-run.sh', fixture / 'bin/fm-test-run.sh')
    shutil.copy2(ROOT / 'tests/git-config-helpers.sh', fixture / 'tests/git-config-helpers.sh')
    for path in (ROOT / 'tests').glob('*.test.sh'):
        (fixture / 'tests' / path.name).write_text('#!/usr/bin/env bash\nexit 0\n')
    for path in ('bin/fm-install-pi.sh', 'etc/ci-pi/package.json', 'etc/ci-pi/package-lock.json'):
        shutil.copy2(ROOT / path, fixture / path)
    clean_git = {'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_CONFIG_SYSTEM': os.devnull,
                 'GIT_CONFIG_COUNT': '0'}
    run('mapping-fixture-init', ['git', 'init', '-q'], cwd=fixture, extra=clean_git)
    run('mapping-fixture-stage', ['git', 'add', '.'], cwd=fixture, extra=clean_git)
    run('mapping-fixture-baseline', ['git', '-c', 'user.name=Live Test', '-c',
        'user.email=test@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'baseline'],
        cwd=fixture, extra=clean_git)
    required = {'tests/fm-install-pi.test.sh', 'tests/fm-calm-pi-extension.test.sh',
                'tests/fm-pi-branch-extension.test.sh', 'tests/fm-pi-primary-types.test.sh',
                'tests/fm-harness-adapter-instructions-live-e2e.test.sh'}
    for index, path in enumerate(('bin/fm-install-pi.sh', 'etc/ci-pi/package.json', 'etc/ci-pi/package-lock.json')):
        target = fixture / path
        before = target.read_bytes()
        target.write_bytes(before + b'\n')
        _, output = run(f'changed-pi-input-{index}', ['bash', 'bin/fm-test-run.sh', '--list', '--changed',
                        '--base', 'HEAD'], cwd=fixture, extra=clean_git)
        assert required.issubset(set(output.splitlines()))
        assert 'tests/fm-brief.test.sh' not in output
        target.write_bytes(before)
    record('Changing installer, manifest, or lock selects Pi consumers and safety regression')

def consumers():
    destination = scratch / 'pinned-pi'
    selected = ['tests/fm-calm-pi-extension.test.sh', 'tests/fm-pi-branch-extension.test.sh']
    extra = {'PATH': str(destination / 'node_modules/.bin') + os.pathsep + env['PATH'],
             'FM_PI_PACKAGE_DIR': str(destination / 'node_modules/@earendil-works/pi-coding-agent')}
    run('pi-consumers-serial', ['bash', 'bin/fm-test-run.sh', '--jobs', '1', '--json',
                              str(EVIDENCE / 'pi-consumers-timing.json'), *selected], extra=extra, timeout=600)
    record('Affected Pi runtime extension consumers pass through real serial runner')

def calm():
    # Linux AF_UNIX paths stop at 108 bytes; the required worktree path is
    # already 87 bytes. Translate only tmux's socket selector to a relative
    # worktree path, then execute the unchanged real tmux binary.
    wrapper_dir = scratch / 'socket-tools'
    wrapper_dir.mkdir(exist_ok=True)
    wrapper = wrapper_dir / 'tmux'
    real_tmux = shutil.which('tmux')
    relative_socket_dir = str((scratch / 'tmux').relative_to(ROOT))
    wrapper.write_text('#!/usr/bin/env python3\nimport os, sys\n'
        'args = sys.argv[1:]\n'
        'if "-L" in args:\n'
        '    index = args.index("-L")\n'
        f'    socket = {relative_socket_dir!r} + "/" + args[index+1] + ".sock"\n'
        '    args[index:index+2] = ["-S", socket]\n'
        f'    os.chdir({str(ROOT)!r})\n'
        f'os.execv({real_tmux!r}, ["tmux", *args])\n')
    wrapper.chmod(0o755)
    destination = scratch / 'pinned-pi'
    extra = {'PATH': str(wrapper_dir) + os.pathsep + str(destination / 'node_modules/.bin') + os.pathsep + env['PATH'],
             'FM_PI_PACKAGE_DIR': str(destination / 'node_modules/@earendil-works/pi-coding-agent')}
    real_chrome = shutil.which('google-chrome')
    if real_chrome:
        chrome_wrapper = wrapper_dir / 'chrome'
        chrome_wrapper.write_text('#!/usr/bin/env python3\nimport os, sys\n'
            f'os.chdir({str(ROOT)!r})\n'
            f'os.environ["TMPDIR"] = {str((scratch / "tmp").relative_to(ROOT))!r}\n'
            f'os.execv({real_chrome!r}, ["google-chrome", *sys.argv[1:]])\n')
        chrome_wrapper.chmod(0o755)
        extra['FM_CHROME_BIN'] = str(chrome_wrapper)
    run('pi-calm-consumer-workspace-sockets', ['bash', 'bin/fm-test-run.sh', '--jobs', '1', '--json',
        str(EVIDENCE / 'pi-calm-final-timing.json'), 'tests/fm-calm-pi-extension.test.sh'], extra=extra, timeout=600)
    record('Calm runtime consumer passes with worktree-local relative tmux sockets')

if __name__ == '__main__':
    try:
        {'install': install, 'guards': guards, 'runner': runner, 'mapping': mapping, 'consumers': consumers,
         'calm': calm,
         'cleanup': lambda: shutil.rmtree(scratch)}[sys.argv[1]]()
    except Exception as exc:
        state['failure'] = repr(exc)
        STATE.write_text(json.dumps(state, indent=2))
        raise
