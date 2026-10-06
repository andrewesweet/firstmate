import pathlib, os, subprocess, shutil, json
root=pathlib.Path.cwd(); lab=root/'t/typed-home'; ev=pathlib.Path('/home/andre/.no-mistakes/evidence/01M47GDMMHP9GND9V4JZHAAQ9G'); env=os.environ.copy()
for k in list(env):
 if k.startswith(('FM_','TASKS_AXI_')):env.pop(k)
env.update(FM_HOME=str(lab),HOME=str(lab/'account'),TMPDIR=str(root/'t'),NM_HOME=str(lab/'nm'),QUOTA_AXI_SNAPSHOT=str(root/'t/quota-cache.json'))
try:
 subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],env=env,stdout=subprocess.DEVNULL,check=True)
 (lab/'account').mkdir();(lab/'data/typed-proof').mkdir();brief=lab/'data/typed-proof/brief.md';brief.write_text("# Task\n\n## Captain's intent\nFix the task spend ledger while preserving its schema.\n\n## Firstmate spec\nThe root cause is a lost branch after ownership-verified return. Keep cleanup safety.\n")
 (lab/'config/crew-dispatch.json').write_text(json.dumps({'rules':[{'when':'A simple bug fix with a stated root cause.','approval':'captain','use':{'harness':'claude','model':'sonnet','effort':'high'}}], 'default':{'harness':'codex'}}))
 p=subprocess.run(['bin/fm-dispatch-resolve.sh',str(brief),'--project','sandbox'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=65)
 (ev/'typed-dispatch-live.log').write_text(p.stdout+'\nexit='+str(p.returncode)+'\n');print(p.stdout)
 assert p.returncode==0
 ledger=lab/'data/dispatch-resolve.jsonl'; assert ledger.exists();rows=[json.loads(x) for x in ledger.read_text().splitlines()];assert len(rows)==1
 rec=rows[0];assert rec['status'] in ['escalate','error','ambiguous'];assert not rec['profile'];shutil.copyfile(ledger,ev/'typed-dispatch-record.jsonl')
 # Exercise the never-send guard with the same real key and synthetic brief.
 (lab/'config/dispatch-never-send').write_text('lost branch\n')
 p=subprocess.run(['bin/fm-dispatch-resolve.sh',str(brief),'--project','sandbox'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=65)
 with (ev/'typed-dispatch-live.log').open('a') as f:f.write('\nNever-send attempt:\n'+p.stdout+'\nexit='+str(p.returncode)+'\n')
 assert 'nothing sent' in p.stdout and len(ledger.read_text().splitlines())==1
finally:
 if lab.exists():shutil.rmtree(lab)
