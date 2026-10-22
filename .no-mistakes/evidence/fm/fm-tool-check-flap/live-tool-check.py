import contextlib, functools, hashlib, http.server, json, math, os, pathlib, shutil, ssl, subprocess, tempfile, threading, time, traceback
ROOT=pathlib.Path.cwd()
EVIDENCE=pathlib.Path('/home/cti/.no-mistakes/evidence/01M5HHTSWMAT2Z86V93H6K6W7B')
LAB=pathlib.Path(tempfile.mkdtemp(prefix='live-',dir=ROOT/'.test-tool-check-tmp'))
LOG=open(EVIDENCE/'live-transcript.log','w',buffering=1)
results=[]
def note(s): print(s,file=LOG); print(s,flush=True)
env=dict(os.environ)
for k in list(env):
    if k.startswith('FM_') or k.startswith('GIT_'): env.pop(k)
env.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Live validation',GIT_AUTHOR_EMAIL='test@example.invalid',GIT_COMMITTER_NAME='Live validation',GIT_COMMITTER_EMAIL='test@example.invalid',GIT_CEILING_DIRECTORIES=str(LAB),TMPDIR=str(LAB),FM_TOOL_UPDATE_INTERVAL='0',FM_TOOL_UPDATE_PROBE_SECS='2',FM_TOOL_UPDATE_BUDGET_SECS='10',FM_CHECK_TIMEOUT='30')
def run(args,extra=None,expected=0):
    e=env.copy();e.update(extra or {})
    p=subprocess.run([str(x) for x in args],cwd=ROOT,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=20)
    if p.returncode!=expected: raise AssertionError(f'{args}: exit {p.returncode}, expected {expected}: {p.stdout} {p.stderr}')
    return p.stdout

def home(name,tools):
    h=LAB/name;(h/'state').mkdir(parents=True);(h/'config').mkdir()
    (h/'config/watched-tools.json').write_text(json.dumps({'tools':tools}))
    return h

def check(h,label,extra=None):
    start=time.monotonic(); out=run([ROOT/'bin/fm-tool-update-check.sh','check'],dict(FM_HOME=str(h),**(extra or {})))
    note(f'\n{label}: bin/fm-tool-update-check.sh check ({time.monotonic()-start:.3f}s)\nstdout: {out.rstrip() or "<silent>"}\nstate/.tool-updates:\n{(h/"state/.tool-updates").read_text()}')
    return out

def record(h):
    return dict(x.split('=',1) for x in (h/'state/.tool-updates').read_text().splitlines()[1:])
def scenario(name,fn):
    try: fn();results.append(dict(name=name,result='pass',live=True,evidence='live-transcript.log',reason=''));note('SCENARIO PASS: '+name)
    except Exception as e: results.append(dict(name=name,result='fail',live=True,evidence='live-transcript.log',reason=str(e)));note('SCENARIO FAIL: '+name+'\n'+traceback.format_exc())

