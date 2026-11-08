#!/usr/bin/env bash
# Durable Treehouse slot leases and the spawn steps that acquire them.
# bin/fm-wake-lib.sh sources this file.
# It is its own lint root so source-aware shellcheck of bin/fm-spawn.sh stays under the 8G resident cap.

fm_treehouse_same_project() {  # <project-dir> <worktree>
  local project=$1 slot=$2 project_common slot_common project_lock slot_lock
  project_common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  slot_common=$(git -C "$slot" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  project_common=$(CDPATH='' cd -- "$project_common" 2>/dev/null && pwd -P) || return 1
  slot_common=$(CDPATH='' cd -- "$slot_common" 2>/dev/null && pwd -P) || return 1
  [ "$project_common" != "$slot_common" ] || return 0
  project_lock=$(fm_treehouse_project_lock_path "$project") || return 1
  slot_lock=$(fm_treehouse_project_lock_path "$slot") || return 1
  [ "$project_lock" = "$slot_lock" ]
}

# Require the CLI contract before any allocation or endpoint mutation.
fm_treehouse_lease_cli() {
  local get_help return_help flag
  get_help=$(treehouse get --help 2>&1) || return 1
  return_help=$(treehouse return --help 2>&1) || return 1
  for flag in --lease --lease-holder --json; do
    printf '%s\n' "$get_help" | grep -Eq -- "(^|[[:space:]])$flag([[:space:]=]|$)" || return 1
  done
  for flag in --if-lease-id --if-lease-holder; do
    printf '%s\n' "$return_help" | grep -Eq -- "(^|[[:space:]])$flag([[:space:]=]|$)" || return 1
  done
  command -v jq >/dev/null 2>&1
}

fm_treehouse_legacy_holds_supported() {
  local version verified
  local -a verified_in_use_versions=(v2.3.0)
  version=$(treehouse --version 2>/dev/null) || version=unreadable
  for verified in "${verified_in_use_versions[@]}"; do
    [ "$version" != "$verified" ] || return 0
  done
  echo "REFUSED: Treehouse version '${version:-unreadable}' is not verified to protect legacy-named pool copies; verify in-use copy exclusion before adding it to verified_in_use_versions (docs/verification/runtime-backends.md; Treehouse v2.3.0 internal/pool/pool.go acquire and internal/process/detect.go). No Treehouse allocation was attempted." >&2
  return 1
}

# Read only the pool JSON, never a Treehouse command. Match physical paths so
# aliases cannot hide two records naming the same copy. Refuse ambiguous,
# malformed, unreadable, or identity-less leases. Output globals are valid only
# on success; callers compare them to the immutable acquisition record.
# shellcheck disable=SC2034 # Outputs for spawn and teardown.
fm_treehouse_pool_entry() {  # <worktree>; prints exactly one canonical entry
  local worktree=$1 slot state paths path real entry='' count=0 snapshot
  slot=$(CDPATH='' cd -- "$worktree" 2>/dev/null && pwd -P) || return 1
  state="$(dirname "$(dirname "$slot")")/treehouse-state.json"
  [ -f "$state" ] && [ ! -L "$state" ] && [ -r "$state" ] || return 1
  snapshot=$(cat "$state") || return 1
  paths=$(printf '%s\n' "$snapshot" | jq -er '
    def text: type == "string" and length > 0 and (test("[\\r\\n\\t]") | not);
    if (.worktrees | type) != "array" then error("worktrees") else
      .worktrees[] | if (.path | text) then .path else error("path") end end
  ' 2>/dev/null) || return 1
  while IFS= read -r path; do
    real=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || continue
    [ "$real" = "$slot" ] || continue
    count=$((count + 1))
    entry=$(printf '%s\n' "$snapshot" | jq -cer --arg path "$path" '.worktrees[] | select(.path == $path)' 2>/dev/null) || return 1
  done <<< "$paths"
  [ "$count" = 1 ] || return 1
  printf '%s\n' "$entry"
}

# shellcheck disable=SC2034 # Outputs for spawn and teardown.
fm_treehouse_lease_read() {  # <worktree>
  local entry
  FM_TREEHOUSE_LEASE_ID=
  FM_TREEHOUSE_LEASE_HOLDER=
  entry=$(fm_treehouse_pool_entry "$1") || return 1
  printf '%s\n' "$entry" | jq -e '
    .leased == true and (.destroying != true) and
    ([.lease_id, .lease_holder] | all(.[];
      type == "string" and length > 0 and (test("[\\r\\n\\t]") | not)))
  ' >/dev/null 2>&1 || return 1
  FM_TREEHOUSE_LEASE_ID=$(printf '%s\n' "$entry" | jq -er .lease_id) || return 1
  FM_TREEHOUSE_LEASE_HOLDER=$(printf '%s\n' "$entry" | jq -er .lease_holder) || return 1
}

fm_treehouse_legacy_unleased() {  # <worktree>
  local entry
  entry=$(fm_treehouse_pool_entry "$1") || return 1
  printf '%s\n' "$entry" | jq -e '
    (.leased == null or .leased == false) and (.destroying != true) and
    ((.lease_id // "") == "") and ((.lease_holder // "") == "")
  ' >/dev/null 2>&1
}

# Herdr's treehouse get --lease --lease-holder records the task id on the pool
# entry and does not write treehouse_lease_* into the task record.
fm_treehouse_task_holds_pool_lease() {  # <worktree> <task-id>
  [ -n "$2" ] || return 1
  fm_treehouse_pool_entry "$1" | jq -e --arg id "$2" '
    .leased == true and .lease_holder == $id and (.destroying != true)
  ' >/dev/null 2>&1
}

# True only when readable pool state proves this acquisition is no longer held,
# such as after a return whose later teardown steps failed.
fm_treehouse_lease_released() {  # <worktree> <lease-id>
  local entry
  [ -n "$2" ] || return 1
  entry=$(fm_treehouse_pool_entry "$1") || return 1
  printf '%s\n' "$entry" | jq -e --arg id "$2" '.lease_id != $id' >/dev/null 2>&1
}

fm_treehouse_lease_matches() {  # <worktree> <lease-id> <holder>
  [ -n "$2" ] && [ -n "$3" ] || return 1
  fm_treehouse_lease_read "$1" || return 1
  [ "$FM_TREEHOUSE_LEASE_ID" = "$2" ] && [ "$FM_TREEHOUSE_LEASE_HOLDER" = "$3" ]
}

# Missing fields mean legacy, never permission to infer a lease. Duplicate
# fields and unsafe records refuse even when their final values agree.
# shellcheck disable=SC2034 # Outputs for spawn and teardown.
fm_treehouse_record_lease() {  # <meta>
  local meta=$1
  FM_TREEHOUSE_RECORD_LEASE_ID=
  FM_TREEHOUSE_RECORD_LEASE_HOLDER=
  [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || return 1
  awk -F= '
    $1 == "treehouse_lease_id" { ids++; if (length($0) <= length($1)+1) bad=1 }
    $1 == "treehouse_lease_holder" { holders++; if (length($0) <= length($1)+1) bad=1 }
    END { exit !(ids == 1 && holders == 1 && !bad) }
  ' "$meta" || return 1
  FM_TREEHOUSE_RECORD_LEASE_ID=$(fm_meta_get "$meta" treehouse_lease_id)
  FM_TREEHOUSE_RECORD_LEASE_HOLDER=$(fm_meta_get "$meta" treehouse_lease_holder)
  case "$FM_TREEHOUSE_RECORD_LEASE_ID$FM_TREEHOUSE_RECORD_LEASE_HOLDER" in
    *[$'\r\n\t']*) return 1 ;;
  esac
}

# A last-value metadata reader must not hide an earlier reference to a copy.
fm_treehouse_record_paths_safe() {  # <meta>
  [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ] || return 1
  awk -F= '
    $1 == "worktree" || $1 == "home" || $1 == "project" {
      if (++seen[$1] > 1) bad=1
    }
    END { exit bad }
  ' "$1"
}

# Under the project lock, refuse unverifiable retained references BEFORE get
# can reset them. New leased references simply remain unavailable to get. A
# legacy record (no treehouse_lease_* field) naming an unleased copy is listed
# in FM_TREEHOUSE_LEGACY_COPIES for fm_treehouse_lease_get to hold instead.
# bin/fm-spawn.sh's header owns acquisition-journal retention and retry rules.
# shellcheck disable=SC2034 # FM_TREEHOUSE_LEGACY_COPIES is read by fm_treehouse_lease_get.
fm_treehouse_records_reserved() {  # <project> <state>
  local project=$1 state=$2 dir meta id path field journal journal_project paths pool_state
  FM_TREEHOUSE_LEGACY_COPIES=()
  fm_local_firstmate_state_dirs "$state" || {
    echo "REFUSED: $FM_LOCAL_FIRSTMATE_ERROR; no Treehouse allocation was attempted" >&2
    return 1
  }
  for dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] || {
      echo "REFUSED: missing or unreadable local state directory $dir; cannot verify retained task records" >&2
      return 1
    }
    for meta in "$dir"/*.meta; do
      [ -e "$meta" ] || [ -L "$meta" ] || continue
      fm_treehouse_record_paths_safe "$meta" || {
        echo "REFUSED: unreadable or ambiguous task record $meta; no Treehouse allocation was attempted" >&2
        return 1
      }
      id=${meta##*/}; id=${id%.meta}
      for field in worktree home; do
        path=$(fm_meta_get "$meta" "$field")
        [ -n "$path" ] || continue
        if ! fm_treehouse_pool_slot "$project" "$path"; then
          [ -d "$path" ] || continue
          fm_treehouse_same_project "$project" "$path" || continue
          path=$(CDPATH='' cd -- "$path" && pwd -P) || {
            echo "REFUSED: cannot resolve $field path in task record $meta; no Treehouse allocation was attempted" >&2
            return 1
          }
          pool_state="$(dirname "$(dirname "$path")")/treehouse-state.json"
          if [ -e "$pool_state" ] || [ -L "$pool_state" ]; then
            echo "REFUSED: cannot verify pool ownership for retained task $id at $path; no allocation was attempted" >&2
            return 1
          fi
          continue
        fi
        if [ "$(fm_meta_get "$meta" kind)" = secondmate ]; then
          # The existing home-seed contract labels secondmate leases by id.
          if fm_treehouse_task_holds_pool_lease "$path" "$id"; then
            continue
          fi
        elif fm_treehouse_record_lease "$meta" &&
          fm_treehouse_lease_matches "$path" "$FM_TREEHOUSE_RECORD_LEASE_ID" "$FM_TREEHOUSE_RECORD_LEASE_HOLDER"; then
          continue
        elif ! grep -q '^treehouse_lease_' "$meta" && fm_treehouse_legacy_unleased "$path"; then
          path=$(CDPATH='' cd -- "$path" && pwd -P) || {
            echo "REFUSED: cannot resolve $field path in task record $meta; no Treehouse allocation was attempted" >&2
            return 1
          }
          FM_TREEHOUSE_LEGACY_COPIES+=("$path")
          continue
        elif ! grep -q '^treehouse_lease_' "$meta" && fm_treehouse_task_holds_pool_lease "$path" "$id"; then
          continue
        fi
        echo "REFUSED: retained task $id ($meta) names pool copy $path without a verified matching durable lease; reconcile its ownership and run guarded cleanup before spawning again. No Treehouse allocation was attempted." >&2
        return 1
      done
    done
    for journal in "$dir"/*.treehouse-acquire; do
      [ -e "$journal" ] || [ -L "$journal" ] || continue
      journal_project=
      if [ -f "$journal/identity" ] && [ -r "$journal/identity" ] && [ ! -L "$journal/identity" ]; then
        journal_project=$(awk '
          /^project=/ { count++; value=substr($0,9) }
          END { if (count == 1 && length(value)) print value; else exit 1 }
        ' "$journal/identity") || journal_project=
      fi
      if [ -n "$journal_project" ]; then
        fm_treehouse_same_project "$project" "$journal_project" || continue
      fi
      if [ ! -d "$journal" ] || [ -L "$journal" ]; then
        echo "REFUSED: unsafe Treehouse acquisition journal $journal (not a directory or a symlink); reconcile it before allocating" >&2
        return 1
      fi
      if [ -z "$journal_project" ]; then
        echo "REFUSED: cannot determine project of Treehouse acquisition journal $journal; reconcile its identity before allocating" >&2
        return 1
      fi
      # A pending/partial response is unknown ownership, not a free copy.
      paths=$(jq -er '.path | select(type == "string" and length > 0)' "$journal/allocation.json" 2>/dev/null) || {
        echo "REFUSED: unresolved Treehouse acquisition journal $journal; reconcile it before allocating" >&2
        return 1
      }
      fm_treehouse_pool_slot "$project" "$paths" || continue
      if ! fm_treehouse_record_lease "$journal/identity" ||
        ! fm_treehouse_lease_matches "$paths" "$FM_TREEHOUSE_RECORD_LEASE_ID" "$FM_TREEHOUSE_RECORD_LEASE_HOLDER"; then
        echo "REFUSED: unresolved Treehouse acquisition journal $journal; reconcile its lease before allocating" >&2
        return 1
      fi
    done
  done
  if [ -n "${FM_TREEHOUSE_LEGACY_COPIES[*]-}" ]; then
    fm_treehouse_legacy_holds_supported || return 1
  fi
}

# Durable get for a fresh worker while every copy in FM_TREEHOUSE_LEGACY_COPIES
# is held out of allocation. Treehouse v2.3.0 has no command that leases an
# existing copy in place, and its get resets the first idle, unleased, clean,
# merged copy it scans. It never hands out a copy with a live process whose cwd
# is inside it, so one hold process sits in each legacy copy for exactly the get
# call. Holds read a FIFO whose only writer is this shell, so they also end if
# the caller dies; any hold that cannot be confirmed refuses before get.
# fm_treehouse_record_exclusive after get remains the backstop.
# Return 2 only when holds refuse before get; return 1 for any get failure,
# even if Treehouse itself exits 2, so the caller retains acquisition evidence.
fm_treehouse_lease_get() {  # <project> <holder> <allocation-json>
  local project=$1 holder=$2 out=$3 dir path reply status=0 pid
  local -a holds=()
  if [ -z "${FM_TREEHOUSE_LEGACY_COPIES[*]-}" ]; then
    (cd "$project" && treehouse get --lease --lease-holder "$holder" --json) > "$out" || return 1
    return 0
  fi
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-treehouse-hold.XXXXXX") || return 2
  if ! mkfifo "$dir/hold" "$dir/ready" || ! exec 6<>"$dir/hold" 7<>"$dir/ready"; then
    exec 6>&- 7>&-
    rm -rf "$dir"
    echo "REFUSED: cannot prepare holds for legacy task copies; no Treehouse allocation was attempted" >&2
    return 2
  fi
  for path in ${FM_TREEHOUSE_LEGACY_COPIES[@]+"${FM_TREEHOUSE_LEGACY_COPIES[@]}"}; do
    (
      exec 6>&- 7>&-
      if exec < "$dir/hold" && CDPATH='' cd -- "$path" && [ "$(pwd -P)" = "$path" ]; then
        printf 'held\n' > "$dir/ready"
        exec cat > /dev/null 2>&1
      fi
      printf 'failed\n' > "$dir/ready"
    ) &
    holds+=("$!")
    reply=
    IFS= read -r -t 10 reply <&7 || reply=
    if [ "$reply" != held ]; then
      echo "REFUSED: could not hold legacy task copy $path out of allocation; no Treehouse allocation was attempted" >&2
      status=2
      break
    fi
  done
  if [ "$status" -eq 0 ]; then
    (cd "$project" && treehouse get --lease --lease-holder "$holder" --json) > "$out" 6>&- 7>&- || status=1
  fi
  exec 6>&- 7>&-
  for pid in ${holds[@]+"${holds[@]}"}; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$dir"
  return "$status"
}

# Defense in depth after get and before claim/publication; also used for a
# relaunch before endpoint or wiring mutation. No status can exempt a record.
fm_treehouse_record_exclusive() {  # <state> <worktree> [own-meta]
  local state=$1 worktree=$2 own=${3:-} slot dir meta field path real
  slot=$(CDPATH='' cd -- "$worktree" 2>/dev/null && pwd -P) || {
    echo "REFUSED: cannot resolve pool copy $worktree; cannot verify exclusive record ownership" >&2
    return 1
  }
  fm_local_firstmate_state_dirs "$state" || {
    echo "REFUSED: $FM_LOCAL_FIRSTMATE_ERROR; cannot verify exclusive record ownership" >&2
    return 1
  }
  for dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] || {
      echo "REFUSED: missing or unreadable local state directory $dir; cannot verify retained task records" >&2
      return 1
    }
    for meta in "$dir"/*.meta; do
      [ -e "$meta" ] || [ -L "$meta" ] || continue
      fm_treehouse_record_paths_safe "$meta" || {
        echo "REFUSED: unreadable or ambiguous task record $meta; cannot verify exclusive record ownership" >&2
        return 1
      }
      if [ -n "$own" ] && [ "${meta##*/}" = "${own##*/}" ] && [ "$meta" -ef "$own" ]; then
        continue
      fi
      for field in worktree home; do
        path=$(fm_meta_get "$meta" "$field")
        [ -n "$path" ] || continue
        real=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || continue
        if [ "$real" = "$slot" ]; then
          echo "REFUSED: pool copy $slot is still named by task record $meta; reconcile that record first" >&2
          return 1
        fi
      done
    done
  done
}

# Runs inside bin/fm-spawn.sh and reads that script's globals.
# shellcheck disable=SC2153,SC2154
spawn_lease_treehouse_slot() {
  local treehouse_home treehouse_acquire_status
  TREEHOUSE_ACQUIRE_JOURNAL="$STATE/$ID.treehouse-acquire"
  mkdir -m 700 "$TREEHOUSE_ACQUIRE_JOURNAL" || exit 1
  treehouse_home=$(CDPATH='' cd -- "$FM_HOME" && pwd -P) || exit 1
  TREEHOUSE_LEASE_HOLDER="$treehouse_home/$ID/a$(date +%s).${BASHPID:-$$}.$RANDOM"
  printf 'project=%s\ntreehouse_lease_holder=%s\n' "$PROJ_ABS" "$TREEHOUSE_LEASE_HOLDER" > "$TREEHOUSE_ACQUIRE_JOURNAL/identity"
  if fm_treehouse_lease_get "$PROJ_ABS" "$TREEHOUSE_LEASE_HOLDER" "$TREEHOUSE_ACQUIRE_JOURNAL/allocation.json"; then
    :
  else
    treehouse_acquire_status=$?
    if [ "$treehouse_acquire_status" -eq 2 ]; then
      rm -rf "$TREEHOUSE_ACQUIRE_JOURNAL"
      TREEHOUSE_ACQUIRE_JOURNAL=
      echo "error: legacy copy hold failed before Treehouse acquisition; retry after resolving the hold failure" >&2
    else
      echo "error: durable Treehouse acquisition failed; retain $TREEHOUSE_ACQUIRE_JOURNAL for reconciliation" >&2
    fi
    exit 1
  fi
  WT=$(jq -er '.path | select(type == "string" and startswith("/") and (test("[\\r\\n\\t]") | not))' "$TREEHOUSE_ACQUIRE_JOURNAL/allocation.json") || exit 1
  TREEHOUSE_LEASE_ID=$(jq -er --arg holder "$TREEHOUSE_LEASE_HOLDER" '
    select(.lease_holder == $holder) | .lease_id |
    select(type == "string" and length > 0 and (test("[\\r\\n\\t]") | not))
  ' "$TREEHOUSE_ACQUIRE_JOURNAL/allocation.json") || exit 1
  printf 'treehouse_lease_id=%s\n' "$TREEHOUSE_LEASE_ID" >> "$TREEHOUSE_ACQUIRE_JOURNAL/identity"
  validate_spawn_worktree "treehouse get" "$WT"
  fm_treehouse_lease_matches "$WT" "$TREEHOUSE_LEASE_ID" "$TREEHOUSE_LEASE_HOLDER" || {
    echo "REFUSED: allocated Treehouse lease identity does not match pool state; retaining recovery journal" >&2
    exit 1
  }
  fm_treehouse_record_exclusive "$STATE" "$WT" || exit 1
  fm_treehouse_slot_owner_state "$WT" "$ID"
  case "$FM_TREEHOUSE_SLOT_OWNER" in
    absent) ;;
    *) echo "REFUSED: allocated copy $WT carries an existing slot claim; reconcile it before retrying" >&2; exit 1 ;;
  esac
}

# shellcheck disable=SC2153,SC2154
spawn_return_treehouse_slot() {
  [ -n "$TREEHOUSE_ACQUIRE_JOURNAL" ] && [ -n "$TREEHOUSE_LEASE_ID" ] &&
    [ -n "$TREEHOUSE_LEASE_HOLDER" ] || return 1
  if [ "$SPAWN_SLOT_CLAIMED" = 1 ]; then
    if [ "$SPAWN_TREEHOUSE_PROJECT_LOCK_HELD" != 1 ]; then
      [ -n "$SPAWN_TREEHOUSE_PROJECT_LOCK" ] &&
        fm_lock_acquire_wait_max "$SPAWN_TREEHOUSE_PROJECT_LOCK" 60 || return 1
      SPAWN_TREEHOUSE_PROJECT_LOCK_HELD=1
    fi
  fi
  [ "$SPAWN_FRESH_COMMIT_PENDING" = 0 ] &&
    [ ! -e "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ] || return 1
  if [ "$SPAWN_SLOT_CLAIMED" = 1 ]; then
    fm_treehouse_slot_owner_state "$WT" "$ID" "$FM_HOME"
    case "$FM_TREEHOUSE_SLOT_OWNER" in
      mine) fm_treehouse_slot_owner_release "$WT" "$ID" || return 1 ;;
      absent) ;;
      *) return 1 ;;
    esac
    fm_treehouse_slot_owner_state "$WT" "$ID" "$FM_HOME"
    [ "$FM_TREEHOUSE_SLOT_OWNER" = absent ] || return 1
    SPAWN_SLOT_CLAIMED=0
  fi
  (cd "$PROJ_ABS" && treehouse return --force "$WT" \
    --if-lease-id "$TREEHOUSE_LEASE_ID" --if-lease-holder "$TREEHOUSE_LEASE_HOLDER") || return 1
  rm -rf -- "$TREEHOUSE_ACQUIRE_JOURNAL" || return 1
  TREEHOUSE_ACQUIRE_JOURNAL=
}

