"""Drive fresh Pi installs, reproduce dependency float, and check isolation."""
import hashlib
import json
import os
from pathlib import Path
import subprocess

root = Path.cwd()
work = root / '.pi-ci-validation'
evidence = Path('~/.no-mistakes/evidence/01M53Q0RK2MPN19NNQ90V2JFV1')
environment = dict(os.environ, TMPDIR=str(work / 'tmp'), PI_CODING_AGENT_DIR=str(work / 'pi-config'), npm_config_cache=str(work / 'npm-cache'), npm_config_userconfig=str(work / 'npm-user.conf'), npm_config_globalconfig=str(work / 'npm-global.conf'))

def command(args, name, env=environment):
    proc = subprocess.run(args, cwd=root, env=env, capture_output=True, text=True, timeout=180)
    (evidence / name).write_text(proc.stdout if name.endswith('.json') else '$ ' + ' '.join(args) + '\n' + proc.stdout + proc.stderr + f'\nexit={proc.returncode}\n')
    return proc

def import_runtime(prefix, label):
    entry = prefix / 'node_modules/@earendil-works/pi-coding-agent/dist/index.js'
    return command(['node', '--input-type=module', '-e', f'const pi = await import({json.dumps(entry.as_uri())}); console.log("Public Pi runtime imported; exports=" + Object.keys(pi).length);'], label)

floating_tree = command(['npm', 'ls', '--prefix', str(work / 'floating'), '--all', '--json'], 'pi-floating-dependencies.json')
assert floating_tree.returncode == 0, floating_tree.stderr
floating = import_runtime(work / 'floating', 'pi-floating-runtime.log')
assert floating.returncode == 0, floating.stderr
historical = import_runtime(work / 'historical-floating', 'pi-historical-floating-runtime.log')
assert historical.returncode != 0, historical.stdout
assert 'MCP_TYPESCRIPT_PREAMBLE' in historical.stderr and 'does not provide an export' in historical.stderr, historical.stderr

pinned = work / 'pinned'
initial = command(['npm', 'ls', '--prefix', str(pinned), '--all', '--json'], 'pi-pinned-dependencies.json')
assert initial.returncode == 0, initial.stderr
initial_tree = json.loads(initial.stdout)
scoped = {}
def collect(tree):
    for name, package in tree.get('dependencies', {}).items():
        if name.startswith('@earendil-works/'):
            scoped.setdefault(name, set()).add(package['version'])
        collect(package)
collect(initial_tree)
assert len(scoped) == 7 and all(versions == {'1.2.0'} for versions in scoped.values()), scoped
assert import_runtime(pinned, 'pi-pinned-runtime.log').returncode == 0
version = command([str(pinned / 'node_modules/.bin/pi'), '--version'], 'pi-pinned-version.log')
assert version.returncode == 0 and version.stdout.strip() == '1.2.0', version.stdout

# Real npm ci must repair an existing destination with local dependency drift.
codemode = pinned / 'node_modules/@earendil-works/pi-codemode/package.json'
package = json.loads(codemode.read_text())
package['version'] = '999.0.0'
codemode.write_text(json.dumps(package))
unlocked = pinned / 'node_modules/unlocked-sentinel'
unlocked.mkdir()
(unlocked / 'package.json').write_text('{"name":"unlocked-sentinel","version":"9.9.9"}')
source_lock = root / 'etc/ci-pi/package-lock.json'
lock_hash = hashlib.sha256(source_lock.read_bytes()).hexdigest()
restored = command(['bin/fm-install-pi.sh', str(pinned)], 'pi-reinstall-repairs-drift.log')
assert restored.returncode == 0, restored.stderr
assert not unlocked.exists()
assert json.loads(codemode.read_text())['version'] == '1.2.0'
after = command(['npm', 'ls', '--prefix', str(pinned), '--all', '--json'], 'pi-restored-dependencies.json')
assert after.returncode == 0 and json.loads(after.stdout) == initial_tree
assert hashlib.sha256(source_lock.read_bytes()).hexdigest() == lock_hash
assert import_runtime(pinned, 'pi-restored-runtime.log').returncode == 0

# Exercise the global-root refusal with a disposable npm prefix.
global_prefix = work / 'guard-exact'
guarded_root = global_prefix / 'lib/node_modules'
guarded_root.mkdir(parents=True)
guard_env = dict(environment, npm_config_prefix=str(global_prefix))
refused = command(['bin/fm-install-pi.sh', str(guarded_root)], 'pi-global-root-refusal.log', guard_env)
assert refused.returncode != 0 and 'refusing to install into the global npm root' in refused.stderr
assert list(guarded_root.iterdir()) == []
report = {
    'fresh_1_2_0_without_overrides': {'import_exit': floating.returncode, 'pi_codemode_version': json.loads((work / 'floating/node_modules/@earendil-works/pi-codemode/package.json').read_text())['version']},
    'historical_1_0_4_failure': {'import_exit': historical.returncode, 'missing_export': 'MCP_TYPESCRIPT_PREAMBLE'},
    'pinned_install': {'version': version.stdout.strip(), 'public_runtime_import_exit': 0, 'scope_versions': {name: sorted(versions) for name, versions in sorted(scoped.items())}},
    'reinstall_repairs_drift_and_reproduces_entire_tree': True,
    'committed_lock_unchanged': True,
    'global_root_refused_without_writing_packages': True,
}
(evidence / 'pi-install-behavior.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