web=LAB/'www';web.mkdir();(web/'latest').write_text('99.0.0\n');(web/'timed').mkdir();(web/'timed/latest').write_text('99.0.0\n')
run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-keyout',LAB/'key.pem','-out',LAB/'cert.pem','-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost,IP:127.0.0.1'])
class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        # Network delay is injected at the origin, never into curl, Git, date, or the product.
        if self.path.startswith('/timed/'):
            time.sleep(max(0,math.floor(time.time())+1.08-time.time()))
        if self.path.startswith('/hang/'):
            time.sleep(4)
        return super().do_GET()
    def log_message(self,fmt,*args): note('HTTPS origin: '+fmt%args)
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Handler,directory=str(web)))
server.daemon_threads=True
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(LAB/'cert.pem',LAB/'key.pem');server.socket=ctx.wrap_socket(server.socket,server_side=True)
threading.Thread(target=server.serve_forever,daemon=True).start()
base=f'https://localhost:{server.server_port}'
env['CURL_CA_BUNDLE']=str(LAB/'cert.pem')
def tool(name='git-release',path='/latest'): return dict(name=name,command='git',version_url=base+path)
def outage(): (web/'latest').rename(web/'latest.off')
def restore(): (web/'latest.off').rename(web/'latest')
try:
    note('Real product: '+str(ROOT/'bin/fm-tool-update-check.sh'))
    note('Real dependencies: '+run(['git','--version']).strip()+', '+run(['curl','--version']).splitlines()[0])
    note('Isolated HTTPS file origin: '+base+'; certificates and homes confined to '+str(LAB))
    def transient():
        h=home('http-transient',[tool()]);first=check(h,'initial release');assert 'update available: 99.0.0' in first
        assert check(h,'unchanged release')==''
        before=record(h)['reported'];outage()
        try:
            assert check(h,'single real HTTP 404')=='';assert record(h)['reported']==before;assert record(h)['failed']=='git-release'
        finally: restore()
        assert check(h,'origin restored after one failure')=='';assert record(h)['failed']==''
        # Follow the real watcher dispatch path, with the already known release as baseline.
        note(run([ROOT/'bin/fm-tool-update-check.sh','arm'],{'FM_HOME':str(h)}).strip())
        outage()
        try:
            out=run([ROOT/'bin/fm-watch-checkpoint.sh','--seconds','2'],{'FM_HOME':str(h),'FM_POLL':'1','FM_SIGNAL_GRACE':'1','FM_CHECK_INTERVAL':'30'},expected=124)
            note('Watcher during one HTTP failure: '+out.strip());assert 'checkpoint: no actionable wake' in out
        finally: restore()
        assert check(h,'recovery after quiet watcher checkpoint')==''
    scenario('A release update is reported once; one real HTTP failure and recovery leave the report unchanged and do not wake the watcher',transient)
    def persistent():
        h=home('http-persistent',[tool()]);check(h,'initial release before sustained outage');outage()
        try:
            assert check(h,'sustained outage first sweep')==''
            assert 'check failed:' in check(h,'sustained outage second sweep')
            assert check(h,'sustained outage third sweep')==''
        finally:restore()
        assert 'update available: 99.0.0' in check(h,'recovery after reported outage')
        assert check(h,'recovery is reported only once')==''
    scenario('A sustained HTTP failure is reported on its second sweep once, and recovery reports the pending update once',persistent)
    def independent():
        h=home('independent',[tool('first'),tool('second','/second')]);(web/'second').write_text('99.0.0\n');check(h,'two initial updates')
        outage()
        try: assert check(h,'first tool fails once')==''
        finally:restore()
        (web/'second').rename(web/'second.off')
        try: assert check(h,'second tool fails while first recovers')=='';assert record(h)['failed']=='second'
        finally:(web/'second.off').rename(web/'second')
        assert check(h,'both tools recover')==''
    scenario('Failures on different tools never combine into a consecutive failure streak',independent)
    def git_case():
        author=LAB/'author';remote=LAB/'remote.git';clone=LAB/'clone; cache'
        run(['git','init','-b','main',author]);run(['git','-C',author,'commit','--allow-empty','-m','initial']);run(['git','clone','--bare',author,remote]);run(['git','clone',remote,clone])
        run(['git','-C',author,'commit','--allow-empty','-m','release']);run(['git','-C',author,'push',remote,'main'])
        def snapshot(): return {str(p.relative_to(clone)):hashlib.sha256(p.read_bytes()).hexdigest() for p in clone.rglob('*') if p.is_file()}
        before=snapshot();h=home('git-remote',[dict(name='git-project',git=dict(repo=str(clone),branch='main'))])
        assert 'update available:' in check(h,'real Git remote newer than clone')
        remote.rename(LAB/'remote.off')
        try: assert check(h,'real Git remote unavailable once')==''
        finally:(LAB/'remote.off').rename(remote)
        assert check(h,'real Git remote restored')==''
        assert snapshot()==before;note('Watched clone file hashes unchanged, including Git refs, objects, index, config, and FETCH_HEAD presence.')
    scenario('A Git remote outage and recovery preserve its pending update without fetching or changing the watched clone',git_case)
    def immediate():
        h=home('immediate',[dict(name='missing',command='fm-live-clearly-absent'),dict(name='bad-pattern',command='git',announce_pattern='('),dict(name='absent-repo',git=dict(repo=str(LAB/'absent; directory')))])
        out=check(h,'configuration and missing tool problems first sweep');assert 'is not on PATH' in out and 'announce_pattern is not a usable' in out and 'is not a directory' in out;assert record(h)['failed']==''
        assert check(h,'same immediate findings are not repeated')==''
        (h/'config/watched-tools.json').write_text('{invalid')
        assert 'watched tool registry:' in check(h,'invalid registry first sweep');assert record(h)['failed']==''
        h2=home('budget-cut',[tool()]);out=check(h2,'oversized budget reports immediately',{'FM_TOOL_UPDATE_BUDGET_SECS':'120'});assert 'sweep budget 120s cut to ' in out
    scenario('Missing tools, invalid patterns, absent directories, registry errors, and budget cuts remain immediate and outside probe streaks',immediate)
    def notice():
        h=home('notice',[tool('release','/timed/latest'),dict(name='unreached',command='git'),dict(name='also-unreached',command='git')])
        extra={'FM_TOOL_UPDATE_BUDGET_SECS':'1'}
        out=check(h,'update plus exhausted sweep notice',extra);assert 'update available: 99.0.0' in out and 'check incomplete: the time budget ran out before unreached' in out
        prior=record(h)['reported'];(web/'timed/latest').rename(web/'timed/latest.off')
        try:
            assert check(h,'one failed probe with same exhausted sweep notice',extra)=='';assert record(h)['reported']==prior;assert record(h)['failed']=='release';assert prior.count('check incomplete:')==1
        finally:(web/'timed/latest.off').rename(web/'timed/latest')
        assert check(h,'recovery with same exhausted sweep notice',extra)=='';assert record(h)['reported']==prior;assert record(h)['failed']==''
    scenario('A repeated real sweep-budget notice stays single and silent through one failed probe and recovery',notice)
    def timeout():
        h=home('timeout',[tool('slow','/hang/latest')]);extra={'FM_TOOL_UPDATE_PROBE_SECS':'1'}
        start=time.monotonic();assert check(h,'origin does not answer first probe',extra)=='';assert time.monotonic()-start<3
        start=time.monotonic();assert 'check failed:' in check(h,'origin does not answer consecutive probe',extra);assert time.monotonic()-start<3
    scenario('A hung HTTPS origin obeys the probe timeout and reports only after consecutive failed sweeps',timeout)
finally:
    server.shutdown();server.server_close();shutil.rmtree(LAB)
    note('Cleanup: isolated homes, repositories, certificate, and HTTPS server removed.')
    (EVIDENCE/'live-results.json').write_text(json.dumps(results,indent=2)+'\n');LOG.close()
if any(r['result']=='fail' for r in results): raise SystemExit(1)
