import os,pathlib,tempfile,subprocess,shutil,time,html,shlex,json
root=pathlib.Path.cwd(); evidence=pathlib.Path(__file__).parent
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.',dir='/tmp'))
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ['TMUX','TMUX_PANE','NO_MISTAKES_GATE']}
env['FM_HOME']=str(lab); env['TMUX_TMPDIR']=str(lab/'tmux')
def call(args,check=True):
    return subprocess.run(args,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,check=check,timeout=30).stdout
try:
    call(['bin/fm-lab-home.sh','create',str(lab)])
    for d in ['tmux','home','grok-home']: (lab/d).mkdir()
    auth=pathlib.Path(os.environ['HOME'])/'.grok/auth.json'
    if auth.is_file():
        shutil.copyfile(auth,lab/'grok-home/auth.json'); (lab/'grok-home/auth.json').chmod(0o600)
    command=['env','HOME='+str(lab/'home'),'GROK_HOME='+str(lab/'grok-home'),'grok','--leader-socket',str(lab/'grok.sock'),'--always-approve','--reasoning-effort','low','--no-alt-screen']
    print(call(['grok','--version']),flush=True)
    print('Starting genuine Grok in a disposable home on a private 120x40 tmux terminal.',flush=True)
    call(['tmux','-L','fm-lab','new-session','-d','-x','120','-y','40','-s','primary','-c',str(root),'-e','FM_HOME='+str(lab),shlex.join(command)])
    screen=''
    for i in range(40):
        time.sleep(1)
        screen=call(['tmux','-L','fm-lab','capture-pane','-p','-t','primary'],False)
        if 'always-approve' in screen or 'Sign in' in screen or 'Log in' in screen: break
    print(screen,flush=True)
    (evidence/'grok-live-screen.txt').write_text(screen)
    (evidence/'grok-live-screen.html').write_text('<!doctype html><meta charset="utf-8"><title>Live Grok terminal capture</title><body style="background:#161616;color:#eee"><pre style="font:15px monospace;line-height:1.3">'+html.escape(screen)+'</pre>')
    if 'always-approve' not in screen:
        print('UNTESTED: the real Grok did not expose its approval-titled composer in the capture.',flush=True)
    else:
        ansi=call(['tmux','-L','fm-lab','capture-pane','-e','-p','-t','primary'])
        cursor=call(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{cursor_y}']).strip()
        args=['bash','-c','. bin/fm-composer-lib.sh; fm_composer_classify_screen "$1" "$2" "$3" "$4"','_', 'styled=1\ncursor=1\nidentity=1\nrows=40',ansi,cursor,'grok:idle']
        out=call(args); print('Actual empty composer: '+out,flush=True)
        assert out.strip()=='empty'
        call(['tmux','-L','fm-lab','send-keys','-t','primary','-l','unsent live validation text'])
        time.sleep(1)
        ansi=call(['tmux','-L','fm-lab','capture-pane','-e','-p','-t','primary'])
        cursor=call(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{cursor_y}']).strip()
        args[-3]=ansi; args[-2]=cursor
        out=call(args); print('Actual typed composer: '+out,flush=True)
        assert out.strip()=='pending'
finally:
    call(['tmux','-L','fm-lab','kill-server'],False)
    shutil.rmtree(lab)
    print('Private Grok server stopped and disposable home removed.',flush=True)
