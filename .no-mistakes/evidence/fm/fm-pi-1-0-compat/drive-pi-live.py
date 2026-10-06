import os, pathlib, subprocess, tempfile, time, json, shutil, traceback
ROOT=pathlib.Path.cwd()
EVIDENCE=pathlib.Path('/home/cti/.no-mistakes/evidence/01M49EWFTMM2MVDWSZA9MX8GGD')
LAB=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.'))
ENV=os.environ.copy()
for key in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','HERDR_SESSION','HERDR_PANE_ID','PI_CODING_AGENT_DIR']:
    ENV.pop(key,None)
ENV['TMUX_TMPDIR']=str(LAB/'tmux')
results={}
transcript=[]
def run(*args, check=True):
    res=subprocess.run(args,cwd=ROOT,env=ENV,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    if check and res.returncode: raise RuntimeError(f'{args}: {res.stdout}')
    return res.stdout

def tm(*args,**kwargs): return run('tmux','-L','fm-lab',*args,**kwargs)
def pane(): return tm('capture-pane','-p','-t','primary','-S','-300',check=False)
def capture(name):
    text=pane()
    (EVIDENCE/f'pi-0.99.1-{name}.txt').write_text(text)
    (EVIDENCE/f'pi-0.99.1-{name}.ansi').write_text(tm('capture-pane','-p','-e','-t','primary','-S','-300',check=False))
    transcript.append(f'=== {name} ===\n{text}')
    return text

def wait(predicate, seconds=12):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        if predicate(): return True
        time.sleep(.1)
    return False

def submit(text):
    tm('send-keys','-t','primary','-l',text)
    time.sleep(.15)
    tm('send-keys','-t','primary','Enter')
    time.sleep(.25)

def launch(session=None):
    cli=['pi','--offline','--approve','--no-context-files','--no-skills','--no-prompt-templates','--no-extensions','-e',str(ROOT/'.pi/extensions/fm-calm.ts'),'-e',str(ROOT/'.pi/extensions/fm-branch-supervision.ts'),'--session-dir',str(LAB/'sessions')]
    if session: cli+=['--session',str(session)]
    tm('-f','/dev/null','new-session','-d','-s','primary','-x','140','-y','38','-c',str(ROOT),'-e',f'FM_HOME={LAB}',*cli)
    tm('set-option','-g','extended-keys','on')
    assert wait(lambda:'fm-calm.ts' in pane()), 'extensions did not load'

try:
    run('bin/fm-lab-home.sh','create',str(LAB))
    (LAB/'tmux').mkdir()
    launch()
    capture('startup')
    submit('/calm')
    if not wait(lambda:(LAB/'config/calm').exists(),2): tm('send-keys','-t','primary','Enter')
    assert wait(lambda:(LAB/'config/calm').exists()), '/calm did not persist a preference'
    assert (LAB/'config/calm').read_text().strip()=='on'
    capture('calm-on')
    results['calm_toggle']={'result':'pass','live':True,'preference':'on'}

    submit('/supervision-model')
    if not wait(lambda:'Supervision branch model (now:' in pane(),2): tm('send-keys','-t','primary','Enter')
    assert wait(lambda:'Supervision branch model (now:' in pane()), 'model picker did not open'
    assert 'Follow main' in capture('model-picker')
    pins_before={p.name:p.read_text() for p in (LAB/'config').glob('supervision-branch-*')}
    tm('send-keys','-t','primary','-l','impossible-catalog-match-98437')
    time.sleep(.4)
    no_match=capture('model-no-match')
    assert 'No matching commands' in no_match, 'picker search did not filter to an empty result'
    tm('send-keys','-t','primary','Escape')
    assert wait(lambda:'Supervision branch model (now:' not in pane()), 'Escape did not close the picker'
    pins_after={p.name:p.read_text() for p in (LAB/'config').glob('supervision-branch-*')}
    assert pins_after==pins_before, 'cancelled picker changed persisted selections'
    capture('model-cancelled')
    results['picker_search_cancel']={'result':'pass','live':True,'persisted_pins_after':pins_after}

    submit('/supervision-model')
    assert wait(lambda:'Supervision branch model (now:' in pane())
    tm('send-keys','-t','primary','Enter')
    assert wait(lambda:'Supervision branch effort' in pane()), 'effort picker did not open after selecting follow main'
    capture('effort-picker')
    tm('send-keys','-t','primary','Enter')
    assert wait(lambda:'Supervision branch effort' not in pane())
    capture('effort-selected')
    results['picker_effort']={'result':'pass','live':True}

    prompt="Run bash exactly once with printf 'PI_CALM_LIVE_MARKER\\n' and then reply exactly 'Calm compatibility verified.'"
    submit(prompt)
    time.sleep(.5)
    if prompt in pane() and not list((LAB/'sessions').rglob('*.jsonl')): tm('send-keys','-t','primary','Enter')
    def session_files(): return list((LAB/'sessions').rglob('*.jsonl'))
    def final_written():
        for file in session_files():
            for line in file.read_text().splitlines():
                entry=json.loads(line)
                msg=entry.get('message',{})
                if msg.get('role')=='assistant' and any(c.get('type')=='text' and 'Calm compatibility verified.' in c.get('text','') for c in msg.get('content',[])):
                    return True
        return False
    if not wait(final_written,45):
        capture('provider-unavailable')
        results['calm_tools_resume_export']={'result':'untested','live':False,'reason':'The installed provider did not produce a completed turn within 45 seconds; see the real Pi pane for its diagnostic.'}
    else:
        session=session_files()[0]
        entries=[json.loads(line) for line in session.read_text().splitlines()]
        tool_results=[e.get('message',{}) for e in entries if e.get('message',{}).get('role')=='toolResult']
        assert any('PI_CALM_LIVE_MARKER' in json.dumps(m) for m in tool_results), 'requested real bash tool did not run'
        calm_text=capture('tool-calm-on')
        assert 'Calm compatibility verified.' in calm_text
        # The prompt legitimately contains the marker. A hidden tool result must
        # not add a standalone marker line to the visible conversation.
        assert not any(line.strip()=='PI_CALM_LIVE_MARKER' for line in calm_text.splitlines()), 'Calm displayed the bash result'
        submit('/calm')
        assert wait(lambda:(LAB/'config/calm').read_text().strip()=='off')
        assert wait(lambda:any(line.strip()=='PI_CALM_LIVE_MARKER' for line in pane().splitlines())), 'Calm off did not restore the tool result'
        capture('tool-calm-off')
        export=EVIDENCE/'pi-0.99.1-live-export.html'
        submit('/export '+str(export))
        assert wait(lambda:export.exists()), 'Pi /export did not write HTML'
        capture('export-confirmed')
        submit('/calm')
        assert wait(lambda:(LAB/'config/calm').read_text().strip()=='on')
        tm('kill-session','-t','primary')
        launch(session)
        resumed=capture('resumed-calm-on')
        assert 'Calm compatibility verified.' in resumed
        assert not any(line.strip()=='PI_CALM_LIVE_MARKER' for line in resumed.splitlines()), 'restart restored a hidden tool result'
        assert (LAB/'config/calm').read_text().strip()=='on'
        shutil.copyfile(session,EVIDENCE/'pi-0.99.1-live-session.jsonl')
        results['calm_tools_resume_export']={'result':'pass','live':True,'export':str(export),'actual_bash_tool_results':len(tool_results)}
except Exception as exc:
    results['driver_error']={'error':str(exc),'traceback':traceback.format_exc()}
    capture('driver-failure')
finally:
    tm('kill-server',check=False)
    shutil.rmtree(LAB)
    results['cleanup']='private tmux server stopped and disposable lab removed'
    (EVIDENCE/'pi-0.99.1-live-results.json').write_text(json.dumps(results,indent=2))
    (EVIDENCE/'pi-0.99.1-live-transcript.txt').write_text('\n'.join(transcript))
    print(json.dumps(results,indent=2),flush=True)
