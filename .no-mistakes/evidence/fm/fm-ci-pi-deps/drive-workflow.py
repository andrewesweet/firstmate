import json, os, pathlib, subprocess
root = pathlib.Path.cwd()
world = root / '.test-live-ci-pi'
evidence = pathlib.Path('~/.no-mistakes/evidence/01M53Q0RK2MPN19NNQ90V2JFV1')
# Workflow is a machine-consumed declarative contract: parse YAML semantically.
parsed = subprocess.check_output(['ruby', '-ryaml', '-rjson', '-e', 'puts JSON.generate(YAML.load_file(ARGV[0]).fetch("jobs"))', '.github/workflows/ci.yml'], text=True)
jobs = json.loads(parsed)
with (evidence / 'workflow-install-consumers.log').open('w') as log:
    for key in ['tests-portable-parallel-1', 'tests-portable-serial']:
        job = jobs[key]
        steps = job['steps']
        install = next(step for step in steps if step.get('name') == 'Install the pinned reproducible Pi package set')
        consumer = next(step for step in steps if step.get('name', '').startswith('Run portable '))
        runner_temp = world / ('workflow-' + key)
        runner_temp.mkdir()
        github_path = runner_temp / 'github-path'
        env = dict(os.environ, RUNNER_TEMP=str(runner_temp), GITHUB_PATH=str(github_path), TMPDIR=str(world / 'tmp'), npm_config_cache=str(world / 'npm-cache'), PI_CODING_AGENT_DIR=str(world / 'agent'))
        for name in ['FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE']:
            env.pop(name, None)
        log.write(f'job={key}\n$ {install["run"]}\n')
        log.flush()
        subprocess.run(['bash', '-e', '-c', install['run']], cwd=root, env=env, stdout=log, stderr=log, check=True, timeout=90)
        additions = github_path.read_text().splitlines()
        assert additions == [str(runner_temp / 'pi/node_modules/.bin')], additions
        env['PATH'] = os.pathsep.join(additions + [env['PATH']])
        selected_package = consumer['env']['FM_PI_PACKAGE_DIR'].replace('${{ runner.temp }}', str(runner_temp))
        env['FM_PI_PACKAGE_DIR'] = selected_package
        assert pathlib.Path(selected_package) == runner_temp / 'pi/node_modules/@earendil-works/pi-coding-agent', selected_package
        probe = '''set -eu
command -v pi
pi --version
node --input-type=module <<'JS'
import { pathToFileURL } from 'node:url';
const pkg = process.env.FM_PI_PACKAGE_DIR;
const loaded = await import(pathToFileURL(`${pkg}/dist/index.js`));
console.log(`FM_PI_PACKAGE_DIR=${pkg}`);
console.log(`runtime imported; ExtensionRunner=${typeof loaded.ExtensionRunner}`);
if (typeof loaded.ExtensionRunner !== 'function') process.exit(1);
JS
'''
        log.write(f'consumer={consumer["name"]}\n$ {probe}\n')
        log.flush()
        subprocess.run(['bash', '-e', '-c', probe], cwd=root, env=env, stdout=log, stderr=log, check=True, timeout=30)
        log.write('Local execution of workflow install and consumer environment succeeded.\n\n')
print('Both portable job definitions install real Pi and resolve/import it through their declared PATH and FM_PI_PACKAGE_DIR.')
