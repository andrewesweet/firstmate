import pathlib, subprocess, sys
root=pathlib.Path.cwd()
baseline=root/'bin/.fm-trace-before-fix.sh'
assert not baseline.exists()
baseline.write_bytes(subprocess.check_output(['git','show','66c300bdf5f5f338a6fc4918a89c9d1525dcb7e3:bin/fm-spawn.sh']))
baseline.chmod(0o700)
source=(root/'.test-runtime/live-trace.py').read_text()
source=source.replace("work = root / '.test-runtime/live'", "work = root / '.test-runtime/live-before-fix'")
source=source.replace("/01M54R9YEHJ6EPAQ78ZYQS4VRY')", "/01M54R9YEHJ6EPAQ78ZYQS4VRY/before-fix')")
source=source.replace("work.mkdir(parents=True, exist_ok=True)", "work.mkdir(parents=True, exist_ok=True)\nevidence.mkdir(parents=True, exist_ok=True)")
source=source.replace("root/'bin/fm-spawn.sh'", "root/'bin/.fm-trace-before-fix.sh'")
source=source.replace("assert tp is None, f'{name}: ambient trace leaked: {tp}'", "assert tp == env['TRACEPARENT'], f'{name}: expected original ambient-carrier leak, observed: {tp}'")
source=source.replace("'result':'pass'", "'result':'original stale-carrier leak reproduced'")
sys.argv=['before-fix.py','1']
try:
    exec(compile(source,'live-trace-before-fix','exec'))
finally:
    baseline.unlink()
