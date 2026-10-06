import pathlib,os,json,subprocess,shutil,datetime,time
root=pathlib.Path.cwd();lab=root/'t/measured-home';ev=pathlib.Path('/home/andre/.no-mistakes/evidence/01M47GDMMHP9GND9V4JZHAAQ9G');source=ev/'pi-session-2026-10-06T03-12-48-448Z_01a10f33-153f-75e0-b2dd-372ef500e467.jsonl';env=os.environ.copy()
for k in list(env):
 if k.startswith(('FM_','TASKS_AXI_')):env.pop(k)
env.update(FM_HOME=str(lab),HOME=str(lab/'account'),NM_HOME=str(lab/'nm'),PI_CODING_AGENT_DIR=str(lab/'pi'),TMPDIR=str(root/'t'))
try:
 subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],env=env,stdout=subprocess.DEVNULL,check=True)
 data=[json.loads(x) for x in source.read_text().splitlines()]
 times=[datetime.datetime.fromisoformat(x['timestamp'].replace('Z','+00:00')).timestamp() for x in data if x.get('timestamp')]
 start=int(min(times))-1;end=int(max(times))+1
 folder=lab/'pi/sessions'/('--'+str(root)[1:].replace('/','-')+'--');folder.mkdir(parents=True);shutil.copyfile(source,folder/source.name)
 (lab/'state/measured.meta').write_text('kind=ship\nharness=pi\nmodel=zai/glm-5.3-flash\neffort=default\nworktree='+str(root)+'\nspawn_epoch_first='+str(start)+'\nspawn_gen=s'+str(start)+'.1.live\n')
 activity=lab/'state/measured.turn-ended';activity.touch();os.utime(activity,(end,end))
 with (ev/'measured-worker-spend.log').open('w') as log:
  for _ in range(2):
   p=subprocess.run(['bin/fm-spend-ledger-append.sh','measured'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,check=True);log.write(p.stdout)
 ledger=lab/'data/spend-ledger.jsonl';rows=[json.loads(x) for x in ledger.read_text().splitlines()];assert len(rows)==1;row=rows[0];assert row['calls']>=5 and row['usd_lane']=='recorded' and row['usd']>0,row
 assert not (lab/'data/pipeline-spend.jsonl').exists()
 shutil.copyfile(ledger,ev/'measured-worker-spend.jsonl');print(json.dumps(row))
finally:
 if lab.exists():shutil.rmtree(lab)
