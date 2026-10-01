#!/usr/bin/env bash
# Apply one primary-authoritative inherited item inside the selected remote home.
#
# Usage:
#   fm-remote-inherit.sh put <allowlisted-relative-path> <bytes> <sha256> <generation> < stdin
#   fm-remote-inherit.sh absent <allowlisted-relative-path> 0 <empty-sha256> <generation>
#
# Only the inherited-material allowlist is writable or removable. Writes are
# atomic ordinary-file replacements. data/captain-shared.md is read-only and is
# quarantined before removal or before replacing bytes not last published here.
set -eu

FM_HOME=${FM_HOME:?FM_HOME is required}
MAX_BYTES=1048576
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
file_link_count() {
  if [ "$(uname)" = Darwin ]; then /usr/bin/stat -f %l "$1" 2>/dev/null; else stat -c %h "$1" 2>/dev/null; fi
}
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}
# Writable set, derived from the ONE declared inherited-material owner
# (FM_INHERITABLE_CONFIG in bin/fm-config-inherit-lib.sh), so this code root's
# receiver and sender cannot drift silently. This runs under the remote
# entrypoint's fixed empty environment, so the declaration is this code root's
# own, never something the caller can widen over SSH; a caller from a different
# revision must match it or the transfer fails closed.
allowed() {
  local candidate
  while IFS= read -r candidate; do
    [ "$candidate" = "$1" ] && return 0
  done <<EOF
$(fm_config_inherit_items)
EOF
  return 1
}

[ "$#" -eq 5 ] || usage
COMMAND=$1
REL=$2
EXPECTED_BYTES=$3
EXPECTED_HASH=$4
GENERATION=$5
allowed "$REL" || die "path is not inherited material: $REL"
case "$EXPECTED_BYTES" in ''|*[!0-9]*) die "expected bytes must be a nonnegative integer" ;; esac
[ "${#EXPECTED_BYTES}" -le 10 ] || die "expected bytes exceed the byte bound"
[ "$EXPECTED_BYTES" -le "$MAX_BYTES" ] || die "expected bytes exceed the byte bound"
case "$EXPECTED_HASH" in ''|*[!A-Fa-f0-9]*) die "expected SHA-256 is invalid" ;; esac
[ "${#EXPECTED_HASH}" -eq 64 ] || die "expected SHA-256 has the wrong length"
EXPECTED_HASH=$(printf '%s' "$EXPECTED_HASH" | tr 'A-F' 'a-f')
case "$GENERATION" in ''|*[!0-9]*) die "generation must be a positive integer" ;; esac
[ "${#GENERATION}" -le 18 ] && [ "$GENERATION" -ge 1 ] || die "generation is outside the supported range"
HOME_REAL=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die "FM_HOME is unavailable"
PARENT="$HOME_REAL/$(dirname "$REL")"
# The captain accepts this config/data parent TOCTOU within Firstmate's single-user trust boundary.
[ ! -L "$PARENT" ] || die "inherited destination parent is a symlink"
mkdir -p "$PARENT" || die "cannot create inherited destination parent"
PARENT_REAL=$(CDPATH='' cd -- "$PARENT" && pwd -P)
case "$PARENT_REAL" in "$HOME_REAL/config"|"$HOME_REAL/data") ;; *) die "inherited destination escapes FM_HOME" ;; esac
DEST="$PARENT_REAL/$(basename "$REL")"
[ ! -L "$DEST" ] || die "inherited destination is a symlink"
if [ -e "$DEST" ]; then
  [ -f "$DEST" ] || die "inherited destination is not a regular file"
  [ "$(file_link_count "$DEST")" = 1 ] || die "inherited destination is hardlinked"
fi

