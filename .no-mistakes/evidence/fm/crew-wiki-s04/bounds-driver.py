"""Fixed-bound live checks through real CLI and real key-absent Jev shim.
Oracle: accepted 25-lesson, 8-candidate, 200-pair constants; overrides removed.
"""
import os, pathlib, subprocess, shutil, json
R=pathlib.Path.cwd();E=pathlib.Path('~/.no-mistakes/evidence/01M6FN5J98JQ4133ZM3GFVC7WX');S=R/'.live-validation/bounds';S.mkdir(parents=True)
h=S/'home';repo=S/'wiki'
for d in [h/'config',h/'state',h/'data',h/'user',repo/'pages/tools',repo/'raw/2026/11']:d.mkdir(parents=True)
(h/'config/wiki').write_text('role=gardener\nremote=file://'+str(S/'unused.git')+'\n')
e=os.environ.copy()
for k in ['TYPESAFE_API_KEY','FM_WIKI_JEV','FM_ROOT_OVERRIDE','TS_BASE','TS_TIMEOUT']:e.pop(k,None)
e.update(FM_HOME=str(h),FM_STATE_OVERRIDE=str(h/'state'),FM_DATA_OVERRIDE=str(h/'data'),FM_CONFIG_OVERRIDE=str(h/'config'),FM_PROJECTS_OVERRIDE=str(h/'projects'),HOME=str(h/'user'),TMPDIR=str(R/'.live-validation/tmp'))
log=(E/'bounds-cli.txt').open('w')
def show(s):print(s,flush=True);log.write(s+'\n');log.flush()
def run(*args,on=False,ok=True):
    ee=e.copy()
    if on:ee.update(FM_WIKI_JEV=str(R/'bin/fm-branch-shadow-jev.sh'),FM_WIKI_JEV_PAIRS_CAP='1000',FM_WIKI_JEV_CANDIDATES='1000')
    p=subprocess.run([str(R/'bin/fm-wiki.sh'),*args],env=ee,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=400)
    show('$ bin/fm-wiki.sh '+' '.join(args).replace(str(S),'$LAB')+'\n'+p.stdout+'[exit %d]'%p.returncode)
    if ok:assert p.returncode==0
    return p
try:
    seed='raw/2026/11/20261101T000000Z-bound-seed.md';(repo/seed).write_text('## Retry seed\nscope: tool:retry\nclaim: Retry reads after transient failure.\nevidence: synthetic check\n')
    for i in range(21):
        (repo/'pages/tools'/f'retry-{i:02d}.md').write_text(f'> summary: Retry reads after transient failure\n> scope: tool:retry\n> last-confirmed: 2026-11-03\n> sources: {seed}\n\n# Retry {i}\n\nRetry reads after transient failure ([lesson](../../{seed})).\n')
    (repo/'index.md').write_text('# Wiki\n'+'\n'.join(f'- [Retry](pages/tools/retry-{i:02d}.md)' for i in range(21))+'\n')
    (repo/'log.md').write_text('## [2026-11-01] ingest | 20261101T000000Z-bound-seed\n')
    expected=[]
    for i in range(30):
        id=f'20261102T00{i:02d}00Z-bound-pending';expected.append(id)
        (repo/'raw/2026/11'/f'{id}.md').write_text('## Retry guidance\nscope: tool:retry\nclaim: Retry reads after transient failure.\nevidence: synthetic check\n')
    run('triage','--repo',str(repo))
    p=json.loads((h/'data/gardener/plan.json').read_text())
    assert [l['id'] for l in p['lessons']]==expected[:25]
    assert all(len(l['candidates'])==8 for l in p['lessons'])
    assert not (h/'state/wiki/jev.jsonl').exists()
    run('triage','--repo',str(repo),'--limit','100',ok=False)
    rejected=run('triage','--repo',str(repo),'--limit','100',ok=False);assert rejected.returncode==2
    show('30 pending lessons produced the oldest 25 in order, each with 8 candidates; --limit 100 was rejected.')
    (h/'config/wiki').write_text((h/'config/wiki').read_text()+'jev=off\n')
    run('triage','--repo',str(repo),on=True)
    off=json.loads((h/'data/gardener/plan.json').read_text())
    assert [l['id'] for l in off['lessons']]==expected[:25] and all(l['jev'] is None for l in off['lessons'])
    assert not (h/'state/wiki/jev.jsonl').exists()
    show('Home opt-out ignored the configured real shim for all 25 pending lessons; no Jev records.')
    shutil.copyfile(h/'data/gardener/plan.json',E/'bounded-off-plan.json')
    (h/'config/wiki').write_text((h/'config/wiki').read_text().replace('jev=off\n',''))
    # 21 same-scope pages yield independently 21*20/2 = 210 pairs. All
    # requests run through the genuine shim with no key in the isolated home.
    r=run('lint','--repo',str(repo),on=True)
    records=[json.loads(l) for l in (h/'state/wiki/jev.jsonl').read_text().splitlines()]
    assert len(records)==200 and all(x['verb']=='contradicts' and not x['ok'] for x in records)
    assert 'jev contradiction candidates capped at 200 pairs this run' in r.stdout
    show('21 pages, 210 possible same-scope pairs; genuine shim recorded exactly 200 unavailable answers; lint stayed clean despite FM_WIKI_JEV_PAIRS_CAP=1000.')
    shutil.copyfile(h/'state/wiki/jev.jsonl',E/'capped-jev.jsonl')
    (E/'bounds-results.json').write_text(json.dumps([dict(name='Thirty pending lessons keep oldest-first order, stop at 25, cap candidates at eight and reject --limit',result='pass',live=True,evidence='bounds-cli.txt; bounded-off-plan.json',reason=''),dict(name='Twenty-one same-scope pages stop at 200 advisory pairs despite a larger obsolete override',result='pass',live=True,evidence='bounds-cli.txt; capped-jev.jsonl',reason='')],indent=2)+'\n')
finally:
    log.close();shutil.rmtree(S)
