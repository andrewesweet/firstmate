#!/usr/bin/env python3
"""Drive the real watcher with real curl and a disposable HTTPS publisher.
Oracle: supplied user intent and accepted R1 decision, with fixed published and
installed versions. A false-current failure, lexical comparison, or comparing
only the first PATH copy must fail these checks. No implementation is parsed.
"""
import http.server
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import tempfile
import threading
import time
import traceback

ROOT = Path('~/.no-mistakes/worktrees/3d78cffe00b3/01M54MMDEVYV2QGWZ6VJ25Y57G')
EVIDENCE = Path('~/.no-mistakes/evidence/01M54MMDEVYV2QGWZ6VJ25Y57G')
CHECK = ROOT / 'bin/fm-tool-update-check.sh'
transcript = []
results = []
requests = []
server = None

def note(value):
    transcript.append(str(value))
    print(value, flush=True)

def require(value, message):
    if not value:
        raise AssertionError(message)

def scenario(name, action):
    note('\nSCENARIO: ' + name)
    try:
        action()
        results.append({'name': name, 'result': 'pass', 'live': True})
        note('RESULT: pass')
    except Exception as exc:
        results.append({'name': name, 'result': 'fail', 'live': True, 'reason': str(exc)})
        note(traceback.format_exc())
        note('RESULT: fail')

