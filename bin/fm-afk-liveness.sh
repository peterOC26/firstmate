#!/usr/bin/env bash
# fm-afk-liveness.sh - away-session liveness for one away window.
#
# Usage:
#   fm-afk-liveness.sh arm       Record the expected actor and register the check.
#   fm-afk-liveness.sh check     Print a line only when the window shows no away
#                                session. The line wakes once per window.
#   fm-afk-liveness.sh disarm    Remove the check and fired ledger; keep the actor.
#   fm-afk-liveness.sh health    Print the return brief's away-session lines.
#   fm-afk-liveness.sh --help
#
# `arm` writes state/.afk-away-actor (actor, entry epoch, window) and registers
# state/fm-afk-liveness.check.sh. A refresh that keeps the same posture-record
# entry epoch does not move that epoch. Quiet mode and a missing record arm
# nothing. The check stays registered for the whole away window; the return
# path disarms it.
#
# Actor is host when this home runs the supervision host, branch on Pi, and
# daemon otherwise. A host turn is a state/.supervision-host.log row at or
# after entry marked handled with posture=away. A daemon turn is a logged
# heartbeat wake at or after entry. Branch outcomes
# do not establish actor identity and are not counted. Nothing reads a transcript.
#
# The check stays silent until the window has elapsed (default 15 minutes,
# FM_AFK_LIVENESS_WINDOW). FM_AFK_LIVENESS_NOW pins the clock for tests.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CHECK_ID=fm-afk-liveness
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
ACTOR_FILE="$STATE/.afk-away-actor"
FIRED_FILE="$STATE/.afk-liveness-fired"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
DEFAULT_WINDOW=900

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-afk-contract.sh
. "$SCRIPT_DIR/fm-afk-contract.sh"

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
}

now_epoch() {
  case "${FM_AFK_LIVENESS_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_AFK_LIVENESS_NOW" ;;
  esac
}

window_seconds() {
  case "${FM_AFK_LIVENESS_WINDOW:-}" in
    ''|*[!0-9]*) printf '%s\n' "$DEFAULT_WINDOW" ;;
    *) printf '%s\n' "$FM_AFK_LIVENESS_WINDOW" ;;
  esac
}

read_actor() {
  ACTOR=
  ENTRY=
  WINDOW=$(window_seconds)
  [ -f "$ACTOR_FILE" ] && [ ! -L "$ACTOR_FILE" ] || return 1
  ACTOR=$(sed -n 's/^actor: //p' "$ACTOR_FILE" | head -1)
  ENTRY=$(sed -n 's/^entry_epoch: //p' "$ACTOR_FILE" | head -1)
  case "$ENTRY" in ''|*[!0-9]*) return 1 ;; esac
  case "$ACTOR" in host|daemon|branch|main) ;; *) return 1 ;; esac
  if [ -z "${FM_AFK_LIVENESS_WINDOW:-}" ]; then
    case "$(sed -n 's/^window: //p' "$ACTOR_FILE" | head -1)" in
      ''|*[!0-9]*) ;;
      *) WINDOW=$(sed -n 's/^window: //p' "$ACTOR_FILE" | head -1) ;;
    esac
  fi
  return 0
}

load_log_evidence() {
  local host=/dev/null daemon=/dev/null
  [ ! -f "$STATE/.supervision-host.log" ] || host="$STATE/.supervision-host.log"
  [ ! -f "$STATE/.supervise-daemon.log" ] || daemon="$STATE/.supervise-daemon.log"
  LOG_EVIDENCE=$(awk -F '\t' -v host="$host" '
    function leap(y) { return y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) }
    function days(y) { y--; return 365*y + int(y/4) - int(y/100) + int(y/400) }
    function epoch(t,    y,m,d,i,n,offset,month) {
      y=substr(t,1,4)+0; m=substr(t,6,2)+0; d=substr(t,9,2)+0
      split("31 28 31 30 31 30 31 31 30 31 30 31",month," ")
      n=days(y)-days(1970)+d-1
      for(i=1;i<m;i++) n+=month[i]+(i==2 && leap(y))
      offset=(substr(t,21,2)*60+substr(t,23,2))*60
      if(substr(t,20,1)=="-") offset=-offset
      return n*86400+substr(t,12,2)*3600+substr(t,15,2)*60+substr(t,18,2)-offset
    }
    FILENAME == host {
      if ($1 ~ /^[0-9]+$/ && $2 == "handled" && index($0,"posture=away"))
        print $1 "\thost"
      next
    }
    /^\[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9][+-][0-9][0-9][0-9][0-9]\] / {
      message=substr($0,28)
      if (message ~ /^wake: heartbeat($|:)/)
        printf "%.0f\tdaemon\n", epoch(substr($0,2,24))
    }
  ' "$host" "$daemon")
}