# shellcheck disable=SC2153,SC2154
spawn_treehouse_recovery_steps() {
  local journal=$1
  {
    echo "Manual recovery: pause allocations and cleanup for this project; inspect the journal, retained task records, pool treehouse-state.json, and slot claim before releasing anything."
    printf 'journal=%q\n' "$journal"
    cat <<'RECOVERY'
Read project= and treehouse_lease_holder= from "$journal/identity".
Set worktree, lease_id, and lease_holder from "$journal/allocation.json"; verify them against that identity and the pool state.
If allocation.json is incomplete, locate the exact holder from identity in treehouse-state.json and recover its path and lease_id; do not guess the holder.
If no pool entry carries the recorded lease holder, confirm this never-acquired case from pool treehouse-state.json, then remove only this journal by hand and stop:
  rm -rf -- "$journal"
Preserve any unlanded work and reconcile any retained task record first.
For a conflicting claim, confirm it is orphaned: no live task record in any local home names the claim's task and home.
Stop if another task owns the claim or lease or orphan status is uncertain.
With worktree, lease_id, and lease_holder set to those verified values, run:
  treehouse return --if-lease-id "$lease_id" --if-lease-holder "$lease_holder" "$worktree"
Only after return succeeds, and the slot claim belongs to this acquisition, is confirmed orphaned, or is absent, remove the claim and journal by hand:
  rm -f -- "$(dirname "$worktree")/.fm-slot-owner"
  rm -rf -- "$journal"
Keep the journal and claim if return fails or ownership is uncertain.
RECOVERY
  } >&2
}

