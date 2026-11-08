#!/usr/bin/env bash
# Queued-check delivery markers shared by the watcher and the attended host.
# bin/fm-wake-lib.sh sources this file.
# It is its own lint root so source-aware shellcheck of bin/fm-spawn.sh stays
# under the 8G resident cap. Call the readers and the writer under
# FM_WAKE_QUEUE_LOCK. Mark a key only when handing that close to its owner.

# shellcheck disable=SC2154 # STATE and the queue helpers are set by fm-wake-lib.sh.
fm_wake_surfaced_marker() {  # <procevent:...|inbox:...>
  local key=$1
  case "$key" in procevent:*|inbox:*) ;; *) return 1 ;; esac
  printf '%s/.seen-%s-%s' "$STATE" "${key%%:*}" "$(printf '%s' "$key" | LC_ALL=C od -An -tx1 | tr -d ' \n')"
}

fm_wake_surfaced_mark_locked() {  # <procevent:...|inbox:...>
  local key=$1 marker tmp
  marker=$(fm_wake_surfaced_marker "$key") || return 1
  tmp=$(umask 077; mktemp "$STATE/.seen-${key%%:*}.XXXXXX") || return 1
  if ! mv -f -- "$tmp" "$marker"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# List only inbox delivery markers, excluding per-task signal markers.
fm_wake_inbox_surfaced_markers() {
  local marker
  for marker in "$STATE"/.seen-inbox-*; do
    [ -e "$marker" ] || [ -L "$marker" ] || continue
    case "${marker##*/.seen-inbox-}" in ''|*[!0-9a-f]*) continue ;; esac
    printf '%s\n' "$marker"
  done
}

# Prints unsurfaced inbox keys and prunes markers for rows no longer queued.
fm_wake_inbox_unsurfaced_keys_locked() {
  local key marker queued_markers=$'\n'
  while IFS= read -r key; do
    case "$key" in inbox:*) ;; *) continue ;; esac
    marker=$(fm_wake_surfaced_marker "$key") || return 1
    queued_markers="$queued_markers$marker"$'\n'
    [ -e "$marker" ] || printf '%s\n' "$key"
  done < <(fm_wake_queued_keys_locked check)
  while IFS= read -r marker; do
    case "$queued_markers" in
      *$'\n'"$marker"$'\n'*) ;;
      *) rm -f -- "$marker" || return 1 ;;
    esac
  done < <(fm_wake_inbox_surfaced_markers)
}
