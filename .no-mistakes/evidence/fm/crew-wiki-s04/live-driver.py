"""Drive real fm-wiki CLI and TypeSafe shim with disposable synthetic data.
Oracle: supplied user intent and accepted calibration/secret-scan/fixed-cap decisions.
All homes and file:// remotes live below this worktree; never use operator files.
"""
import os, json, subprocess, shutil, pathlib, time, hashlib
ROOT = pathlib.Path.cwd()
E = pathlib.Path('~/.no-mistakes/evidence/01M6FN5J98JQ4133ZM3GFVC7WX')
S = ROOT / '.live-validation/manual'
S.mkdir(parents=True, exist_ok=True)
log = (E/'live-cli.txt').open('w')
results=[]
baseenv=os.environ.copy()
for k in ['FM_WIKI_JEV','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','TS_BASE','TS_TIMEOUT','GIT_CONFIG','GIT_CONFIG_PARAMETERS','GIT_CONFIG_COUNT','GIT_DIR','GIT_WORK_TREE']:
    baseenv.pop(k,None)
baseenv.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_SYSTEM='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Wiki validation',GIT_AUTHOR_EMAIL='wiki@example.test',GIT_COMMITTER_NAME='Wiki validation',GIT_COMMITTER_EMAIL='wiki@example.test',FM_WIKI_CLOSE_DRAIN='0',TMPDIR=str(ROOT/'.live-validation/tmp'))

def out(s):
    print(s, flush=True); log.write(s+'\n'); log.flush()
def cmd(args, env=None, check=True, show=False):
    r=subprocess.run([str(x) for x in args],env=env or baseenv,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=200)
    if show: out('$ '+' '.join(str(a).replace(str(S),'$LAB') for a in args)+'\n'+r.stdout+'[exit %d]'%r.returncode)
    if check and r.returncode: raise AssertionError(r.stdout)
    return r

def home(name, role='gardener', remote=None):
    h=S/name
    for d in ['config','state','data','home','projects']: (h/d).mkdir(parents=True,exist_ok=True)
    (h/'config/wiki').write_text('role='+role+'\nremote=file://'+str(remote or (S/'remote.git'))+'\nhost=validation\n')
    return h

def env(h, on=False, **kw):
    e=baseenv.copy(); e.update(FM_HOME=str(h),HOME=str(h/'home'),FM_STATE_OVERRIDE=str(h/'state'),FM_DATA_OVERRIDE=str(h/'data'),FM_CONFIG_OVERRIDE=str(h/'config'),FM_PROJECTS_OVERRIDE=str(h/'projects'))
    if on: e['FM_WIKI_JEV']=str(ROOT/'bin/fm-branch-shadow-jev.sh')
    e.update(kw); return e

def wiki(h,*args,on=False,check=True,**kw):
    return cmd([ROOT/'bin/fm-wiki.sh',*args],env(h,on,**kw),check,True)

def records(h):
    p=h/'state/wiki/jev.jsonl'
    return [json.loads(l) for l in p.read_text().splitlines()] if p.exists() else []
def artifact(p,name): shutil.copyfile(p,E/name)
def scenario(name,fn):
    out('\nSCENARIO: '+name)
    try:
        fn(); results.append(dict(name=name,result='pass',live=True,evidence='live-cli.txt',reason='')); out('RESULT: pass')
    except Exception as ex:
        results.append(dict(name=name,result='fail',live=True,evidence='live-cli.txt',reason=str(ex))); out('RESULT: fail: '+str(ex))

def raw(repo,id,scope,claim):
    p=repo/'raw/2026/11'/f'{id}.md';p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(f'---\nwiki: raw-lesson v1\nwiki-home: disposable\nwiki-task: {id}\nwiki-final: done\ndate: 2026-11-03\n---\n\n## Reusable lesson\nscope: {scope}\nclaim: {claim}\nevidence: synthetic validation example\n')
    return p.relative_to(repo).as_posix()
def page(repo,name,scope,claim,cite):
    p=repo/'pages/tools'/name;p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(f'> summary: {claim}\n> scope: {scope}\n> last-confirmed: 2026-11-03\n> sources: {cite}\n\n# {name[:-3]}\n\n{claim} ([lesson](../../{cite})).\n')
    return p
