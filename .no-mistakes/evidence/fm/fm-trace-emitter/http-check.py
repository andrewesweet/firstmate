import http.server, threading, subprocess, os, json, pathlib, time, socket
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/andre/.no-mistakes/evidence/01M2C1KGAKKTR8Y4NANKN9WHEQ')
requests=[]
class Handler(http.server.BaseHTTPRequestHandler):
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  requests.append({'path':self.path,'content_type':self.headers['Content-Type'],'body':body})
  if self.path=='/slow': time.sleep(2)
  self.send_response(200); self.end_headers()
 def log_message(self,*args): pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
home=root/'.test-phase-tmp/http-home'; (home/'state').mkdir(parents=True)
(home/'state/.lock').write_text(str(os.getpid())+'\n')
(home/'state/.trace-context-effective').write_text(str(os.getpid())+' on\n')
(home/'state/task.meta').write_text('endpoint_task_id=task\nkind=ship\nproject=/example/my proj\ntraceparent=00-11111111111111111111111111111112-3333333333333334-01\ntrace_started=1700000000000\n')
script='''source bin/fm-trace-span-lib.sh
fm_trace_span_emit "$1" firstmate.spawn 1700000000000 1700000000100 firstmate.relaunch=false
fm_trace_span_emit "$1" firstmate.task 1700000000000 1700000000200 --root --status ok firstmate.task.outcome=done
printf 'caller continued\\n'
'''
env=os.environ.copy(); env['OTEL_EXPORTER_OTLP_TRACES_ENDPOINT']=f'http://127.0.0.1:{server.server_port}/v1/traces'
def run(code,env):
 start=time.monotonic(); result=subprocess.run(['bash','-euo','pipefail','-c',code,'_',str(home/'state/task.meta')],env=env,capture_output=True,text=True)
 assert result.returncode==0 and result.stdout=='caller continued\n' and not result.stderr, result
 return round(time.monotonic()-start,3)
run(script,env)
spans=[r['body']['resourceSpans'][0]['scopeSpans'][0]['spans'][0] for r in requests]
assert len(spans)==2 and spans[0]['parentSpanId']==spans[1]['spanId']=='3333333333333334'
assert spans[0]['traceId']==spans[1]['traceId'] and 'parentSpanId' not in spans[1]
assert all(r['path']=='/v1/traces' and r['content_type']=='application/json' for r in requests)
(evidence/'http-otlp-requests.json').write_text(json.dumps(requests,indent=2)+'\n')
single='source bin/fm-trace-span-lib.sh; fm_trace_span_emit "$1" firstmate.spawn - -; printf "caller continued\\n"'
env['OTEL_EXPORTER_OTLP_TRACES_ENDPOINT']=f'http://127.0.0.1:{server.server_port}/slow'
slow=run(single,env); assert slow<1.8,slow
sock=socket.socket(); sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]; sock.close()
env['OTEL_EXPORTER_OTLP_TRACES_ENDPOINT']=f'http://127.0.0.1:{port}/v1/traces'
refusal=run(single,env)
(evidence/'http-delivery.log').write_text(f'Real curl posted spawn and task root to local HTTP receiver.\nPOST /v1/traces; Content-Type: application/json; HTTP 200.\nBoth spans share trace ID; spawn parent equals parentless task root span ID.\nStrict Bash caller continued silently after real collector timeout ({slow}s) and connection refusal ({refusal}s).\n')
server.shutdown()
print('Real HTTP delivery, timeout, and refusal checks passed')
