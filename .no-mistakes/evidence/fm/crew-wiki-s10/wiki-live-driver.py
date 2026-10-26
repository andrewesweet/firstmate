#!/usr/bin/env python3
"""Drive actual wiki CLI with disposable homes and Git remotes, without tool stubs.
Oracle: required supervisor contribution contract and recorded R1-R6 decisions.
Reject loss/duplication, attribution changes, secret publication, and false reports.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import traceback

ROOT = Path.cwd()
EVIDENCE = Path('~/.no-mistakes/evidence/01M5X410KFS4SEYWSEKPVXT197')
LAB = Path(tempfile.mkdtemp(prefix='wiki-live-', dir=ROOT / '.test-tmp/wiki-validation'))
BASE = os.environ.copy()
for key in list(BASE):
    if key.startswith(('FM_', 'GIT_', 'TASKS_AXI_', 'OTEL_')):
        BASE.pop(key)
BASE.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
            GIT_AUTHOR_NAME='Wiki live validation', GIT_AUTHOR_EMAIL='wiki@example.invalid',
            GIT_COMMITTER_NAME='Wiki live validation', GIT_COMMITTER_EMAIL='wiki@example.invalid',
            TMPDIR=str(LAB), HOME=str(LAB / 'login-home'), XDG_CONFIG_HOME=str(LAB / 'xdg'))
Path(BASE['HOME']).mkdir()
Path(BASE['XDG_CONFIG_HOME']).mkdir()
LOG = (EVIDENCE / 'wiki-live-transcript.log').open('w', buffering=1)
RESULTS = []


def record(text):
    LOG.write(text + '\n')


def command(args, env=None, expected=0, log=True):
    if log:
        record('$ ' + ' '.join(map(str, args)))
    p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env or BASE,
                       text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=45)
    if log:
        record(p.stdout.rstrip())
        record(f'[exit {p.returncode}]')
    assert p.returncode == expected, p.stdout
    return p.stdout


def home(name, role='contributor', remote=True):
    h = LAB / name
    for child in ('state', 'data', 'config', 'home'):
        (h / child).mkdir(parents=True, exist_ok=True)
    bare = LAB / (name + '.git')
    if remote:
        command(['git', 'init', '-q', '--bare', '--initial-branch=main', bare])
    (h / 'config/wiki').write_text(f'role={role}\nremote={bare.as_uri() if remote else ""}\nhost=validation\n')
    return h, bare


def wiki(h, *args, drain=False, expected=0):
    env = BASE | dict(FM_HOME=str(h), FM_STATE_OVERRIDE=str(h/'state'),
                      FM_DATA_OVERRIDE=str(h/'data'), FM_CONFIG_OVERRIDE=str(h/'config'),
                      FM_WIKI_CLOSE_DRAIN='1' if drain else '0', HOME=str(h/'home'))
    record(f'FM_HOME={h} FM_WIKI_CLOSE_DRAIN={env["FM_WIKI_CLOSE_DRAIN"]}')
    return command([ROOT/'bin/fm-wiki.sh', *args], env, expected)


def task(h, name, worker=None, supervisor=None, final='done'):
    d = h/'data'/name
    d.mkdir(parents=True, exist_ok=True)
    (h/'state'/f'{name}.meta').write_text('kind=ship\nharness=codex\nmodel=validation\nproject=local-project\n')
    (h/'state'/f'{name}.status').write_text(f'{final} [at=1]: isolated validation\n')
    for filename, body in [('lessons.md', worker), ('supervision.md', supervisor)]:
        if body is not None:
            (d/filename).write_text(body)
    return d


def lesson(title):
    return f'## {title}\nscope: supervision\nclaim: {title}\nevidence: isolated product validation\n'


def queue(h, kind='outbox'):
    return sorted((h/'state/wiki'/kind).glob('*.md'))


def ledger(h):
    path = h/'state/wiki/ledger.jsonl'
    return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []


def stamp(path):
    fields = {}
    for line in path.read_text().split('---', 2)[1].splitlines():
        if ': ' in line:
            key, value = line.split(': ', 1)
            fields[key] = value
    return fields


def remote_files(bare):
    p = subprocess.run(['git', '-C', str(bare), 'ls-tree', '-r', '--name-only', 'main', '--', 'raw/'],
                       env=BASE, capture_output=True, text=True)
    return p.stdout.splitlines() if p.returncode == 0 else []


def show_remote(bare):
    files = command(['git', '-C', bare, 'ls-tree', '-r', '--name-only', 'main', '--', 'raw/']).splitlines()
    bodies = [command(['git', '-C', bare, 'show', f'main:{p}']) for p in files]
    return bodies


def wait_drained(h, bare, expected):
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        if not queue(h) and len(remote_files(bare)) == expected:
            # The publication proof precedes mirror refresh. Wait for its lock to release.
            lock = h/'state/wiki/.drain.lock'
            import fcntl
            if lock.exists():
                with lock.open() as f:
                    try:
                        fcntl.flock(f, fcntl.LOCK_SH | fcntl.LOCK_NB)
                    except BlockingIOError:
                        time.sleep(.05)
                        continue
            return
        time.sleep(.05)
    raise AssertionError(f'detached drain did not publish {expected} lessons')


def scenario(name, fn):
    record('\nSCENARIO: ' + name)
    try:
        fn()
        RESULTS.append(dict(name=name, result='pass', live=True, reason='', evidence='wiki-live-transcript.log'))
        record('OBSERVED: scenario assertions satisfied\n')
    except Exception as ex:
        record(traceback.format_exc())
        RESULTS.append(dict(name=name, result='fail', live=True, reason=str(ex), evidence='wiki-live-transcript.log'))
    print(RESULTS[-1]['result'] + ': ' + name, flush=True)


def close_publish_consult():
    h, bare = home('close-and-consult')
    task(h, 'supervisor-only', supervisor=lesson('Route unfamiliar intake through the charter'), final='failed')
    task(h, 'both', worker=lesson('Keep the worker evidence'), supervisor=lesson('Keep the supervision evidence'))
    task(h, 'worker-only', worker=lesson('Worker compatibility'))
    task(h, 'nothing', worker='nothing-to-teach: routine\n', supervisor=lesson('Supervisor still has evidence'))
    for name in ('supervisor-only', 'both', 'worker-only', 'nothing'):
        wiki(h, 'close', name)
    assert len(queue(h)) == 5
    records = {x['task']: x for x in ledger(h)}
    assert records['supervisor-only']['supervisor'] == 'lesson'
    assert records['supervisor-only']['worker'] == 'no-lessons'
    assert records['both']['files'] == 2
    assert records['worker-only']['supervisor'] == 'none'
    assert records['nothing']['worker'] == 'nothing-to-teach'
    for p in queue(h):
        s = stamp(p)
        if s['wiki-task'] == 'supervisor-only':
            assert s['wiki-final'] == 'failed'
        if s.get('wiki-role') == 'supervisor':
            assert s['wiki-agent'] == 'firstmate' and s['wiki-kind'] == 'supervision'
    wiki(h, 'drain')
    bodies = show_remote(bare)
    assert len(bodies) == 5
    for body in bodies:
        assert 'isolated product validation' in body
    found = wiki(h, 'consult', 'grep', '-ril', '--', 'Route unfamiliar intake', 'raw')
    assert found.startswith('raw/')
    read = wiki(h, 'consult', 'cat', found.strip())
    assert 'wiki-role: supervisor' in read and 'Route unfamiliar intake' in read
    for name in ('supervisor-only', 'both'):
        wiki(h, 'close', name)
    assert not queue(h)
    record('Persisted capture ledger: ' + json.dumps(ledger(h)))


def standalone():
    h, bare = home('standalone')
    source = h/'data/idle lesson.md'
    source.write_text(lesson('File an empty-fleet supervision lesson'))
    wiki(h, 'file', source)
    copy = h/'data/renamed.md'
    shutil.copyfile(source, copy)
    assert 'already recorded' in wiki(h, 'file', copy)
    assert len(queue(h)) == 1
    fields = stamp(queue(h)[0])
    assert fields['wiki-task'] == 'session' and fields['wiki-agent'] == 'firstmate'
    assert fields['wiki-role'] == 'supervisor'
    wiki(h, 'drain')
    assert 'already recorded' in wiki(h, 'file', source)
    assert not queue(h)
    source.write_text(lesson('A new fact in the same file'))
    wiki(h, 'file', source)
    assert len(queue(h)) == 1
    wiki(h, 'drain')
    assert len(show_remote(bare)) == 2
    n = len(ledger(h))
    assert 'no lesson file' in wiki(h, 'file', h/'data/missing.md')
    empty = h/'data/empty.md'
    empty.touch()
    assert 'empty' in wiki(h, 'file', empty)
    assert len(ledger(h)) == n
    record('Persisted standalone ledger: ' + json.dumps(ledger(h)))


def attribution():
    identities = ['Research.A', 'research.a', 'A'*63+'B', 'A'*63+'C', 'invalid/id', 'A'*65, 'Research.A\nforged']
    for index, identity in enumerate(identities):
        h, _ = home('attribution-' + str(index), remote=False)
        (h/'.fm-secondmate-home').write_text(identity+'\n')
        expected = 'firstmate' if index >= 4 else 'secondmate:'+identity
        task(h, 'mate', supervisor=lesson('Task supervisor attribution'))
        wiki(h, 'close', 'mate')
        source = h/'data/idle.md'
        source.write_text(lesson('Idle supervisor attribution'))
        wiki(h, 'file', source)
        assert len(queue(h)) == 2
        for p in queue(h):
            assert stamp(p)['wiki-agent'] == expected
            record(p.name + ': wiki-agent: ' + stamp(p)['wiki-agent'])


def secrets():
    h, bare = home('secret-holds')
    leak = lesson('Synthetic secret must stay private')+'evidence: AKIAIOSFODNN7EXAMPLE\n'
    task(h, 'supervisor-only', supervisor=leak)
    out = wiki(h, 'close', 'supervisor-only')
    assert 'held recorded' in out and 'queued' not in out
    task(h, 'nothing', worker='nothing-to-teach: routine\n', supervisor=leak)
    out = wiki(h, 'close', 'nothing')
    assert 'held recorded' in out and 'queued' not in out
    source = h/'data/idle.md'
    source.write_text(leak)
    out = wiki(h, 'file', source)
    assert 'held' in out and 'queued' not in out
    wiki(h, 'file', source)
    task(h, 'mixed', worker=lesson('Publish only this clean worker lesson'), supervisor=leak)
    wiki(h, 'close', 'mixed')
    assert len(queue(h, 'held')) == 4 and len(queue(h)) == 1
    for p in queue(h, 'held'):
        assert p.stat().st_mode & 0o077 == 0
        assert stamp(p)['wiki-role'] == 'supervisor'
    wiki(h, 'drain')
    bodies = show_remote(bare)
    assert len(bodies) == 1 and all('AKIA' not in b for b in bodies)
    assert len(queue(h, 'held')) == 4
    record('Persisted held outcomes: ' + json.dumps(ledger(h)))


def partial_recovery():
    for secret in (False, True):
        h, bare = home('partial-'+str(secret))
        d = task(h, 'partial', worker=lesson('Worker saved before supervisor read fails'),
                 supervisor=lesson('Supervisor recovered without duplicating worker'))
        source = d/'supervision.md'
        source.chmod(0)
        try:
            out = wiki(h, 'close', 'partial')
            assert 'failed to stamp' in out and 'queued' not in out and 'recorded for' not in out
            assert ledger(h)[-1]['supervisor'] == 'failed'
            assert len(queue(h)) == 1
            wiki(h, 'drain')
        finally:
            source.chmod(0o600)
        if secret:
            source.write_text(source.read_text()+'evidence: AKIAIOSFODNN7EXAMPLE\n')
        out = wiki(h, 'close', 'partial')
        if secret:
            assert 'held locally' in out and 'queued' not in out
        else:
            assert 'supervision lesson queued' in out
        assert ledger(h)[-1]['files'] == 2
        wiki(h, 'drain')
        assert len(show_remote(bare)) == (1 if secret else 2)
        wiki(h, 'close', 'partial')
        assert not queue(h)
        record('Recovered partial ledger: ' + json.dumps(ledger(h)))


def independent_identities():
    for retained in ('worker', 'supervisor'):
        h, _ = home('queue-recovery-'+retained, remote=False)
        task(h, 'recover', worker=lesson('Worker crash recovery'), supervisor=lesson('Supervisor crash recovery'))
        wiki(h, 'close', 'recover')
        (h/'state/wiki/ledger.jsonl').unlink()
        for p in queue(h):
            is_supervisor = stamp(p).get('wiki-role') == 'supervisor'
            if is_supervisor != (retained == 'supervisor'):
                p.unlink()
        wiki(h, 'close', 'recover')
        assert len(queue(h)) == 2 and ledger(h)[-1]['files'] == 2
    h, _ = home('namespace-boundary', remote=False)
    source = h/'data/idle.md'
    source.write_text(lesson('Standalone and task namespaces remain independent'))
    digest = hashlib.sha256(source.read_bytes()).hexdigest()[:12]
    wiki(h, 'file', source)
    task(h, 'session', supervisor=lesson('A real task named session'))
    task(h, 'file-'+digest, worker=lesson('A real task named file plus digest'))
    wiki(h, 'close', 'session')
    wiki(h, 'close', 'file-'+digest)
    assert len(queue(h)) == 3 and len(ledger(h)) == 3
    record('Distinct identities: '+json.dumps(ledger(h)))


def outage_refile():
    for recorded in (True, False):
        h, bare = home('outage-'+str(recorded))
        source = h/'data/idle.md'
        source.write_text(lesson('Retry publication when the remote returns'))
        away = bare.with_suffix('.unavailable')
        bare.rename(away)
        wiki(h, 'file', source)
        wiki(h, 'drain')
        assert len(queue(h)) == 1
        if not recorded:
            (h/'state/wiki/ledger.jsonl').unlink()
        away.rename(bare)
        wiki(h, 'file', source, drain=True)
        wait_drained(h, bare, 1)
        assert len(show_remote(bare)) == 1
        wiki(h, 'file', source, drain=True)
        wait_drained(h, bare, 1)
        assert len(remote_files(bare)) == 1
        record('Refiling alone published the existing queue without a watcher.')


def collision():
    # Seed a competing queue entry at the actual staged destination. No tool
    # shims: observe real capture staging and race insertion before the real
    # scanner completes. A long clean body gives the observer time to act.
    for verb in ('worker', 'supervisor', 'file'):
        h, _ = home('collision-'+verb, remote=False)
        long_body = lesson('Keep the new contribution retryable') + ('evidence: innocuous local observation\n' * 60000)
        if verb == 'file':
            source = h/'data/idle.md'
            source.write_text(long_body)
            args = ('file', source)
        else:
            task(h, 'collide', worker=long_body if verb == 'worker' else None,
                 supervisor=long_body if verb == 'supervisor' else None)
            args = ('close', 'collide')
        # Prepare the actual outbox without invoking close.
        (h/'state/wiki/outbox').mkdir(parents=True)
        (h/'state/wiki/held').mkdir()
        inserted = []
        stop = threading.Event()
        existing = '## Existing unrelated contribution\nclaim: never overwrite these bytes\n'
        def inject_competing_entry():
            while not stop.is_set():
                for p in (h/'state/wiki').glob('.capture.*/*.md'):
                    target = h/'state/wiki/outbox'/p.name
                    try:
                        with target.open('x') as f:
                            f.write(existing)
                        inserted.append(target)
                        return
                    except FileExistsError:
                        continue
                time.sleep(.0005)
        thread = threading.Thread(target=inject_competing_entry)
        thread.start()
        try:
            out = wiki(h, *args)
        finally:
            stop.set()
            thread.join()
        assert inserted, 'observer did not reach the capture window'
        assert 'failed to queue' in out
        assert inserted[0].read_text() == existing
        assert not ledger(h), 'failed contribution must remain retryable'
        wiki(h, *args)
        assert len(queue(h)) == 2
        assert inserted[0].read_text() == existing
        record(f'{verb}: existing destination unchanged; subsequent retry saved the other contribution.')


def role_boundaries():
    for role in ('off', 'reader', 'absent'):
        h, _ = home('role-'+role, role=role, remote=False)
        if role == 'absent':
            (h/'config/wiki').unlink()
        source = h/'data/idle.md'
        source.write_text(lesson('No contribution from an inactive home'))
        task(h, 'role', supervisor=lesson('No contribution from an inactive home'))
        assert wiki(h, 'file', source) == ''
        assert wiki(h, 'close', 'role') == ''
        assert not (h/'state/wiki').exists()
        record(f'{role}: no capture output and no wiki state created.')

try:
    scenario('Close supervisor-only and mixed tasks, publish each contribution once, then consult the mirror', close_publish_consult)
    scenario('File an idle supervision lesson; deduplicate identical bytes and accept changed content', standalone)
    scenario('Preserve literal secondmate identities in task and standalone supervisor stamps', attribution)
    scenario('Hold secret-bearing supervisor lessons and publish only clean contributions with truthful reports', secrets)
    scenario('Recover real supervisor read failures after worker publication without duplication or false queued reports', partial_recovery)
    scenario('Recover individual queued contributions and keep standalone/session/digest task identities separate', independent_identities)
    scenario('Refile after a real remote outage and publish the existing queue without a watcher', outage_refile)
    scenario('Reject real competing outbox insertions without overwrite and allow worker/supervisor/file retries', collision)
    scenario('Keep absent, off, and reader homes silent without capturing supervisor lessons', role_boundaries)
finally:
    (EVIDENCE/'wiki-live-results.json').write_text(json.dumps(RESULTS, indent=2)+'\n')
    shutil.rmtree(LAB)
    record('TEARDOWN: removed all disposable live homes, remotes, staged lessons, and queues.')
    LOG.close()
raise SystemExit(any(r['result'] != 'pass' for r in RESULTS))
