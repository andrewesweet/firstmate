#!/usr/bin/env python3
"""Drive real inheritance, briefs, capture, drain and consult against disposable Git repositories.
Oracle: docs/configuration.md crew-wiki policy and the supplied author intent.
Rejects inherited gardener/host stamps, missing brief contracts, dropped lessons,
unproven publication, missing consult data, destructive inactive inheritance,
and receiver corruption. No implementation-source assertions or agent fakes.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path.cwd()
EVIDENCE = Path('~/.no-mistakes/evidence/01M5WZCZRG3KA8DZ7CFB1NDK3P')
fixture = Path(tempfile.mkdtemp(prefix='.wiki-live-', dir=ROOT))
env = os.environ.copy()
for key in list(env):
    if key.startswith(('FM_', 'GIT_', 'TASKS_AXI_')) or key in ('TMUX', 'HERDR_ENV'):
        env.pop(key, None)
env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           GIT_AUTHOR_NAME='Wiki live validation', GIT_AUTHOR_EMAIL='wiki@example.test',
           GIT_COMMITTER_NAME='Wiki live validation', GIT_COMMITTER_EMAIL='wiki@example.test',
           HOME=str(fixture / 'account'), TMPDIR=str(fixture / 'tmp'))
(fixture / 'account').mkdir()
(fixture / 'tmp').mkdir()

def run(args, home=None, data=None, check=True, extra=None, show=True):
    e = env.copy()
    if home:
        e.update(FM_HOME=str(home), FM_CONFIG_OVERRIDE=str(home/'config'),
                 FM_DATA_OVERRIDE=str(home/'data'), FM_STATE_OVERRIDE=str(home/'state'),
                 FM_PROJECTS_OVERRIDE=str(home/'projects'), FM_ROOT_OVERRIDE=str(ROOT))
    if extra:
        e.update(extra)
    p = subprocess.run([str(a) for a in args], env=e, input=data, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=50)
    if show:
        print('$ ' + ' '.join(str(a) for a in args), flush=True)
        if p.stdout: print(p.stdout.rstrip(), flush=True)
        if p.stderr: print('stderr: ' + p.stderr.rstrip(), flush=True)
    if check and p.returncode:
        raise RuntimeError(f'command exited {p.returncode}: {p.stdout}\n{p.stderr}')
    return p

def home(name):
    h = fixture / name
    for part in ('config', 'state', 'data', 'projects'):
        (h/part).mkdir(parents=True, exist_ok=True)
    run(['git','init','-q','-b','main',h], show=False)
    (h/'.gitignore').write_text('config/\nstate/\ndata/\nprojects/\n.fm-*\n')
    run(['git','-C',h,'add','.gitignore'], show=False)
    run(['git','-C',h,'commit','-qm','Isolated validation home'], show=False)
    return h

def inherit(parent, child, show=True):
    # Invoke the real shared propagation API used by launch/bootstrap/config-push.
    return run(['bash','-c','. "$1/bin/fm-config-inherit-lib.sh"; propagate_secondmate_inheritance "$2" "$3"',
                'inherit',ROOT,parent,child], home=parent, show=show)

def config(h):
    return dict(line.split('=',1) for line in (h/'config/wiki').read_text().splitlines() if '=' in line)

def wiki(h, *args, **kwargs):
    return run([ROOT/'bin/fm-wiki.sh',*args], home=h, **kwargs)

try:
    parent = home('parent')
    child = home('child')
    remote = fixture/'wiki.git'
    run(['git','init','-q','--bare','-b','main',remote])
    for role in ('gardener','reader','contributor'):
        (parent/'config/wiki').write_text(f'host=parent-stamp-must-not-leak\nremote=file://{remote}\nrole={role}\njev=on\n')
        inherit(parent, child)
        assert config(child) == {'remote':f'file://{remote}','role':'contributor','jev':'on'}
        print(f'Observed parent {role}: child config = {json.dumps(config(child),sort_keys=True)}')
    before = (child/'config/wiki').stat().st_mtime_ns
    inherit(parent, child)
    assert (child/'config/wiki').stat().st_mtime_ns == before
    print('Observed unchanged propagation preserves file mtime.')
    (child/'config/wiki').write_text('remote=file:///wrong-remote.git\nrole=reader\nhost=wrong-host\n')
    inherit(parent, child)
    assert config(child) == {'remote':f'file://{remote}','role':'contributor','jev':'on'}
    print('Observed divergent child converges to primary remote and contributor role.')

    project = child/'projects/demo'
    run(['git','init','-q','-b','main',project], show=False)
    (project/'README.md').write_text('Disposable project for emitted brief validation.\n')
    run(['git','-C',project,'add','.'], show=False)
    run(['git','-C',project,'commit','-qm','Seed demo'], show=False)
    for task, options in [('ship-proof',['--mode','local-only']),('scout-proof',['--scout'])]:
        run([ROOT/'bin/fm-brief.sh',task,'demo',*options],home=child)
        brief = child/f'data/{task}/brief.md'
        text = brief.read_text()
        # The emitted task brief is an intentional public generated prompt contract.
        assert f'data/{task}/lessons.md' in text
        assert 'nothing-to-teach' in text
        assert 'crew-wiki mirror lives at' in text
        assert str(child/'state/wiki/mirror') in text
        shutil.copyfile(brief,EVIDENCE/f'{task}-brief.md')
        print(f'Observed emitted {task} brief: task-specific lesson path and local mirror consult contract.')
    for task, kind in [('ship-proof','ship'),('scout-proof','scout')]:
        (child/f'state/{task}.meta').write_text(f'kind={kind}\nharness=codex\nmodel=validation\nproject={project}\n')
        (child/f'state/{task}.status').write_text('done [at=1]: report complete\n')
        (child/f'data/{task}/lessons.md').write_text(
            f'## Preserve wiki lessons from {kind} cleanup\n'
            'scope: tool:firstmate\n'
            'claim: A child home captures lessons before task status is retired.\n\n'
            f'evidence: Live {kind} cleanup-boundary capture in an isolated child home.\n')
        wiki(child,'close',task,extra={'FM_WIKI_CLOSE_DRAIN':'0'})
    queued = sorted((child/'state/wiki/outbox').glob('*.md'))
    assert len(queued) == 2
    print('Observed two clean captured lessons in child outbox before publication.')
    wiki(child,'drain')
    paths = run(['git','-C',remote,'ls-tree','-r','--name-only','main']).stdout.splitlines()
    assert len(paths) == 2 and all(p.startswith('raw/') for p in paths)
    assert not list((child/'state/wiki/outbox').glob('*.md'))
    bodies = []
    for p in paths:
        body = run(['git','-C',remote,'show',f'main:{p}']).stdout
        bodies.append(body)
        assert 'wiki-final: done' in body
        assert 'wiki-host: parent-stamp-must-not-leak' not in body
        consulted = wiki(child,'consult','cat',p).stdout
        assert consulted == body
    assert any('wiki-task: ship-proof' in b for b in bodies)
    assert any('wiki-task: scout-proof' in b for b in bodies)
    (EVIDENCE/'published-lessons.md').write_text('\n\n'.join(bodies))
    run(['git','-C',remote,'log','-1','--format=full'])
    print('Observed both tasks landed in real Git remote; outbox retired only after landing; consult returns exact remote blobs.')

    # Missing write access/offline remote must retain captured data until recoverable.
    blocked_remote = fixture/'not-yet-provisioned.git'
    (parent/'config/wiki').write_text(f'role=gardener\nremote=file://{blocked_remote}\n')
    inherit(parent,child)
    task = 'offline-proof'
    (child/f'data/{task}').mkdir()
    (child/f'data/{task}/lessons.md').write_text('## Keep pending lessons\nscope: tool:firstmate\nclaim: Retry publication after the remote is available.\n\nevidence: Isolated unavailable-remote check.\n')
    (child/f'state/{task}.meta').write_text(f'kind=ship\nharness=codex\nproject={project}\n')
    (child/f'state/{task}.status').write_text('done [at=1]: complete\n')
    wiki(child,'close',task,extra={'FM_WIKI_CLOSE_DRAIN':'0'})
    pending = list((child/'state/wiki/outbox').glob('*.md'))
    assert len(pending) == 1
    saved = pending[0].read_bytes()
    wiki(child,'drain')
    assert pending[0].read_bytes() == saved
    print('Observed unavailable remote preserves exact queued lesson bytes.')
    run(['git','init','-q','--bare','-b','main',blocked_remote])
    wiki(child,'drain')
    assert not pending[0].exists()
    assert run(['git','-C',blocked_remote,'ls-tree','-r','--name-only','main']).stdout.startswith('raw/')
    print('Observed later drain publishes retained lesson after remote becomes available.')

    stable = (child/'config/wiki').read_bytes()
    fresh = home('fresh')
    for mode in ('absent','off','unknown','missing-role','directory'):
        p = parent/'config/wiki'
        if p.is_dir(): p.rmdir()
        elif p.exists(): p.unlink()
        if mode == 'directory': p.mkdir()
        elif mode != 'absent':
            role_line = '' if mode == 'missing-role' else f'role={"off" if mode == "off" else "emperor"}\n'
            p.write_text(f'remote=file://{remote}\n{role_line}')
        inherit(parent,child)
        inherit(parent,fresh)
        assert (child/'config/wiki').read_bytes() == stable
        assert not (fresh/'config/wiki').exists()
        print(f'Observed {mode} primary: existing child bytes preserved; fresh child stays unconfigured.')

    # Execute the real remote receiver, including transport-integrity and path guards.
    receiver = home('remote-child')
    payload = f'remote=file://{remote}\nrole=contributor\njev=on\n'
    digest = hashlib.sha256(payload.encode()).hexdigest()
    run([ROOT/'bin/fm-remote-inherit.sh','put','config/wiki',len(payload.encode()),digest,1],home=receiver,data=payload)
    assert (receiver/'config/wiki').read_text() == payload
    old = (receiver/'config/wiki').read_bytes()
    bad = run([ROOT/'bin/fm-remote-inherit.sh','put','config/wiki',len(payload.encode()),'0'*64,2],home=receiver,data=payload,check=False)
    assert bad.returncode != 0 and (receiver/'config/wiki').read_bytes() == old
    bad = run([ROOT/'bin/fm-remote-inherit.sh','put','../escape',len(payload.encode()),digest,3],home=receiver,data=payload,check=False)
    assert bad.returncode != 0 and not (fixture/'escape').exists()
    wiki(receiver,'drain')
    first_path = paths[0]
    result = wiki(receiver,'consult','cat',first_path).stdout
    assert result in bodies
    print('Observed real remote receiver accepts wiki, rejects corrupted/traversal payloads without overwriting, and activates mirror consultation.')
    print('LIVE SCENARIOS COMPLETED')
finally:
    shutil.rmtree(fixture)
    print('Disposable homes and Git repositories removed.',flush=True)