# shellcheck disable=SC2153,SC2154
spawn_treehouse_reservation_preflight() {
  [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ] || return 0
  if [ "$RELAUNCH" -eq 1 ]; then
    if ! grep -q '^treehouse_lease_' "$RELAUNCH_META"; then
      # A record from before durable leases keeps relaunching into its own
      # claimed copy; fresh-spawn preflight keeps that copy out of allocation.
      fm_treehouse_legacy_unleased "$RELAUNCH_WT" || {
        echo "REFUSED: task $ID's recorded copy has no verifiable pool reservation; reconcile its ownership before relaunch" >&2
        exit 1
      }
    elif ! fm_treehouse_record_lease "$RELAUNCH_META" ||
      ! fm_treehouse_lease_matches "$RELAUNCH_WT" "$FM_TREEHOUSE_RECORD_LEASE_ID" "$FM_TREEHOUSE_RECORD_LEASE_HOLDER"; then
      echo "REFUSED: task $ID's recorded durable lease cannot be verified; reconcile its ownership before relaunch" >&2
      exit 1
    else
      TREEHOUSE_LEASE_ID=$FM_TREEHOUSE_RECORD_LEASE_ID
      TREEHOUSE_LEASE_HOLDER=$FM_TREEHOUSE_RECORD_LEASE_HOLDER
    fi
    fm_treehouse_slot_owner_state "$RELAUNCH_WT" "$ID" "$FM_HOME"
    if [ "$FM_TREEHOUSE_SLOT_OWNER" != mine ]; then
      echo "REFUSED: task $ID's recorded copy is not claimed by this home and task; reconcile its ownership before relaunch" >&2
      exit 1
    fi
    fm_treehouse_record_exclusive "$STATE" "$RELAUNCH_WT" "$RELAUNCH_META" || exit 1
  else
    if [ -e "$STATE/$ID.treehouse-acquire" ] || [ -L "$STATE/$ID.treehouse-acquire" ]; then
      echo "REFUSED: task $ID has a retained Treehouse acquisition journal; reconcile $STATE/$ID.treehouse-acquire before retrying" >&2
      spawn_treehouse_recovery_steps "$STATE/$ID.treehouse-acquire"
      exit 1
    fi
    fm_treehouse_records_reserved "$PROJ_ABS" "$STATE" || exit 1
  fi
}