BASE=$(basename "$REL")
LOCK="$PARENT_REAL/.fm-inherit-$BASE.lock"
GENERATION_FILE="$PARENT_REAL/.fm-inherit-$BASE.generation"
fm_lock_acquire_wait "$LOCK" || die "cannot lock inherited destination"
TMP=
GENERATION_TMP=
# Digest this receiver last published to DEST, read from the receipt's applied
# record before staging a newer generation. Empty when no put generation has
# been applied here. LAST_PENDING_HASH is the payload digest of an interrupted
# in-flight put generation, so a destination holding it is convergence too.
LAST_PUBLISHED_HASH=
LAST_PENDING_HASH=
cleanup() {
  [ -z "$TMP" ] || rm -f -- "$TMP"
  [ -z "$GENERATION_TMP" ] || rm -f -- "$GENERATION_TMP"
  fm_lock_release "$LOCK" || true
}
trap cleanup EXIT

# The generation receipt beside the destination holds one applied record and,
# while a transfer is in flight, one newer pending record after it. Each
# record is five newline-terminated fields: state, generation, bytes, hash,
# command. A four-line receipt written by revisions before pending state
# existed is one applied record. Pending means only that the transfer was
# staged; the record is promoted to applied once the destination holds the
# payload, so an interrupted transfer can never make the previous copy read
# as drift on retry.
validate_receipt_record() {  # <state> <generation> <bytes> <hash> <command>
  case "$1" in applied|pending) ;; *) die "inheritance generation record is malformed" ;; esac
  case "$2" in ''|*[!0-9]*) die "inheritance generation record is malformed" ;; esac
  [ "${#2}" -le 18 ] || die "inheritance generation record is malformed"
  case "$3" in ''|*[!0-9]*) die "inheritance generation record is malformed" ;; esac
  case "$4" in ''|*[!A-Fa-f0-9]*) die "inheritance generation record is malformed" ;; esac
  [ "${#4}" -eq 64 ] || die "inheritance generation record is malformed"
  case "$5" in put|absent) ;; *) die "inheritance generation record is malformed" ;; esac
}

# Parse the receipt into APPLIED_* (APPLIED_PRESENT=1 when an applied record
# exists) and PENDING_* (PENDING_GEN empty when none) globals.
read_generation_receipt() {
  APPLIED_PRESENT=0
  APPLIED_GEN=
  APPLIED_BYTES=
  APPLIED_HASH=
  APPLIED_CMD=
  PENDING_GEN=
  PENDING_BYTES=
  PENDING_HASH=
  PENDING_CMD=
  [ -e "$GENERATION_FILE" ] || [ -L "$GENERATION_FILE" ] || return 0
  [ -f "$GENERATION_FILE" ] && [ ! -L "$GENERATION_FILE" ] || die "inheritance generation record is unsafe"
  local line lines=0
  set --
  while IFS= read -r line || [ -n "$line" ]; do
    lines=$((lines + 1))
    [ "$lines" -le 10 ] || die "inheritance generation record is malformed"
    set -- "$@" "$line"
  done < "$GENERATION_FILE"
  [ "$lines" -ge 1 ] || die "inheritance generation record is malformed"
  if [ "$1" = applied ] || [ "$1" = pending ]; then
    case "$lines" in 5|10) ;; *) die "inheritance generation record is malformed" ;; esac
    validate_receipt_record "$1" "$2" "$3" "$4" "$5"
    if [ "$1" = applied ]; then
      APPLIED_PRESENT=1
      APPLIED_GEN=$2 APPLIED_BYTES=$3 APPLIED_HASH=$4 APPLIED_CMD=$5
      if [ "$lines" -eq 10 ]; then
        [ "$6" = pending ] || die "inheritance generation record is malformed"
        validate_receipt_record "$6" "$7" "$8" "$9" "${10}"
        PENDING_GEN=$7 PENDING_BYTES=$8 PENDING_HASH=$9 PENDING_CMD=${10}
      fi
    else
      PENDING_GEN=$2 PENDING_BYTES=$3 PENDING_HASH=$4 PENDING_CMD=$5
    fi
  else
    [ "$lines" -eq 4 ] || die "inheritance generation record is malformed"
    validate_receipt_record applied "$1" "$2" "$3" "$4"
    APPLIED_PRESENT=1
    APPLIED_GEN=$1 APPLIED_BYTES=$2 APPLIED_HASH=$3 APPLIED_CMD=$4
  fi
  APPLIED_HASH=$(printf '%s' "$APPLIED_HASH" | tr 'A-F' 'a-f')
  if [ -n "$PENDING_HASH" ]; then
    PENDING_HASH=$(printf '%s' "$PENDING_HASH" | tr 'A-F' 'a-f')
  fi
  return 0
}

