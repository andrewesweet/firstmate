"""Compare base and target public flag-off capture/lint/index byte contracts."""
import pathlib, subprocess, os, shutil, json, hashlib
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M6FN5J98JQ4133ZM3GFVC7WX'); S=R/'.live-validation/baseline';S.mkdir(parents=True)
b=S/'base/bin';b.mkdir(parents=True)
for p in (R/'bin').iterdir():
    if p.name!='fm-wiki.sh': (b/p.name).symlink_to(p)
p=b/'fm-wiki.sh';p.write_bytes(subprocess.check_output(['git','show','d019c0f5b942c1ee82171cd4913a18aa1b4c6263:bin/fm-wiki.sh']));p.chmod(0o700)
h=S/'home'
for d in ['config','state','data/task-example','user']: (h/d).mkdir(parents=True)
(h/'config/wiki').write_text('role=gardener\nremote=file://'+str(S/'unused.git')+'\nhost=validation\n')
(h/'state/task-example.meta').write_text('kind=ship\nharness=codex\nmodel=example\nproject='+str(S/'project')+'\n')
(h/'state/task-example.status').write_text('done [at=1]: synthetic completion\n')
body='## Reuse bounded retries\nscope: tool:retry\nclaim: Cap retries after transient failure.\nevidence: synthetic example\n';(h/'data/task-example/lessons.md').write_text(body)
e=os.environ.copy();e.pop('FM_WIKI_JEV',None);e.pop('FM_ROOT_OVERRIDE',None)
e.update(FM_HOME=str(h),HOME=str(h/'user'),FM_CONFIG_OVERRIDE=str(h/'config'),FM_DATA_OVERRIDE=str(h/'data'),FM_STATE_OVERRIDE=str(h/'state'),FM_PROJECTS_OVERRIDE=str(h/'projects'),FM_WIKI_CLOSE_DRAIN='0',TMPDIR=str(R/'.live-validation/tmp'))
log=[]
def run(exe,*a):
    p=subprocess.run([str(exe),*map(str,a)],env=e,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    log.append('$ '+('BASE' if exe==b/'fm-wiki.sh' else 'TARGET')+' fm-wiki.sh '+' '.join(map(str,a))+'\n'+p.stdout.decode()+'[exit %s]'%p.returncode)
    assert p.returncode==0,p.stdout
    return p.stdout
try:
    oldout=run(b/'fm-wiki.sh','close','task-example');old=next((h/'state/wiki/outbox').glob('*.md')).read_bytes()
    shutil.rmtree(h/'state/wiki')
    newout=run(R/'bin/fm-wiki.sh','close','task-example');new=next((h/'state/wiki/outbox').glob('*.md')).read_bytes()
    assert old==new and oldout==newout and not (h/'state/wiki/jev.jsonl').exists()
    log.append('Flag-off capture: complete stamped raw bytes and CLI output match base exactly. SHA256='+hashlib.sha256(new).hexdigest()+'\n'+new.decode())
    repo=S/'repo';(repo/'pages/tools').mkdir(parents=True);(repo/'raw').mkdir()
    (repo/'raw/seed.md').write_text(body);(repo/'log.md').write_text('')
    (repo/'index.md').write_text('# Wiki\n')
    (repo/'pages/tools/retry.md').write_text('> summary: bounded retries\n> scope: tool:retry\n> last-confirmed: 2026-11-03\n> sources: raw/seed.md\n\n# Retries\n\nCap retries ([lesson](../../raw/seed.md)).\n')
    oi=run(b/'fm-wiki.sh','index','--repo',repo);old=(repo/'index.md').read_bytes()
    ni=run(R/'bin/fm-wiki.sh','index','--repo',repo);new=(repo/'index.md').read_bytes()
    assert old==new and oi==ni
    old=run(b/'fm-wiki.sh','lint','--repo',repo);new=run(R/'bin/fm-wiki.sh','lint','--repo',repo);assert old==new
    log.append('Flag-off generated index bytes, index output and lint output match base exactly; no model record exists.')
    (E/'flag-off-results.json').write_text(json.dumps(dict(name='With Jev unset, captured raw bytes, generated index bytes and close/index/lint output match the base commit exactly',result='pass',live=True,evidence='flag-off-cli.txt',reason=''),indent=2)+'\n')
finally:
    (E/'flag-off-cli.txt').write_text('\n\n'.join(log)+'\n');shutil.rmtree(S)
