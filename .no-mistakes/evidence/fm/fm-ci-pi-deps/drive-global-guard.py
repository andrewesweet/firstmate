"""Attack the installer's global-state boundary using a real disposable npm prefix."""
import json
import os
from pathlib import Path
import subprocess

root = Path.cwd()
work = root / '.pi-ci-validation'
evidence = Path('~/.no-mistakes/evidence/01M53Q0RK2MPN19NNQ90V2JFV1')
prefix = work / 'guard-global'
global_root = prefix / 'lib/node_modules'
sentinel = global_root / 'pre-existing-global-package/package.json'
sentinel.parent.mkdir(parents=True)
sentinel.write_text('{"name":"pre-existing-global-package","version":"1.0.0"}\n')
environment = dict(os.environ, TMPDIR=str(work / 'tmp'), PI_CODING_AGENT_DIR=str(work / 'pi-config'), npm_config_cache=str(work / 'npm-cache'), npm_config_userconfig=str(work / 'npm-user.conf'), npm_config_globalconfig=str(work / 'npm-global.conf'), npm_config_prefix=str(prefix))
actual_root = subprocess.check_output(['npm', 'root', '-g'], env=environment, text=True).strip()
assert actual_root == str(global_root)
records = []
for label, destination in [('exact-global-root', global_root), ('parent-of-global-root', global_root.parent)]:
    proc = subprocess.run(['bin/fm-install-pi.sh', str(destination)], cwd=root, env=environment, capture_output=True, text=True, timeout=120)
    (evidence / f'pi-guard-{label}.log').write_text(f'npm root -g: {actual_root}\nDestination: {destination}\nPre-existing global package existed before: true\n' + proc.stdout + proc.stderr + f'\nInstaller exit: {proc.returncode}\nPre-existing global package survives: {sentinel.exists()}\n')
    records.append({'destination': label, 'installer_exit': proc.returncode, 'pre_existing_global_package_survives': sentinel.exists()})
report = {'oracle': 'Installer header promises the host global npm install is shared state this helper never touches', 'isolated_npm_global_root': actual_root, 'results': records}
(evidence / 'pi-global-guard-behavior.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
