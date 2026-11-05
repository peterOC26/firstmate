#!/usr/bin/env bash
# fm-afk-main-outcome.sh - one routine outcome for an event main handled
# while the away record stood and no away session was running.
#
# Usage:
#   fm-afk-main-outcome.sh --task <id> --summary <text> [--wake <text>] [--silent true|false]
#       Append one routine outcome row. --silent defaults to true, so a routine
#       note stays out of the captain's chat. This is not new authority.
#       A captain call stays a held backlog task through bin/fm-captain-hold.sh.
#       --verdict and --continuation are refused.
#   fm-afk-main-outcome.sh --help
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

TASK=''
SUMMARY=''
WAKE=''
SILENT=true

while [ "$#" -gt 0 ]; do
  case "$1" in
    --task) TASK=${2:-}; shift 2 || { usage >&2; exit 2; } ;;
    --summary) SUMMARY=${2:-}; shift 2 || { usage >&2; exit 2; } ;;
    --wake) WAKE=${2:-}; shift 2 || { usage >&2; exit 2; } ;;
    --silent) SILENT=${2:-}; shift 2 || { usage >&2; exit 2; } ;;
    --verdict|--continuation) usage >&2; exit 2 ;;
    -h|--help|help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[ -n "$TASK" ] || { usage >&2; exit 2; }
[ -n "$SUMMARY" ] || { usage >&2; exit 2; }
case "$SILENT" in true|false) ;; *) usage >&2; exit 2 ;; esac

exec "$SCRIPT_DIR/fm-branch-outcome.sh" append \
  --task "$TASK" \
  --verdict routine \
  --summary "$SUMMARY" \
  --wake "$WAKE" \
  --silent "$SILENT"
