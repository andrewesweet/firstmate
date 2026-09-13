# Tracing test evidence

The real spawn and teardown scripts were exercised using isolated Git fixtures and simulated terminal/harness boundaries. No live agent or MLflow server was launched. This PR's OTLP transport was additionally exercised with real curl and a local HTTP receiver.

## Observable lifecycle outputs

- `relaunch-pane-delivery.log`: generated terminal input, including carrier export before harness launch.
- `relaunch-task.meta`: persisted task carrier and original start time after relaunch.
- `relaunch-otlp.log`: emitted spawn child span, including the current and prior generation.
- `troot-done-cli.log`: successful cleanup CLI output. The test also confirmed task metadata was removed.
- `troot-done-otlp.log`, `troot-failed-otlp.log`, `troot-forced-otlp.log`: emitted cleanup root spans for successful, failed, and forced fixture cleanup.
- `http-otlp-requests.json`: actual HTTP request bodies received from real curl, showing matching trace IDs and the spawn parent pointing to the parentless task root.
- `http-delivery.log`: real HTTP delivery and strict-shell continuation after timeout and connection refusal.

Existing focused tests assert default-off omission, carrier delivery ordering, timestamp and identity preservation across relaunch, resource value preservation, endpoint precedence, and cleanup status mapping. HTTP verification script is preserved as `http-check.py`.

The initial spawn test invocation used a temporary directory inside the repository, which triggered the intended prohibition on nested secondmate homes. The retry uses normal toolchain temporary storage. No product source changes were necessary.
