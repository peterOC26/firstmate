#!/usr/bin/env bash
# Deduplicated non-blocking warning transition for worker context usage.
#
# Usage: fm-context-warning.sh <task-id> [<task-id> ...]
#
# Calls the read-only fm-context-usage.sh interface. It prints one line when a
# task first enters warning or over, and stays silent throughout the same
# above-threshold episode. Returning under clears that task's marker so a later
# crossing can surface again. Unknown neither warns nor clears a prior marker.
#
# The small state/.<id>.context-warning marker is deduplication state, not a
# worker progress note. This command never blocks, refuses, reroutes, rotates,
# interrupts, or otherwise changes a worker or its launch.
set -u

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
[ "$#" -gt 0 ] || { usage >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
[ -d "$STATE" ] || exit 0
STATE=$(cd "$STATE" && pwd -P)

for id in "$@"; do
  case "$id" in ''|*[!A-Za-z0-9._-]*|.*) continue ;; esac
  row=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$CONFIG" \
    "$SCRIPT_DIR/fm-context-usage.sh" --json "$id" 2>/dev/null || true)
  [ -n "$row" ] || continue
  status=$(printf '%s\n' "$row" | jq -r '.status // "unknown"' 2>/dev/null || printf unknown)
  marker="$STATE/.$id.context-warning"
  case "$status" in
    under)
      rm -f -- "$marker" 2>/dev/null || true
      ;;
    warning|over)
      tokens=$(printf '%s\n' "$row" | jq -r '.tokens // empty')
      threshold=$(printf '%s\n' "$row" | jq -r '.threshold // empty')
      window=$(printf '%s\n' "$row" | jq -r '.context_window // empty')
      signature="$threshold"
      [ "$(cat "$marker" 2>/dev/null || true)" = "$signature" ] && continue
      tmp=$(mktemp "$STATE/.$id.context-warning.XXXXXX") || continue
      printf '%s' "$signature" > "$tmp" || { rm -f "$tmp"; continue; }
      chmod 0600 "$tmp" 2>/dev/null || true
      mv -f -- "$tmp" "$marker" || { rm -f "$tmp"; continue; }
      if [ "$status" = over ]; then
        printf 'context usage over native window: task=%s tokens=%s window=%s warning-threshold=%s\n' \
          "$id" "$tokens" "$window" "$threshold"
      else
        printf 'context usage warning: task=%s tokens=%s threshold=%s\n' "$id" "$tokens" "$threshold"
      fi
      ;;
  esac
done

exit 0
