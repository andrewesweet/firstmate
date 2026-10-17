// Independent oracle: child exit status/stdout/stderr remain authoritative;
// bin/fm-operational-input.sh's public wire contract supplies the typed prefix.
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { EventEmitter } from 'node:events';
import assert from 'node:assert/strict';
const root='~/.no-mistakes/worktrees/c75a534c6389/01M54HXZWEKVDYCYK19Q7245WW';
const {encodeFirstmateOperationalInput:encode}=await import(pathToFileURL(`${root}/.opencode/plugins/lib/fm-operational-input.js`));
const guardRoot=process.argv[2] || root;
const {FmPrimaryTurnendGuard:guard}=await import(pathToFileURL(`${guardRoot}/.opencode/plugins/fm-primary-turnend-guard.js`));
const lab=mkdtempSync(`${process.env.FM_EPIPE_TEST_TMPDIR || root}/.stdin-outcomes-`);
mkdirSync(`${lab}/bin`);
let errors=[];
const emit=EventEmitter.prototype.emit;
EventEmitter.prototype.emit=function(name,...args) {
  if(name==='error' && args[0]?.code==='EPIPE') errors.push('EPIPE');
  return emit.call(this,name,...args);
};
const payload='x'.repeat(8*1024*1024);
const script=body=>writeFileSync(`${lab}/bin/fm-operational-input.sh`,`#!/usr/bin/env bash\nexec 0<&-\n${body}\n`,{mode:0o755});
try {
  console.log(JSON.stringify({runtime:{node:process.versions.node,bun:process.versions.bun},oracle:'Intent: ignore stdin transport errors; preserve child result. Public encoder protocol: U+2063 FIRSTMATE_OP: v1 <kind>: <body>.'}));
  script('printf "child refused with status 7\\n" >&2\nexit 7');
  await assert.rejects(encode(lab,'watcher',payload),{message:'child refused with status 7'});
  console.log(JSON.stringify({case:'nonreader exit 7',result:'rejected with exact child diagnostic',broken_pipe_events:errors.length}));
  assert.ok(errors.length>0,'EPIPE must actually occur');
  script('printf "CHILD_CHOSEN_OUTPUT\\n"\nexit 0');
  assert.equal(await encode(lab,'watcher',payload),'CHILD_CHOSEN_OUTPUT\n');
  console.log(JSON.stringify({case:'nonreader exit 0 with output',result:'resolved with exact child stdout',broken_pipe_events:errors.length}));
  script('exit 0');
  await assert.rejects(encode(lab,'watcher',payload),{message:'operational-input encoder exited 0'});
  console.log(JSON.stringify({case:'nonreader exit 0 without output',result:'existing empty-output rejection preserved',broken_pipe_events:errors.length}));
  writeFileSync(`${lab}/bin/fm-operational-input.sh`, `#!/usr/bin/env bash\nexec '${root}/bin/fm-operational-input.sh' "$@"\n`,{mode:0o755});
  const normal='First line\nSecond line';
  assert.equal(await encode(lab,'watcher',normal),'\u2063FIRSTMATE_OP: v1 watcher: '+normal);
  console.log(JSON.stringify({case:'real encoder normal input',stdout:await encode(lab,'watcher',normal)}));
  await assert.rejects(encode(lab,'not-a-kind',normal),{message:'operational-input encoder exited 2'});
  console.log(JSON.stringify({case:'real encoder refuses invalid kind',result:'child diagnostic preserved',broken_pipe_events:errors.length}));
  // Stress the guard's separate stdin writer with the fastest available child.
  writeFileSync(`${lab}/bin/fm-turnend-guard.sh`,'#!/usr/bin/true\n',{mode:0o755});
  const hook=await guard({directory:lab,worktree:lab,client:{session:{promptAsync:async()=>assert.fail('early guard exit must not prompt')}}});
  const before=errors.length;
  for(let i=0;i<1000;i++) await hook.event({event:{type:'session.idle',properties:{sessionID:'live-boundary-probe'}}});
  console.log(JSON.stringify({case:'guard child exits before reading',calls:1000,host_survived:true,broken_pipe_events:errors.length-before}));
} finally { EventEmitter.prototype.emit=emit;rmSync(lab,{recursive:true,force:true}); }