repo=S/'repo'; remote=S/'remote.git'
cmd(['git','init','-q','--bare','--initial-branch=main',remote])
cmd(['git','init','-q','--initial-branch=main',repo]);cmd(['git','-C',repo,'remote','add','origin','file://'+str(remote)])
seed=raw(repo,'20261101T000000Z-validation-seed','tool:retry','Retry reads after a transient connection failure.')
a=raw(repo,'20261102T000000Z-validation-alpha','tool:retry','Retry reads after a transient connection failure.')
b=raw(repo,'20261102T010000Z-validation-beta','tool:retry','Use a capped exponential retry delay for connection failures.')
page(repo,'retry.md','tool:retry','Retry reads after a transient connection failure.',seed)
p2=page(repo,'opposite.md','tool:retry','Never retry reads after a transient connection failure.',seed)
(repo/'README.md').write_text('# Synthetic wiki\n');(repo/'AGENTS.md').write_text('# Synthetic wiki fixture\n');(repo/'index.md').write_text('# Wiki index\n');(repo/'log.md').write_text('## [2026-11-01] ingest | 20261101T000000Z-validation-seed\n')
cmd(['git','-C',repo,'add','.']);cmd(['git','-C',repo,'commit','-qm','Synthetic raw batch']);cmd(['git','-C',repo,'push','-q','origin','main'])
h=home('gardener'); plan=h/'data/gardener/plan.json';report=plan.with_name('report.md')
expected=[pathlib.Path(a).stem,pathlib.Path(b).stem]

def hints():
    wiki(h,'triage','--repo',str(repo),on=True)
    p=json.loads(plan.read_text()); rs=records(h)
    out('Plan: '+json.dumps(p,indent=2));out('Recorded model answers: '+json.dumps(rs,indent=2))
    assert [l['id'] for l in p['lessons']]==expected
    assert p['jev']['unavailable']==0 and p['jev']['calls']==6
    assert all(set(l['jev'])=={'route','duplicate','worth_keeping'} for l in p['lessons'])
    assert len(rs)==6 and all(r['ok'] for r in rs)
    assert 'Retry reads after' not in (h/'state/wiki/jev.jsonl').read_text()
    artifact(plan,'live-plan.json');artifact(report,'calibration-before.md');artifact(h/'state/wiki/jev.jsonl','live-jev.jsonl')
scenario('Opted-in gardener receives real route, duplicate and worth-keeping answers without changing pending order',hints)

