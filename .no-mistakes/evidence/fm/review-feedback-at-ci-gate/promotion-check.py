"""Exercise scout promotion in a marked disposable home, without a worker backend."""
import json
import os
from pathlib import Path
import shutil
import subprocess

os.umask(0o022)
root = Path.cwd()
evidence = Path('~/.no-mistakes/evidence/01M53BPY6P9T8GV7XEW114R9Z0')
home = root / '.no-mistakes/test-ci-feedback/promotion-lab'
env = os.environ.copy()
for name in ['FM_HOME','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','GIT_DIR','GIT_COMMON_DIR','GIT_WORK_TREE','GIT_INDEX_FILE']:
    env.pop(name, None)
env.update(FM_HOME=str(home), FM_CLASSIFY_PAUSED_VERB='holding', TMPDIR=str(root / '.no-mistakes/test-ci-feedback/tmp'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
transcript = []
def run(*args):
    result = subprocess.run(args, cwd=root, env=env, capture_output=True, text=True, timeout=40)
    transcript.append('$ ' + ' '.join(args) + '\n' + result.stdout + result.stderr + f'[exit {result.returncode}]\n')
    assert result.returncode == 0, transcript[-1]
    return result.stdout
try:
    run('bash','bin/fm-lab-home.sh','create',str(home))
    run('bash','bin/fm-brief.sh','promote-ci-feedback','isolated-project','--scout')
    brief = home / 'data/promote-ci-feedback/brief.md'
    brief.write_text(brief.read_text().replace('{TASK}', 'Read CI review feedback while polling.').replace('{FIRSTMATE_SPEC}', 'Validate the generated ship contract.'))
    meta = home / 'state/promote-ci-feedback.meta'
    meta.write_text('window=fm-promote-ci-feedback\nkind=scout\nworktree=' + str(home / 'projects/disposable-worktree') + '\n')
    run('bash','bin/fm-promote.sh','promote-ci-feedback','--mode','no-mistakes','--yolo','off')
    output = (home / 'data/promote-ci-feedback/ship-instructions.md').read_text()
    for phrase in ['At the CI gate, poll about once a minute', '`gh-axi pr view <n> --comments --reviews`', 'processing and acknowledging your Firstmate instruction inbox on each poll', 'when it names one (an already synchronized branch needs none)', '`holding [at=<epoch>] [key=nm-<run>-ci-wait]']:
        assert phrase in output, 'Promoted contract is missing ' + phrase
        assert phrase in brief.read_text(), 'Durable brief is missing ' + phrase
    assert 'kind=ship' in meta.read_text()
    shutil.copyfile(home / 'data/promote-ci-feedback/ship-instructions.md', evidence / 'promoted-ship-instructions.md')
    shutil.copyfile(meta, evidence / 'promoted-task.meta')
    shutil.copyfile(brief, evidence / 'promoted-durable-brief.md')
    results_path = evidence / 'live-brief-results.json'
    results = json.loads(results_path.read_text())
    results.append(dict(name='Promote a scout to a no-mistakes ship: the emitted ship instructions and durable brief carry CI feedback guidance and the custom pause verb', result='pass', live=True, evidence='promoted-ship-instructions.md; promoted-task.meta; promotion-transcript.txt', reason=''))
    results_path.write_text(json.dumps(results, indent=2) + '\n')
    run('bash','bin/fm-lab-home.sh','teardown',str(home))
    print('Promotion emitted the shared CI feedback contract, used holding, changed kind to ship, and appended the same instructions to the durable brief.')
finally:
    (evidence / 'promotion-transcript.txt').write_text('\n'.join(transcript))
    if home.exists():
        shutil.rmtree(home)
