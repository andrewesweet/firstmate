#!/usr/bin/env python3
"""Confirm the two existing regressions reject wrong metadata selection.

Only disposable executable copies are mutated. The status guard remains intact,
so a failure demonstrates the metadata behavior rather than the status behavior.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path('~/.no-mistakes/worktrees/5ac353bebe94/01M54NF7FAK33AVF9TVBAP55YG')
EVIDENCE = Path('~/.no-mistakes/evidence/01M54NF7FAK33AVF9TVBAP55YG')
LAB = ROOT / '.metadata-mutation-check'
DRIVER = ROOT / 'tests/.crew-state-regression-driver.sh'
assert not LAB.exists() and not DRIVER.exists()
rows = []
try:
    LAB.mkdir()
    (LAB / 'tmp').mkdir()
    suite = (ROOT / 'tests/fm-crew-state.test.sh').read_text()
    definitions, marker, _ = suite.partition('\ntest_captured_axi_status_shapes\n')
    assert marker, 'Cannot identify existing regression dispatch boundary'
    DRIVER.write_text(definitions + '\nCREW_STATE=${CREW_STATE_CANDIDATE:-$CREW_STATE}\n"$1"\n')
    source = (ROOT / 'bin/fm-crew-state.sh').read_text()
    guard = '''case ${FM_CREW_STATE_META_OVERRIDE:-} in
  "$ID.meta"|*/"$ID.meta") META=$FM_CREW_STATE_META_OVERRIDE ;;
  *) META=$STATE/$ID.meta ;;
esac'''
    assert source.count(guard) == 1
    variants = {
        'foreign-metadata-accepted': 'META=${FM_CREW_STATE_META_OVERRIDE:-"$STATE/$ID.meta"}',
        'matching-metadata-ignored': 'META=$STATE/$ID.meta',
    }
    paths = {'current': ROOT / 'bin/fm-crew-state.sh'}
    for name, replacement in variants.items():
        directory = LAB / name
        directory.mkdir()
        for item in (ROOT / 'bin').iterdir():
            if item.name != 'fm-crew-state.sh':
                (directory / item.name).symlink_to(item)
        command = directory / 'fm-crew-state.sh'
        command.write_text(source.replace(guard, replacement))
        command.chmod(0o755)
        paths[name] = command
    for variant, test, expected_rc in [
        ('current', 'test_mismatched_state_override_is_ignored', 0),
        ('current', 'test_matched_state_override_is_honoured', 0),
        ('foreign-metadata-accepted', 'test_mismatched_state_override_is_ignored', 1),
        ('matching-metadata-ignored', 'test_matched_state_override_is_honoured', 1),
    ]:
        env = {key: value for key, value in os.environ.items() if not key.startswith('FM_')}
        env.update(TMPDIR=str(LAB / 'tmp'), CREW_STATE_CANDIDATE=str(paths[variant]))
        result = subprocess.run(['bash', str(DRIVER), test], cwd=ROOT, env=env,
                                text=True, capture_output=True, timeout=30)
        row = {'variant': variant, 'test': test, 'expected_exit': expected_rc,
               'actual_exit': result.returncode, 'stdout': result.stdout.strip(),
               'stderr': result.stderr.strip()}
        rows.append(row)
        print(json.dumps(row, indent=2), flush=True)
        assert result.returncode == expected_rc
finally:
    DRIVER.unlink(missing_ok=True)
    if LAB.exists():
        shutil.rmtree(LAB)
    (EVIDENCE / 'metadata-regression-mutation-results.json').write_text(json.dumps(rows, indent=2) + '\n')
    print('Disposable metadata mutations and temporary regression driver removed.', flush=True)
