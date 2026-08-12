#!/usr/bin/env bash
# Read-only active-context usage reader for dispatched workers.
#
# Usage: fm-context-usage.sh [--json] [<task-id> ...]
#
# With no task ids, reads every state/*.meta record in FM_HOME. The default
# output is tab-separated with this header:
#   task harness tokens threshold context_window status detail
# --json emits one JSON object per task.
#
# Status is under, warning, over, or unknown. Warning means tokens have reached
# the freely configurable operator threshold. Over is reserved for tokens above
# a native context window reported by the runtime; it is observational and has
# no dispatch or lifecycle effect. Unknown covers missing, conflicting, remote,
# unsafe, ambiguous, unrecognized-version, or schema-invalid bindings. The
# effective threshold belongs to the home's config rather than to a task, so
# every row reports it, including an unknown one; only tokens and the native
# context window are conditional.
#
# Codex metric: the last complete event_msg/payload.type=token_count record's
# payload.info.last_token_usage.total_tokens. Cached input remains included.
# Its payload.info.model_context_window is the native window when valid.
# Claude metric: the last complete finalized assistant record's input_tokens +
# cache_creation_input_tokens + cache_read_input_tokens + output_tokens.
#
# The reading is best-effort and bounded, not authoritative. Only the last
# FM_CONTEXT_TAIL_BYTES of a transcript are scanned for a usage record (plus the
# first FM_CONTEXT_HEAD_BYTES for Codex's session_meta identity line), so the
# cost of a read never grows with session length and this stays cheap enough to
# run on the watcher's turn-end path. A malformed or truncated line inside the
# window is skipped rather than treated as fatal, and a transcript whose most
# recent usage record sits outside the window reports unknown instead of
# triggering a full-file scan. A reading that is stale by a turn, or missed
# entirely, is expected; nothing here retries to close that gap. Both bounds are
# environment overrides taking a positive integer byte count; an absent or
# unusable value keeps the 262144 and 65536 defaults.
#
# The command never guesses a transcript by cwd or mtime and never follows a
# path that was not validated beneath the recorded harness-session root.
set -u
set -o pipefail

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-context-usage-lib.sh
. "$SCRIPT_DIR/fm-context-usage-lib.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
FORMAT=tsv
if [ "${1:-}" = --json ]; then FORMAT=json; shift; fi
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

case "$STATE" in /*) ;; *) echo "error: state directory must be absolute" >&2; exit 2 ;; esac
[ -d "$STATE" ] || { echo "error: state directory does not exist: $STATE" >&2; exit 2; }
STATE=$(cd "$STATE" && pwd -P)

safe_transcript() {  # <root> <candidate>
  local root=$1 candidate=$2 parent
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
  parent=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || return 1
  case "$parent/" in "$root/"*) return 0 ;; esac
  return 1
}

find_transcript() {  # <harness> <root> <session-id>
  local harness=$1 root=$2 sid=$3 base candidate found='' count=0 listing rc=0
  case "$harness" in
    codex) base="$root/sessions"; [ -d "$base" ] || return 1 ;;
    claude) base="$root/projects"; [ -d "$base" ] || return 1 ;;
    *) return 1 ;;
  esac
  listing=$(mktemp "${TMPDIR:-/tmp}/fm-context-files.XXXXXX") || return 1
  if ! find "$base" -type f -name "*$sid.jsonl" -print > "$listing" 2>/dev/null; then
    rm -f "$listing"
    return 1
  fi
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    safe_transcript "$root" "$candidate" || { rc=1; break; }
    case "$harness:${candidate##*/}" in
      codex:*"-$sid.jsonl") ;;
      claude:"$sid.jsonl") ;;
      *) rc=1; break ;;
    esac
    found=$candidate
    count=$((count + 1))
  done < "$listing"
  rm -f "$listing"
  [ "$rc" -eq 0 ] || return 1
  [ "$count" -eq 1 ] || return 1
  printf '%s\n' "$found"
}

# Bounded slice of a transcript, so a read costs the same on a 20 MB rollout as
# on a fresh one. A byte-offset cut may leave its first line partial, and the
# trailing line of a live transcript may also be partial; both are skipped by
# the per-line parse below.
FM_CONTEXT_TAIL_BYTES=${FM_CONTEXT_TAIL_BYTES:-262144}
FM_CONTEXT_HEAD_BYTES=${FM_CONTEXT_HEAD_BYTES:-65536}
fm_context_valid_positive_uint "$FM_CONTEXT_TAIL_BYTES" || FM_CONTEXT_TAIL_BYTES=262144
fm_context_valid_positive_uint "$FM_CONTEXT_HEAD_BYTES" || FM_CONTEXT_HEAD_BYTES=65536

