import pathlib, tempfile, os, subprocess, shutil, json
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/cti/.no-mistakes/evidence/01M5CGF3ACMA45G6YFQV3T9Q56')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.b',dir=root))
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ['TMUX','HERDR_ENV','HERDR_SESSION','CLAUDE_CODE_SESSION_ID','STATE','CONFIG']}
env.update(FM_HOME=str(lab/'home'),FM_BACKEND='tmux',TMPDIR=str(lab),FM_POLL='1',FM_CHECK_INTERVAL='0',FM_HEARTBEAT='0')
socket=str(lab/'s')
def run(args,check=True):
    r=subprocess.run(args,cwd=root,env=env,capture_output=True,text=True,timeout=30)
    if check: assert r.returncode==0,(args,r.stdout,r.stderr)
    return r
try:
    run(['bin/fm-lab-home.sh','create',str(lab/'home')])
    run(['tmux','-S',socket,'new-session','-d','-s','fm-lab-baseline','-x','120','-y','40','sleep 120'])
    env['TMUX']=run(['tmux','-S',socket,'display-message','-p','#{socket_path},#{pid},0']).stdout.strip()
    code=lab/'code'; (code/'bin').mkdir(parents=True)
    # Isolate the changed runtime owner at the base version; all sibling helpers are unchanged real scripts.
    for file in (root/'bin').iterdir():
        if file.name!='fm-wake-lib.sh': (code/'bin'/file.name).symlink_to(file)
    old=run(['git','show','afaf62027c55b6c14bd7fafe462eddae127f2756:bin/fm-wake-lib.sh']).stdout
    (code/'bin'/'fm-wake-lib.sh').write_text(old)
    state=lab/'home'/'state'
    check=state/'cadence.check.sh'
    check.write_text('#!/usr/bin/env bash\nprintf "check executed\\n" >> "$FM_HOME/state/check-runs"\n'); check.chmod(0o700)
    run(['bin/fm-check-register.sh','cadence'])
    run(['bash','-c','. "$1"; fm_wake_append check inbox:baseline "check: unchanged row"','_',str(code/'bin'/'fm-wake-lib.sh')])
    records=[]
    for restart in range(3):
        r=run([str(code/'bin'/'fm-watch.sh')])
        record={'start':restart+1,'stdout':r.stdout.strip(),'marker':(state/'.watcher-down').read_text().strip(),'queue':(state/'.wake-queue').read_text().strip(),'last_check_exists':(state/'.last-check').exists(),'check_ran':(state/'check-runs').exists()}
        records.append(record)
        assert 'check: rearm-resurface' in record['stdout']
        assert not record['last_check_exists'] and not record['check_ran']
    assert len(set(r['marker'] for r in records))==3
    text='Counterfactual: target watcher with only fm-wake-lib.sh restored to base afaf620.\n'+json.dumps(records,indent=2)+'\nObserved: three launches over the same row minted three recovery generations; the registered due check never ran.\n'
    print(text)
    (evidence/'baseline-reproduction.txt').write_text(text)
finally:
    run(['tmux','-S',socket,'kill-server'],False)
    shutil.rmtree(lab)
