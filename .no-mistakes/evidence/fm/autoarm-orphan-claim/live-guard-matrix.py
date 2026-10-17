import json,os,re,subprocess
from pathlib import Path
root=Path.cwd();lab=Path(os.environ['FM_HOME']);state=lab/'state'
evidence=Path('~/.no-mistakes/evidence/01M54P4C0CEWF8GWG85R4BMWKB')
phase=(state/'probe-next-stop').read_text().strip();(state/'probe-next-stop').unlink()
original=(state/'.claude-autoarm-epoch').read_text().splitlines()
anchor=(state/'.lock').read_text();sid=(state/'.lock-session').read_text()
legacy=re.sub(r' owner_session_id=[^ ]+','',original[0])+'\n'+original[1]+'\n'
cases=[('legacy-with-ancestry',anchor,sid,legacy,0)] if phase=='before' else [
 ('recycled-bridge-matching-session-and-holder-identity',anchor,sid,'\n'.join(original)+'\n',0),
 ('missing-session-lock',None,sid,'\n'.join(original)+'\n',2),
 ('malformed-session-lock','not-a-pid\n',sid,'\n'.join(original)+'\n',2),
 ('same-bare-pid-stale-holder-identity',anchor,sid,'\n'.join(original[:2]+[original[1]])+'\n',2),
 ('missing-holder-identity',anchor,sid,'\n'.join(original[:2])+'\n',2),
 ('missing-session-sidecar',anchor,None,'\n'.join(original)+'\n',2),
 ('different-session-sidecar',anchor,'another-session\n','\n'.join(original)+'\n',2),
 ('legacy-broken-ancestry',anchor,sid,legacy,2),
 ('pid-1-ancestry-remains-valid','1\n',sid,legacy,0),
]
for name,lock,sidecar,ledger,expected in cases:
 p=lab/('probe-'+phase+'-'+name);p.mkdir()
 (p/'lab.meta').write_text('')
 (p/'.last-watcher-beat').touch()
 (p/'.claude-autoarm-epoch').write_text(ledger)
 if lock is not None:(p/'.lock').write_text(lock)
 if sidecar is not None:(p/'.lock-session').write_text(sidecar)
 env=os.environ.copy();env['FM_STATE_OVERRIDE']=str(p);env['FM_CLAUDE_AUTOARM_SYNC_WAIT_MS']='0'
 out=subprocess.run([str(root/'bin/fm-turnend-guard.sh'),'--claude'],input=json.dumps({'session_id':sid.strip(),'stop_hook_active':False}),env=env,text=True,capture_output=True)
 record={'phase':phase,'case':name,'expected_exit':expected,'actual_exit':out.returncode,'stdout':out.stdout,'stderr':out.stderr,'claim_owner':re.search(r'owner_pid=(\d+)',ledger)[1],'lock_pid':lock,'CLAUDE_PID':os.environ.get('CLAUDE_PID')}
 with (evidence/'live-guard-boundaries.jsonl').open('a') as f:f.write(json.dumps(record)+'\n')
 assert out.returncode==expected,(name,out.returncode,out.stdout,out.stderr)
 if expected==2:assert 'TURN WOULD END BLIND' in out.stderr
 else:assert not out.stdout and not out.stderr