try:
    with tempfile.TemporaryDirectory(prefix='.tool-version-live-', dir=ROOT) as temp:
        lab = Path(temp)
        (lab / 'tmp').mkdir()
        cert, key = lab / 'publisher-cert.pem', lab / 'publisher-key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-days', '1', '-subj', '/CN=localhost',
                        '-addext', 'subjectAltName=IP:127.0.0.1,DNS:localhost',
                        '-keyout', str(key), '-out', str(cert)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        class Publisher(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_GET(self):
                status, body, delay = {
                    '/latest': (200, b'2.1.273\n', 0),
                    '/newest': (200, b'2.1.275\n', 0),
                    '/older': (200, b'2.1.270\n', 0),
                    '/numeric': (200, b'v2.10.0\n', 0),
                    '/body/9.9.9': (200, b'no version is published here\n', 0),
                    '/error': (503, b'9.9.9\n', 0),
                    '/slow': (200, b'9.9.9\n', 8),
                }.get(self.path, (404, b'not found\n', 0))
                requests.append({'method': self.command, 'path': self.path, 'status': status,
                                 'body': body.decode(), 'delay_seconds': delay})
                if delay:
                    time.sleep(delay)
                try:
                    self.send_response(status)
                    self.send_header('Content-Type', 'text/plain')
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                    pass
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Publisher)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base_url = 'https://127.0.0.1:' + str(server.server_port)
        note('Product: bin/fm-tool-update-check.sh at target HEAD; real curl over verified HTTPS.')
        note('Disposable publisher: ' + base_url + '; fixture CA supplied through CURL_CA_BUNDLE.')
        bins = {}
        dependencies = ['bash', 'dirname', 'date', 'jq', 'tr', 'grep', 'head', 'tail',
                        'stat', 'uname', 'mktemp', 'cat', 'rm', 'mv', 'chmod', 'timeout',
                        'mkdir', 'sha256sum', 'awk', 'wc', 'cut', 'sort', 'sleep', 'git']
        for kind in ('normal', 'no-curl'):
            directory = lab / kind
            directory.mkdir()
            for command in dependencies + (['curl'] if kind == 'normal' else []):
                executable = shutil.which(command)
                require(executable, 'Required command missing from PATH: ' + command)
                (directory / command).symlink_to(executable)
            bins[kind] = directory

        def tool(directory, version, name='watched-fixture', announcement=''):
            directory.mkdir(parents=True, exist_ok=True)
            target = directory / name
            target.write_text('#!/usr/bin/env bash\nprintf "%s\\n" ' + repr(version + announcement) + '\n')
            target.chmod(0o755)

        def home(name, entries):
            directory = lab / name
            (directory / 'config').mkdir(parents=True)
            (directory / 'state').mkdir()
            (directory / 'config/supervision-host-off').touch()
            (directory / 'config/watched-tools.json').write_text(json.dumps({'tools': entries}))
            return directory

        def entry(url='/latest', command='watched-fixture', **extra):
            value = {'name': 'watched', 'command': command}
            if url is not None:
                value['version_url'] = base_url + url
            value.update(extra)
            return value

        def environment(directory, paths, kind='normal', full=False, external=False):
            env = {'PATH': ':'.join(map(str, paths + [bins[kind]])),
                   'HOME': str(directory), 'TMPDIR': str(lab / 'tmp'), 'LC_ALL': 'C',
                   'FM_HOME': str(directory), 'FM_TOOL_UPDATE_INTERVAL': '0',
                   'FM_TOOL_UPDATE_PROBE_SECS': '2', 'FM_TOOL_UPDATE_BUDGET_SECS': '20',
                   'FM_CHECK_TIMEOUT': '30', 'CURL_CA_BUNDLE': str(cert), 'NO_PROXY': '*'}
            if full:
                env['PATH'] += ':' + os.environ['PATH']
            if external:
                env.pop('CURL_CA_BUNDLE')
                env.pop('NO_PROXY')
                env['FM_TOOL_UPDATE_PROBE_SECS'] = '5'
                for key in ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy'):
                    if key in os.environ:
                        env[key] = os.environ[key]
            return env

        def run(directory, paths, action='check', clear=True, kind='normal', executable=None,
                full=False, external=False, extra=None, expected=0, args=None):
            record = directory / 'state/.tool-updates'
            if clear:
                record.unlink(missing_ok=True)
            env = environment(directory, paths, kind, full, external)
            env.update(extra or {})
            command = [str(executable or CHECK)] + (args if args is not None else [action])
            start = time.monotonic()
            result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True, timeout=15)
            elapsed = time.monotonic() - start
            note('$ FM_HOME=' + str(directory) + ' ' + ' '.join(command))
            note('exit=' + str(result.returncode) + ', elapsed=' + format(elapsed, '.3f') + 's')
            note('stdout: ' + (result.stdout.rstrip() or '<silent>'))
            if result.stderr:
                note('stderr: ' + result.stderr.rstrip())
            if record.exists():
                note('persisted state/.tool-updates:\n' + record.read_text().rstrip())
            require(result.returncode == expected, 'Unexpected product exit status')
            return result.stdout, elapsed

        old, same, newer, numeric = [lab / name for name in ('old-bin', 'same-bin', 'new-bin', 'numeric-bin')]
        tool(old, '2.1.271 (Example Tool)')
        tool(same, '2.1.273 (Example Tool)')
        tool(newer, '2.1.274 (Example Tool)')
        tool(numeric, '2.9.0 (Example Tool)')

        def happy():
            h = home('armed', [entry()])
            run(h, [old], action='arm')
            require((h / 'state/tool-updates.check-trust').is_file(), 'Arm did not create trust binding')
            out, _ = run(h, [old], executable=h / 'state/tool-updates.check.sh', args=[])
            require('watched update available: 2.1.273 published at ' + base_url + '/latest, PATH resolves 2.1.271' in out,
                    'New published version missing from real armed shim output')
            out, _ = run(h, [old], executable=h / 'state/tool-updates.check.sh', args=[], clear=False)
            require(out == '', 'Unchanged update repeated instead of being deduplicated')
            out, _ = run(h, [old], executable=ROOT / 'bin/fm-watch-checkpoint.sh',
                         args=['--seconds', '10'], full=True,
                         extra={'FM_POLL': '1', 'FM_SIGNAL_GRACE': '1', 'FM_CHECK_INTERVAL': '1'})
            require('check:' in out and 'watched update available: 2.1.273' in out,
                    'Real watcher did not deliver published-version check wake')
            run(h, [old], action='disarm', clear=False)
            require(not (h / 'state/tool-updates.check.sh').exists(), 'Disarm retained shim')
        scenario('Arm version_url and receive a real watcher wake for a silent tool; repeat is suppressed', happy)

        def current():
            h = home('current', [entry()])
            out, _ = run(h, [same])
            require(out == '', 'Equal published and active version should be silent')
            h = home('older-publisher', [entry('/older')])
            out, _ = run(h, [same])
            require(out == '', 'Older published version should be silent')
            h = home('numeric', [entry('/numeric')])
            out, _ = run(h, [numeric])
            require('update available: 2.10.0' in out, 'Numeric comparison treated 2.10.0 as older than 2.9.0')
        scenario('Current or newer active copy stays silent; dotted versions compare numerically', current)

        def skew():
            h = home('already-installed', [entry()])
            for installed in (same, newer):
                out, _ = run(h, [old, installed])
                require('update not in effect: PATH resolves 2.1.271' in out, 'PATH skew missing')
                require('update available' not in out and 'check failed' not in out,
                        'Already-installed release was double reported as available')
                out, _ = run(h, [installed, old])
                require(out == '', 'Activating newest installed copy should be silent')
            h = home('newer-than-all', [entry('/newest')])
            out, _ = run(h, [old, same])
            require('update available: 2.1.275' in out and 'update not in effect:' in out,
                    'Release newer than every copy must report update and existing skew')
        scenario('Installed release reports only PATH skew; release newer than all copies also reports availability', skew)

        def failures():
            for route in ('/error', '/body/9.9.9', '/slow'):
                h = home('failure-' + route.replace('/', '-'), [entry(route), entry('/newest', name='next')])
                out, elapsed = run(h, [old])
                require('watched check failed: ' + base_url + route + ' did not report a version' in out,
                        'Failed source was falsely read as current or available')
                require('watched update available:' not in out, 'Failed numeric response produced a false update')
                require('next update available: 2.1.275' in out, 'Failed source prevented next tool from being checked')
                require(elapsed < 6, 'Failed probe escaped configured 2-second bound')
        scenario('HTTP failure, unreadable body, and slow HTTPS report check failure within bound and continue sweep', failures)

        def missing():
            h = home('missing-curl', [entry()])
            count = len(requests)
            out, _ = run(h, [old], kind='no-curl')
            require('watched check failed: curl is required to read ' + base_url + '/latest' in out,
                    'Missing curl falsely read as current')
            require(len(requests) == count, 'Missing-curl scenario unexpectedly contacted publisher')
        scenario('Curl absent from PATH produces explicit check failure without a network request', missing)

        def invalid():
            invalid_urls = ['http://127.0.0.1/latest', '', None, 123, [], {},
                            base_url + '/latest extra', base_url + '/latest\nextra',
                            base_url + '/latest\x1fextra', 'file:///etc/passwd']
            count = len(requests)
            for index, url in enumerate(invalid_urls):
                item = entry()
                item['version_url'] = url
                h = home('invalid-' + str(index), [item])
                out, _ = run(h, [old])
                require('version_url must be one https URL' in out, 'Invalid URL accepted: ' + repr(url))
                run(h, [old], action='arm', expected=1)
                require(not (h / 'state/tool-updates.check.sh').exists(), 'Invalid registry armed a shim')
            h = home('missing-command', [{'name': 'watched', 'git': {'repo': str(lab)},
                                          'version_url': base_url + '/latest'}])
            out, _ = run(h, [old])
            require('version_url needs command' in out, 'URL without command was accepted')
            run(h, [old], action='arm', expected=1)
            require(len(requests) == count, 'Invalid registry reached a network endpoint')
        scenario('Malformed, insecure, wrong-type, or command-less version_url is rejected before probing or arming', invalid)

        def legacy():
            count = len(requests)
            h = home('legacy-quiet', [entry(None)])
            out, _ = run(h, [old], kind='no-curl')
            require(out == '', 'Optional URL altered silent legacy tool')
            out, _ = run(h, [old, same], kind='no-curl')
            require('update not in effect' in out and 'check failed' not in out, 'Legacy PATH skew changed')
            announce = lab / 'announce-bin'
            tool(announce, '2.1.271\nUpdate available: 2.1.273')
            h = home('legacy-announcement', [entry(None, announce_pattern='Update available: [0-9.]+')])
            out, _ = run(h, [announce], kind='no-curl')
            require('update available: Update available: 2.1.273' in out, 'Legacy announcement changed')
            require(len(requests) == count, 'URL-less registry made a network request')
        scenario('Entries without version_url retain silent, PATH-skew, and announcement behavior without curl', legacy)

        def example():
            published_example = json.loads((ROOT / 'docs/examples/watched-tools.json').read_text())
            item = next(item for item in published_example['tools'] if item['name'] == 'claude')
            require(item['version_url'].startswith('https://'), 'Shipped example does not configure HTTPS')
            example_bin = lab / 'example-bin'
            tool(example_bin, '0.0.0 (Claude Code)', name='claude')
            h = home('shipped-example', [item])
            out, _ = run(h, [example_bin], external=True)
            require('claude update available:' in out and 'published at ' + item['version_url'] in out,
                    'Real shipped endpoint did not yield a published version through the watcher')
        scenario('Shipped Claude example retrieves a version from its real public HTTPS endpoint', example)
        note('\nAll watched commands were disposable external-boundary fixtures; watcher and curl were real.')
        server.shutdown()
        server.server_close()
        server = None
    note('Disposable homes, binaries, private TLS key, and publisher removed.')
finally:
    if server:
        server.shutdown()
        server.server_close()
    (EVIDENCE / 'watched-version-live-transcript.log').write_text('\n'.join(transcript) + '\n')
    (EVIDENCE / 'watched-version-https-requests.json').write_text(json.dumps(requests, indent=2) + '\n')
    (EVIDENCE / 'watched-version-live-results.json').write_text(json.dumps(results, indent=2) + '\n')

raise SystemExit(1 if any(item['result'] == 'fail' for item in results) else 0)
