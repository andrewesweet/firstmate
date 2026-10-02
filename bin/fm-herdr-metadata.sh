#!/usr/bin/env bash
# bin/fm-herdr-metadata.sh - display-only Herdr pane metadata projection entry.
#
# Thin public interface over bin/backends/herdr-metadata.sh for the call sites
# that project task records onto the task's own Herdr pane: spawn (publish
# after endpoint creation), supervision's bounded reconcile tick (publish),
# PR registration (publish), and teardown (clear before the pane close).
# docs/herdr-backend.md "Endpoint metadata projection" owns the field contract
# and the display-only boundaries.
#
# Usage:
#   fm-herdr-metadata.sh publish <task-id>   project current records onto the pane
#   fm-herdr-metadata.sh clear <task-id>     erase every Firstmate-owned value
#
# The projection is strictly best effort: a refusal or write failure prints a
# one-line diagnostic to stderr and exits nonzero, and never blocks the caller.
# A non-Herdr or remote-hosted task record is a silent no-op (exit 0).
set -u

action=${1:-}
id=${2:-}
case $action in
  publish|clear) ;;
  *) printf 'usage: fm-herdr-metadata.sh publish|clear <task-id>\n' >&2; exit 2 ;;
esac
[ -n "$id" ] || { printf 'usage: fm-herdr-metadata.sh publish|clear <task-id>\n' >&2; exit 2; }

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P) || exit 1

# shellcheck source=bin/fm-backend.sh
. "$ROOT/fm-backend.sh"
fm_backend_source herdr || exit 0

case $action in
  publish) fm_backend_herdr_metadata_publish "$id" ;;
  clear) fm_backend_herdr_metadata_clear "$id" ;;
esac
