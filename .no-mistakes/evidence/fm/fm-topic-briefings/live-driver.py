import os, json, pathlib, subprocess, datetime

root = pathlib.Path.cwd()
work = root / '.topic-live'
ev = pathlib.Path('~/.no-mistakes/evidence/01M6ACPD6ZQCA731JT03PGGRAA')
main = work / 'main'
mate = work / 'mate'
env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_', 'LAVISH_AXI_'))}
env.update(TMPDIR=str(work), FM_HOME=str(main), LAVISH_AXI_STATE_DIR=str(work/'lavish-state'),
           LAVISH_AXI_PORT='44389', LAVISH_AXI_HOST='127.0.0.1', LAVISH_AXI_NO_OPEN='1',
           FM_PROCEVENT_CLAIM_ROOT=str(work/'claims'))
log = open(ev/'live-cli.log','w')
def run(args, home=main, expected=0):
    e=env|{'FM_HOME':str(home)}
    p=subprocess.run([str(x) for x in args],env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=90)
    log.write('$ '+ ' '.join(str(x) for x in args)+'\n'+p.stdout+p.stderr+f'\nexit: {p.returncode}\n'); log.flush()
    if p.returncode != expected: raise RuntimeError(p.stderr or p.stdout)
    return p.stdout
def tasks(*args, home=main): return run([root/'bin/fm-tasks-axi.sh',*args],home)
def brief(*args, name='release', expected=0): return run([root/'bin/fm-topic-brief.sh',name,*args], expected=expected)
for home in [main,mate]:
    run([root/'bin/fm-lab-home.sh','create',home])
    (home/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 50\n')
    (home/'data/topics.md').write_text('- release | aliases: launch | projects: demo\n- other | projects: elsewhere\n')
    tasks('add','ready','Publish release notes — 日本語', '--repo','demo',home=home)
    tasks('add','waiting','Dependent rollout','--repo','demo','--blocked-by','ready',home=home)
    tasks('add','external','Vendor release approval','--repo','demo',home=home)
    tasks('hold','external','--kind','external','--reason','Waiting for vendor approval','--until','2099-12-01',home=home)
    tasks('add','observation','Held flight observation','--repo','demo','--kind','observation',home=home)
    tasks('start','observation',home=home)
    tasks('hold','observation','--kind','external','--reason','Waiting for upstream signal',home=home)
    tasks('add','excluded','Other project must stay out','--repo','elsewhere',home=home)
    tasks('add','landed','Recorded delivery <script>window.bad=1</script>','--repo','demo',home=home)
    tasks('done','landed','--pr','https://github.com/example/demo/pull/42',home=home)
    run([root/'bin/fm-captain-hold.sh','hold','decision','--title','Choose release posture','--repo','demo','--reason','Which posture? options: ship now | reconcile | wait for review'],home)
    tasks('add','orphan','Inventory missing its worker','--repo','demo',home=home)
    tasks('start','orphan',home=home)
(main/'data/secondmates.md').write_text(f'- mate - Release specialist (home: {mate}; scope: demo; projects: demo; added 2026-11-01)\n')
# A local registered home is a real disposable record source, not a mocked snapshot.
(mate/'.fm-secondmate-home').touch()
(mate/'AGENTS.md').write_text('# Disposable validation home\n')
(mate/'bin').symlink_to(root/'bin',target_is_directory=True)
model=json.loads(brief('--json',name='launch'))
(ev/'topic-model.json').write_text(json.dumps(model,ensure_ascii=False,indent=2))
assert model['topic']['name']=='release' and not model['labels_available']
assert model['window']['source']=='default-14d'
assert 'excluded' not in json.dumps(model) and 'mate/excluded' not in json.dumps(model)
assert {'ready','mate/ready'} <= {r['id'] for r in model['next_steps']['ready']}
assert {'external','observation','mate/external','mate/observation'} <= {r['id'] for r in model['next_steps']['blocked']}
assert {'decision','mate/decision'} == {r['id'] for r in model['decisions_open']}
assert any('inventory' in d.lower() for d in model['disclosures'])
assert not any(r['id'].endswith('orphan') for r in model['in_flight'])
brief('--html',ev/'topic-brief.html')
after=json.loads(brief('--json'))
assert after['window']['source']=='previous-briefing' and after['recap']['paragraph']
explicit=json.loads(brief('--since','2026-10-01','--json'))
assert explicit['window']['source']=='flag' and explicit['recap']['paragraph']
(ev/'topic-history-recap.json').write_text(json.dumps(explicit,ensure_ascii=False,indent=2))
(ev/'topic-chat.txt').write_text(brief('--since','2026-10-01'))
brief('--since','2026-02-30','--json',expected=2)
brief('--json',name='unknown',expected=2)
history=list((main/'data/topic-briefings').rglob('*.json'))
assert len(history)==1
run([root/'bin/fm-captain-hold.sh','hold','decision','--reason','Which posture? options: ship now | reconcile | wait for review'])
brief('--since','2026-10-01','--board')
(ev/'board-build.txt').write_text('Board was built using the real topic, snapshot, tasks-axi, board, Lavish and captured-answer binding.\n')
print('Live records, fallback membership, secondmate rows, external holds, inventory warnings, history, errors and board build passed.')
