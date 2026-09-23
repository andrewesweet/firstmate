# Real Claude Code 2.1.281 headless sessions (claude -p --plugin-dir <mod>), module event logs

## A. pre-change pin 2.1.278 on host 2.1.281 - reproduces the reported refusal
{"t":"2026-09-23T21:35:35.570Z","kind":"pin.refused","data":{"version":"2.1.281","pin":"2.1.278","pinSource":"running binary","probe":"2.1.281 (Claude Code)"}}

## B. bumped pin 2.1.281 - module loads, hooks run the whole turn
{"t":"2026-09-23T21:35:20.189Z","kind":"monitor.skipped","data":{"why":"session start","mode":false,"lockPid":""}}
{"t":"2026-09-23T21:35:20.282Z","kind":"session.start","data":{"cwd":"/tmp/fm-pinprobe-4Low/home2","home":"/tmp/fm-pinprobe-4Low/home2","state":"/tmp/fm-pinprobe-4Low/home2/state","enabled":false,"generation":"cc1790199320186","version":"2.1.281","pinSource":"running binary","probe":"2.1.281 (Claude Code)","persistenceOn":true,"persistenceCause":"default"}}
{"t":"2026-09-23T21:35:20.394Z","kind":"prompt.submit","data":{"origin":{"kind":"sdk"},"text":"Reply with the single word ready."}}
{"t":"2026-09-23T21:35:20.450Z","kind":"turn.start","data":{"turnId":"7af38fe3-bf07-4dff-80c5-eef7382ce54d","text":"Reply with the single word ready."}}
{"t":"2026-09-23T21:35:22.593Z","kind":"turn.complete.main","data":{"reason":"answer","usage":{"input_tokens":2,"output_tokens":4,"cache_read_input_tokens":11756,"cache_creation_input_tokens":24200,"model":"claude-opus-5-5"}}}

## C. adversarial bogus pin 9.9.9 - guard still refuses, records the deciding source
{"t":"2026-09-23T21:35:07.426Z","kind":"pin.refused","data":{"version":"2.1.281","pin":"9.9.9","pinSource":"running binary","probe":"2.1.281 (Claude Code)"}}
