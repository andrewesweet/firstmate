"""Run the real pinned installer and npm against disposable workspace state.
Oracle: locked Pi scope versions are 1.2.0, public entry imports successfully,
reinstallation restores the same tree, and shared global packages never change.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess

root = Path.cwd()
work = root / '.pi-ci-validation'
evidence = Path('~/.no-mistakes/evidence/01M53Q0RK2MPN19NNQ90V2JFV1/round3')
env = dict(os.environ, HOME=str(work/'home'), TMPDIR=str(work/'tmp'),
    PI_CODING_AGENT_DIR=str(work/'pi-config'), PI_OFFLINE='1',
    npm_config_prefix=str(work/'global'), npm_config_cache=str(work/'npm-cache'),
    npm_config_userconfig=str(work/'npm-user.conf'), npm_config_globalconfig=str(work/'npm-global.conf'))

def run(args, name, environment=env):
    proc = subprocess.run(args, cwd=root, env=environment, capture_output=True, text=True, timeout=240)
    (evidence/name).write_text('$ '+' '.join(args)+'\n'+proc.stdout+proc.stderr+f'\nexit={proc.returncode}\n')
    return proc

def inventory(prefix, label):
    proc = run(['npm','ls','--prefix',str(prefix),'--all','--json'],label)
    assert proc.returncode == 0, proc.stderr
    return json.loads(proc.stdout)

def scope(tree, found=None):
    found = {} if found is None else found
    for name, package in tree.get('dependencies',{}).items():
        if name.startswith('@earendil-works/'):
            found.setdefault(name,set()).add(package['version'])
        scope(package,found)
    return found

lock = root/'etc/ci-pi/package-lock.json'
original_hash = hashlib.sha256(lock.read_bytes()).hexdigest()
pinned=work/'pinned'
first=run(['bash','bin/fm-install-pi.sh',str(pinned)],'install-fresh.log')
assert first.returncode == 0, first.stdout+first.stderr
initial=inventory(pinned,'installed-tree.log')
versions=scope(initial)
assert len(versions)==7 and all(v=={'1.2.0'} for v in versions.values()),versions
version=run([str(pinned/'node_modules/.bin/pi'),'--version'],'pi-version.log')
assert version.returncode==0 and version.stdout.strip()=='1.2.0',version.stdout
entry=(pinned/'node_modules/@earendil-works/pi-coding-agent/dist/index.js').as_uri()
probe=f'const pi = await import({json.dumps(entry)}); console.log("Public Pi runtime imported; exports=" + Object.keys(pi).length);'
assert run(['node','--input-type=module','-e',probe],'runtime-import.log').returncode==0
package=pinned/'node_modules/@earendil-works/pi-codemode/package.json'
drift=json.loads(package.read_text()); drift['version']='999.0.0'; package.write_text(json.dumps(drift))
extraneous=pinned/'node_modules/unlocked-sentinel'
extraneous.mkdir(); (extraneous/'package.json').write_text('{"name":"unlocked-sentinel","version":"9.9.9"}')
repaired=run(['bash','bin/fm-install-pi.sh',str(pinned)],'install-repair.log')
assert repaired.returncode==0,repaired.stdout+repaired.stderr
assert not extraneous.exists()
assert inventory(pinned,'repaired-tree.log')==initial
assert hashlib.sha256(lock.read_bytes()).hexdigest()==original_hash
assert run(['node','--input-type=module','-e',probe],'repaired-runtime-import.log').returncode==0
report={'fresh_install':{'installer_exit':first.returncode,'version':version.stdout.strip(),'scope_versions':{k:sorted(v) for k,v in versions.items()},'public_runtime_imported':True},'reinstall_repairs_drift_and_removes_extraneous':True,'entire_dependency_tree_reproduced':True,'committed_lock_unchanged':True}
(evidence/'install-behavior.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2),flush=True)

# Adversarial boundary checks use real npm prefix resolution, no npm shim.
results=[]
for case in ['global-root','global-root-parent','symlink-prefix-parent']:
    prefix=work/('guard-'+case)
    actual=prefix/'lib/node_modules'
    sentinel=actual/'pre-existing-global-package/package.json'
    sentinel.parent.mkdir(parents=True)
    expected='{"name":"pre-existing-global-package","version":"1.0.0"}\n'
    sentinel.write_text(expected)
    configured=prefix
    if case=='symlink-prefix-parent':
        configured=work/'alias-global-prefix'
        configured.symlink_to(prefix,target_is_directory=True)
    guard_env=dict(env,npm_config_prefix=str(configured))
    global_root=subprocess.check_output(['npm','root','-g'],env=guard_env,text=True).strip()
    destination=actual if case=='global-root' else actual.parent
    manifest=destination/'package.json'; lockfile=destination/'package-lock.json'
    marker='{"name":"pre-existing-manifest","version":"1.0.0"}\n'
    manifest.write_text(marker); lockfile.write_text(marker)
    proc=run(['bash','bin/fm-install-pi.sh',str(destination)],f'guard-{case}.log',guard_env)
    saved=sentinel.exists() and sentinel.read_text()==expected
    unstaged=manifest.read_text()==marker and lockfile.read_text()==marker
    refused=proc.returncode!=0 and 'refusing to install into the global npm root' in proc.stderr
    item={'case':case,'npm_global_root':global_root,'physical_destination':str(destination),'exit':proc.returncode,'refused':refused,'global_package_preserved':saved,'manifests_preserved':unstaged,'result':'pass' if refused and saved and unstaged else 'fail'}
    results.append(item)
    print(json.dumps(item),flush=True)
(evidence/'global-guard-behavior.json').write_text(json.dumps({'oracle':'The installer promises never to touch global npm shared state, including an existing global prefix named by a symlink.','results':results},indent=2)+'\n')
