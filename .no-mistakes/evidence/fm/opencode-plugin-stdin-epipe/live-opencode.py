#!/usr/bin/env python3
"""Drive real OpenCode with local model I/O and disposable child executables.
Oracle: the supplied intent requires host survival and preservation of child
outcomes. The model fixture is only an external provider boundary, not OpenCode.
"""
import json, os, pathlib, shutil, socket, subprocess, tempfile, threading, time, traceback
import urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
ROOT = pathlib.Path('~/.no-mistakes/worktrees/c75a534c6389/01M54HXZWEKVDYCYK19Q7245WW')
EVIDENCE = pathlib.Path('~/.no-mistakes/evidence/01M54HXZWEKVDYCYK19Q7245WW')
lab = pathlib.Path(tempfile.mkdtemp(prefix='.', dir=ROOT))
project = lab / 'project'
records = []
provider_calls = []
def record(**fields):
    records.append(fields)
    print(json.dumps(fields, ensure_ascii=False), flush=True)
def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]
class Provider(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
        provider_calls.append({'path':self.path, 'stream':body.get('stream')})
        text = 'LAB_MODEL_OK'
        if body.get('stream'):
            self.send_response(200)
            self.send_header('Content-Type','text/event-stream')
            self.end_headers()
            common = {'id':'chatcmpl-lab', 'object':'chat.completion.chunk', 'created':int(time.time()), 'model':'lab'}
            for delta, finish in [({'role':'assistant','content':text}, None), ({},'stop')]:
                chunk = dict(common, choices=[{'index':0,'delta':delta,'finish_reason':finish}])
                self.wfile.write(('data: '+json.dumps(chunk)+'\n\n').encode())
            self.wfile.write(b'data: [DONE]\n\n')
        else:
            response = {'id':'chatcmpl-lab', 'object':'chat.completion','created':int(time.time()),'model':'lab','choices':[{'index':0,'message':{'role':'assistant','content':text},'finish_reason':'stop'}],'usage':{'prompt_tokens':1,'completion_tokens':1,'total_tokens':2}}
            self.send_response(200)
            self.send_header('Content-Type','application/json')
            self.end_headers()
            self.wfile.write(json.dumps(response).encode())
provider = ThreadingHTTPServer(('127.0.0.1',0), Provider)
threading.Thread(target=provider.serve_forever,daemon=True).start()
port = free_port()
base = f'http://127.0.0.1:{port}'
tmux_env = dict(os.environ, TMUX_TMPDIR=str(lab/'tmux'))
def tmux(*args, check=True):
    return subprocess.run(['tmux','-L','fm-lab',*args], env=tmux_env, cwd=ROOT, text=True, stdout=subprocess.PIPE,stderr=subprocess.STDOUT,check=check)
def request(path, data=None, timeout=45):
    url=base+path+('?' if '?' not in path else '&')+'directory='+urllib.parse.quote(str(project),safe='')
    payload=None if data is None else json.dumps(data).encode()
    req=urllib.request.Request(url,data=payload,headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=timeout) as r:
        return json.loads(r.read())
def wait_for(predicate, label, timeout=30):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        val=predicate()
        if val: return val
        time.sleep(.1)
    raise AssertionError('timed out: '+label)
def events():
    log=lab/'child-events.jsonl'
    return [json.loads(row) for row in log.read_text().splitlines()] if log.exists() else []
def messages(sid): return request(f'/session/{sid}/message')
def assistants(sid):
    return [m for m in messages(sid) if m['info']['role']=='assistant' and m['info'].get('time',{}).get('completed')]
def drive(label, expected_assistants=1):
    (lab/'mode').write_text(label)
    before=len(events())
    session=request('/session',{})
    sid=session['id']
    result=request(f'/session/{sid}/message',{'model':{'providerID':'lab','modelID':'lab'},'parts':[{'type':'text','text':f'Check {label}.'}]})
    record(case=label,action='prompt',session=sid,finish=result.get('info',{}).get('finish'),parts=[p.get('text') for p in result.get('parts',[]) if p.get('type')=='text'])
    wait_for(lambda: any(e.get('kind')=='guard' for e in events()[before:]),'guard invocation')
    wait_for(lambda: len(assistants(sid))>=expected_assistants,'completed assistant replies')
    time.sleep(.5)
    actual=messages(sid)
    assert len(assistants(sid))==expected_assistants, actual
    assert not any(m['info'].get('error') for m in actual), actual
    user_texts=[''.join(p.get('text','') for p in m['parts'] if p.get('type')=='text') for m in actual if m['info']['role']=='user']
    if expected_assistants==2:
        assert user_texts[1].startswith('\u2063FIRSTMATE_OP: v1 turn-end-guard: '), user_texts
        assert ('LAB_EARLY_SUCCESS' if label=='encoder-success' else 'LAB_GUARD_BODY') in user_texts[1], user_texts
    health=request('/global/health')
    record(case=label,user_texts=user_texts,action='host-survived',health=health,assistant_replies=len(assistants(sid)),user_messages=sum(m['info']['role']=='user' for m in actual),child_events=events()[before:])
    return sid
try:
    subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],cwd=ROOT,check=True,stdout=subprocess.DEVNULL)
    (lab/'tmux').mkdir()
    (project/'.opencode/plugins/lib').mkdir(parents=True)
    (project/'bin').mkdir()
    subprocess.run(['git','init','-q',str(project)],check=True)
    for name in ['fm-primary-turnend-guard.js','lib/fm-operational-input.js','package.json']:
        shutil.copy2(ROOT/'.opencode/plugins'/name,project/'.opencode/plugins'/name)
    # This observes errors without adding an error listener or suppressing errors.
    (project/'.opencode/plugins/zz-lab-observe.js').write_text('''import { EventEmitter } from "node:events";
import { appendFileSync } from "node:fs";
export const LabObserve = async () => {
  appendFileSync(process.env.FM_HOME + "/child-events.jsonl", JSON.stringify({kind:"observer-loaded"}) + "\\n");
  const emit = EventEmitter.prototype.emit;
  EventEmitter.prototype.emit = function(name, ...args) {
    if (name === "error" && ["EPIPE", "ECONNRESET"].includes(args[0]?.code)) {
      appendFileSync(process.env.FM_HOME + "/child-events.jsonl", JSON.stringify({kind:"stdin-error",code:args[0].code}) + "\\n");
    }
    return emit.call(this, name, ...args);
  };
  return {};
};
''')
    # The guard and encoder are subprocess boundaries. Both close stdin without reading.
    (project/'bin/fm-turnend-guard.sh').write_text('''#!/usr/bin/env python3
import json,os,pathlib,sys
lab=pathlib.Path(os.environ['FM_HOME'])
mode=(lab/'mode').read_text()
with (lab/'child-events.jsonl').open('a') as f: f.write(json.dumps({'kind':'guard','mode':mode})+'\\n')
os.close(0)
if mode.startswith('guard-early'): sys.exit(0 if mode.endswith('zero') else 7)
sys.stderr.write('watcher: FAILED - '+('x'*8388608 if mode.startswith('encoder-') else 'LAB_GUARD_BODY')+'\\n')
sys.exit(2)
''')
    (project/'bin/fm-operational-input.sh').write_text('''#!/usr/bin/env python3
import json,os,pathlib,sys
lab=pathlib.Path(os.environ['FM_HOME'])
mode=(lab/'mode').read_text()
with (lab/'child-events.jsonl').open('a') as f: f.write(json.dumps({'kind':'encoder','mode':mode})+'\\n')
if mode=='normal-encoding':
    os.execv('/usr/bin/bash',['bash',str(lab/'real-encoder.sh'),*sys.argv[1:]])
os.close(0)
if mode=='encoder-refusal':
    sys.stderr.write('operational-input: refused exit=7\\n')
    sys.exit(7)
print('\\u2063FIRSTMATE_OP: v1 turn-end-guard: LAB_EARLY_SUCCESS')
''')
    for p in (project/'bin').iterdir(): p.chmod(0o755)
    shutil.copy2(ROOT/'bin/fm-operational-input.sh',lab/'real-encoder.sh')
    config={'model':'lab/lab','small_model':'lab/lab','provider':{'lab':{'npm':'@ai-sdk/openai-compatible','name':'Local disposable provider','options':{'baseURL':f'http://127.0.0.1:{provider.server_port}/v1','apiKey':'disposable-local-only'},'models':{'lab':{'name':'lab','limit':{'context':32768,'output':128}}}}}}
    (project/'opencode.json').write_text(json.dumps(config))
    (lab/'mode').write_text('guard-early')
    for d in ['xdg-data','xdg-config','xdg-state','xdg-cache','opencode-config','bun-cache','user-home']:(lab/d).mkdir()
    options={'FM_HOME':str(lab),'HOME':str(lab/'user-home'),'XDG_DATA_HOME':str(lab/'xdg-data'),'XDG_CONFIG_HOME':str(lab/'xdg-config'),'XDG_STATE_HOME':str(lab/'xdg-state'),'XDG_CACHE_HOME':str(lab/'xdg-cache'),'OPENCODE_CONFIG_DIR':str(lab/'opencode-config'),'OPENCODE_CONFIG':str(project/'opencode.json'),'OPENCODE_CONFIG_CONTENT':'{}','OPENCODE_DB':str(lab/'opencode.db'),'OPENCODE_DISABLE_AUTOUPDATE':'1','OPENCODE_DISABLE_LSP_DOWNLOAD':'1','OPENCODE_DISABLE_DEFAULT_PLUGINS':'1','OPENCODE_DISABLE_MODELS_FETCH':'1','BUN_INSTALL_CACHE_DIR':str(lab/'bun-cache')}
    unset=['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','OPENCODE_CONFIG','OPENCODE_CONFIG_CONTENT','OPENCODE_CONFIG_DIR']
    command=['env',*[item for name in unset for item in ['-u',name]],*[f'{k}={v}' for k,v in options.items()],'opencode','serve','--port',str(port),'--hostname','127.0.0.1','--print-logs','--log-level','INFO']
    tmux('new-session','-d','-x','120','-y','36','-s','primary','-c',str(ROOT),'-e','FM_HOME='+str(lab),*command)
    def healthy():
        try:return request('/global/health',timeout=1)
        except (OSError,urllib.error.URLError):return None
    record(action='server-started',health=wait_for(healthy,'OpenCode start',45),provider='local HTTP fixture; no real account',socket=str(lab/'tmux'/f'tmux-{os.getuid()}'/'fm-lab'))
    drive('guard-early-zero')
    drive('guard-early-failure')
    sid=drive('encoder-refusal')
    # A second real user turn must complete in the SAME surviving session.
    response=request(f'/session/{sid}/message',{'model':{'providerID':'lab','modelID':'lab'},'parts':[{'type':'text','text':'Confirm the session still works.'}]})
    wait_for(lambda:len(assistants(sid))==2,'same session continuation')
    wait_for(lambda:sum(e.get('kind')=='encoder' and e.get('mode')=='encoder-refusal' for e in events())==2,'second encoder refusal')
    time.sleep(.5)
    record(case='encoder-refusal',action='same-session-continuation',finish=response.get('info',{}).get('finish'),assistant_replies=len(assistants(sid)),health=request('/global/health'))
    drive('encoder-success',expected_assistants=2)
    drive('normal-encoding',expected_assistants=2)
    assert any(e.get('kind')=='stdin-error' for e in events()),'No actual broken stdin observed'
    record(action='all-live-cases-complete',events=events(),provider_requests=len(provider_calls))
except Exception as exc:
    record(action='driver-failure',error=repr(exc),traceback=traceback.format_exc())
    raise
finally:
    capture=tmux('capture-pane','-p','-t','primary','-S','-300',check=False)
    (EVIDENCE/'opencode-server-pane.log').write_text(capture.stdout)
    for log in (lab/'xdg-data').glob('opencode/log/*.log'):
        shutil.copy2(log,EVIDENCE/('opencode-'+log.name))
    if (lab/'child-events.jsonl').exists(): shutil.copy2(lab/'child-events.jsonl',EVIDENCE/'live-child-events.jsonl')
    tmux('kill-server',check=False)
    provider.shutdown()
    shutil.rmtree(lab)
    record(action='cleanup',lab_removed=not lab.exists(),private_server_stopped=True)
    (EVIDENCE/'live-opencode-results.json').write_text(json.dumps({'events':records,'provider_calls':provider_calls},ensure_ascii=False,indent=2)+'\n')
