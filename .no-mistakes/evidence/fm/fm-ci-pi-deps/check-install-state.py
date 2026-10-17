import hashlib, json, os, pathlib, subprocess
root = pathlib.Path.cwd()
world = root / '.test-live-ci-pi'
evidence = pathlib.Path('~/.no-mistakes/evidence/01M53Q0RK2MPN19NNQ90V2JFV1')
scoped = ['chord', 'pi-agent-core', 'pi-ai', 'pi-codemode', 'pi-coding-agent', 'pi-mcp', 'pi-telemetry', 'pi-tui']
inventories = []
for name in ['pinned-a', 'pinned-b']:
    install = world / name
    lock = json.loads((install / 'node_modules/.package-lock.json').read_text())
    actual = {}
    for relative in lock['packages']:
        package = json.loads((install / relative / 'package.json').read_text())
        actual[relative] = {'name': package['name'], 'version': package['version']}
    for name in scoped:
        assert actual[f'node_modules/@earendil-works/{name}']['version'] == '1.0.4'
    inventories.append(actual)
    cp = subprocess.run([str(install / 'node_modules/.bin/pi'), '--version'], capture_output=True, text=True, check=True)
    assert cp.stdout.strip() == '1.0.4', cp
    (evidence / (install.name + '-inventory.json')).write_text(json.dumps(actual, indent=2, sort_keys=True) + '\n')
    print(f'{install.name}: pi --version -> {cp.stdout.strip()}; {len(actual)} installed package versions inspected')
assert inventories[0] == inventories[1]
print('Two fresh destinations have identical installed dependency-version inventories.')
for name in scoped:
    print(f'@earendil-works/{name}=1.0.4')
# npm itself resolves a disposable global root. No production prefix is selected.
env = dict(os.environ, npm_config_prefix=str(world / 'isolated-global'), npm_config_cache=str(world / 'npm-cache'), TMPDIR=str(world / 'tmp'))
global_root = pathlib.Path(subprocess.check_output(['npm', 'root', '-g'], env=env, text=True).strip())
assert global_root.is_relative_to(world)
cp = subprocess.run(['bin/fm-install-pi.sh', str(global_root)], env=env, capture_output=True, text=True)
print('$ npm_config_prefix=<disposable-prefix> bin/fm-install-pi.sh "$(npm root -g)"')
print(cp.stdout + cp.stderr, end='')
print(f'process_exit={cp.returncode}')
assert cp.returncode == 1 and 'refusing to install into the global npm root' in cp.stderr, cp
assert not (global_root / 'package.json').exists() and not (global_root / 'package-lock.json').exists()
assert not (global_root / 'node_modules').exists()
print('Refusal leaves destination free of manifests and installed dependencies.')
