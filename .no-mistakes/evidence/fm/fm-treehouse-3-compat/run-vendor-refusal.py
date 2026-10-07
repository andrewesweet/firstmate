import pathlib,os,subprocess,json
root=pathlib.Path.cwd(); base=root/'.v'; evidence=pathlib.Path('/home/cti/.no-mistakes/evidence/01M4A57VKWXAXVVTYZ7H6SP6T0')
env=os.environ.copy()
for key in ['TREEHOUSE_ROOT','TREEHOUSE_UNIQUE_LEAF','TREEHOUSE_WORKTREE_PATH']: env.pop(key,None)
env.update(TMPDIR=str(base/'tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
with (evidence/'vendor-dirty-refusal.log').open('w') as log:
 def run(args,cwd,input=''):
  p=subprocess.run(args,cwd=cwd,env=env,input=input,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
  log.write('$ '+subprocess.list2cmdline(args)+'\n'+p.stdout+f'[exit {p.returncode}]\n');log.flush()
  return p
 for version in ['v2','v3']:
  binary=str(base/version/'treehouse');project=base/version/'lab'/'projects'/'sample'
  p=run([binary,'--version'],root);assert p.returncode==0
  task='vendor-'+version+'-dirty'
  p=run([binary,'get','--lease','--lease-holder',task],project);assert p.returncode==0
  slot=pathlib.Path(p.stdout.strip().splitlines()[-1]);assert slot.is_relative_to(base/version/'lab')
  dirt=slot/'untracked.txt';dirt.write_text('preserve me\n')
  state=slot.parent.parent/'treehouse-state.json'
  before=json.loads(state.read_text()); log.write('POOL BEFORE '+json.dumps(before)+'\n')
  p=run([binary,'return','--if-lease-holder',task,str(slot)],project)
  assert p.returncode==({'v2':0,'v3':3}[version])
  assert dirt.read_text()=='preserve me\n'
  assert json.loads(state.read_text())==before
  log.write('OBSERVED dirty file, lease identity, holder and pool state are unchanged\n')
  if version=='v3':
   p=run([binary,'return','--if-lease-holder',task,str(slot)],project,input='n\n')
   assert p.returncode==3 and 'worktree not returned: cleaning declined' in p.stdout
   assert json.loads(state.read_text())==before and dirt.read_text()=='preserve me\n'
   log.write('OBSERVED explicitly declining cleaning also preserves the lease and dirty copy\n')
  p=run([binary,'return','--force','--if-lease-holder',task,str(slot)],project);assert p.returncode==0
  assert not dirt.exists()
  after=json.loads(state.read_text());log.write('POOL AFTER FORCE '+json.dumps(after)+'\n')
  entry=next(x for x in after['worktrees'] if x['path']==str(slot));assert not entry.get('leased',False)
  log.write('OBSERVED --force cleaned and released the lease\n');log.flush()
print('Real vendor dirty-refusal transcript:',evidence/'vendor-dirty-refusal.log')
