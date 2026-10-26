"""Drive real Firstmate CLIs and installed no-mistakes reader over disposable data.
Oracle: interrupted CI monitoring is terminal, does not imply checks passed,
and must not consume executing-work capacity; unknown states stay fail-safe.
No pipeline is initialized, started, controlled, or pushed. No CLI is mocked.
"""
import os
from pathlib import Path
import sqlite3
import subprocess
import time

root = Path.cwd()
lab = root / '.test-ci-interrupted/live'
lab.mkdir(parents=True)
env = os.environ.copy()
for key in list(env):
    if key.startswith(('FM_', 'GIT_')):
        env.pop(key)
for key, child in [('HOME','home'), ('NM_HOME','nm'), ('XDG_CONFIG_HOME','config'), ('XDG_RUNTIME_DIR','runtime'), ('TMPDIR','tmp'), ('FM_HOME','fleet')]:
    env[key] = str(lab / child)
    Path(env[key]).mkdir()
env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='Validation fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid', GIT_COMMITTER_NAME='Validation fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid')
repo = lab / 'repo'
repo.mkdir()

def run(args, cwd=repo, expected=0):
    print('$ ' + ' '.join(map(str, args)), flush=True)
    p = subprocess.run(list(map(str, args)), cwd=cwd, env=env, text=True, capture_output=True, timeout=45)
    print(p.stdout + p.stderr, end='')
    print('exit:', p.returncode, flush=True)
    assert p.returncode == expected, (args, p.returncode, expected)
    return p.stdout + p.stderr

run(['git', 'init', '-q', '-b', 'fm/interrupted'])
run(['git', 'commit', '-q', '--allow-empty', '-m', 'fixture'])
head = run(['git', 'rev-parse', 'HEAD']).strip()
# Read-only public CLI builds its own actual store schema, without init.
run(['no-mistakes', 'axi', 'status'], expected=1)
db = sqlite3.connect(lab / 'nm/state.sqlite')
now = int(time.time())
db.execute('INSERT INTO repos (id,working_path,upstream_url,created_at) VALUES (?,?,?,?)', ('fixture', str(repo), 'https://example.invalid/fixture/repo.git', now))

def add_run(rid, status, offset=0, branch='fm/interrupted', steps=None):
    db.execute('INSERT INTO runs (id,repo_id,branch,head_sha,base_sha,status,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?)', (rid, 'fixture', branch, head, head, status, now+offset, now+offset))
    if steps is None:
        steps = [(s, 'skipped' if s == 'ci' else 'completed') for s in ['intent','rebase','review','test','document','lint','push','pr','ci']]
    for order, (name, state) in enumerate(steps):
        db.execute('INSERT INTO step_results (id,run_id,step_name,step_order,status) VALUES (?,?,?,?,?)', (rid+'-'+name, rid, name, order, state))
    db.commit()

for i in range(5):
    add_run('INTERRUPTED-'+str(i+1), 'ci_monitor_interrupted', i)
state = lab / 'fleet/state'
state.mkdir()
(state / 'interrupted.meta').write_text('kind=ship\nworktree='+str(repo)+'\n')
# Run base scripts with the same public inputs and actual dependencies.
basebin = lab / 'basebin'
basebin.mkdir()
changed = {'fm-nm-run-lib.sh', 'fm-crew-state.sh'}
for source in (root/'bin').iterdir():
    if source.name not in changed:
        (basebin/source.name).symlink_to(source)
for name in changed:
    content = subprocess.check_output(['git','show','68d0d4ce1babf6bef1ff49526469ab4cd8b0adac:bin/'+name], cwd=root)
    (basebin/name).write_bytes(content)
    (basebin/name).chmod(0o755)
# slot must reside beside the old library, rather than resolving a symlink.
(basebin/'fm-nm-slot.sh').unlink()
(basebin/'fm-nm-slot.sh').write_bytes((root/'bin/fm-nm-slot.sh').read_bytes())
(basebin/'fm-nm-slot.sh').chmod(0o755)
slot = root/'bin/fm-nm-slot.sh'
crew = root/'bin/fm-crew-state.sh'
wrapped = ['/usr/bin/printf', 'validation start admitted\\n']

def admitted():
    assert 'validation start admitted' in run([slot, *wrapped])

def waiting(count):
    out = run([slot, *wrapped], expected=75)
    assert f'{count} counted' in out and 'INTERRUPTED-' not in out
    assert 'validation start admitted' not in out
    return out

print('\n=== Incident reproduction and root-cause counterfactual ===')
run(['no-mistakes', '--version'])
run(['no-mistakes', 'axi', 'status'])
run(['no-mistakes', 'axi'])
run(['no-mistakes', 'runs'])
old = run([basebin/'fm-nm-slot.sh', *wrapped], expected=75)
assert '5 counted' in old and 'INTERRUPTED-1' in old
old = run([basebin/'fm-crew-state.sh', 'interrupted'])
assert 'state: unknown' in old
admitted()
out = run([crew, 'interrupted'])
assert 'state: done' in out and 'ci monitor interrupted (PR state unknown)' in out
assert 'passed' not in out and 'green' not in out

print('\n=== PR unavailable: terminal status remains honest and preserves identity ===')
# The explicit no-forge mode is a public product feature, not a fake CLI.
db.execute("UPDATE runs SET pr_url='https://github.com/example/fixture/pull/205'")
db.commit()
env['FM_CREW_STATE_NO_FORGE'] = '1'
run(['no-mistakes', 'axi', 'status', '--run', 'INTERRUPTED-5'])
out = run([crew, 'interrupted'])
assert 'state: done' in out and 'PR state unknown' in out and '/pull/205' in out
assert 'passed' not in out and 'green' not in out

print('\n=== Capacity guard: interrupted history plus actual executing work ===')
for i in range(2):
    add_run('EXECUTING-'+str(i+1), 'running', 10+i, branch='fm/other-'+str(i), steps=[('test', 'running')])
admitted()
add_run('EXECUTING-3', 'running', 12, branch='fm/other-2', steps=[('test','running')])
out = waiting(3)
assert all('EXECUTING-'+str(i) in out for i in range(1,4))
db.execute("DELETE FROM step_results WHERE run_id LIKE 'EXECUTING-%'")
db.execute("DELETE FROM runs WHERE id LIKE 'EXECUTING-%'")
db.commit()

print('\n=== Unknown future status is never silently freed or marked done ===')
for i in range(3):
    add_run('UNKNOWN-'+str(i+1), 'quiescing', 20+i, steps=[('review', 'running')])
waiting(3)
out = run([crew, 'interrupted'])
assert 'state: unknown' in out and 'unrecognized run status' in out
# Remove unknown records to verify later scenarios independently.
db.execute("DELETE FROM step_results WHERE run_id LIKE 'UNKNOWN-%'")
db.execute("DELETE FROM runs WHERE id LIKE 'UNKNOWN-%'")
db.commit()

print('\n=== New executing replacement outranks old interrupted run ===')
add_run('REPLACEMENT', 'running', 30, steps=[('review','running')])
out = run([crew, 'interrupted'])
assert 'state: working' in out and 'REPLACEMENT' in out and 'interrupted' not in out
db.execute("DELETE FROM step_results WHERE run_id='REPLACEMENT'")
db.execute("DELETE FROM runs WHERE id='REPLACEMENT'")
db.commit()

print('\n=== Reused branch with new local work is not falsely completed ===')
run(['git','commit','-q','--allow-empty','-m','new local work'])
out = run([crew, 'interrupted'])
assert 'state: done' not in out
print('\nAll public-interface assertions passed. Fixtures contain no real operator data.')
db.close()
