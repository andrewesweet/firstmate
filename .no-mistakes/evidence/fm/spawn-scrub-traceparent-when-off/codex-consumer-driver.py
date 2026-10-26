import os,pathlib,tempfile,subprocess,json,selectors,shutil
root=pathlib.Path.cwd(); ev=pathlib.Path('~/.no-mistakes/evidence/01M5WJV0PFF30JVSQ3GW5P8YPV')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.codex-trace-consumer-',dir=root))
home=lab/'home';home.mkdir()
proj=lab/'project';(proj/'.codex').mkdir(parents=True)
(proj/'.codex/config.toml').write_text('model = "gpt-5.6-sol"\n')
(home/'config.toml').write_text('[projects.'+json.dumps(str(proj))+']\ntrust_level = "trusted"\n')
env={'PATH':os.environ['PATH'],'HOME':str(home),'CODEX_HOME':str(home),'GIT_CONFIG_GLOBAL':'/dev/null','GIT_CONFIG_NOSYSTEM':'1','TRACEPARENT':'00-11111111111111111111111111111111-2222222222222222-01','COMPACT_ADVISER_DISABLE':'1'}
server=None
with (ev/'codex-consumer.log').open('w',buffering=1) as log:
    def run(args,cwd=proj):
        p=subprocess.run(args,cwd=cwd,env=env,text=True,capture_output=True,timeout=30)
        log.write('$ '+' '.join(args)+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode)+'\n')
        assert p.returncode==0,p
    try:
        run(['git','init','-q','-b','main']);run(['git','add','.']);run(['git','-c','user.name=Trace Lab','-c','user.email=trace@example.invalid','commit','-qm','seed'])
        run([str(root/'bin/fm-t3code-codex-env.sh'),'install',str(proj),'TRACEPARENT=','FM_TASK_ID=trace-consumer'])
        log.write('Generated public TOML contract:\n'+(proj/'.codex/config.toml').read_text()+'\n')
        run(['codex','--version'])
        with (ev/'codex-consumer-stderr.log').open('w') as errors:
            server=subprocess.Popen(['codex','app-server','--stdio'],cwd=proj,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=errors,text=True)
            def request(i,method,params):
                server.stdin.write(json.dumps({'id':i,'method':method,'params':params})+'\n');server.stdin.flush()
                with selectors.DefaultSelector() as selector:
                    selector.register(server.stdout,selectors.EVENT_READ)
                    while selector.select(20):
                        line=server.stdout.readline()
                        if not line:raise RuntimeError('app-server exited')
                        d=json.loads(line)
                        if d.get('id')==i:
                            assert 'error' not in d,d
                            return d['result']
                raise TimeoutError(method)
            request(1,'initialize',{'clientInfo':{'name':'fm-trace-consumer','version':'1'}})
            cfg=request(2,'config/read',{'cwd':str(proj),'includeLayers':True})
            policy=cfg['config']['shell_environment_policy']['set']
            log.write('Real Codex config/read shell_environment_policy.set: '+json.dumps(policy)+'\n')
            assert policy['TRACEPARENT']=='' and policy['FM_TASK_ID']=='trace-consumer',policy
            result=request(3,'command/exec',{'cwd':str(proj),'command':['/usr/bin/printenv','TRACEPARENT','FM_TASK_ID'],'timeoutMs':10000,'sandboxPolicy':{'type':'dangerFullAccess'}})
            log.write('Real Codex command/exec printenv TRACEPARENT FM_TASK_ID: '+json.dumps(result)+'\n')
            assert result=={'exitCode':0,'stdout':'\ntrace-consumer\n','stderr':''},result
            server.terminate();server.wait(timeout=10);server=None
        run([str(root/'bin/fm-t3code-codex-env.sh'),'cleanup',str(proj)])
        log.write('PASS: trusted real Codex child replaced the stale ambient carrier with an empty value.\n')
    finally:
        if server is not None:server.terminate();server.wait(timeout=10)
        shutil.rmtree(lab)
        log.write('Disposable project and Codex home removed.\n')
print((ev/'codex-consumer.log').read_text())
