#!/usr/bin/env python3
"""Execute the changed test function against the real helper; audit its boundary.

Oracle: the published intent requires absent child credentials, fixture curl for
all calls, key-absent output before .env exists, and fixture-key header afterward.
The baseline run must reject the ambient-key bug. No source-text assertions.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path.cwd()
evidence = Path('~/.no-mistakes/evidence/01M6QND0EEA9C4J0K36DFJAYX4')
function = 'test_shadow_jev_helper_keeps_the_key_off_argv_and_the_child_env'
scratch = Path(tempfile.mkdtemp(prefix='.jev-validation-', dir=root))
generated = []
results = []
try:
    safety = scratch / 'safety-bin'
    safety.mkdir()
    (safety / 'curl').write_text('#!/bin/sh\nprintf "unexpected fallback curl; network blocked\\n" >> "$AUDIT_FALLBACK"\nexit 99\n')
    (safety / 'curl').chmod(0o755)
    wrapper = scratch / 'audit-jev'
    wrapper.write_text('''#!/usr/bin/env python3
import json, os, shutil, subprocess, sys
request = sys.stdin.read()
r = subprocess.run([os.environ['AUDIT_REAL_JEV']], input=request, text=True, capture_output=True)
record = {'child_key_present': 'TYPESAFE_API_KEY' in os.environ,
          'curl': shutil.which('curl'), 'home_has_env': os.path.isfile(os.path.join(os.environ['FM_HOME'], '.env')),
          'request': json.loads(request), 'exit': r.returncode, 'stdout': r.stdout, 'stderr': r.stderr}
logdir = os.environ.get('FAKE_JEV_LOG')
record['curl_records'] = {name: open(os.path.join(logdir, name)).read() for name in ['header', 'argv', 'body', 'leak'] if os.path.isfile(os.path.join(logdir, name))}
with open(os.environ['AUDIT_LOG'], 'a') as out:
    out.write(json.dumps(record) + '\\n')
sys.stdout.write(r.stdout)
sys.stderr.write(r.stderr)
sys.exit(r.returncode)
''')
    wrapper.chmod(0o755)
    current = (root / 'tests/fm-branch-mod-bin.test.sh').read_text()
    baseline = subprocess.run(['git', 'show', 'e1828d3ead9bdcbc16906f59fd0abee513c3ecc5:tests/fm-branch-mod-bin.test.sh'], text=True, capture_output=True, check=True).stdout
    for name, source, ambient, expected_exit in [
        ('target-no-ambient-key', current, None, 0),
        ('target-ambient-key', current, 'ambient-sentinel-do-not-use', 0),
        ('baseline-ambient-key', baseline, 'ambient-sentinel-do-not-use', 1),
    ]:
        # Load the unchanged suite definitions but invoke only the affected case.
        definitions, calls = source.rsplit('\ntest_evidence_bundle_marks_new_lines_and_advances_the_offset\n', 1)
        script = root / 'tests' / ('.' + name + '-phase.test.sh')
        generated.append(script)
        script.write_text(definitions + '\nJEV="$AUDIT_WRAPPER"\n' + function + '\n')
        tmp = scratch / name
        tmp.mkdir()
        env = os.environ.copy()
        env.pop('TYPESAFE_API_KEY', None)
        if ambient is not None:
            env['TYPESAFE_API_KEY'] = ambient
        env.update(TMPDIR=str(tmp), FM_TEST_SKIP_ORPHAN_REAP='1',
                   PATH=str(safety) + os.pathsep + env['PATH'],
                   AUDIT_WRAPPER=str(wrapper), AUDIT_REAL_JEV=str(root / 'bin/fm-branch-shadow-jev.sh'),
                   AUDIT_LOG=str(evidence / (name + '.jsonl')),
                   AUDIT_FALLBACK=str(evidence / (name + '-fallback.log')))
        trace = evidence / (name + '-network.trace')
        run = subprocess.run(['strace', '-f', '-e', 'trace=network', '-o', str(trace), 'bash', str(script)], env=env, text=True, capture_output=True)
        (evidence / (name + '.log')).write_text(run.stdout + run.stderr)
        records = [json.loads(line) for line in Path(env['AUDIT_LOG']).read_text().splitlines()]
        if run.returncode != expected_exit:
            raise AssertionError((name, run.returncode, run.stdout, run.stderr))
        network = trace.read_text()
        assert 'AF_INET' not in network and 'AF_INET6' not in network, name + ': network attempted'
        if name.startswith('target'):
            assert len(records) == 3
            assert all(not rec['child_key_present'] for rec in records)
            assert all('/jev-helper/fakebin/curl' in rec['curl'] for rec in records)
            assert not Path(env['AUDIT_FALLBACK']).exists()
            assert json.loads(records[0]['stdout']) == {'ok': False, 'unavailable': 'key absent', 'model': 'jev'}
            assert records[0]['curl_records'] == {}
            assert json.loads(records[1]['stdout'])['ok'] is True
            assert json.loads(records[2]['stdout'])['unavailable'] == 'http 503'
            for rec in records[1:]:
                assert rec['curl_records']['header'] == 'Authorization: Bearer sk-jev-trial-key\n'
                assert 'sk-jev-trial-key' not in rec['curl_records']['argv']
                assert 'ambient-sentinel' not in json.dumps(rec)
                assert 'leak' not in rec['curl_records']
                assert json.loads(rec['curl_records']['body']) == rec['request']
        else:
            assert len(records) == 1 and records[0]['child_key_present']
            assert Path(env['AUDIT_FALLBACK']).is_file()
            assert 'absent key must print an unavailable record' in run.stderr
        results.append({'run': name, 'exit': run.returncode, 'calls': len(records),
                        'internet_socket_operations': 0, 'stdout': run.stdout, 'stderr': run.stderr})
    (evidence / 'validation-summary.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(results, indent=2))
finally:
    for script in generated:
        script.unlink(missing_ok=True)
    shutil.rmtree(scratch)
