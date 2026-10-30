"""Drive the real due CLI against isolated, committed wiki data.
Oracle: fm-wiki.sh public threshold contract, crew-wiki schema, and accepted
whole-token/optional-.md decision. A substring match or counting logged lessons
must fail these observations. No implementation-source assertions are used.
"""
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path.cwd()
EVIDENCE = Path('~/.no-mistakes/evidence/01M676RFN05EKP13Y1J05KNYXT')
records = []
with tempfile.TemporaryDirectory(prefix='.due-live-', dir=ROOT) as scratch:
    lab = Path(scratch)
    home = lab / 'home'
    for child in ['config', 'state/wiki', 'data', 'user', 'tmp']:
        (home / child).mkdir(parents=True, exist_ok=True)
    env = {'PATH': os.environ['PATH'], 'HOME': str(home / 'user'),
           'TMPDIR': str(home / 'tmp'), 'LC_ALL': 'C', 'TZ': 'UTC',
           'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_NOSYSTEM': '1',
           'GIT_AUTHOR_NAME': 'Live validation', 'GIT_AUTHOR_EMAIL': 'test@example.test',
           'GIT_COMMITTER_NAME': 'Live validation', 'GIT_COMMITTER_EMAIL': 'test@example.test',
           'FM_HOME': str(home), 'FM_CONFIG_OVERRIDE': str(home / 'config'),
           'FM_STATE_OVERRIDE': str(home / 'state'), 'FM_DATA_OVERRIDE': str(home / 'data')}
    def run(args, cwd=ROOT, check=True):
        return subprocess.run(list(map(str, args)), cwd=cwd, env=env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=30, check=check)
    remote = lab / 'wiki.git'
    run(['git', 'init', '-q', '--bare', remote])
    repo = home / 'state/wiki/repo'
    run(['git', 'clone', '-q', remote, repo])
    run(['git', 'checkout', '-q', '-b', 'main'], repo)
    (home / 'config/wiki').write_text(f'remote={remote}\nrole=gardener\n')
    (home / 'config/backlog-backend').write_text('manual\n')
    (home / 'data/backlog.md').write_text('## Queued\n\n## In flight\n\n## Done\n')
    def commit(label):
        run(['git', 'add', '-A'], repo)
        run(['git', 'commit', '-q', '--allow-empty', '-m', label], repo)
    def raw(ident):
        p = repo / 'raw' / ident[:4] / ident[4:6] / (ident + '.md')
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text('---\nwiki: raw-lesson v1\nwiki-home: testhome\nwiki-final: done\n---\n\nA disposable lesson.\n')
    def log(ids, suffix='', crlf=False):
        with (repo / 'log.md').open('ab') as f:
            f.write(('## [2026-10-30] ingest | %d lessons |\t' % len(ids) +
                     ' \t'.join(i + suffix for i in ids) + ('\r\n' if crlf else '\n')).encode())
    def reset():
        if (repo / 'raw').exists():
            shutil.rmtree(repo / 'raw')
        (repo / 'log.md').write_text('# Ingest log\n')
    def due(label, count=None, day=None, executable=None, expect=True):
        cli = executable or ROOT / 'bin/fm-wiki.sh'
        result = run(['bash', cli, 'due'], check=False)
        expected = '' if count is None else f'wiki: gardener due ({count} uncompiled raw lesson(s), oldest {day})\n'
        ok = result.returncode == (1 if count is None else 0) and result.stdout == expected and result.stderr == ''
        record = {'step': label, 'command': f'bash {cli.relative_to(ROOT)} due',
                  'exit': result.returncode, 'stdout': result.stdout,
                  'stderr': result.stderr, 'expected_exit': 1 if count is None else 0,
                  'expected_stdout': expected, 'matches_contract': ok}
        records.append(record)
        print(json.dumps(record), flush=True)
        if expect:
            assert ok, record
        return ok
    fresh = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    today = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d')
    old = '20200101T000000Z-testhost-testhome-old-abcd'
    new = fresh + '-testhost-testhome-new-1234'
    reset()
    raw(old); raw(new); commit('Old and fresh pending lessons')
    due('Unlogged old lesson triggers age readiness', 2, '2020-01-01')
    log([old]); commit('Compile old lesson using schema bare id')
    due('Bare-id ingest removes old lesson from pending age')
    # Run the pre-change executable with its real libraries, against the same data.
    baseline = lab / 'baseline/bin'
    baseline.mkdir(parents=True)
    for source in (ROOT / 'bin').iterdir():
        if source.name != 'fm-wiki.sh':
            (baseline / source.name).symlink_to(source)
    baseline_cli = baseline / 'fm-wiki.sh'
    baseline_cli.write_text(run(['git', 'show', 'e9cd0b4776255baa41740291d7c64a1a072e16a1:bin/fm-wiki.sh']).stdout)
    assert not due('Pre-change reproduction: bare-id ingest still triggers readiness', executable=baseline_cli, expect=False)
    for suffix in ['', '.md']:
        reset()
        ids = [fresh + '-testhost-testhome-batch-%02d-abcd' % n for n in range(25)]
        for ident in ids:
            raw(ident)
        commit('25 fresh pending lessons')
        due(f'25 fresh lessons trigger count readiness ({suffix or "bare"})', 25, today)
        log([ids[0]], suffix, crlf=True); commit('Compile one lesson')
        due(f'One logged ID drops fresh pending count below 25 ({suffix or "bare"})')
        reset()
        short = '20200101T000000Z-testhost-testhome-fix-abcd'
        long = short + '-1234'
        raw(short); raw(long)
        fresh_ids = ids[:24]
        for ident in fresh_ids:
            raw(ident)
        log([long], suffix, crlf=True); commit('Only longer ID is compiled')
        due(f'Prefix remains pending at count threshold ({suffix or "bare"}, tab and CRLF)', 25, '2020-01-01')
        log(fresh_ids, suffix); commit('Compile 24 fresh lessons')
        due(f'Prefix remains pending by age ({suffix or "bare"})', 1, '2020-01-01')
        log([short], suffix); commit('Compile exact prefix ID')
        due(f'All exact IDs compiled suppress readiness ({suffix or "bare"})')
    reset(); raw(old)
    log(['x' + old, old + '-extra', old + '.md.md', old + '.md-extra'])
    commit('Similar tokens are not complete lesson IDs')
    due('Embedded IDs and additional suffixes never compile an exact ID', 1, '2020-01-01')
    (home / 'state/gardener.meta').write_text('kind=ship\nproject=/disposable/crew-wiki\n')
    (home / 'state/gardener.status').write_text('running\n')
    due('An open gardener task suppresses duplicate readiness')
    (home / 'state/gardener.status').write_text('done\n')
    due('Closing gardener task restores pending readiness', 1, '2020-01-01')
    for role in ['reader', 'contributor', 'off']:
        (home / 'config/wiki').write_text(f'remote={remote}\nrole={role}\n')
        due(f'Role guard remains silent for {role}')
    (home / 'config/wiki').unlink()
    due('Absent feature config stays silent')
(EVIDENCE / 'due-live-results.json').write_text(json.dumps(records, indent=2) + '\n')
print('Disposable home, git repositories, baseline executable, and all temporary data removed.')