write_applied_generation() {  # <generation> <bytes> <hash> <command>
  GENERATION_TMP=$(umask 077; mktemp "$PARENT_REAL/.inherit-generation.XXXXXX") \
    || die "cannot stage inheritance generation"
  printf 'applied\n%s\n%s\n%s\n%s\n' "$1" "$2" "$3" "$4" > "$GENERATION_TMP" \
    || die "cannot write inheritance generation"
  chmod 600 "$GENERATION_TMP" || die "cannot secure inheritance generation"
  mv -f -- "$GENERATION_TMP" "$GENERATION_FILE" || die "cannot publish inheritance generation"
  GENERATION_TMP=
}

# Stage the incoming generation as pending, keeping the applied record so a
# retry after an interrupted transfer can still tell an untouched destination
# from real drift.
write_pending_generation() {
  GENERATION_TMP=$(umask 077; mktemp "$PARENT_REAL/.inherit-generation.XXXXXX") \
    || die "cannot stage inheritance generation"
  if [ "$APPLIED_PRESENT" = 1 ]; then
    {
      printf 'applied\n%s\n%s\n%s\n%s\n' "$APPLIED_GEN" "$APPLIED_BYTES" "$APPLIED_HASH" "$APPLIED_CMD"
      printf 'pending\n%s\n%s\n%s\n%s\n' "$GENERATION" "$EXPECTED_BYTES" "$EXPECTED_HASH" "$COMMAND"
    } > "$GENERATION_TMP" || die "cannot write inheritance generation"
  else
    printf 'pending\n%s\n%s\n%s\n%s\n' "$GENERATION" "$EXPECTED_BYTES" "$EXPECTED_HASH" "$COMMAND" \
      > "$GENERATION_TMP" || die "cannot write inheritance generation"
  fi
  chmod 600 "$GENERATION_TMP" || die "cannot secure inheritance generation"
  mv -f -- "$GENERATION_TMP" "$GENERATION_FILE" || die "cannot publish inheritance generation"
  GENERATION_TMP=
}

commit_generation() {
  read_generation_receipt
  if [ "$APPLIED_PRESENT" = 1 ]; then
    [ "$APPLIED_CMD" != put ] || LAST_PUBLISHED_HASH=$APPLIED_HASH
    if [ "$APPLIED_GEN" -gt "$GENERATION" ]; then
      die "inheritance write generation is superseded"
    fi
  fi
  if [ -n "$PENDING_GEN" ]; then
    [ "$PENDING_CMD" != put ] || LAST_PENDING_HASH=$PENDING_HASH
    if [ "$PENDING_GEN" -gt "$GENERATION" ]; then
      die "inheritance write generation is superseded"
    fi
    if [ "$PENDING_GEN" -eq "$GENERATION" ]; then
      [ "$PENDING_BYTES" = "$EXPECTED_BYTES" ] \
        && [ "$PENDING_HASH" = "$EXPECTED_HASH" ] \
        && [ "$PENDING_CMD" = "$COMMAND" ] \
        || die "inheritance generation conflicts with its committed payload"
      return 0
    fi
  fi
  if [ "$APPLIED_PRESENT" = 1 ] && [ "$APPLIED_GEN" -eq "$GENERATION" ]; then
    [ "$APPLIED_BYTES" = "$EXPECTED_BYTES" ] \
      && [ "$APPLIED_HASH" = "$EXPECTED_HASH" ] \
      && [ "$APPLIED_CMD" = "$COMMAND" ] \
      || die "inheritance generation conflicts with its committed payload"
    write_applied_generation "$APPLIED_GEN" "$APPLIED_BYTES" "$APPLIED_HASH" "$APPLIED_CMD"
    return 0
  fi
  write_pending_generation
}

