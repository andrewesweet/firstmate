#!/usr/bin/env python3
"""Real changed sender/receiver over loopback SSH, with disposable auth and direct dispatch.
The SSH forced-command adapter decodes fm-on's envelope and invokes the actual
fm-remote-inherit.sh receiver, avoiding the unrelated account-level job daemon.
No sender, receiver, SSH client, SSH server, or Git operation is mocked.
"""
import base64
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
ROOT=Path.cwd()
f=Path(tempfile.mkdtemp(prefix='.wiki-ssh-',dir=ROOT))
server=None
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_','GIT_','TASKS_AXI_')): env.pop(k,None)
env.update(HOME=str(f/'account'),TMPDIR=str(f/'tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
for p in ('account','tmp','parent/config','parent/data','parent/state','child/config','child/data','child/state'):
    (f/p).mkdir(parents=True,exist_ok=True)
def run(args,check=True):
    p=subprocess.run([str(a) for a in args],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=45)
    print('$ '+' '.join(str(a) for a in args),flush=True)
    if p.stdout: print(p.stdout.rstrip(),flush=True)
    if p.stderr: print('stderr: '+p.stderr.rstrip(),flush=True)
    if check and p.returncode: raise RuntimeError(f'exit {p.returncode}')
    return p
try:
    run(['ssh-keygen','-q','-t','ed25519','-N','','-f',f/'host-key'])
    run(['ssh-keygen','-q','-t','ed25519','-N','','-f',f/'client-key'])
    # Direct isolated transport dispatch. Product stdin and return status pass unchanged.
    dispatch=f/'dispatch.py'
    dispatch.write_text('''#!/usr/bin/env python3
import base64, os, shlex, sys
from pathlib import Path
root=Path('''+repr(str(ROOT))+''')
f=Path('''+repr(str(f))+''')
a=shlex.split(os.environ['SSH_ORIGINAL_COMMAND'])
assert len(a)==5 and a[0]=='fm-remote-entrypoint.sh' and a[1]=='1'
assert base64.b64decode(a[2]).decode()==str(root)
home=base64.b64decode(a[3]).decode()
assert home==str(f/'child')
argv=[x.decode() for x in base64.b64decode(a[4]).split(b'\\0') if x]
assert argv[0]=='fm-remote-inherit.sh'
e={'PATH': '/usr/bin:/bin', 'HOME':str(f/'account'), 'FM_HOME':home,
   'TMPDIR':str(f/'tmp'), 'GIT_CONFIG_GLOBAL':'/dev/null','GIT_CONFIG_NOSYSTEM':'1'}
os.execve(str(root/'bin'/argv[0]),[str(root/'bin'/argv[0]),*argv[1:]],e)
''')
    dispatch.chmod(0o700)
    user=run(['id','-un']).stdout.strip()
    s=socket.socket(); s.bind(('127.0.0.1',0)); port=s.getsockname()[1]; s.close()
    sshd=f/'sshd.conf'
    sshd.write_text(f'Port {port}\nListenAddress 127.0.0.1\nHostKey {f}/host-key\nPidFile {f}/sshd.pid\nAuthorizedKeysFile {f}/client-key.pub\nStrictModes no\nUsePAM no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\nAllowUsers {user}\nPrintMotd no\nLogLevel ERROR\nForceCommand {dispatch}\n')
    server_log=(f/'sshd.log').open('w')
    server=subprocess.Popen(['/usr/sbin/sshd','-D','-f',str(sshd)],env=env,stdout=server_log,stderr=server_log)
    for _ in range(50):
        if server.poll() is not None: raise RuntimeError((f/'sshd.log').read_text())
        try:
            with socket.create_connection(('127.0.0.1',port),timeout=.1): break
        except OSError: time.sleep(.1)
    known=f/'known_hosts'
    pub=(f/'host-key.pub').read_text().split()
    known.write_text(f'[127.0.0.1]:{port} {pub[0]} {pub[1]}\n')
    client_config=f/'ssh.conf'
    client_config.write_text(f'Host wiki-validation\n  HostName 127.0.0.1\n  Port {port}\n  User {user}\n  IdentityFile {f}/client-key\n  IdentitiesOnly yes\n  IdentityAgent none\n  UserKnownHostsFile {known}\n  StrictHostKeyChecking yes\n  BatchMode yes\n')
    client=f/'ssh-client'
    client.write_text(f'#!/bin/sh\nexec /usr/bin/ssh -F {client_config} "$@"\n')
    client.chmod(0o700)
    parent=f/'parent'; child=f/'child'
    (parent/'data/secondmates.md').write_text(f'- sm - isolated SSH wiki child (host: wiki-validation; root: {ROOT}; home: {child}; scope: validation; projects: alpha; added 2026-10-26)\n')
    env.update(FM_HOME=str(parent),FM_ROOT_OVERRIDE=str(ROOT),FM_SSH_BIN=str(client),FM_INHERITABLE_CONFIG='wiki')
    expected='remote=file:///isolated-wiki.git\nrole=contributor\njev=on\n'
    (parent/'config/wiki').write_text('host=must-not-transfer\nremote=file:///isolated-wiki.git\nrole=gardener\njev=on\n')
    run([ROOT/'bin/fm-remote-inherit-push.sh','sm','1'])
    assert (child/'config/wiki').read_text()==expected
    print('Observed remote child config:\n'+(child/'config/wiki').read_text(),flush=True)
    before=(child/'config/wiki').stat().st_mtime_ns
    run([ROOT/'bin/fm-remote-inherit-push.sh','sm','2'])
    assert (child/'config/wiki').stat().st_mtime_ns==before
    print('Observed repeat remote push unchanged.',flush=True)
    (parent/'config/wiki').unlink()
    run([ROOT/'bin/fm-remote-inherit-push.sh','sm','3'])
    assert (child/'config/wiki').read_text()==expected
    (parent/'config/wiki').write_text('role=off\nremote=file:///isolated-wiki.git\n')
    run([ROOT/'bin/fm-remote-inherit-push.sh','sm','4'])
    assert (child/'config/wiki').read_text()==expected
    print('Observed absent and inactive primary leave exact remote child config bytes unchanged.',flush=True)
    print('LIVE SSH SENDER/RECEIVER SCENARIO COMPLETED',flush=True)
finally:
    if server and server.poll() is None:
        server.terminate()
        server.wait(timeout=10)
    shutil.rmtree(f)
    print('Disposable SSH server, keys, homes and transport adapter removed.',flush=True)
