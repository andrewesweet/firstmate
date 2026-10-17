from pathlib import Path
source=Path('.test-runtime/live-trace.py').read_text()
source=source.replace("work = root / '.test-runtime/live'", "work = root / '.test-runtime/live-enabled-empty'")
source=source.replace("/01M54R9YEHJ6EPAQ78ZYQS4VRY')", "/01M54R9YEHJ6EPAQ78ZYQS4VRY/enabled-empty')")
source=source.replace("work.mkdir(parents=True, exist_ok=True)", "work.mkdir(parents=True, exist_ok=True)\nevidence.mkdir(parents=True, exist_ok=True)")
start=source.index('    cases=[')
end=source.index('\n    if len(sys.argv)',start)
source=source[:start]+"    cases=[('on-empty-allowlist','on','')]"+source[end:]
exec(compile(source,'live-trace-enabled-empty','exec'))
