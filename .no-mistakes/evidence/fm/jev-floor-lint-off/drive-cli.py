import os
from pathlib import Path
import subprocess
import shutil

root = Path.cwd()
evidence = Path('/home/cti/.no-mistakes/evidence/01M55Z5RSNFD2ARHGKKBPWWGQ6')
home = root / '.test-phase-tmp' / 'cli-home'
if home.exists():
    shutil.rmtree(home)
home.mkdir(parents=True, exist_ok=True)
env = {k: v for k, v in os.environ.items() if not k.startswith('FM_') and k != 'TYPESAFE_API_KEY'}
env.update(FM_HOME=str(home), TMPDIR=str(root / '.test-phase-tmp'))
transcript = []
def run(args):
    p = subprocess.run(['bash', *args], env=env, text=True, capture_output=True)
    transcript.append('$ FM_HOME=<isolated-worktree-home> bash ' + ' '.join(args) + '\n' + p.stdout + p.stderr + f'exit: {p.returncode}\n')
    assert p.returncode == 0, transcript[-1]
    return p

for mode, forge in [('no-mistakes', 'none'), ('no-mistakes', 'gerrit'), ('no-mistakes', 'forgejo'), ('direct-PR', 'none'), ('local-only', 'none')]:
    task = f'check-{mode.lower()}-{forge}'
    run(['bin/fm-brief.sh', task, 'disposable-example-project', '--mode', mode, '--forge', forge])
    brief = (home / 'data' / task / 'brief.md').read_text()
    assert 'Delivery contract: mode=' + mode in brief
    assert 'fm-jev-lint' not in brief
    if mode == 'no-mistakes':
        assert 'before starting validation' in brief
        assert 'When your implementation is committed' in brief
    (evidence / f'{task}-brief.md').write_text(brief)
    transcript.append(f'Generated public brief {task}: correct delivery contract; no advisory Jev self-check instruction.\n')

p = run(['bin/fm-dispatch-resolve.sh', str(home / 'data/check-no-mistakes-none/brief.md')])
assert p.stdout == '' and p.stderr.startswith('dispatch-resolve: off (TYPESAFE_API_KEY absent')
assert not (home / 'data/dispatch-resolve.jsonl').exists()
transcript.append('Resolver is off without TYPESAFE_API_KEY; no outcome record created. Real Jev confidence scenarios require that credential.\n')

p = run(['bin/fm-dispatch-resolve-score.sh'])
assert 'floor=0.5 *' in p.stdout and 'floor=0.6 *' not in p.stdout
transcript.append('Replay report identifies 0.5 as the active floor on a new, empty home. Populated-log arithmetic is tested separately with fixtures.\n')

p = run(['bin/fm-jev-lint.sh', 'check'])
assert not p.stdout and not p.stderr
assert not (home / 'data/jev-lint.jsonl').exists()
transcript.append('Optional self-check still executes and silently skips without a key, without creating or altering a record.\n')
p = run(['bin/fm-jev-lint.sh', 'score'])
assert 'no record at' in p.stdout
transcript.append('Retained record scorer is callable. Finding recording/resolution uses controlled-response tests; no live Jev request was possible.\n')
(evidence / 'cli-transcript.txt').write_text('\n'.join(transcript))
print('\n'.join(transcript))