def calibrate():
    before=plan.read_bytes();base=cmd(['git','-C',repo,'rev-parse','HEAD']).stdout.strip()
    p=repo/'pages/tools/retry.md';p.write_text(p.read_text()+f'\nConfirmed duplicate ([lesson](../../{a})).\n')
    # Header mention plus a fenced example must NOT count as keeping beta.
    p.write_text(p.read_text().replace('> sources: '+seed,'> sources: '+seed+'; '+b)+f'\n```markdown\n[example](../../{b})\n```\n')
    (repo/'log.md').write_text((repo/'log.md').read_text()+'\n## [2026-11-03] ingest | '+ '; '.join(expected)+'\n')
    # Accepted guard: rejected publication must leave calibration pending.
    rp=repo/a; original=rp.read_bytes();rp.write_bytes(original+b'\nforbidden raw edit\n')
    pending=report.read_bytes();r=wiki(h,'publish','--repo',str(repo),'--base',base,check=False)
    assert r.returncode==1 and 'raw lessons are add-only' in r.stdout and report.read_bytes()==pending
    rp.write_bytes(original)
    wiki(h,'publish','--repo',str(repo),'--base',base)
    assert plan.read_bytes()==before
    text=report.read_text();out(text)
    rows={line.split('|')[1].strip().strip('`'):[c.strip() for c in line.split('|')[1:-1]] for line in text.splitlines() if line.startswith('| `')}
    assert rows[expected[0]][6]=='yes' and rows[expected[1]][6]=='no'
    assert rows[expected[0]][2]=='`pages/tools/retry.md`' and rows[expected[1]][2]=='(none)'
    assert all('pending' not in row for row in rows.values())
    local=cmd(['git','-C',repo,'rev-parse','HEAD']).stdout.strip();landed=cmd(['git','--git-dir='+str(remote),'rev-parse','main']).stdout.strip();assert local==landed
    out('file:// remote landing proved at '+landed)
    assert 'jev.jsonl' not in cmd(['git','--git-dir='+str(remote),'ls-tree','-r','--name-only','main']).stdout
    artifact(report,'calibration-published.md')
    # New batch with no candidate: only valid route is the declared "new page".
    gamma=raw(repo,'20261103T000000Z-validation-gamma','algorithm:lamport','Lamport clocks advance monotonically across causal events.')
    cmd(['git','-C',repo,'add','raw']);cmd(['git','-C',repo,'commit','-qm','Next synthetic raw lesson']);cmd(['git','-C',repo,'push','-q','origin','main'])
    oldrows=[line for line in report.read_text().splitlines() if line.startswith('| `')]
    wiki(h,'triage','--repo',str(repo),on=True)
    pp=json.loads(plan.read_text());out('Next batch: '+json.dumps(pp,indent=2))
    assert len(pp['lessons'])==1 and pp['lessons'][0]['jev']['route']['choice']=='new page'
    page(repo,'lamport.md','algorithm:lamport','Lamport clocks advance monotonically across causal events.',gamma)
    (repo/'log.md').write_text((repo/'log.md').read_text()+'\n## [2026-11-03] ingest | '+pathlib.Path(gamma).stem+'\n')
    base=cmd(['git','-C',repo,'rev-parse','HEAD']).stdout.strip()
    wiki(h,'publish','--repo',str(repo),'--base',base)
    assert all(row in report.read_text().splitlines() for row in oldrows)
    gamma_row=next(line for line in report.read_text().splitlines() if line.startswith('| `'+pathlib.Path(gamma).stem+'`'))
    assert '| `new page` | `pages/tools/lamport.md` | yes |' in gamma_row
    out(report.read_text());artifact(report,'calibration-two-batches.md')
scenario('Publishing fills kept/dropped and duplicate outcomes from body citations, records new-page agreement and retains the prior batch',calibrate)

def optout():
    hh=home('off');wiki(hh,'triage','--repo',str(repo))
    p=json.loads((hh/'data/gardener/plan.json').read_text());assert p['jev']['flag']=='off' and not records(hh)
    (hh/'config/wiki').write_text((hh/'config/wiki').read_text()+'jev=off\n')
    wiki(hh,'triage','--repo',str(repo),on=True);wiki(hh,'lint','--repo',str(repo),on=True)
    assert not records(hh)
    out('Unset flag and jev=off produced no advisory records; ordinary lint remained clean.')
scenario('Unset flag and home jev=off disable advisories while ordinary triage and lint continue',optout)

def contradictions():
    old=len(records(h));r=wiki(h,'lint','--repo',str(repo),on=True)
    rs=records(h)[old:];out('Contradiction record: '+json.dumps(rs,indent=2))
    assert r.returncode==0 and len(rs)==1 and rs[0]['verb']=='contradicts' and rs[0]['ok']
    assert 'contradiction candidate' in r.stdout
    artifact(h/'state/wiki/jev.jsonl','live-jev.jsonl')
scenario('Real Jev identifies opposing same-scope pages as an advisory while deterministic lint succeeds',contradictions)

