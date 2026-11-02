"""Focused public-CLI checks; no lint, typecheck, pipeline, or fleet calls.

Oracle: the author's intent requires a success-chained freshness command;
--check's documented contract requires exit 1 without rewriting stale output.
Embedded-skill edits must be reflected in the generated public agent definition.
"""
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path('~/.no-mistakes/worktrees/feb37d45d9da/01M6DMD3GRCSFH194RTYRA1EWZ')
EVIDENCE = Path('~/.no-mistakes/evidence/01M6DMD3GRCSFH194RTYRA1EWZ')
AGENT = Path('.claude/mods/fm-branch-mod/agents/fm-branch.md')
SKILLS = ['stuck-crewmate-recovery', 'ask-user-authority', 'scout-completion', 'captain-hold-lifecycle']
log = []
results = []

def emit(text):
    print(text, flush=True)
    log.append(text)

def config(text):
    proc = subprocess.run(['ruby', '-ryaml', '-rjson', '-e', 'puts JSON.generate(YAML.safe_load(STDIN.read))'], input=text, text=True, capture_output=True, check=True)
    return json.loads(proc.stdout)

def clauses(command):
    lexer = shlex.shlex(command, posix=True, punctuation_chars=';&|')
    lexer.whitespace_split = True
    output = [[]]
    for token in lexer:
        if token == '&&':
            assert output[-1], 'empty command before &&'
            output.append([])
        else:
            assert token not in [';', '&', '|', '||'], f'not a success-only chain: {token}'
            output[-1].append(token)
    assert output[-1], 'empty final command'
    return output

def run(command, cwd, expected):
    proc = subprocess.run(command, cwd=cwd, text=True, capture_output=True, timeout=20)
    emit(f'$ (cwd={cwd}) {shlex.join(command)}')
    emit(f'exit={proc.returncode}')
    if proc.stdout:
        emit('stdout: ' + proc.stdout.rstrip())
    if proc.stderr:
        emit('stderr: ' + proc.stderr.rstrip())
    assert proc.returncode == expected, (command, expected, proc.returncode)
    return proc

try:
    current = config((ROOT / '.no-mistakes.yaml').read_text())
    base_yaml = subprocess.run(['git', 'show', '367c846cc35314f778d11f9f0dd2ea45cc5f5eef:.no-mistakes.yaml'], cwd=ROOT, text=True, capture_output=True, check=True).stdout
    old_chain = clauses(config(base_yaml)['commands']['lint'])
    chain = clauses(current['commands']['lint'])
    required = ['bin/fm-branch-agent-md.sh', '--check']
    assert chain == old_chain + [required], chain
    assert required not in old_chain, 'baseline unexpectedly already checks freshness'
    guard = chain[-1]
    emit('Parsed commands.lint as a success-only command chain:')
    emit(json.dumps(chain, indent=2))
    emit('The base configuration lacks the required guard; the target adds it after the unchanged two prior commands.')
    emit('Lint and typecheck clauses were not executed: this Test phase forbids those phases.')
    committed_bytes = (ROOT / AGENT).read_bytes()
    run(guard, ROOT, 0)
    assert (ROOT / AGENT).read_bytes() == committed_bytes
    results.append({'name': 'Configured freshness command accepts the committed current agent without rewriting it', 'result': 'pass', 'live': True})

    with tempfile.TemporaryDirectory(prefix='.fm-agent-freshness-live-', dir=ROOT) as scratch:
        fixture = Path(scratch)
        for path in [Path('bin/fm-branch-agent-md.sh'), Path('bin/fm-branch-prompt.sh'), AGENT] + [Path('.agents/skills') / name / 'SKILL.md' for name in SKILLS]:
            target = fixture / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / path, target)
        output = fixture / AGENT
        run(guard, fixture, 0)
        output.write_bytes(committed_bytes + b'\nSTALE GENERATED OUTPUT\n')
        stale_bytes = output.read_bytes()
        refused = run(guard, fixture, 1)
        assert refused.stdout == ''
        assert refused.stderr == f'stale: {output} (run bin/fm-branch-agent-md.sh)\n'
        assert output.read_bytes() == stale_bytes, '--check rewrote stale output'
        emit('Stale generated output rejected; file bytes unchanged by --check.')
        run(['bin/fm-branch-agent-md.sh'], fixture, 0)
        run(guard, fixture, 0)
        assert output.read_bytes() == committed_bytes
        results.append({'name': 'Developer checks a stale generated agent, receives the file and regeneration command, then regenerates successfully', 'result': 'pass', 'live': True})

        for name in SKILLS:
            skill = fixture / '.agents/skills' / name / 'SKILL.md'
            original_skill = skill.read_bytes()
            marker = f'\nFreshness validation input for {name}.\n'.encode()
            try:
                skill.write_bytes(original_skill + marker)
                emit(f'Only input changed: .agents/skills/{name}/SKILL.md; both generators and the generated file are unchanged.')
                refused = run(guard, fixture, 1)
                assert refused.stderr == f'stale: {output} (run bin/fm-branch-agent-md.sh)\n'
                assert output.read_bytes() == committed_bytes
                run(['bin/fm-branch-agent-md.sh'], fixture, 0)
                run(guard, fixture, 0)
                generated = output.read_bytes()
                assert marker in generated, 'generated public definition omitted the changed skill input'
                emit(f'Regenerated public agent contains the changed {name} input; sha256={hashlib.sha256(generated).hexdigest()}')
            finally:
                skill.write_bytes(original_skill)
                output.write_bytes(committed_bytes)
        results.append({'name': 'Developer changes each embedded skill alone; freshness refuses until the agent is regenerated with that change', 'result': 'pass', 'live': True})
    assert not Path(scratch).exists()
    emit('Disposable fixture removed; committed generated agent remains byte-identical.')
    assert (ROOT / AGENT).read_bytes() == committed_bytes
finally:
    (EVIDENCE / 'agent-freshness-cli.log').write_text('\n'.join(log) + '\n')
    (EVIDENCE / 'agent-freshness-results.json').write_text(json.dumps(results, indent=2) + '\n')
