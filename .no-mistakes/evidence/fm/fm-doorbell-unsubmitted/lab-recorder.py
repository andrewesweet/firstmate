#!/usr/bin/env python3
import sys,os,subprocess,json,time,pathlib
root=pathlib.Path(os.environ['VALIDATION_ROOT'])
evidence=pathlib.Path(os.environ['VALIDATION_EVIDENCE'])
args=sys.argv[1:]
helper=str(root/'bin/fm-herdr-lab.sh')
state=root/'.test-phase/last-workspace.json'
if args[0]=='teardown' and state.exists():
    ws=json.loads(state.read_text()); pane=ws['pane']; cwd=pathlib.Path(ws['cwd'])
    if evidence.name=='sparse-affinity':
        info=subprocess.run([helper,'run',args[1],'pane','process-info','--pane',pane],capture_output=True,text=True)
        data=json.loads(info.stdout)
        processes=data['result']['process_info']['foreground_processes']
        pid=next(p['pid'] for p in processes if p['name']=='claude')
        masks={p.name:sorted(os.sched_getaffinity(int(p.name))) for p in pathlib.Path('/proc',str(pid),'task').iterdir()}
        (evidence/'affinity-restoration.json').write_text(json.dumps({'claude_pid':pid,'expected_original_allowed_cpus':[6,11],'actual_thread_masks_after_unslow':masks},indent=2))
    final=subprocess.run([helper,'run',args[1],'pane','read',pane,'--source','visible'],capture_output=True,text=True)
    (evidence/'final-pane.txt').write_text(final.stdout+final.stderr)
    records={str(p.relative_to(cwd)):p.read_text() for p in cwd.rglob('*') if p.is_file() and ('acted-' in p.name or p.suffix in ('.md','.msg'))}
    (evidence/'inbox-state.json').write_text(json.dumps(records,indent=2))
r=subprocess.run([helper,*args],capture_output=True)
entry={'time':time.time(),'args':args,'rc':r.returncode,'stdout':r.stdout.decode(errors='replace'),'stderr':r.stderr.decode(errors='replace')}
with (evidence/'herdr-transcript.jsonl').open('a') as f: f.write(json.dumps(entry)+'\n')
if args[0]=='run' and args[2:4]==['workspace','create'] and r.returncode==0:
    data=json.loads(r.stdout); state.write_text(json.dumps({'pane':data['result']['root_pane']['pane_id'],'cwd':args[args.index('--cwd')+1]}))
sys.stdout.buffer.write(r.stdout);sys.stderr.buffer.write(r.stderr);sys.exit(r.returncode)
