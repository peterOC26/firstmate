#!/usr/bin/env bash
# Shared validation helpers for worker context-usage measurement.
#
# config/context-warning is an operator warning threshold, not a launch limit.
# It defaults to 150000 tokens and accepts any positive decimal integer.
# fm-spawn.sh uses only the session UUID and version-normalization helpers below.
# It never reads the threshold, so an absent, malformed, lower, or higher value
# can never block, reroute, or alter a worker launch.
#
# Transcript schema support is deliberately version-aware. A harness upgrade
# remains dispatchable, but fm-context-usage.sh reports unknown until its emitted
# schema is verified and the known-version list below is refreshed.

FM_CONTEXT_WARNING_DEFAULT=150000
FM_CONTEXT_KNOWN_CLAUDE_VERSIONS="${FM_CONTEXT_KNOWN_CLAUDE_VERSIONS:-2.1.220}"
FM_CONTEXT_KNOWN_CODEX_VERSIONS="${FM_CONTEXT_KNOWN_CODEX_VERSIONS:-0.147.0}"

fm_context_warning_threshold() {  # <config-dir>
  local config_dir=$1 file value lines
  file="$config_dir/context-warning"
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf '%s\n' "$FM_CONTEXT_WARNING_DEFAULT"
    return 0
  fi
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    echo "error: config/context-warning must be a regular non-symlink file" >&2
    return 1
  fi
  lines=$(wc -l < "$file" | tr -d '[:space:]')
  value=$(sed -n '1p' "$file")
  if [ "$lines" != 1 ] || ! printf '%s' "$value" | grep -Eq '^[1-9][0-9]*$'; then
    echo "error: config/context-warning must contain exactly one newline-terminated positive integer" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

fm_context_normalize_version() {  # <harness> <version-output>
  local harness=$1 output=$2
  case "$harness" in
    claude) printf '%s\n' "$output" | sed -n 's/^\([0-9][0-9.]*\).*/\1/p' | head -1 ;;
    codex) printf '%s\n' "$output" | awk '
      $1 == "codex-cli" && $2 ~ /^[0-9][0-9.]*$/ { print $2; exit }
      NF == 1 && $1 ~ /^[0-9][0-9.]*$/ { print $1; exit }
    ' ;;
    *) return 1 ;;
  esac
}

fm_context_schema_known() {  # <harness> <normalized-version>
  local harness=$1 version=$2 candidate list
  case "$harness" in
    claude) list=$FM_CONTEXT_KNOWN_CLAUDE_VERSIONS ;;
    codex) list=$FM_CONTEXT_KNOWN_CODEX_VERSIONS ;;
    *) return 1 ;;
  esac
  for candidate in $list; do
    [ "$candidate" = "$version" ] && return 0
  done
  return 1
}

fm_context_meta_exact() {  # <meta> <key>
  local meta=$1 key=$2 count
  count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  grep "^${key}=" "$meta" | cut -d= -f2-
}

fm_context_valid_uint() {
  printf '%s' "$1" | grep -Eq '^(0|[1-9][0-9]*)$'
}

fm_context_valid_positive_uint() {
  printf '%s' "$1" | grep -Eq '^[1-9][0-9]*$'
}

fm_context_decimal_gt() {  # <left> <right>
  local left=$1 right=$2
  [ "${#left}" -gt "${#right}" ] && return 0
  [ "${#left}" -lt "${#right}" ] && return 1
  [ "$left" != "$right" ] && [ "$(printf '%s\n%s\n' "$left" "$right" | LC_ALL=C sort | tail -1)" = "$left" ]
}

fm_context_decimal_ge() {  # <left> <right>
  [ "$1" = "$2" ] || fm_context_decimal_gt "$1" "$2"
}

fm_context_valid_uuid() {
  printf '%s' "$1" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

fm_context_uuid() {
  local value hex
  if command -v uuidgen >/dev/null 2>&1; then
    value=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]') || value=
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    value=$(tr '[:upper:]' '[:lower:]' < /proc/sys/kernel/random/uuid 2>/dev/null) || value=
  elif [ -r /dev/urandom ] && command -v od >/dev/null 2>&1; then
    hex=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || hex=
    if [ "${#hex}" -eq 32 ]; then
      value=$(printf '%s' "$hex" | sed 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)$/\1-\2-\3-\4-\5/')
    fi
  fi
  fm_context_valid_uuid "${value:-}" || return 1
  printf '%s\n' "$value"
}
