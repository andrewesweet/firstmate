from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import hashlib, json, os, shutil, subprocess, threading
root=Path.cwd(); lab=root/'.test-phase-tmp/dispatch-live'; lab.mkdir()
evidence=Path('~/.no-mistakes/evidence/01M6PPNG6H1R7WRHVY6CWGFJXH')
(lab/'config').mkdir(); (lab/'data').mkdir()
brief=lab/'brief.md'; brief.write_text("# Task\n## Captain's intent\nRepair the pager off-by-one.\n## Published intent\nPRIVATE-PUBLICATION-TEXT\n## Firstmate spec\nReturn one page per call.\n")
(lab/'config/crew-dispatch.json').write_text(json.dumps({'shared_quota':True,'rules':[{'when':'A simple bug fix with a stated root cause.','use':[{'harness':'codex','model':'default','effort':'low'},{'harness':'claude','model':'default'}]}],'default':{'harness':'codex','model':'default'}}))
confidence=.95
requests=[]
class Handler(BaseHTTPRequestHandler):
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  assert self.path=='/v1/systemone'
  assert 'Authorization' not in self.headers
  assert 'PRIVATE-PUBLICATION-TEXT' not in json.dumps(body)
  requests.append(body)
  data=json.dumps({'model':'local-contract-provider','answers':{'rule':{'type':'choice','choice':'rule_1','confidence':confidence,'probabilities':{'rule_1':.95,'default':.05}}},'usage':{'input_tokens':1,'output_tokens':1}}).encode()
  self.send_response(200); self.end_headers(); self.wfile.write(data)
 def log_message(self,*args): pass
server=HTTPServer(('127.0.0.1',0),Handler)
thread=threading.Thread(target=server.serve_forever);thread.start()
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TYPESAFE_','OPENAI_','OPENROUTER_','TS_BASE'))}
env.update(FM_HOME=str(lab),FM_DISPATCH_PROVIDER='systemone',FM_DISPATCH_MODEL='local-contract-provider',FM_DISPATCH_BASE_URL='http://127.0.0.1:'+str(server.server_port),TMPDIR=str(lab))
try:
 for value,expected in [(.95,'status: clear'),(.49,'status: ambiguous')]:
  confidence=value
  run=subprocess.run([str(root/'bin/fm-dispatch-resolve.sh'),str(brief),'--project','lab-pager'],env=env,capture_output=True,text=True)
  print('provider confidence =',value,'exit =',run.returncode,flush=True)
  print(run.stdout,run.stderr,flush=True)
  assert run.returncode==0 and expected in run.stdout,(run.returncode,run.stdout,run.stderr)
  if value==.95: assert "--harness 'codex'" in run.stdout
 rows=[json.loads(s) for s in (lab/'data/dispatch-resolve.jsonl').read_text().splitlines()]
 assert len(rows)==2
 raw=(lab/'data/dispatch-resolve.jsonl').read_text()
 assert 'PRIVATE-PUBLICATION-TEXT' not in raw
 digest='sha256:'+hashlib.sha256(brief.read_bytes()).hexdigest()
 assert all(digest in json.dumps(row) for row in rows)
 (evidence/'dispatch-outcomes.jsonl').write_text(raw)
 (evidence/'dispatch-request.json').write_text(json.dumps(requests,indent=2))
 print('Real HTTP requests reached local provider; high confidence selected codex; confidence below 0.5 did not authorize dispatch; both outcome records preserve the exact brief fingerprint without its text.',flush=True)
finally:
 server.shutdown();thread.join();server.server_close();shutil.rmtree(lab)
