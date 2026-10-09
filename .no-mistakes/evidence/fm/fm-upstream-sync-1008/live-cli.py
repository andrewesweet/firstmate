import os, pathlib, tempfile, subprocess, json, hashlib, shutil, time, traceback
root=pathlib.Path.cwd()
ev=pathlib.Path('/home/cti/.no-mistakes/evidence/01M4FC0EXAEYKAXXQKZKTGBDFH')
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-cli.', dir=root/'.validation-tmp'))
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ('NO_MISTAKES_GATE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','TMUX','TMUX_PANE'):
        env.pop(k,None)
env.update(FM_HOME=str(lab), TMPDIR=str(root/'.validation-tmp'))
results=[]
log=open(ev/'live-cli.log','w')
def say(s):
    print(s,flush=True); print(s,file=log,flush=True)
def run(args, expected=0, e=None):
    command=[str(root/a) if a.startswith('bin/') else a for a in args]
    p=subprocess.run(command,env=e or env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
    say('$ '+' '.join(args)+'\n'+p.stdout+f'[exit={p.returncode}]')
    if p.returncode != expected: raise AssertionError(f'expected {expected}, got {p.returncode}')
    return p.stdout
def record(name, fn):
    try: fn(); results.append(dict(name=name,result='pass',live=True,evidence='live-cli.log',reason=''))
    except Exception as ex:
        say(traceback.format_exc()); results.append(dict(name=name,result='fail',live=True,evidence='live-cli.log',reason=str(ex)))
try:
    run(['bin/fm-lab-home.sh','create',str(lab)])
    (lab/'state').chmod(0o700)
    env['FM_PROCEVENT_CLAIM_ROOT']=str(lab/'claims')
    (lab/'config/startup-memory-budget').write_text('7500\n')
    def growth():
        (lab/'data/learnings.md').write_text('baseline\n')
        g=env.copy(); g['FM_STARTUP_GROWTH_NOW']='1000'
        run(['bin/fm-startup-growth-check.sh','arm'],e=g)
        assert (lab/'state/startup-growth.check.sh').stat().st_mode & 0o777 == 0o700
        assert (lab/'state/startup-growth.check-trust').exists()
        assert not run(['bin/fm-startup-growth-check.sh','check'],e=g).strip()
        (lab/'data/learnings.md').write_text('baseline\n'+'x'*900)
        g['FM_STARTUP_GROWTH_NOW']='1200'
        assert not run(['bin/fm-startup-growth-check.sh','check'],e=g).strip()
        g['FM_STARTUP_GROWTH_NOW']='87401'
        output=run(['bin/fm-startup-growth-check.sh','check'],e=g)
        assert 'memory growth data/learnings.md +300 estimated_tokens' in output
        shutil.copy(lab/'state/.startup-growth-check',ev/'startup-growth-record.tsv')
        g['FM_STARTUP_GROWTH_NOW']='173802'
        assert not run(['bin/fm-startup-growth-check.sh','check'],e=g).strip()
        run(['bin/fm-startup-growth-check.sh','disarm'],e=g)
        assert all(not (lab/'state'/p).exists() for p in ('startup-growth.check.sh','startup-growth.check-trust','.startup-growth-check'))
        say('Observed: trusted opt-in check; same-day silence; 900-byte growth reports once; unchanged next-day silence; disarm removes registration and state.')
    record('Arm the daily startup check, grow memory, receive one due warning, and disarm it',growth)
    def relay():
        remote=lab/'remote'; (remote/'state').mkdir(parents=True)
        r=env.copy(); r['FM_HOME']=str(remote)
        source=remote/'state/parent-replies.status'
        source.write_text('note: ordinary progress without correlation\nneeds-decision [key=relay-choice]: pick a format\n')
        empty=hashlib.sha256(b'').hexdigest()
        data=run(['bin/fm-remote-delta-read.sh','state/parent-replies.status','0',empty,'1'],e=r)
        delta=lab/'delta.result'; delta.write_text(data)
        run(['bin/fm-procevent-remote-reply.sh','ingest','relay',str(delta)])
        original=(lab/'state/relay.status').read_bytes()
        assert b'ordinary progress without correlation' in original and b'relay-choice' in original
        run(['bin/fm-procevent-remote-reply.sh','ingest','relay',str(delta)])
        assert (lab/'state/relay.status').read_bytes()==original
        cursor=dict(line.split('=',1) for line in (lab/'state/remote-replies/relay.cursor').read_text().splitlines())
        source.write_text('short\n')
        broken=run(['bin/fm-remote-delta-read.sh','state/parent-replies.status',cursor['offset'],cursor['prefix_sha256'],'1'],e=r)
        bad=lab/'broken.result'; bad.write_text(broken)
        run(['bin/fm-procevent-remote-reply.sh','ingest','relay',str(bad)],expected=3)
        first=(lab/'state/relay.status').read_bytes()
        run(['bin/fm-procevent-remote-reply.sh','ingest','relay',str(bad)],expected=3)
        assert (lab/'state/relay.status').read_bytes()==first
        run(['bin/fm-procevent-remote-reply.sh','retire','relay'])
        assert (lab/'state/remote-replies/relay.retirements').read_text()=='count=1\n'
        source.write_text('note: ordinary progress without correlation\nneeds-decision [key=relay-choice]: pick a format\n')
        replay=run(['bin/fm-remote-delta-read.sh','state/parent-replies.status','0',empty,'1'],e=r)
        delta.write_text(replay)
        run(['bin/fm-procevent-remote-reply.sh','ingest','relay',str(delta)])
        source.write_text('short\n')
        run(['bin/fm-procevent-remote-reply.sh','ingest','relay',str(bad)],expected=3)
        final=(lab/'state/relay.status').read_text()
        assert final.count('remote reply continuity broke')==2 and 'retirements 0' in final and 'retirements 1' in final
        (ev/'remote-reply-status.log').write_text(final)
        say('Observed: real delta reader mirrors progress and decisions; replay adds no bytes; repeated break is deduped; retire-and-reconnect creates a distinct continuity event.')
    record('Mirror remote reply bytes, reject a broken prefix, and report a later break after retirement',relay)
    def retire():
        task='gone-pr'; url='https://github.com/example/deleted-repo/pull/1'
        d=lab/'data'/task; d.mkdir()
        (lab/'data/backlog.md').write_text(f'# Backlog\n\n## Queued\n- [ ] {task} - Deleted repository {url} (repo: sample) (kind: ship)\n')
        row={'schema':'fm-contributions.v1','task':task,'records':[{'url':url,'kind':'pr','checked_at':None,'error':'permanently gone','pending':[],'seen':[],'notified':[],'observation':None,'verdict':None}]}
        path=d/'contributions.json'; path.write_text(json.dumps(row))
        run(['bin/fm-contributions.sh','retire',task,url,'fleet','deleted repository'],expected=1)
        run(['bin/fm-contributions.sh','retire',task,url,'captain','  '],expected=1)
        row['records'][0]['pending']=[{'token':'must-ack'}]; path.write_text(json.dumps(row))
        run(['bin/fm-contributions.sh','retire',task,url,'captain','deleted repository'],expected=1)
        row['records'][0]['pending']=[]; path.write_text(json.dumps(row))
        run(['bin/fm-contributions.sh','retire',task,url,'captain','Repository was deleted; stop observing this saved contribution.'])
        saved=json.loads(path.read_text()); assert saved['records'][0]['retired']['actor']=='captain'
        prior=path.read_bytes()
        run(['bin/fm-contributions.sh','retire',task,url,'captain','replacement reason'])
        assert path.read_bytes()==prior
        input_text=run(['bin/fm-fleet-snapshot.sh','--contribution-input'])
        input_file=lab/'input.json'; input_file.write_text(input_text)
        projection=json.loads(run(['bin/fm-contributions.sh','snapshot',str(input_file),'--all']))
        assert projection['known']==0 and not projection['rows']
        (ev/'retired-contribution.json').write_text(json.dumps(saved,indent=2)+'\n')
        say('Observed: non-captain, blank-reason, and pending-signal retirement refused; successful retirement preserves original provenance and removes coverage despite backlog link.')
    record('Retire a permanently gone contribution with provenance and enforce retirement guards',retire)
finally:
    shutil.rmtree(lab)
    (ev/'live-cli-results.json').write_text(json.dumps(results,indent=2)+'\n')
    log.close()
