#!/usr/bin/env python3
"""Drive real windowless task cleanup in marked disposable lab homes.
Oracle: cleanup captures supervision.md before retiring task status (required intent).
No backend endpoint exists, so no live panes are probed or closed.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import traceback

root = Path.cwd()
evidence = Path('~/.no-mistakes/evidence/01M5X410KFS4SEYWSEKPVXT197')
lab = Path(tempfile.mkdtemp(prefix='wiki-cleanup-', dir=root/'.test-tmp/wiki-validation'))
env = os.environ.copy()
for key in list(env):
    if key.startswith(('FM_', 'GIT_', 'TASKS_AXI_', 'OTEL_')) or key in ('TMUX', 'HERDR_ENV'):
        env.pop(key)
env.update(HOME=str(lab/'login-home'), XDG_CONFIG_HOME=str(lab/'xdg'), TMPDIR=str(lab),
           GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           GIT_AUTHOR_NAME='Wiki validation', GIT_COMMITTER_NAME='Wiki validation',
           GIT_AUTHOR_EMAIL='wiki@example.invalid', GIT_COMMITTER_EMAIL='wiki@example.invalid',
           FM_WIKI_CLOSE_DRAIN='0')
Path(env['HOME']).mkdir()
Path(env['XDG_CONFIG_HOME']).mkdir()
results = []
with (evidence/'wiki-cleanup-transcript.log').open('w', buffering=1) as log:
    def run(args, local_env=env):
        log.write('$ '+' '.join(map(str,args))+'\n')
        p = subprocess.run(list(map(str,args)), env=local_env, cwd=root, capture_output=True, text=True, timeout=50)
        log.write(p.stdout+p.stderr+f'[exit {p.returncode}]\n')
        assert p.returncode == 0, p.stdout+p.stderr
        return p.stdout
    try:
        for kind in ('ship', 'scout'):
            name = f'Retire a finished {kind} and retain its supervisor lesson with final-status attribution'
            try:
                h=lab/kind
                run([root/'bin/fm-lab-home.sh','create',h])
                local_env=env|dict(FM_HOME=str(h))
                (h/'config/wiki').write_text('role=contributor\n')
                task='wiki-live-cleanup-'+kind
                project=h/'projects/local'
                project.mkdir()
                run(['git','init','-q','--initial-branch=main',project])
                (h/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
                run([root/'bin/fm-tasks-axi.sh','add',task,'Isolated wiki cleanup task','--kind',kind],local_env)
                run([root/'bin/fm-tasks-axi.sh','start',task],local_env)
                (h/'state'/f'{task}.meta').write_text(f'kind={kind}\nharness=codex\nmode=local-only\nproject={project}\nworktree={h/"missing-worktree"}\n')
                (h/'state'/f'{task}.status').write_text('done [at=1]: isolated lab cleanup\n')
                data=h/'data'/task
                data.mkdir()
                if kind=='scout':
                    (data/'report.md').write_text('# Isolated completed scout\nNo unresolved choices.\n')
                    run([root/'bin/fm-captain-hold.sh','complete',task,'--none'],local_env)
                body=f'## Capture {kind} supervision before cleanup\nscope: supervision\nclaim: retain the final outcome\nevidence: real marked-lab task teardown\n'
                (data/'supervision.md').write_text(body)
                run([root/'bin/fm-teardown.sh',task], local_env)
                assert not (h/'state'/f'{task}.meta').exists()
                assert not (h/'state'/f'{task}.status').exists()
                queued=list((h/'state/wiki/outbox').glob('*.md'))
                assert len(queued)==1
                raw=queued[0].read_text()
                log.write('Saved raw lesson after metadata/status retirement:\n'+raw)
                assert body in raw and 'wiki-role: supervisor\n' in raw
                assert 'wiki-final: done\n' in raw and 'wiki-agent: firstmate\n' in raw
                ledger=(h/'state/wiki/ledger.jsonl').read_text()
                log.write('Saved capture ledger:\n'+ledger)
                record=json.loads(ledger)
                assert record['supervisor']=='lesson' and record['files']==1
                shown=run([root/'bin/fm-tasks-axi.sh','show',task],local_env)
                assert 'state: done' in shown
                results.append(dict(name=name,result='pass',live=True,evidence='wiki-cleanup-transcript.log',reason=''))
            except Exception as ex:
                log.write(traceback.format_exc())
                results.append(dict(name=name,result='fail',live=True,evidence='wiki-cleanup-transcript.log',reason=str(ex)))
            print(results[-1]['result']+': '+name,flush=True)
    finally:
        shutil.rmtree(lab)
        log.write('TEARDOWN: removed marked lab homes and all task data. No backend endpoint was used.\n')
(evidence/'wiki-cleanup-results.json').write_text(json.dumps(results,indent=2)+'\n')
raise SystemExit(any(r['result']!='pass' for r in results))
