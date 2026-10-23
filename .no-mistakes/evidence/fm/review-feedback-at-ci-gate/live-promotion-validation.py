"""Promote disposable recorded scouts through the real CLI and inspect its output."""
from pathlib import Path
import os
import shutil
import subprocess

root = Path.cwd()
evidence = Path('~/.no-mistakes/evidence/01M5NDG7A89JX5FJNB7V36WM66')
base_env = {k: v for k, v in os.environ.items() if not k.startswith('FM_')}
base_env['TMPDIR'] = str(root / '.test-phase-tmp')
log = []
for label, verb in [('default', None), ('configured', 'holding')]:
    home = root / '.test-phase-tmp' / f'fm-lab-promotion-{label}'
    env = dict(base_env, FM_HOME=str(home))
    if verb:
        env['FM_CLASSIFY_PAUSED_VERB'] = verb
    try:
        for command in [['bin/fm-lab-home.sh', 'create', str(home)]]:
            result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=20)
            log.append(f'$ {" ".join(command)}\n{result.stdout}{result.stderr}')
            assert result.returncode == 0, log[-1]
        task = f'promote-{label}'
        data = home / 'data' / task
        data.mkdir()
        (data / 'brief.md').write_text("# Task\n## Captain's intent\nRead and route PR feedback before done.\n\n## Firstmate spec\nKeep existing delivery boundaries.\n")
        (home / 'state' / f'{task}.meta').write_text(f'window=fm-{task}\nkind=scout\nworktree={root}\n')
        command = ['bin/fm-promote.sh', task, '--mode', 'no-mistakes', '--yolo', 'off']
        result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=30)
        log.append(f'$ FM_HOME={home} {" ".join(command)}\nexit={result.returncode}\n{result.stdout}{result.stderr}')
        assert result.returncode == 0, log[-1]
        instructions = (data / 'ship-instructions.md').read_text()
        assert 'Every poll reads the PR itself' in instructions
        assert 'no-mistakes axi respond --action fix' in instructions
        assert f'{verb or "paused"} [at=<epoch>] [key=nm-<run>-ci-wait]' in instructions
        metadata = (home / 'state' / f'{task}.meta').read_text()
        assert 'kind=ship\n' in metadata
        assert 'mode=no-mistakes\n' in metadata
        relaunch = (data / 'brief.md').read_text()
        assert 'Every poll reads the PR itself' in relaunch
        assert 'no-mistakes axi respond --action fix' in relaunch
        assert f'{verb or "paused"} [at=<epoch>] [key=nm-<run>-ci-wait]' in relaunch
        (evidence / f'promoted-{label}-instructions.md').write_text(instructions)
        (evidence / f'promoted-{label}-metadata.txt').write_text(metadata)
        log.append(f'PASS {label}: real promotion persists ship contract, feedback routing, {verb or "paused"} verb, and relaunch instructions.\n')
    finally:
        (evidence / 'live-promotion-transcript.log').write_text('\n'.join(log))
        shutil.rmtree(home, ignore_errors=True)
print('\n'.join(line for line in log if line.startswith('PASS')))
