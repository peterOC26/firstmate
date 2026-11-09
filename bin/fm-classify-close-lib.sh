#!/usr/bin/env bash
# Closing-epoch watch for one blocked key.
# bin/fm-classify-lib.sh sources this file. It is its own lint root so the
# extra arguments stay out of the source-aware check of bin/fm-spawn.sh.
# The caller owns __fm_close_watch, __fm_close_seen, and __fm_close_at.

# shellcheck disable=SC2154
fm_classify_close_watch_reset() {  # <out-var> <blocked-epoch>
  __fm_close_watch=0
  __fm_close_seen=0
  __fm_close_at=''
  if [ -n "${1:-}" ] && [ -n "${2:-}" ]; then printf -v "$1" '%s' ''; fi
}

# shellcheck disable=SC2154
fm_classify_close_watch_arm() {  # <line> <event> <want> <open> <blocked-epoch>
  [ -n "${5:-}" ] || return 0
  [ "$2" = blocked ] || return 0
  [ "$(_fm_decision_key "$1")" = "$3" ] || return 0
  [ "$(status_line_at_epoch "$1")" = "$5" ] || return 0
  [ "$(_fm_open_set_verb "$4" "$3")" = blocked ] || return 0
  __fm_close_watch=1
  __fm_close_seen=0
  __fm_close_at=''
}

# shellcheck disable=SC2154
fm_classify_close_watch_capture() {  # <line>
  [ "${__fm_close_watch:-0}" -eq 1 ] || return 0
  [ "${__fm_close_seen:-0}" -eq 0 ] || return 0
  _fm_status_at_epoch "$1" __fm_close_at || true
  __fm_close_seen=1
}

# shellcheck disable=SC2154
fm_classify_close_watch_publish() {  # <out-var> <blocked-epoch>
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 0
  printf -v "$1" '%s' "$__fm_close_at"
}
