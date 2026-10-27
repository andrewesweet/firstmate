import os, pathlib, subprocess, json, hashlib, shutil
root=pathlib.Path.cwd(); work=root/'.t/manual'; work.mkdir()
keys=['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS']
env={k:v for k,v in os.environ.items() if k not in keys}
def run(args,home,expected=0):
    e=env|{'FM_HOME':str(home),'TMPDIR':str(root/'.t')}
    p=subprocess.run([str(root/'bin'/args[0]),*args[1:]],env=e,text=True,capture_output=True)
    print('$ FM_HOME=<disposable> bin/'+' '.join(args)); print(p.stdout,end=''); print(p.stderr,end=''); print('exit='+str(p.returncode))
    assert p.returncode==expected,(args,p.returncode,expected)
    return p
home=work/'home'
subprocess.run([str(root/'bin/fm-lab-home.sh'),'create',str(home)],check=True,env=env,capture_output=True)
try:
    print('SCENARIO: opt-in record export and exact allowlist')
    (home/'data/projects.md').write_text('demo-project: local-only\n')
    (home/'data/private.txt').write_text('excluded private content\n')
    run(['fm-record-export.sh','sync'],home)
    assert not (work/'export').exists()
    target=work/'export'; (home/'config/record-export-root').write_text(str(target)+'\n')
    task=home/'data/demo'; task.mkdir(); (task/'brief.md').write_text('# Demo task\n')
    inbox=home/'state/demo.inbox'; (inbox/'handled').mkdir(parents=True)
    (inbox/'001.msg').write_text('pending instruction\n'); (inbox/'handled/002.msg').write_text('handled instruction\n')
    meta=home/'state/demo.meta'; meta.write_text('task=demo\nkind=ship\nspawn_gen=live-one\n')
    (home/'state/demo.status').write_text('done: local verification\n')
    run(['fm-record-export.sh','sync'],home)
    paths=sorted(str(p.relative_to(target/'live')) for p in (target/'live').rglob('*') if p.is_file())
    print('Published live files:',json.dumps(paths))
    assert 'data/projects.md' in paths and 'data/private.txt' not in paths
    assert (target/'live/state/demo.inbox/001.msg').read_text()=='pending instruction\n'
    (inbox/'001.msg').rename(inbox/'handled/001.msg')
    run(['fm-record-export.sh','sync'],home)
    assert not (target/'live/state/demo.inbox/001.msg').exists()
    assert (target/'live/state/demo.inbox/handled/001.msg').read_text()=='pending instruction\n'
    print('Acknowledged message appears only under handled/.')
    print('SCENARIO: archive integrity, retry and reused task generation')
    run(['fm-record-export.sh','archive-task','demo'],home)
    manifest=target/'archive/demo/live-one/manifest.v1.json'; original=manifest.read_bytes()
    print(original.decode())
    data=json.loads(original)
    for entry in data['files']:
        payload=(manifest.parent/entry['archive']).read_bytes()
        assert len(payload)==entry['bytes'] and hashlib.sha256(payload).hexdigest()==entry['sha256']
    print('Every archive entry matches manifest byte count and SHA-256.')
    assert (target/'archive/demo/live-one/status').exists() or any((target/'archive/demo/live-one').rglob('*.status'))
    run(['fm-record-export.sh','archive-task','demo'],home)
    assert manifest.read_bytes()==original
    meta.write_text('task=demo\nkind=ship\nspawn_gen=live-two\n')
    run(['fm-record-export.sh','archive-task','demo'],home)
    assert (target/'archive/demo/live-two/manifest.v1.json').exists()
    assert manifest.read_bytes()==original
    print('Both generation archives retained; retry leaves committed manifest unchanged.')
    print('SCENARIO: export root symlink refuses without changing sentinel')
    outside=work/'sentinel-dir'; outside.mkdir(); sentinel=outside/'sentinel'; sentinel.write_text('preserve\n')
    link=work/'export-symlink'; link.symlink_to(outside,target_is_directory=True)
    (home/'config/record-export-root').write_text(str(link)+'\n')
    run(['fm-record-export.sh','sync'],home,1)
    assert sentinel.read_text()=='preserve\n' and list(outside.iterdir())==[sentinel]
    print('SCENARIO: real host capacity, lane accounting and reserve deferral')
    (home/'state/mate.meta').write_text('kind=secondmate\n')
    (home/'config/lane-capacity').write_text('4\nreserve-flag '+str(home/'reserved.flag')+' verification reserve\n')
    (home/'reserved.flag').touch()
    p=run(['fm-capacity.sh','--json'],home); cap=json.loads(p.stdout)
    assert cap['lanes']['count']==1 and cap['cap']['target']==4
    assert cap['verdict']['admit']==False and cap['reserve']['flag']=='present' and any('verification reserve' in reason for reason in cap['verdict']['reasons'])
    run(['fm-capacity.sh','--admit'],home,75)
    run(['fm-capacity.sh','--publish'],home)
    assert json.loads((home/'state/lane-capacity.json').read_text())['verdict']['admit']==False
    (home/'config/lane-capacity').write_text('lots\n')
    run(['fm-capacity.sh','--json'],home,1)
    print('SCENARIO: usage warner silent default and Linux notification refusal')
    p=run(['fm-usage-warner.sh','check'],home); assert not p.stdout and not p.stderr
    (home/'config/usage-warner').write_text('five_hour:80\n')
    p=run(['fm-usage-warner.sh','arm'],home,1)
    assert 'macOS' in p.stderr+p.stdout
    assert not (home/'state/usage-warner.check.sh').exists()
    print('All driven CLI scenarios passed.')
finally:
    shutil.rmtree(work)