count_turns() {
  printf '%s\n' "$LOG_EVIDENCE" | awk -F '\t' -v actor="$1" -v since="$2" '
    $1 + 0 >= since && $2 == actor { n++ }
    END { print n + 0 }
  '
}

fired_has() {  # <key>
  [ -f "$FIRED_FILE" ] && grep -Fxq -- "$ENTRY:$1" "$FIRED_FILE"
}

fired_add() {  # <key>
  printf '%s:%s\n' "$ENTRY" "$1" >> "$FIRED_FILE" 2>/dev/null || true
}

choose_actor() {
  local harness
  # shellcheck source=bin/fm-supervision-engine-lib.sh
  . "$SCRIPT_DIR/fm-supervision-engine-lib.sh" || { printf 'daemon\n'; return; }
  harness=$(fm_supervision_host_primary)
  case "$harness" in
    pi|pi-signed) printf 'branch\n'; return ;;
  esac
  if fm_supervision_host_enabled "$CONFIG" "$harness"; then
    printf 'host\n'
  else
    printf 'daemon\n'
  fi
}

shim_write() {  # <bytes>
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-afk-liveness.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

arm_check() {
  local home want
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || return 1 ;;
  esac
  want=$(printf '%s\n' \
    '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-afk-liveness.sh") check")
  shim_write "$want" || return 1
  FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null || {
    rm -f -- "$CHECK_SHIM"
    return 1
  }
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

cmd_arm() {
  local mode entry actor tmp
  mode=$(fm_afk_contract_mode "$STATE" 2>/dev/null || true)
  [ "$mode" = away ] || return 0
  entry=$(fm_afk_contract_read_field "$(fm_afk_contract_path "$STATE")" entered_epoch)
  case "$entry" in ''|*[!0-9]*) entry=$(now_epoch) ;; esac
  actor=$(choose_actor)
  mkdir -p "$STATE" || return 1
  if ! read_actor || [ "$ENTRY" != "$entry" ]; then
    rm -f -- "$FIRED_FILE" || return 1
  fi
  tmp=$(mktemp "$STATE/.afk-away-actor.XXXXXX" 2>/dev/null) || return 1
  printf 'actor: %s\nentry_epoch: %s\nwindow: %s\n' "$actor" "$entry" "$(window_seconds)" > "$tmp" \
    || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$ACTOR_FILE" || { rm -f "$tmp"; return 1; }
  arm_check
}

cmd_disarm() {
  if [ -e "$CHECK_SHIM" ] || [ -e "$CHECK_TRUST" ] || [ -L "$CHECK_SHIM" ] || [ -L "$CHECK_TRUST" ]; then
    "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null 2>&1 || rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
  fi
  rm -f -- "$FIRED_FILE" || return 1
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

cmd_health() {
  local turns
  read_actor || return 0
  load_log_evidence
  turns=$(count_turns "$ACTOR" "$ENTRY")
  printf 'away-session turns: %s\n' "$turns"
  [ "$turns" -eq 0 ] && printf 'no away session ran; main handled the window itself\n'
}

cmd_check() {
  local now due turns
  read_actor || return 0
  now=$(now_epoch)
  due=$((ENTRY + WINDOW))
  if [ "$now" -ge "$due" ] && ! fired_has no-session; then
    load_log_evidence
    turns=$(count_turns "$ACTOR" "$ENTRY")
    if [ "$turns" -eq 0 ]; then
      printf 'no away session ran; main handled the window itself\n'
      fired_add no-session
    fi
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    arm) cmd_arm ;;
    check) cmd_check ;;
    disarm) cmd_disarm ;;
    health) cmd_health ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
fi
