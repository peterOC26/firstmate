#!/usr/bin/env bash
# Shared "is this git lock file provably abandoned?" decision procedure.
#
# ONE owner for the staleness proof that fm-teardown.sh (a worktree index.lock)
# and fm-fleet-sync.sh (a clone's .git/packed-refs.lock) both rely on: a lock is
# provably stale iff ALL of the following hold -
#   1. the lock file still exists;
#   2. no live process holds the lock file open, and none holds a companion
#      directory (the worktree, or the repo's .git dir) open as an fd, or has
#      its cwd or any open file in that directory or any of its descendants -
#      a live git process keeps its own lock open for the whole operation, so
#      an empty lsof result means the file was abandoned, not that no one held
#      it;
#   3. its mtime age is at least a caller-supplied threshold - a freshly created
#      lock might belong to a process lsof has not yet reflected.
# ANY uncertainty - lsof missing, an lsof error, an unreadable mtime - returns
# non-zero (NOT stale): fail safe, never remove a lock that cannot be proven dead.
# Diagnostics print to stderr prefixed by ${FM_LOCK_LOG_PREFIX:-fm-lock} so each
# caller's output stays recognizable.

fm_lock_log() {
  echo "${FM_LOCK_LOG_PREFIX:-fm-lock}: $*" >&2
}

# Portable mtime in epoch seconds. Kept self-contained so this leaf lib drags in
# no wake-queue machinery when a caller only needs the staleness proof.
fm_lock_path_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_lock_lsof_holder <target>: 0 a process holds it, 1 provably none, 2 lsof
# errored (cannot tell). A directory target is held when a process has it open
# as an fd or cwd, or has its cwd or any open file anywhere under it: the
# descendant check is one system-wide `lsof -Fpn` listing of every process's
# open paths filtered by path prefix - bounded by what is open, never the
# recursive +D file-tree walk that lsof documents as slow. Diagnostics print on
# the error path only.
fm_lock_lsof_holder() {
  local target=$1 output status
  if output=$(lsof -- "$target" 2>&1); then
    return 0
  else
    status=$?
  fi
  if [ "$status" -ne 1 ] || [ -n "$output" ]; then
    fm_lock_report_lsof_failure "$target" "$status" "$output"
    return 2
  fi
  [ -d "$target" ] || return 1
  fm_lock_lsof_path_under "$target"
}

fm_lock_report_lsof_failure() {  # <target> <status> <output>
  local target=$1 status=$2 output=$3 line
  if [ -n "$output" ]; then
    while IFS= read -r line; do
      fm_lock_log "lsof check failed: $line"
    done <<< "$output"
  else
    fm_lock_log "lsof check failed for $target with exit $status"
  fi
}

# fm_lock_lsof_path_under <dir>: 0 a process has its cwd, its root, or any
# open file at or under <dir>, 1 provably none, 2 the scan could not establish
# a safe result (cannot tell). Parses lsof's -F field output the way
# fm-teardown.sh pids_with_cwd_under does, but over every fd rather than cwd
# alone; any line the parser does not recognize means cannot tell, never
# "nobody".
fm_lock_lsof_path_under() {
  local dir=$1 real out status pid path line
  real=$(cd "$dir" 2>/dev/null && pwd -P) || {
    fm_lock_log "cannot resolve $dir for the lsof open-path scan"
    return 2
  }
  if out=$(lsof -Fpn 2>/dev/null); then
    status=0
  else
    status=$?
  fi
  if [ "$status" -ne 0 ]; then
    if [ "$status" -eq 1 ] && [ -z "$out" ]; then
      return 1
    fi
    fm_lock_log "lsof open-path scan failed for $dir with exit $status"
    return 2
  fi
  pid=
  while IFS= read -r line; do
    case "$line" in
      p*)
        pid=${line#p}
        case "$pid" in ''|*[!0-9]*) fm_lock_log "lsof open-path scan returned an unexpected pid line: $line"; return 2 ;; esac
        ;;
      f*) [ -n "$pid" ] || { fm_lock_log "lsof open-path scan returned an fd before any pid"; return 2; } ;;
      n*)
        [ -n "$pid" ] || { fm_lock_log "lsof open-path scan returned a path before any pid"; return 2; }
        path=${line#n}
        case "$path" in
          "$dir"|"$dir"/*|"$real"|"$real"/*) return 0 ;;
        esac
        ;;
      '') ;;
      *) fm_lock_log "lsof open-path scan returned an unexpected line: $line"; return 2 ;;
    esac
  done <<EOF
$out
EOF
  return 1
}

# fm_lock_has_live_holder <lock> <dir>: 0 if a live process holds $lock or the
# companion $dir open, OR if the answer is uncertain - a missing lsof or an lsof
# error is treated as "cannot prove no holder" (fail safe: assume live). Returns
# 1 only when lsof reports provably no holder on both.
fm_lock_has_live_holder() {
  local lock=$1 dir=$2 status
  command -v lsof >/dev/null 2>&1 || return 0
  if [ -n "$lock" ]; then
    if fm_lock_lsof_holder "$lock"; then
      return 0
    else
      status=$?
      [ "$status" -eq 1 ] || return 0
    fi
  fi
  if [ -n "$dir" ]; then
    if fm_lock_lsof_holder "$dir"; then
      return 0
    else
      status=$?
      [ "$status" -eq 1 ] || return 0
    fi
  fi
  return 1
}

# fm_lock_age <lock>: prints the lock's mtime age in whole seconds, or fails.
fm_lock_age() {
  local lock=$1 m now
  m=$(fm_lock_path_mtime "$lock") || return 1
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s) || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$(( now - m ))"
}

# fm_lock_is_provably_stale <lock> <dir> <min_age_secs>: THE proof. Returns 0 iff
# the lock exists, has no live holder, and its mtime age is at least
# <min_age_secs>. Returns non-zero on any uncertainty - never remove a lock this
# returns non-zero for.
fm_lock_is_provably_stale() {
  local lock=$1 dir=$2 min_age=$3 age
  [ -n "$lock" ] && [ -e "$lock" ] || return 1
  fm_lock_has_live_holder "$lock" "$dir" && return 1
  if ! age=$(fm_lock_age "$lock"); then
    fm_lock_log "cannot read mtime for git lock $lock; leaving it in place"
    return 1
  fi
  [ "$age" -ge "$min_age" ]
}
