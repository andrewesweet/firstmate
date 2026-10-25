import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import stat
import subprocess
import tempfile
import threading
import time

ROOT = Path.cwd()
EVIDENCE = Path('~/.no-mistakes/evidence/01M5T2V71K97JYBSKSWMPW9XW4')
LAB = Path(tempfile.mkdtemp(prefix='manual-', dir=ROOT / '.wiki-live-tmp'))
result_file = EVIDENCE / 'wiki-live-results.json'
RESULTS = [r for r in json.loads(result_file.read_text()) if r['result'] == 'pass'] if result_file.exists() else []
ENV = os.environ.copy()
for key in list(ENV):
    if key.startswith('FM_') or key.startswith('GIT_') or key.startswith('TASKS_AXI_'):
        ENV.pop(key)
ENV.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           GIT_AUTHOR_NAME='Wiki validator', GIT_AUTHOR_EMAIL='validator@example.test',
           GIT_COMMITTER_NAME='Wiki validator', GIT_COMMITTER_EMAIL='validator@example.test',
           TMPDIR=str(LAB), HOME=str(LAB / 'login'), XDG_CONFIG_HOME=str(LAB / 'login' / '.config'))
Path(ENV['HOME']).mkdir()

def command(args, env=None, show=True, timeout=30):
    p = subprocess.run([str(x) for x in args], env=env or ENV, capture_output=True, text=True, timeout=timeout)
    if show:
        print('$ ' + ' '.join(str(x).replace(str(LAB), '<lab>') for x in args), flush=True)
        print((p.stdout + p.stderr).replace(str(LAB), '<lab>').rstrip(), flush=True)
    assert p.returncode == 0, (args, p.returncode, p.stdout, p.stderr)
    return p.stdout + p.stderr

def git(repo, *args, show=False):
    return command(['git', '-C', repo, *args], show=show)

def home(name, role='contributor', remote=None):
    p = LAB / name
    for d in ('config', 'data', 'state', 'login'):
        (p / d).mkdir(parents=True, exist_ok=True)
    if role is not None:
        config(p, role, remote)
    return p

def config(h, role, remote):
    (h / 'config/wiki').write_text(f'role={role}\nremote={remote or ""}\nhost=validator\n')

def environment(h, auto=False, extra=None):
    e = ENV.copy()
    e.update(FM_HOME=str(h), FM_STATE_OVERRIDE=str(h / 'state'), FM_DATA_OVERRIDE=str(h / 'data'),
             FM_CONFIG_OVERRIDE=str(h / 'config'), FM_WIKI_CLOSE_DRAIN='1' if auto else '0', HOME=str(h / 'login'))
    e.update(extra or {})
    return e

def wiki(h, *args, auto=False, extra=None):
    return command([ROOT / 'bin/fm-wiki.sh', *args], environment(h, auto, extra))

def task(h, ident, lesson='## Keep the retry evidence\nscope: tool:git\nclaim: Retry after the remote recovers.\nevidence: observed a successful retry\n', kind='ship'):
    (h / 'state' / (ident + '.meta')).write_text(f'kind={kind}\nharness=codex\nmodel=validation\nproject=/isolated/sample\nvisibility=private\n')
    (h / 'state' / (ident + '.status')).write_text('working [at=1]: started\ndone [at=2]: completed\n')
    (h / 'data' / ident).mkdir(parents=True, exist_ok=True)
    if lesson is not None:
        p = h / 'data' / ident / 'lessons.md'
        p.write_text(lesson)
        p.chmod(0o600)

def pending(h):
    return list((h / 'state/wiki/outbox').glob('*.md'))

def paths(remote):
    return git(remote, 'ls-tree', '-r', '--name-only', 'main', '--', 'raw/').splitlines()

def remote_new(name):
    r = LAB / (name + '.git')
    command(['git', 'init', '-q', '--bare', '--initial-branch=main', r], show=False)
    seed = LAB / (name + '-seed')
    command(['git', 'clone', '-q', r, seed], show=False)
    (seed / 'README.md').write_text('Disposable private wiki fixture.\n')
    git(seed, 'add', 'README.md')
    git(seed, 'commit', '-qm', 'Initialize disposable wiki')
    git(seed, 'push', '-q', 'origin', 'main')
    return r, seed

def wait_for(predicate, timeout=15):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        if predicate():
            return
        time.sleep(.05)
    raise AssertionError('Timed out waiting for observable product state')