# Record this invocation's generation as applied once the destination holds
# its payload, so a later run reads it as the last published state.
promote_generation() {
  write_applied_generation "$GENERATION" "$EXPECTED_BYTES" "$EXPECTED_HASH" "$COMMAND"
}

# True when the destination still holds the bytes of the last applied or last
# staged put generation, so replacing it is ordinary convergence rather than
# destination drift.
dest_matches_last_published() {
  local actual
  [ -f "$DEST" ] || return 1
  actual=$(sha256_file "$DEST") || return 1
  [ -n "$LAST_PUBLISHED_HASH" ] && [ "$actual" = "$LAST_PUBLISHED_HASH" ] && return 0
  [ -n "$LAST_PENDING_HASH" ] && [ "$actual" = "$LAST_PENDING_HASH" ] && return 0
  return 1
}

quarantine_shared() {
  local reason=$1 quarantine stamp base n=0
  [ "$REL" = data/captain-shared.md ] && [ -f "$DEST" ] || return 0
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  base="$HOME_REAL/data/captain-shared.md.remote-quarantine-$stamp-$$"
  quarantine=$base
  while [ -e "$quarantine" ] || [ -L "$quarantine" ]; do
    n=$((n + 1))
    quarantine="$base.$n"
  done
  cp -p -- "$DEST" "$quarantine" || die "cannot quarantine divergent shared captain preferences"
  chmod 600 "$quarantine" || die "cannot secure shared-preference quarantine"
  printf 'quarantined: %s (%s)\n' "${quarantine#"$HOME_REAL/"}" "$reason" >&2
}

case "$COMMAND" in
  put)
    TMP=$(umask 077; mktemp "$PARENT_REAL/.inherit.XXXXXX") || die "cannot stage inherited material"
    head -c "$((MAX_BYTES + 1))" > "$TMP" || die "cannot read inherited material"
    BYTES=$(LC_ALL=C wc -c < "$TMP" | tr -d ' ')
    [ "$BYTES" -le "$MAX_BYTES" ] || die "inherited material exceeds the byte bound"
    [ "$BYTES" -eq "$EXPECTED_BYTES" ] || die "inherited material length does not match its commitment"
    ACTUAL_HASH=$(sha256_file "$TMP") || die "cannot hash inherited material"
    [ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] || die "inherited material digest does not match its commitment"
    commit_generation
    if [ -f "$DEST" ] && cmp -s "$TMP" "$DEST"; then
      promote_generation
      [ "$REL" != data/captain-shared.md ] || chmod 444 "$DEST"
      printf 'unchanged: %s\n' "$REL"
      exit 0
    fi
    dest_matches_last_published || quarantine_shared replaced
    chmod 600 "$TMP" || die "cannot secure inherited material"
    mv -f -- "$TMP" "$DEST" || die "cannot publish inherited material"
    TMP=
    [ "$REL" != data/captain-shared.md ] || chmod 444 "$DEST"
    promote_generation
    printf 'pushed: %s\n' "$REL"
    ;;
  absent)
    [ "$EXPECTED_BYTES" -eq 0 ] || die "absent inheritance has a nonzero payload commitment"
    EMPTY=$(umask 077; mktemp "$PARENT_REAL/.inherit-empty.XXXXXX") || die "cannot stage empty inheritance commitment"
    : > "$EMPTY"
    EMPTY_HASH=$(sha256_file "$EMPTY") || die "cannot hash empty inheritance payload"
    rm -f -- "$EMPTY"
    [ "$EMPTY_HASH" = "$EXPECTED_HASH" ] || die "absent inheritance digest is not the empty payload"
    commit_generation
    if [ ! -e "$DEST" ]; then
      promote_generation
      printf 'unchanged: %s\n' "$REL"
      exit 0
    fi
    quarantine_shared removed
    rm -f -- "$DEST" || die "cannot remove absent inherited material"
    promote_generation
    printf 'removed: %s\n' "$REL"
    ;;
  *) usage ;;
esac
