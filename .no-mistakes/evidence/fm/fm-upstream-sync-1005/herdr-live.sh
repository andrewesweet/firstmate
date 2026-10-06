#!/bin/bash
set -eu
export FM_HERDR_LAB_STATE_DIR="$PWD/t/herdr-state"
. bin/fm-herdr-lab.sh
lab_session=$(fm_herdr_lab_name sync-product)
trap 'fm_herdr_lab_teardown "$lab_session"' EXIT
fm_herdr_lab_provision "$lab_session"
fm_herdr_lab_cli "$lab_session" status --json
fm_herdr_lab_cli "$lab_session" workspace create --label isolated-sync --cwd "$PWD"
fm_herdr_lab_cli "$lab_session" tab create --cwd "$PWD" --label isolated-sync --no-focus
fm_herdr_lab_cli "$lab_session" pane list
