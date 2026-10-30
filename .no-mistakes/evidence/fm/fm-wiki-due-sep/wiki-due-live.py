"""Drive the public due CLI using disposable, committed wiki repositories.
Oracle: author's separator intent; fm-wiki.sh documented 25-lesson/7-day
readiness and exact bare-id/optional single .md membership contracts.
Rejects punctuation retained on ids, substring matches, double suffix stripping,
and counting compiled lessons toward either readiness threshold.
"""
import datetime
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path.cwd()
EVIDENCE = Path('~/.no-mistakes/evidence/01M67C57DXDZ12CK4GB869HSQW')
BASE = '89fd6d03e55d6096bad0d95804fb89baec48930d'
lines = []
results = []

def record(message):
    lines.append(message)
    print(message, flush=True)

def command(args, env, cwd=None):
    return subprocess.run([str(x) for x in args], env=env, cwd=cwd,
                          capture_output=True, text=True, timeout=30, check=True)

with tempfile.TemporaryDirectory(prefix='.wiki-due-live-', dir=ROOT) as scratch:
    scratch = Path(scratch)
    for sub in ('home', 'tmp', 'baseline'):
        (scratch / sub).mkdir()
    env = {'PATH': os.environ['PATH'], 'HOME': str(scratch / 'home'),
           'TMPDIR': str(scratch / 'tmp'), 'LC_ALL': 'C',
           'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
           'GIT_TERMINAL_PROMPT': '0'}
    archive = subprocess.run(['git', 'archive', BASE, 'bin'], env=env,
                             cwd=ROOT, capture_output=True, check=True).stdout
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        tar.extractall(scratch / 'baseline', filter='data')
    target_cli = ROOT / 'bin/fm-wiki.sh'
    base_cli = scratch / 'baseline/bin/fm-wiki.sh'

    class Wiki:
        def __init__(self, name, ids):
            self.home = scratch / name
            self.repo = self.home / 'state/wiki/repo'
            self.ids = ids
            for sub in ('config', 'data', 'state', 'home'):
                (self.home / sub).mkdir(parents=True, exist_ok=True)
            self.env = dict(env, FM_HOME=str(self.home),
                            FM_STATE_OVERRIDE=str(self.home / 'state'),
                            FM_DATA_OVERRIDE=str(self.home / 'data'),
                            FM_CONFIG_OVERRIDE=str(self.home / 'config'),
                            HOME=str(self.home / 'home'))
            remote = self.home / 'remote.git'
            command(['git', 'init', '-q', '--bare', '--initial-branch=main', remote], self.env)
            command(['git', 'clone', '-q', remote.as_uri(), self.repo], self.env)
            (self.home / 'config/wiki').write_text(f'remote={remote.as_uri()}\nrole=gardener\n')
            (self.home / 'config/backlog-backend').write_text('manual\n')
            for raw_id in ids:
                self.add(raw_id)
            self.log('')

        def git(self, *args):
            return command(['git', '-c', 'user.name=Live Test', '-c',
                            'user.email=live-test@example.test', '-c',
                            'core.hooksPath=/dev/null', '-C', self.repo, *args], self.env)

        def add(self, raw_id):
            path = self.repo / 'raw' / raw_id[:4] / raw_id[4:6] / (raw_id + '.md')
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('---\nwiki: raw-lesson v1\nwiki-home: disposable\n'
                            'wiki-task: live-test\nwiki-final: done\n---\n\n'
                            '## Isolated readiness lesson\nscope: tool:wiki\n'
                            'claim: a test lesson\nevidence: disposable live CLI scenario\n')

        def log(self, text):
            (self.repo / 'log.md').write_text(text)
            self.git('add', '-A')
            self.git('commit', '-q', '--allow-empty', '-m', 'Disposable wiki readiness state')
            record('COMMITTED log.md = ' + json.dumps(text))

        def check(self, label, expected_code, expected_output, cli=None):
            cli = cli or target_cli
            product = 'base' if cli == base_cli else 'target'
            out = subprocess.run(['bash', str(cli), 'due'], env=self.env,
                                 cwd=ROOT, capture_output=True, text=True, timeout=30)
            record(f'$ [{product}: {label}] FM_HOME=<isolated:{self.home.name}> bash bin/fm-wiki.sh due')
            record(f'exit={out.returncode}; stdout={json.dumps(out.stdout)}; stderr={json.dumps(out.stderr)}')
            assert (out.returncode, out.stdout, out.stderr) == (expected_code, expected_output, ''), label

    old_a = '20200101T000000Z-lab-home-alpha-a1b2'
    old_b = '20200101T000000Z-lab-home-beta-c3d4'
    old_due2 = 'wiki: gardener due (2 uncompiled raw lesson(s), oldest 2020-01-01)\n'
    old_due1 = 'wiki: gardener due (1 uncompiled raw lesson(s), oldest 2020-01-01)\n'
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    fresh = [f'{stamp}-lab-home-fresh-{i}-a1b2' for i in range(25)]
    today = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d')
    def ingest(ids):
        return f'## [{today}] ingest | 2 lessons | {ids}\n'

    record('Oracle: compiled exact ids do not count as pending; 25 pending or an old pending lesson fires due.')
    for name, separators in [('Semicolon ingest batches', ['; ', ';', ';\t', ';;;  ']),
                             ('Comma ingest batches', [',', ', ', ',\t', ',,,'])]:
        record('\nSCENARIO ' + name)
        wiki = Wiki('semicolon' if name.startswith('Semicolon') else 'comma', [old_a, old_b])
        record('RAW IDS = ' + json.dumps(wiki.ids))
        wiki.check('unlogged old lessons trigger readiness', 0, old_due2)
        for sep in separators:
            wiki.log(ingest(old_a + sep + old_b))
            wiki.check('both compiled ids clear readiness, delimiter=' + repr(sep), 1, '')
        # Reproduce the original failure with the same committed input and real base CLI.
        canonical = '; ' if name.startswith('Semicolon') else ','
        wiki.log(ingest(old_a + canonical + old_b))
        wiki.check('target clears the exact baseline regression input', 1, '')
        wiki.check('base still counts separator-adjacent compiled ids as pending', 0,
                   old_due1 if canonical == '; ' else old_due2, base_cli)
        results.append({'name': name, 'result': 'pass', 'live': True})

    record('\nSCENARIO Mixed delimiters, whitespace and legacy .md ids remain compiled')
    wiki = Wiki('compatible', [old_a, old_b])
    wiki.check('control: old lessons pending', 0, old_due2)
    for tokens in [old_a + '\t' + old_b + '.md\r\n',
                   ';,' + old_a + '.md;,\t' + old_b + ',;',
                   old_a + '.md, ' + old_b + '.md;']:
        wiki.log(ingest(tokens))
        wiki.check('compiled bare and legacy ids with mixed delimiters', 1, '')
    results.append({'name': 'Mixed delimiters, whitespace and legacy .md ids remain compiled', 'result': 'pass', 'live': True})

    record('\nSCENARIO Compiled ids stop contributing to count and oldest-age thresholds')
    wiki = Wiki('thresholds', fresh)
    record('RAW IDS = 25 distinct lessons stamped ' + stamp)
    wiki.check('25 recent pending lessons trigger count', 0,
               f'wiki: gardener due (25 uncompiled raw lesson(s), oldest {today})\n')
    wiki.log(ingest(fresh[0] + ';' + fresh[1]))
    wiki.check('two semicolon-compiled ids reduce count to 23', 1, '')
    wiki.add(old_a)
    wiki.log(ingest(fresh[0] + ',' + fresh[1]))
    wiki.check('23 fresh plus one old pending lesson trigger age', 0,
               'wiki: gardener due (24 uncompiled raw lesson(s), oldest 2020-01-01)\n')
    wiki.log(ingest(fresh[0] + ',' + fresh[1] + ';' + old_a))
    wiki.check('compiled old id no longer contributes age; 23 fresh remain', 1, '')
    results.append({'name': 'Compiled ids stop contributing to count and oldest-age thresholds', 'result': 'pass', 'live': True})

    record('\nSCENARIO Near-match ids cannot falsely compile a pending lesson')
    longer = old_a + '-longer'
    wiki = Wiki('exact-id', [old_a, longer])
    record('RAW IDS = ' + json.dumps(wiki.ids))
    for suffix in ['', '.md']:
        for sep in [';', ',']:
            wiki.log(ingest('unknown' + sep + longer + suffix + sep + 'another-unknown'))
            wiki.check('logging longer id leaves prefix pending ' + repr((suffix, sep)), 0, old_due1)
    for wrong in ['x' + old_a, old_a + '-extra', old_a + '.md.md']:
        wiki.log(ingest(longer + '.md;' + wrong + ','))
        wiki.check('embedded or double-suffixed id remains pending ' + wrong, 0, old_due1)
    wiki.log(ingest(longer + '.md;' + old_a + ','))
    wiki.check('logging exact remaining id clears readiness', 1, '')
    results.append({'name': 'Near-match ids cannot falsely compile a pending lesson', 'result': 'pass', 'live': True})
    record('\nAll live scenarios passed. Baseline reproduced both separator failures. Disposable homes are removed on exit.')

(EVIDENCE / 'wiki-due-live.log').write_text('\n'.join(lines) + '\n')
(EVIDENCE / 'wiki-due-live-results.json').write_text(json.dumps(results, indent=2) + '\n')
assert not scratch.exists()
