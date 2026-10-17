#!/usr/bin/env python3
"""Drive real Firstmate CLI commands with isolated homes and real git repositories."""
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path.cwd()
EVIDENCE = Path('/home/cti/.no-mistakes/evidence/01M55HFG02TXH18QVHM4DFTY70')
PARENT = 'github.com/kunchenguid/firstmate'
FORK = 'github.com/fork-owner/firstmate'
OTHER = 'github.com/mirror-owner/firstmate'
BASE = 'c4aa0a8c45caddc9f79d328073e5440f3cbb3538'
ENV = {key: value for key, value in os.environ.items()
       if not (key.startswith('FM_') or key.startswith('GIT_CONFIG_')
               or key in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR'))}
ENV.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_COUNT='0',
           TMPDIR=str(ROOT / '.test-role-tmp'))
log = (EVIDENCE / 'role-cli-transcript.txt').open('w')
scenarios = []

def note(value):
    log.write(value + '\n')
    log.flush()

def run(args, home=None, expected=0, show=True, extra=None):
    env = ENV.copy()
    if home:
        env['FM_HOME'] = str(home)
    if extra:
        env.update(extra)
    args = [str(arg) for arg in args]
    result = subprocess.run(args, cwd=ROOT, env=env, text=True, capture_output=True, timeout=45)
    if show:
        note('$ ' + ('FM_HOME=' + shlex.quote(str(home)) + ' ' if home else '') + shlex.join(args))
        note(result.stdout.rstrip() + ('\n' + result.stderr.rstrip() if result.stderr else ''))
        note('[exit %s]\n' % result.returncode)
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    return result.stdout

def require(text, output):
    assert text in output, (text, output)

def scenario(name, fn):
    note('=== ' + name + ' ===')
    try:
        fn()
        scenarios.append(dict(name=name, result='pass', live=True,
                              evidence='role-cli-transcript.txt: ' + name, reason=''))
        note('OBSERVED: scenario passed.\n')
    except Exception as exc:
        scenarios.append(dict(name=name, result='fail', live=True,
                              evidence='role-cli-transcript.txt: ' + name, reason=str(exc)))
        note('FAILURE: ' + repr(exc))
        raise

def write(path, content):
    path.write_text(content)
    note('CONFIG ' + str(path.relative_to(LAB)) + ': ' + repr(content))

def home(name, declaration=None, role=None):
    result = LAB / name
    run([ROOT / 'bin/fm-lab-home.sh', 'create', result], show=False)
    if declaration is not None:
        write(result / 'config/firstmate-pub-target', declaration)
    if role is not None:
        write(result / 'config/firstmate-role', role)
    return result

def check(h, project, consent=None, expected=0, cli=None):
    args = ['bash', cli or ROOT / 'bin/fm-role.sh', 'check', project]
    if consent is not None:
        args += ['upstream-consent', consent]
    extra = {'FM_ROOT_OVERRIDE': str(ROOT)} if cli else None
    return run(args, h, expected, extra=extra)

def assert_pin(output, target):
    pin = next(line[len('publication pin: '):] for line in output.splitlines()
               if line.startswith('publication pin: '))
    actual = run(['bash', '-c', pin + '; printf "%s\\n%s\\n" "$GH_HOST" "$GH_REPO"'],
                 extra={'GH_HOST': 'wrong.example', 'GH_REPO': PARENT})
    assert actual == target.split('/')[0] + '\n' + target + '\n', actual

def scaffold(h, ident, mode, consent=None, project=None, expected=0):
    args = ['bash', ROOT / 'bin/fm-brief.sh', ident, 'firstmate', '--mode', mode,
            '--project', project or FORK_REPO]
    if consent is not None:
        args += ['--upstream-consent', consent]
    return run(args, h, expected, extra={'GH_HOST': 'wrong.example', 'GH_REPO': PARENT})

try:
    with tempfile.TemporaryDirectory(prefix='live-role-', dir=ROOT / '.test-role-tmp') as tmp:
        LAB = Path(tmp)
        FORK_REPO = LAB / 'fork-repository'
        run(['git', 'clone', '-q', '--shared', '--no-checkout', ROOT, FORK_REPO], show=False)
        run(['git', '-C', FORK_REPO, 'remote', 'set-url', 'origin', 'https://' + FORK + '.git'], show=False)
        run(['git', '-C', FORK_REPO, 'remote', 'add', 'upstream', 'https://' + PARENT + '.git'], show=False)
        run(['git', '-C', FORK_REPO, 'remote', 'add', 'github', 'https://' + OTHER + '.git'], show=False)
        note('Real CLI from gate worktree; no mocked commands, external fetches, harness launches, or publication.')
        note('Oracle: declared target selects the fork; only matching role/consent authorizes it; legacy remote order and lineage refusals persist.')
        run(['git', '-C', FORK_REPO, 'remote', '-v'])
        fork_home = home('fork-home', '\n# publication belongs to this fork\n  GitHub.COM/Fork-Owner/Firstmate\n\n')
        plain_home = home('plain-home')

        def regression():
            baseline = LAB / 'baseline-bin'
            baseline.mkdir()
            for filename in ('fm-role.sh', 'fm-role-lib.sh'):
                (baseline / filename).write_text(run(['git', 'show', BASE + ':bin/' + filename], show=False))
            old = check(fork_home, FORK_REPO, FORK, expected=1, cli=baseline / 'fm-role.sh')
            require('no publication authority for ' + PARENT, old)
            actual = check(fork_home, FORK_REPO, FORK)
            require('authorized: task consent for ' + FORK, actual)
            assert_pin(actual, FORK)
            assert run(['bash', ROOT / 'bin/fm-role.sh', 'report'], fork_home) == 'fm-role: user (default)\n'
        scenario('Fork declaration authorizes matching task consent and emits a fork publication pin', regression)

        def authority():
            require('no publication authority for ' + FORK, check(fork_home, FORK_REPO, expected=1))
            require('no publication authority for ' + FORK, check(fork_home, FORK_REPO, PARENT, expected=1))
            check(fork_home, FORK_REPO, FORK)
            require('no publication authority for ' + FORK, check(fork_home, FORK_REPO, expected=1))
            parent_maint = home('parent-maintainer', FORK + '\n', 'maintainer ' + PARENT + '\n')
            require('no publication authority for ' + FORK, check(parent_maint, FORK_REPO, expected=1))
            fork_maint = home('fork-maintainer', FORK + '\n', 'maintainer ' + FORK + '\n')
            require('authorized: maintainer scope ' + FORK, check(fork_maint, FORK_REPO))
        scenario('Declaration alone, parent consent, and parent maintainer scope cannot authorize the fork', authority)

        def briefs():
            for mode in ('direct-PR', 'no-mistakes'):
                ident = 'declared-' + mode.lower()
                scaffold(fork_home, ident, mode, FORK)
                brief = fork_home / 'data' / ident / 'brief.md'
                output = brief.read_text()
                destination = EVIDENCE / (ident + '-brief.md')
                shutil.copyfile(brief, destination)
                require('upstream-consent=' + FORK, output)
                first_shell = re.search(r'^```sh\n(.*?)^```', output, re.MULTILINE | re.DOTALL).group(1)
                actual = run(['bash', '-c', first_shell + '\nprintf "%s\\n%s\\n" "$GH_HOST" "$GH_REPO"'],
                             extra={'GH_HOST': 'wrong.example', 'GH_REPO': PARENT})
                assert actual == 'github.com\n' + FORK + '\n', actual
            scaffold(fork_home, 'refused-no-consent', 'direct-PR', expected=1)
            assert not (fork_home / 'data/refused-no-consent').exists()
            scaffold(fork_home, 'refused-parent-consent', 'no-mistakes', PARENT, expected=1)
            assert not (fork_home / 'data/refused-parent-consent').exists()
            scaffold(fork_home, 'local-repair', 'local-only')
        scenario('Ship brief generation pins the declared fork in both publishing modes and refuses missing authority', briefs)

        def fallback():
            require('no publication authority for ' + PARENT, check(plain_home, FORK_REPO, FORK, expected=1))
            assert_pin(check(plain_home, FORK_REPO, PARENT), PARENT)
            file = plain_home / 'config/firstmate-pub-target'
            for malformed in ('not-a-scope\n', '../escape\n', '/fork-owner/firstmate\n',
                              FORK + '\n' + OTHER + '\n', '# comments only\n\n', ''):
                write(file, malformed)
                assert_pin(check(plain_home, FORK_REPO, PARENT), PARENT)
                check(plain_home, FORK_REPO, FORK, expected=1)
            write(file, FORK + '\n')
            file.chmod(0)
            assert not os.access(file, os.R_OK), 'cannot demonstrate unreadable-file behavior with this UID'
            assert_pin(check(plain_home, FORK_REPO, PARENT), PARENT)
            file.chmod(0o600)
            file.unlink()
            file.mkdir()
            assert_pin(check(plain_home, FORK_REPO, PARENT), PARENT)
            file.rmdir()
            target = LAB / 'symlink-target'
            target.write_text(FORK + '\n')
            file.symlink_to(target)
            assert_pin(check(plain_home, FORK_REPO, PARENT), PARENT)
            check(plain_home, FORK_REPO, FORK, expected=1)
            file.unlink()
            run(['git', '-C', FORK_REPO, 'remote', 'remove', 'upstream'], show=False)
            assert_pin(check(plain_home, FORK_REPO, OTHER), OTHER)
            run(['git', '-C', FORK_REPO, 'remote', 'remove', 'github'], show=False)
            assert_pin(check(plain_home, FORK_REPO, FORK), FORK)
            run(['git', '-C', FORK_REPO, 'remote', 'add', 'upstream', 'https://' + PARENT], show=False)
        scenario('Absent, unreadable, symlinked, and malformed declarations retain upstream then github then origin fallback', fallback)

        def empty_host():
            h = home('empty-host-home', '/fork-owner/firstmate\n', 'maintainer /fork-owner/firstmate\n')
            assert_pin(check(h, FORK_REPO, PARENT), PARENT)
            require('is not a valid <host>/<owner>/<repo> scope',
                    check(h, FORK_REPO, '/fork-owner/firstmate', expected=1))
            report = run(['bash', ROOT / 'bin/fm-role.sh', 'report'], h)
            require('fm-role: user', report)
            require('invalid repository scope', report)
            scaffold(h, 'bad-host-consent', 'direct-PR', '/fork-owner/firstmate', expected=1)
        scenario('Empty-host declarations fall back while empty-host grants and consent are rejected', empty_host)

        def lineage():
            shallow = LAB / 'shallow-repository'
            run(['git', 'clone', '-q', '--depth', '1', '--no-checkout', FORK_REPO.as_uri(), shallow], show=False)
            run(['git', '-C', shallow, 'remote', 'set-url', 'origin', 'https://' + FORK], show=False)
            require('cannot determine whether', check(fork_home, shallow, FORK, expected=1))
            scaffold(fork_home, 'unknown-lineage', 'direct-PR', FORK, project=shallow, expected=1)
            assert not (fork_home / 'data/unknown-lineage').exists()
            foreign = LAB / 'unrelated-repository'
            run(['git', 'init', '-q', foreign], show=False)
            run(['git', '-C', foreign, '-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '-q', '--allow-empty', '-m', 'Unrelated history'], show=False)
            run(['git', '-C', foreign, 'remote', 'add', 'origin', 'https://' + FORK], show=False)
            require('not a self-repository task', check(fork_home, foreign, FORK, expected=2))
        scenario('Matching declaration and consent cannot bypass unknown lineage or reclassify unrelated history', lineage)

        def no_target():
            remote_free = LAB / 'remote-free-repository'
            run(['git', 'clone', '-q', '--shared', '--no-checkout', FORK_REPO, remote_free], show=False)
            run(['git', '-C', remote_free, 'remote', 'remove', 'origin'], show=False)
            require('no publication target can be determined', check(plain_home, remote_free, FORK, expected=1))
            assert_pin(check(fork_home, remote_free, FORK), FORK)
            write(plain_home / 'config/firstmate-pub-target', 'not-a-scope\n')
            require('no publication target can be determined', check(plain_home, remote_free, FORK, expected=1))
        scenario('Remote-free repository refuses an unknown target and accepts a declared target only with matching consent', no_target)
        note('All isolated repositories, home configuration, generated state, and baseline files removed by TemporaryDirectory cleanup.')
finally:
    log.close()
    (EVIDENCE / 'role-cli-scenarios.json').write_text(json.dumps(scenarios, indent=2) + '\n')

print(json.dumps(scenarios, indent=2))
