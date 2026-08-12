#!/usr/bin/env bash
# Atomic Codex harness-session binding callback.
#
# Usage:
#   fm-context-bind.sh codex-notify <state-dir> <task-id> <epoch> <expected-cwd> <turn-end-or-> <notification-json>
#
# Codex appends one JSON notification argument to the configured notify argv.
# The callback preserves the pre-existing turn-end notification independently
# of binding success, validates agent-turn-complete thread-id/cwd fields, and
# atomically records the first thread id for the current spawn incarnation.
# A different thread id in the same incarnation records a conflict so the
# read-only reader returns unknown. A stale callback never replaces a relaunch.
set -euo pipefail

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

[ "$#" -eq 7 ] && [ "$1" = codex-notify ] || {
  usage >&2
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-context-usage-lib.sh
. "$SCRIPT_DIR/fm-context-usage-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

STATE=$2
ID=$3
EPOCH=$4
EXPECTED_CWD=$5
TURNEND=$6
PAYLOAD=$7

case "$ID" in
  ''|*[!A-Za-z0-9._-]*|.*) echo "error: invalid task id" >&2; exit 1 ;;
esac
fm_context_valid_uuid "$EPOCH" || { echo "error: invalid session epoch" >&2; exit 1; }
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: invalid state directory" >&2; exit 1; }
STATE=$(cd "$STATE" && pwd -P)

if [ "$TURNEND" != - ]; then
  case "$TURNEND" in
    "$STATE"/*.turn-ended) ;;
    *) echo "error: invalid turn-end path" >&2; exit 1 ;;
  esac
  trap 'touch "$TURNEND" 2>/dev/null || true' EXIT
fi

[ -d "$EXPECTED_CWD" ] || { echo "error: expected cwd is unavailable" >&2; exit 1; }
CWD_REAL=$(cd "$EXPECTED_CWD" && pwd -P)
[ "$EXPECTED_CWD" = "$CWD_REAL" ] || { echo "error: expected cwd must be canonical" >&2; exit 1; }

THREAD_ID=$(printf '%s\n' "$PAYLOAD" | jq -er '
  if type == "object"
     and .type == "agent-turn-complete"
     and (."thread-id" | type) == "string"
     and (.cwd | type) == "string"
     and (."thread-id" | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
  then ."thread-id" else error("invalid notification") end
') || { echo "error: invalid Codex notification schema" >&2; exit 1; }
NOTIFY_CWD=$(printf '%s\n' "$PAYLOAD" | jq -er '.cwd') || exit 1
[ "$NOTIFY_CWD" = "$EXPECTED_CWD" ] || {
  echo "error: Codex notification cwd '$NOTIFY_CWD' conflicts with expected cwd '$EXPECTED_CWD'" >&2
  exit 1
}

META="$STATE/$ID.meta"
LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$LOCK"
TMP=
cleanup() {
  [ -z "$TMP" ] || rm -f -- "$TMP" 2>/dev/null || true
  fm_lock_release "$LOCK"
}
trap 'cleanup; [ "$TURNEND" = - ] || touch "$TURNEND" 2>/dev/null || true' EXIT

[ -f "$META" ] && [ ! -L "$META" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
CURRENT_EPOCH=$(fm_context_meta_exact "$META" harness_session_epoch) || { echo "error: task metadata has no unique session epoch" >&2; exit 1; }
[ "$CURRENT_EPOCH" = "$EPOCH" ] || { echo "error: stale Codex notification incarnation" >&2; exit 1; }
[ "$(fm_context_meta_exact "$META" harness)" = codex ] || { echo "error: task metadata does not identify Codex" >&2; exit 1; }
META_WORKTREE=$(fm_context_meta_exact "$META" worktree) || { echo "error: task metadata has no unique worktree" >&2; exit 1; }
[ -d "$META_WORKTREE" ] && [ "$(cd "$META_WORKTREE" && pwd -P)" = "$EXPECTED_CWD" ] || {
  echo "error: task metadata cwd conflicts with notification binding" >&2
  exit 1
}

EXISTING=$(grep '^harness_session_id=' "$META" 2>/dev/null | cut -d= -f2- || true)
CONFLICT=$(grep '^harness_session_conflict=' "$META" 2>/dev/null | cut -d= -f2- || true)
TMP=$(mktemp "$STATE/.$ID.meta.bind.XXXXXX") || exit 1
awk '!/^harness_session_id=/ && !/^harness_session_cwd=/ && !/^harness_session_conflict=/' "$META" > "$TMP"
if [ "$CONFLICT" = 1 ] || { [ -n "$EXISTING" ] && [ "$EXISTING" != "$THREAD_ID" ]; }; then
  [ -z "$EXISTING" ] || printf 'harness_session_id=%s\n' "$EXISTING" >> "$TMP"
  printf 'harness_session_cwd=%s\n' "$EXPECTED_CWD" >> "$TMP"
  printf 'harness_session_conflict=1\n' >> "$TMP"
  chmod --reference="$META" "$TMP" 2>/dev/null || chmod 0600 "$TMP"
  mv -f -- "$TMP" "$META"
  TMP=
  echo "error: conflicting Codex thread id for task $ID" >&2
  exit 1
fi
printf 'harness_session_id=%s\n' "$THREAD_ID" >> "$TMP"
printf 'harness_session_cwd=%s\n' "$EXPECTED_CWD" >> "$TMP"
chmod --reference="$META" "$TMP" 2>/dev/null || chmod 0600 "$TMP"
mv -f -- "$TMP" "$META"
TMP=