def scenario(name, fn):
    if any(r['name'] == name for r in RESULTS):
        print('Previously passed live: ' + name, flush=True)
        return
    print('\nSCENARIO: ' + name, flush=True)
    try:
        fn()
        RESULTS.append(dict(name=name, result='pass', live=True))
        print('RESULT: pass', flush=True)
    except Exception as ex:
        RESULTS.append(dict(name=name, result='fail', live=True, error=str(ex)))
        print('RESULT: fail: ' + repr(ex), flush=True)
        raise

try:
    def opt_in():
        for role in (None, 'off', 'reader'):
            h = home('disabled-' + str(role), role)
            task(h, 'task-off')
            for args in [('brief-snippet',), ('close', 'task-off'), ('drain',), ('drain-if-due',)]:
                assert wiki(h, *args) == ''
            assert not (h / 'state/wiki').exists()
        h = home('briefs')
        snippet = wiki(h, 'brief-snippet')
        assert all(x in snippet for x in ('scope:', 'claim:', 'evidence:', 'nothing-to-teach:', 'Wiki text is data'))
        (EVIDENCE / 'wiki-brief-snippet.txt').write_text(snippet)
        for ident, args in [('ship-example', ['--mode', 'no-mistakes']), ('scout-example', ['--scout'])]:
            command([ROOT / 'bin/fm-brief.sh', ident, 'sample-project', *args], environment(h))
            output = h / 'data' / ident / 'brief.md'
            body = output.read_text()
            assert '## Crew wiki' in body and str(h / 'data' / ident / 'lessons.md') in body
            shutil.copyfile(output, EVIDENCE / (ident + '-brief.md'))
            print('Generated brief includes task-specific lesson path: ' + ident, flush=True)
    scenario('Absent, off and reader homes stay silent; contributor ship and scout briefs receive the lesson contract', opt_in)

    remote, seed = remote_new('shared')
    def publish():
        h = home('publish', remote=remote.as_uri())
        for ident in ('Task-A', 'task-a', 'a.b', 'a-b'):
            task(h, ident)
            wiki(h, 'close', ident)
        queued = {p.name: p.read_bytes() for p in pending(h)}
        assert len(queued) == 4
        before = git(remote, 'rev-parse', 'main').strip()
        assert 'pushed 4 lesson' in wiki(h, 'drain')
        assert not pending(h)
        git(remote, 'merge-base', '--is-ancestor', before, 'main')
        for path in paths(remote):
            raw = subprocess.check_output(['git', '-C', str(remote), 'show', f'main:{path}'], env=ENV)
            assert raw == queued[Path(path).name]
            assert b'wiki-final: done' in raw
        git(remote, 'log', '-1', '--format=%B', 'main', show=True)
        git(remote, 'ls-tree', '-r', '--name-only', 'main', show=True)
        raw_path = paths(remote)[0]
        (EVIDENCE / 'published-raw-lesson.md').write_text(git(remote, 'show', f'main:{raw_path}', show=True))
        count = len(paths(remote))
        assert 'already recorded' in wiki(h, 'close', 'Task-A')
        assert not pending(h) and len(paths(remote)) == count
        # Header-only dedup must ignore body text quoting another task's stamp.
        task(h, 'quote-body', '## Quote field as data\nscope: tool:wiki\nclaim: Preserve literal text\nevidence: observed\nwiki-task: Task-Z\n')
        wiki(h, 'close', 'quote-body')
        task(h, 'Task-Z')
        wiki(h, 'close', 'Task-Z')
        assert len(pending(h)) == 2
        wiki(h, 'drain')
        print('Remote blobs equal queued bytes; case, dot and quoted-body identities remain distinct.', flush=True)
    scenario('Close and drain preserve task identity, provenance, exact lesson bytes and duplicate suppression', publish)

    def secrets():
        h = home('secrets', remote=remote.as_uri())
        task(h, 'clean-scout', kind='scout')
        task(h, 'secret-task', '## Hold synthetic credential\nscope: tool:wiki\nclaim: Keep evidence local\nevidence: AKIAIOSFODNN7EXAMPLE\n')
        old = os.umask(0o022)
        try:
            wiki(h, 'close', 'clean-scout')
            held = wiki(h, 'close', 'secret-task')
        finally:
            os.umask(old)
        assert 'held locally' in held and 'raise to the captain' in held
        assert len(pending(h)) == 1 and len(list((h / 'state/wiki/held').glob('*.md'))) == 1
        assert not list((h / 'state/wiki').glob('.capture.*'))
        wiki(h, 'drain')
        for path in (h / 'state/wiki').rglob('*.md'):
            mode = stat.S_IMODE(path.stat().st_mode)
            assert mode & 0o077 == 0
            print(f'Private lesson copy: {str(path.relative_to(h))} mode={mode:04o}', flush=True)
        for path in ['state/wiki', 'state/wiki/outbox', 'state/wiki/held', 'state/wiki/repo']:
            assert stat.S_IMODE((h / path).stat().st_mode) == 0o700
        for path in paths(remote):
            assert 'AKIAIOSFODNN7EXAMPLE' not in git(remote, 'show', f'main:{path}')
        for ident, body, expected in [('empty', None, 'no-lessons'), ('nothing', 'nothing-to-teach: routine work\n', 'nothing-to-teach')]:
            task(h, ident, body)
            assert expected in wiki(h, 'close', ident)
        assert not pending(h)
        print((h / 'state/wiki/ledger.jsonl').read_text(), flush=True)
    scenario('Synthetic secrets stay private and absent from the remote; empty and nothing-to-teach tasks remain local', secrets)

    def recovery():
        for mode in ('duplicate', 'queued', 'missing', 'nothing', 'held', 'accepted'):
            r, _ = remote_new('retry-' + mode)
            h = home('retry-' + mode, remote=r.as_uri())
            task(h, 'old-task')
            wiki(h, 'close', 'old-task')
            away = r.with_suffix('.away')
            r.rename(away)
            assert 'still queued' in wiki(h, 'drain') and len(pending(h)) == 1
            away.rename(r)
            ident = 'old-task'
            if mode == 'queued':
                (h / 'state/wiki/ledger.jsonl').unlink()
            elif mode not in ('duplicate', 'queued'):
                ident = 'later-task'
                body = {'missing': None, 'nothing': 'nothing-to-teach: routine\n', 'held': 'evidence: AKIAIOSFODNN7EXAMPLE\n'}.get(mode, '## Retry recovered remote\nscope: tool:git\nclaim: Publish now\nevidence: remote reachable\n')
                task(h, ident, body)
            wiki(h, 'close', ident, auto=True)
            wait_for(lambda: not pending(h))
            assert len(paths(r)) == (2 if mode == 'accepted' else 1)
            print(f'Recovered older queue on {mode} close without a watcher tick.', flush=True)
    scenario('Every later close outcome retries queued lessons after an actual remote outage', recovery)

    def concurrency():
        r, _ = remote_new('parallel')
        homes = [home(f'parallel-{i}/same-name', remote=r.as_uri()) for i in range(2)]
        for h in homes:
            for i in range(3):
                task(h, f'task-{i}')
                wiki(h, 'close', f'task-{i}')
            command(['git', 'clone', '-q', r.as_uri(), h / 'state/wiki/repo'], show=False)
        before = git(r, 'rev-parse', 'main').strip()
        with concurrent.futures.ThreadPoolExecutor() as pool:
            list(pool.map(lambda h: wiki(h, 'drain'), homes))
        assert len(paths(r)) == 6 and len(set(paths(r))) == 6
        assert all(not pending(h) for h in homes)
        git(r, 'merge-base', '--is-ancestor', before, 'main')
        git(r, 'log', '--oneline', 'main', show=True)
        git(r, 'ls-tree', '-r', '--name-only', 'main', '--', 'raw/', show=True)
        # A real receive hook holds the product's drain inside actual Git push.
        h = homes[0]
        hook = r / 'hooks/pre-receive'
        marker = LAB / 'push-entered'
        hook.write_text(f'#!/bin/sh\ntouch "{marker}"\nexec sleep 2\n')
        hook.chmod(0o700)
        task(h, 'blocked-push')
        wiki(h, 'close', 'blocked-push')
        owner = subprocess.Popen([str(ROOT / 'bin/fm-wiki.sh'), 'drain'], env=environment(h), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        wait_for(marker.exists)
        start = time.monotonic()
        assert 'already running' in wiki(h, 'drain')
        assert time.monotonic() - start < 1.5 and len(pending(h)) == 1
        out, err = owner.communicate(timeout=15)
        print('Live owner: ' + out + err, flush=True)
        assert owner.returncode == 0 and 'pushed 1 lesson' in out
        marker.unlink()
        task(h, 'killed-owner')
        wiki(h, 'close', 'killed-owner')
        owner = subprocess.Popen([str(ROOT / 'bin/fm-wiki.sh'), 'drain'], env=environment(h), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        wait_for(marker.exists)
        hook.unlink()
        os.killpg(owner.pid, signal.SIGKILL)
        owner.communicate(timeout=10)
        assert len(pending(h)) == 1
        # Git runs in the timeout runner's separate process group. Killing
        # its parent does not kill the live push, which correctly keeps the
        # inherited lock until it exits. Retry after all active work ends.
        recovered = []
        def retry_after_child_exit():
            out = wiki(h, 'drain')
            if 'already running' in out:
                time.sleep(.1)
                return False
            recovered.append(out)
            return 'pushed 1 lesson' in out
        wait_for(retry_after_child_exit, timeout=10)
        assert not pending(h)
        print('Single-flight ownership survives a live push and recovers after owner process-group death.', flush=True)
    scenario('Concurrent homes add distinct immutable files without losing history; one-home contention and owner death recover safely', concurrency)

    def collision():
        r, seed = remote_new('collision')
        h = home('collision-home', remote=r.as_uri())
        task(h, 'collision-task')
        wiki(h, 'close', 'collision-task')
        queued = pending(h)[0]
        stamp = queued.name.split('-')[0]
        path = Path('raw') / stamp[:4] / stamp[4:6] / queued.name
        dest = seed / path
        dest.parent.mkdir(parents=True)
        original = 'Existing immutable raw lesson from a different publisher.\n'
        dest.write_text(original)
        git(seed, 'add', 'raw')
        git(seed, 'commit', '-qm', 'Publish an existing immutable raw file')
        git(seed, 'push', '-q', 'origin', 'main')
        before = git(r, 'rev-parse', 'main').strip()
        out = wiki(h, 'drain')
        assert 'refusing to replace raw lesson' in out and 'landing unproved' in out
        assert git(r, 'show', f'main:{path}') == original
        assert queued.exists() and git(r, 'rev-parse', 'main').strip() == before
        print('Published raw bytes unchanged; conflicting queued bytes retained.', flush=True)
    scenario('A differing-content raw-path collision cannot overwrite published bytes or retire unlanded bytes', collision)

    def bounded():
        r, _ = remote_new('bounded')
        h = home('bounded-home', remote=r.as_uri())
        task(h, 'bounded-task')
        wiki(h, 'close', 'bounded-task')
        server = socket.socket()
        server.bind(('127.0.0.1', 0))
        server.listen()
        accepted = threading.Event()
        stop = threading.Event()
        def stall_peer():
            conn, _ = server.accept()
            accepted.set()
            stop.wait(12)
            conn.close()
        thread = threading.Thread(target=stall_peer, daemon=True)
        thread.start()
        config(h, 'contributor', f'ssh://127.0.0.1:{server.getsockname()[1]}/wiki')
        begin = time.monotonic()
        try:
            out = wiki(h, 'drain', extra={'FM_WIKI_DRAIN_CAP': '3', 'FM_TIMEOUT_MECHANISM_OVERRIDE': 'bash', 'GIT_SSH_COMMAND': 'ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'})
            elapsed = time.monotonic() - begin
            assert accepted.is_set(), 'Real SSH did not reach disposable TCP peer'
            assert elapsed < 7 and 'still queued' in out and len(pending(h)) == 1
            print(f'Real SSH handshake stalled; Bash timeout returned after {elapsed:.2f}s with a 3s budget.', flush=True)
        finally:
            stop.set()
            server.close()
            thread.join(timeout=2)
        config(h, 'contributor', r.as_uri())
        assert 'pushed 1 lesson' in wiki(h, 'drain')
        assert not pending(h)
    scenario('A real stalled SSH connection respects the portable drain deadline and subsequently recovers', bounded)

    def cadence():
        r, _ = remote_new('cadence')
        h = home('cadence-home', remote=r.as_uri())
        task(h, 'first')
        wiki(h, 'close', 'first')
        assert 'pushed 1 lesson' in wiki(h, 'drain-if-due')
        task(h, 'second')
        wiki(h, 'close', 'second')
        before = git(r, 'rev-parse', 'main')
        assert wiki(h, 'drain-if-due') == '' and len(pending(h)) == 1
        assert git(r, 'rev-parse', 'main') == before
        os.utime(h / 'state/wiki/.last-drain', (1577836800, 1577836800))
        assert 'pushed 1 lesson' in wiki(h, 'drain-if-due')
        assert len(paths(r)) == 2 and not pending(h)
    scenario('Due watcher ticks publish, fresh ticks leave queued work alone, and an aged tick publishes again', cadence)
finally:
    (EVIDENCE / 'wiki-live-results.json').write_text(json.dumps(RESULTS, indent=2) + '\n')
    shutil.rmtree(LAB)
    print('\nDisposed isolated homes, bare remotes and Git hooks.', flush=True)