def privacy():
    hh=home('capture','contributor');task='privacy-example'
    (hh/'state'/f'{task}.meta').write_text('kind=ship\nharness=codex\nmodel=test-model\nproject='+str(S/'synthetic-project')+'\n')
    (hh/'state'/f'{task}.status').write_text('done [at=1]: synthetic completion\n')
    d=hh/'data'/task;d.mkdir()
    body='## Private planning example\nscope: fleet:strategy\nclaim: The fictional captain Dana plans a confidential acquisition of Example Widgets in December for 70 million credits. Keep this personal negotiation strategy private.\nevidence: fabricated private planning example used only for this validation\n'
    (d/'lessons.md').write_text(body)
    r=wiki(hh,'close',task,on=True)
    rs=records(hh);out('Privacy answer: '+json.dumps(rs,indent=2))
    assert len(rs)==1 and rs[0]['ok'] and rs[0]['verb']=='privacy'
    queued=list((hh/'state/wiki/outbox').glob('*.md'));assert len(queued)==1
    assert queued[0].read_text().split('---\n',2)[-1].lstrip('\n')==body
    assert not list((hh/'state/wiki/held').glob('*.md'))
    if rs[0]['probability']>=0.8: assert 'advisory only, published unchanged' in r.stdout
    wiki(hh,'drain')
    tree=cmd(['git','--git-dir='+str(remote),'ls-tree','-r','--name-only','main']).stdout
    path=next(p for p in tree.splitlines() if task in p)
    published=cmd(['git','--git-dir='+str(remote),'show','main:'+path]).stdout
    assert published.split('---\n',2)[-1].lstrip('\n')==body
    out('Privacy advisory p=%s; captured lesson published unchanged to isolated file:// remote at %s'%(rs[0]['probability'],path))
    artifact(hh/'state/wiki/jev.jsonl','privacy-jev.jsonl')
scenario('Closing a synthetic private lesson records real privacy advice and still publishes identical lesson content',privacy)

def unavailable():
    hh=home('unavailable');rr=S/'unavailable-repo';shutil.copytree(repo,rr,ignore=shutil.ignore_patterns('.git'));raw(rr,'20261103T020000Z-validation-pending','tool:retry','Retry reads after a transient connection failure.');ee=env(hh,True);ee.pop('TYPESAFE_API_KEY',None)
    # Empty isolated .env means the genuine shim observes key absence.
    r=cmd([ROOT/'bin/fm-wiki.sh','triage','--repo',rr],ee,True,True)
    p=json.loads((hh/'data/gardener/plan.json').read_text());out('Unavailable plan: '+json.dumps(p,indent=2))
    assert p['lessons'] and all(l['jev'] is None for l in p['lessons'])
    assert p['jev']['unavailable']==p['jev']['calls'] and p['jev']['calls']>0
    assert all(not r['ok'] for r in records(hh))
    # Exercise genuine transport failure without credentials via closed local port.
    r=wiki(hh,'lint','--repo',str(rr),on=True,TS_BASE='http://127.0.0.1:1')
    assert r.returncode==0
    out('Real shim key absence and connection refusal left planning and deterministic lint operational.')
    artifact(hh/'data/gardener/plan.json','unavailable-plan.json')
scenario('Missing key and a refused connection leave a complete unannotated plan and do not block lint',unavailable)

def secrets():
    hh=home('secret-guard');rr=S/'unsafe';shutil.copytree(repo,rr,ignore=shutil.ignore_patterns('.git'))
    token='ghp_'+'A'*36
    # All existing lessons compiled; only this unsafe lesson remains pending.
    unsafe=raw(rr,'20261103T010000Z-validation-secret','tool:retry','A synthetic credential '+token+' must stay local.')
    for p in (rr/'pages').rglob('*.md'):
        p.write_text(p.read_text().replace('> summary: ','> summary: '+token+' '))
    wiki(hh,'triage','--repo',str(rr),on=True)
    p=json.loads((hh/'data/gardener/plan.json').read_text());out('Unsafe batch: '+json.dumps({'calls':p['jev']['calls'],'lesson_count':len(p['lessons']),'annotated':any(l['jev'] for l in p['lessons'])}))
    assert p['jev']['calls']==0 and not records(hh) and any(l['path']==unsafe for l in p['lessons'])
    r=wiki(hh,'lint','--repo',str(rr),on=True,check=False)
    assert not records(hh)
    out('Assembled secret-bearing lessons, summaries and contradiction pages skipped every advisory request; pending lesson retained.')
scenario('Secret-bearing assembled inputs never reach Jev and remain in the deterministic pending batch',secrets)

(E/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
log.close()
shutil.rmtree(S)
raise SystemExit(any(r['result']=='fail' for r in results))