transcript_slice() {  # <file> <head|tail>
  local file=$1 end=$2
  case "$end" in
    head)
      head -c "$FM_CONTEXT_HEAD_BYTES" "$file"
      ;;
    tail)
      tail -c "$FM_CONTEXT_TAIL_BYTES" "$file"
      ;;
    *) return 1 ;;
  esac
}

# Every jq program below is a single trailing-? expression: a line that is not
# valid JSON, or whose shape does not match, yields nothing instead of aborting
# the scan. tail -1 then takes the most recent matching record in the window,
# which is what makes a post-compaction record win over a pre-compaction one.
codex_usage() {  # <jsonl> <session-id> <cwd> <version>
  local file=$1 sid=$2 cwd=$3 version=$4 meta row tokens window
  meta=$(transcript_slice "$file" head | jq -R -r '(fromjson |
    select(.type == "session_meta") |
    select((.payload.id|type)=="string" and (.payload.cwd|type)=="string" and (.payload.cli_version|type)=="string") |
    [.payload.id,.payload.cwd,.payload.cli_version] | @tsv)?' 2>/dev/null) || return 1
  [ "$(printf '%s\n' "$meta" | grep -c .)" -eq 1 ] || return 1
  [ "$meta" = "$(printf '%s\t%s\t%s' "$sid" "$cwd" "$version")" ] || return 1
  row=$(transcript_slice "$file" tail | jq -R -r '(fromjson |
    select(.type == "event_msg" and .payload.type == "token_count") |
    select((.payload.info.last_token_usage.total_tokens|type)=="number"
           and .payload.info.last_token_usage.total_tokens >= 0) |
    select((.payload.info.model_context_window == null) or
           ((.payload.info.model_context_window|type)=="number" and .payload.info.model_context_window > 0)) |
    [.payload.info.last_token_usage.total_tokens,
     (.payload.info.model_context_window // "")] | @tsv)?' 2>/dev/null | tail -1) || return 1
  IFS=$(printf '\t') read -r tokens window <<EOF
$row
EOF
  fm_context_valid_uint "$tokens" || return 1
  [ -z "$window" ] || fm_context_valid_positive_uint "$window" || return 1
  printf '%s\t%s\n' "$tokens" "$window"
}

claude_usage() {  # <jsonl> <session-id> <cwd> <version>
  local file=$1 sid=$2 cwd=$3 version=$4 tokens
  tokens=$(transcript_slice "$file" tail \
    | jq -R -r --arg sid "$sid" --arg cwd "$cwd" --arg version "$version" '(fromjson |
    select(.type == "assistant" and .message.usage != null and .message.stop_reason != null) |
    select(.sessionId == $sid and .cwd == $cwd and .version == $version) |
    select([.message.usage.input_tokens,
            .message.usage.cache_creation_input_tokens,
            .message.usage.cache_read_input_tokens,
            .message.usage.output_tokens] | all(type == "number" and . >= 0)) |
    (.message.usage.input_tokens +
     .message.usage.cache_creation_input_tokens +
     .message.usage.cache_read_input_tokens +
     .message.usage.output_tokens))?' 2>/dev/null | tail -1) || return 1
  fm_context_valid_uint "$tokens" || return 1
  printf '%s\t\n' "$tokens"
}

emit() {  # <task> <harness> <tokens> <threshold> <window> <status> <detail>
  if [ "$FORMAT" = json ]; then
    jq -cn --arg task "$1" --arg harness "$2" --arg tokens "$3" --arg threshold "$4" \
      --arg window "$5" --arg status "$6" --arg detail "$7" '
      {task:$task,harness:$harness,
       tokens:(if $tokens=="" then null else ($tokens|tonumber) end),
       threshold:(if $threshold=="" then null else $threshold end),
       context_window:(if $window=="" then null else ($window|tonumber) end),
       status:$status,detail:$detail}'
  else
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"
  fi
}

audit_one() {
  local id=$1 meta harness='' tokens='' window='' status=unknown
  local threshold=$THRESHOLD
  local epoch root sid cwd version remote transcript usage
  case "$id" in ''|*[!A-Za-z0-9._-]*|.*) emit "$id" "" "" "$threshold" "" unknown "invalid task id"; return ;; esac
  # The effective threshold is task-independent, so every row reports it - only
  # tokens, the native window, and the status stay conditional.
  if [ -z "$threshold" ]; then emit "$id" "" "" "" "" unknown "context warning threshold is invalid"; return; fi
  meta="$STATE/$id.meta"
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then emit "$id" "" "" "$threshold" "" unknown "missing or unsafe metadata"; return; fi
  harness=$(fm_context_meta_exact "$meta" harness 2>/dev/null || true)
  case "$harness" in claude|codex) ;; *) emit "$id" "$harness" "" "$threshold" "" unknown "usage schema is not verified for this harness"; return ;; esac
  remote=$(grep -E '^(remote_host=.+|orca_remote=1)$' "$meta" 2>/dev/null || true)
  if [ -n "$remote" ]; then emit "$id" "$harness" "" "$threshold" "" unknown "remote transcript is not locally reachable"; return; fi
  epoch=$(fm_context_meta_exact "$meta" harness_session_epoch 2>/dev/null || true)
  root=$(fm_context_meta_exact "$meta" harness_session_root 2>/dev/null || true)
  sid=$(fm_context_meta_exact "$meta" harness_session_id 2>/dev/null || true)
  cwd=$(fm_context_meta_exact "$meta" harness_session_cwd 2>/dev/null || true)
  version=$(fm_context_meta_exact "$meta" harness_version 2>/dev/null || true)
  if ! fm_context_valid_uuid "$epoch" || ! fm_context_valid_uuid "$sid" \
     || [ "$(grep -c '^harness_session_conflict=1$' "$meta" 2>/dev/null || true)" -gt 0 ]; then
    emit "$id" "$harness" "" "$threshold" "" unknown "missing, conflicting, or invalid session binding"
    return
  fi
  if ! fm_context_schema_known "$harness" "$version"; then
    emit "$id" "$harness" "" "$threshold" "" unknown "transcript schema is unrecognized for version ${version:-unknown}"
    return
  fi
  case "$root" in /*) ;; *) emit "$id" "$harness" "" "$threshold" "" unknown "invalid session root"; return ;; esac
  if [ ! -d "$root" ] || [ -L "$root" ] || [ "$(cd "$root" 2>/dev/null && pwd -P)" != "$root" ]; then
    emit "$id" "$harness" "" "$threshold" "" unknown "session root is unavailable or unsafe"
    return
  fi
  if [ ! -d "$cwd" ] || [ "$(cd "$cwd" 2>/dev/null && pwd -P)" != "$cwd" ]; then
    emit "$id" "$harness" "" "$threshold" "" unknown "bound cwd is unavailable or noncanonical"
    return
  fi
  transcript=$(find_transcript "$harness" "$root" "$sid" 2>/dev/null || true)
  if [ -z "$transcript" ]; then emit "$id" "$harness" "" "$threshold" "" unknown "exact transcript is missing or ambiguous"; return; fi
  case "$harness" in
    codex) usage=$(codex_usage "$transcript" "$sid" "$cwd" "$version" 2>/dev/null || true) ;;
    claude) usage=$(claude_usage "$transcript" "$sid" "$cwd" "$version" 2>/dev/null || true) ;;
  esac
  IFS=$(printf '\t') read -r tokens window <<EOF
$usage
EOF
  if ! fm_context_valid_uint "$tokens"; then emit "$id" "$harness" "" "$threshold" "" unknown "no valid usage record in the bounded transcript window"; return; fi
  if [ -n "$window" ] && fm_context_decimal_gt "$tokens" "$window"; then status=over
  elif fm_context_decimal_ge "$tokens" "$threshold"; then status=warning
  else status=under
  fi
  emit "$id" "$harness" "$tokens" "$threshold" "$window" "$status" "ok"
}

# One read of the operator threshold for the whole audit: it is a property of the
# home's config, not of any task, so an unknown row still reports it.
THRESHOLD=$(fm_context_warning_threshold "$CONFIG" 2>/dev/null || true)
fm_context_valid_positive_uint "$THRESHOLD" || THRESHOLD=

if [ "$FORMAT" = tsv ]; then
  printf 'task\tharness\ttokens\tthreshold\tcontext_window\tstatus\tdetail\n'
fi
if [ "$#" -gt 0 ]; then
  for id in "$@"; do audit_one "$id"; done
else
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    audit_one "$(basename "$meta" .meta)"
  done
fi
