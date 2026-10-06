import os,pathlib,subprocess,time,shutil,json
root=pathlib.Path.cwd(); evidence=pathlib.Path('/home/andre/.no-mistakes/evidence/01M47GDMMHP9GND9V4JZHAAQ9G')
with (evidence/'watch-baseline-comparison.log').open('w') as log:
 for label,code in [('base-65a0e674',root/'t'),('target-5223f111',root)]:
  home=root/'t'/('compare-'+label); env=os.environ.copy()
  for k in list(env):
   if k.startswith(('FM_','TASKS_AXI_')) or k in ['NO_MISTAKES_GATE','TMUX']:env.pop(k)
  env.update(FM_HOME=str(home),NM_HOME=str(home/'nm'),HOME=str(home/'account'),TMPDIR=str(home),FM_POLL='0.2',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',TMUX=str(root/'t/unused-private-socket')+',0,0')
  subprocess.run([str(root/'bin/fm-lab-home.sh'),'create',str(home)],env=env,stdout=subprocess.DEVNULL,check=True)
  (home/'state/demo.meta').write_text('kind=ship\nwindow=private:demo\nendpoint_task_id=demo\nspawn_gen=demo-gen\n')
  (home/'state/demo.status').touch()
  out=(home/'arm.txt').open('w'); p=subprocess.Popen([str(code/'bin/fm-watch-arm.sh')],env=env,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
  try:
   for _ in range(150):
    if (home/'state/.last-watcher-beat').exists():break
    time.sleep(.1)
   (home/'state/demo.status').write_text('needs-decision: preserve original reason\n')
   p.wait(timeout=35);out.flush()
   queue=(home/'state/.wake-queue').read_text()
   log.write(label+' exit='+str(p.returncode)+'\n'+(home/'arm.txt').read_text()+'QUEUE\n'+queue+'\n');log.flush()
   assert p.returncode==0
   assert len(queue.splitlines())==2
  finally:
   subprocess.run([str(code/'bin/fm-watch-arm.sh'),'--stop'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   if p.poll() is None:p.terminate();p.wait(timeout=10)
   out.close();shutil.rmtree(home)
