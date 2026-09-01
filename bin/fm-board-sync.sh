#!/usr/bin/env bash
# fm-board-sync.sh - single owner of the GitHub Projects fleet-board sync.
#
# Usage:
#   fm-board-sync.sh reconcile [--dry-run]
#   fm-board-sync.sh poll
#   fm-board-sync.sh arm
#   fm-board-sync.sh disarm
#   fm-board-sync.sh status
#
# The sync is one-directional plus notifications.
#
# `reconcile` reads every fleet column from fm-bearings-snapshot.sh and pushes
# those columns onto real issues in the configured private board repository.  It
# creates a canonical card for every fleet task the sync owns, restores a card
# that left the board, keeps that card's allowlisted title and body in step,
# sets the card's column to its own task's fleet column, and closes the issue
# once that task reaches Done.  Every applied change is listed under
# `operations`.
#
# The sync never reads board state back into the fleet.  It never observes,
# owns, retires, or acts on captain-made board or issue state, never writes
# fleet state, dispatches work, closes backlog items, merges, or tears down, and
# never deletes, archives, or unarchives a card.  state/board-sync.json holds
# only the task-to-issue mapping the push needs.
#
# Board facts that do not match fleet state become one-line informational notes
# under `escalations`, each a plain `board changed: ...` observation of what the
# run saw when it read the board.  A note is a report, never an instruction and
# never an action, and it carries no attribution because a board read cannot
# tell who made a change.  An archived card, an issue closed while the fleet
# holds a non-Done column, and a card the sync does not manage are reported and
# then left exactly as they are.  Every run reports what it observes, so a note
# repeats while its board fact persists and stops once the fact is gone.
#
# Writes always target the board item the run actually resolved, and the
# resolved item id is persisted as soon as it differs from the recorded one, so
# a card the captain removes and re-adds by hand cannot wedge later runs against
# a stale id.  A mapped task is reached only through its own recorded mapping,
# so every write for it targets the repository that mapping records; the
# configured repository is used only to create a new canonical issue for a task
# that has no mapping yet.  A mapping recording a repository other than the
# configured one is confirmed private and reachable before that task is written
# to, and when that confirmation fails only that one task is skipped: it gets no
# write and no operation, its skip is reported as a one-line note, and the rest
# of the run proceeds normally.  A run interrupted between creating an issue and
# recording its mapping leaves that issue behind; the next run creates the
# canonical card again and reports the leftover as an unmanaged card rather than
# adopting it.
#
# `poll` performs one paginated Projects v2 read, derives the same notes, and
# prints only `board-sync N board change(s) pending` when the note set changes.
# The signature is derived from the note text alone, never from a GitHub
# timestamp, so a bare touch stays quiet.
#
# `arm` creates state/board-watch.check.sh as a byte-static custom watcher
# check, initializes state/board-sync.json when absent, and binds the check with
# fm-check-register.sh.  The existing watcher sweep remains the only poller.
# `disarm` removes only that check and its trust binding.
#
# config/board-sync.json is exactly:
#   {"owner":"LOGIN","project_number":1,"repo":"OWNER/REPO"}
# config/board-exclude is one task id per line with blank lines and `#` comments
# ignored.  That captain-owned local file is the only source of excluded ids;
# reconcile and poll refuse every GitHub call unless it is a readable regular
# file that yields at least one id.  An excluded task is never pushed and never
# gets a card, and a card this sync has already mapped for it is never written
# to and never reported as unmanaged.  A hand-filed card for a task excluded
# before the sync ever mapped it has no mapping, so it is reported as an
# ordinary unmanaged card and still left untouched.
#
# GitHub writes fail closed unless the repository a write targets - a task's
# own mapped repository, or the configured one when creating its first issue -
# is confirmed private immediately before that GitHub mutation.  Issue bodies
# are built from an allowlist only: optional project/kind labels and an HTTPS PR
# URL.  Issue titles come only from the structured backlog title, falling back
# to an opaque short label, never to a runtime summary.  Free-form detail,
# holds, paths, runtime metadata, and task ids never enter a GitHub title/body
# mutation.
# The label salt is a stable hash of the effective home and exact board config,
# so the same task keeps the same opaque label across runs without persisting
# anything.
#
# Environment overrides used by tests and isolated homes:
#   FM_ROOT_OVERRIDE, FM_HOME, FM_CONFIG_OVERRIDE, FM_STATE_OVERRIDE,
#   FM_BOARD_BEARINGS, FM_BOARD_FLEET_SNAPSHOT, FM_BOARD_BEARINGS_HOME,
#   FM_BOARD_NOW.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_FILE="$CONFIG_DIR/board-sync.json"
EXCLUDE_FILE="$CONFIG_DIR/board-exclude"
STATE_FILE="$STATE_DIR/board-sync.json"
SEEN_FILE="$STATE_DIR/board-sync.seen"
LOCK_DIR="$STATE_DIR/.board-sync.lock"
LOCK_FILE="$LOCK_DIR/owner"
LOCK_RECLAIM="$STATE_DIR/.board-sync.lock-reclaim"
CHECK_ID='board-watch'
CHECK_FILE="$STATE_DIR/$CHECK_ID.check.sh"
TRUST_FILE="$STATE_DIR/$CHECK_ID.check-trust"
BEARINGS="${FM_BOARD_BEARINGS:-$SCRIPT_DIR/fm-bearings-snapshot.sh}"
FLEET_SNAPSHOT="${FM_BOARD_FLEET_SNAPSHOT:-$SCRIPT_DIR/fm-fleet-snapshot.sh}"
BEARINGS_HOME="${FM_BOARD_BEARINGS_HOME:-$FM_HOME}"
NOW="${FM_BOARD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0" >&2
}

die() {
  printf 'fm-board-sync: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found"
}

sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    die "sha256 tool not found"
  fi
}

private_dir() {
  local dir=$1
  if [ -e "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] || die "$dir is not a directory"
  else
    umask 077
    mkdir -p -- "$dir" || die "cannot create $dir"
  fi
}

write_json_atomic() {
  local destination=$1 json=$2 dir tmp
  dir=$(dirname "$destination")
  private_dir "$dir"
  [ ! -L "$destination" ] || die "$destination must not be a symlink"
  umask 077
  tmp=$(mktemp "$dir/.fm-board-sync.XXXXXX") || die "cannot create state temp file"
  if ! printf '%s\n' "$json" | jq -e . > "$tmp"; then
    rm -f -- "$tmp"
    die "refusing invalid JSON state"
  fi
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; die "cannot protect state temp file"; }
  mv -f -- "$tmp" "$destination" || { rm -f -- "$tmp"; die "cannot replace $destination"; }
}

label_salt() {
  local config seed
  config=$(jq -cS . "$CONFIG_FILE") || die "cannot derive board label salt"
  seed="fm-board-sync.v1:$FM_HOME:$config"
  sha256_text "$seed" | cut -c1-32
}

empty_state() {
  jq -n '{
    schema:"fm-board-sync.v1",
    project:{},
    synced_at:null,
    tasks:{}
  }'
}

ensure_state() {
  private_dir "$STATE_DIR"
  if [ ! -e "$STATE_FILE" ]; then
    write_json_atomic "$STATE_FILE" "$(empty_state)"
  fi
  load_state
}

load_state() {
  local state
  [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] || die "state file is unavailable"
  state=$(jq -c . "$STATE_FILE") || die "invalid state/board-sync.json"
  printf '%s' "$state" | jq -e '
    type == "object"
    and .schema == "fm-board-sync.v1"
    and (.project | type == "object")
    and (.tasks | type == "object")
  ' >/dev/null || die "invalid state/board-sync.json"
  printf '%s\n' "$state"
}

load_config() {
  local config
  [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] || die "missing config/board-sync.json"
  config=$(jq -c . "$CONFIG_FILE") || die "invalid config/board-sync.json"
  printf '%s' "$config" | jq -e '
    type == "object"
    and ((keys | sort) == ["owner","project_number","repo"])
    and (.owner | type == "string" and test("^[A-Za-z0-9_.-]+$"))
    and (.project_number | type == "number" and floor == . and . > 0)
    and (.repo | type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))
    and (. as $config | .repo | startswith($config.owner + "/"))
  ' >/dev/null || die "invalid config/board-sync.json"
  printf '%s\n' "$config"
}

load_exclusions() {
  local exclusions raw
  [ -e "$EXCLUDE_FILE" ] \
    || die "missing config/board-exclude: list one excluded task id per line before syncing"
  [ -f "$EXCLUDE_FILE" ] && [ ! -L "$EXCLUDE_FILE" ] \
    || die "config/board-exclude must be a regular file, not a symlink or directory"
  [ -r "$EXCLUDE_FILE" ] || die "config/board-exclude is unreadable"
  raw=$(awk '
    { sub(/[[:space:]]*#.*/, "") }
    { gsub(/^[[:space:]]+|[[:space:]]+$/, "") }
    NF { print }
  ' "$EXCLUDE_FILE") || die "cannot read config/board-exclude"
  exclusions=$(printf '%s' "$raw" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique') \
    || die "invalid config/board-exclude"
  printf '%s' "$exclusions" | jq -e 'length > 0' >/dev/null \
    || die "config/board-exclude yields no task ids: every sensitive task would get a card"
  printf '%s\n' "$exclusions"
}

FM_BOARD_LOCK_OWNER_PID=
FM_BOARD_LOCK_OWNER_IDENTITY=

board_lock_read_owner() {
  FM_BOARD_LOCK_OWNER_PID=
  FM_BOARD_LOCK_OWNER_IDENTITY=
  [ -f "$LOCK_FILE" ] && [ ! -L "$LOCK_FILE" ] || return 1
  exec 9< "$LOCK_FILE" || return 1
  IFS= read -r FM_BOARD_LOCK_OWNER_PID <&9 \
    || { exec 9<&-; return 1; }
  IFS= read -r FM_BOARD_LOCK_OWNER_IDENTITY <&9 \
    || { exec 9<&-; return 1; }
  if IFS= read -r <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  case "$FM_BOARD_LOCK_OWNER_PID" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -n "$FM_BOARD_LOCK_OWNER_IDENTITY" ]
}

board_lock_acquire() {
  local tries=0 owner_pid owner_identity current_identity lock_pid lock_identity lock_temp
  private_dir "$LOCK_DIR"
  lock_pid=${BASHPID:-$$}
  lock_identity=$(fm_pid_identity "$lock_pid" 2>/dev/null) \
    || die "cannot identify reconcile lock owner"
  umask 077
  lock_temp=$(mktemp "$LOCK_DIR/.owner.XXXXXX") \
    || die "cannot create reconcile lock owner"
  if ! printf '%s\n%s\n' "$lock_pid" "$lock_identity" > "$lock_temp" \
    || ! chmod 0600 "$lock_temp"; then
    rm -f -- "$lock_temp"
    die "cannot record reconcile lock owner"
  fi
  while :; do
    if [ ! -e "$LOCK_RECLAIM" ] && [ ! -L "$LOCK_RECLAIM" ] \
      && ln "$lock_temp" "$LOCK_FILE" 2>/dev/null; then
      break
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge 20 ]; then
      while ! fm_lock_try_acquire "$LOCK_RECLAIM"; do
        sleep 0.05
      done
      if [ ! -e "$LOCK_FILE" ] && [ ! -L "$LOCK_FILE" ] \
        && ln "$lock_temp" "$LOCK_FILE" 2>/dev/null; then
        fm_lock_release "$LOCK_RECLAIM"
        break
      fi
      if ! board_lock_read_owner; then
        fm_lock_release "$LOCK_RECLAIM"
        rm -f -- "$lock_temp"
        die "another fm-board-sync reconcile holds $LOCK_DIR with unverifiable ownership"
      fi
      owner_pid=$FM_BOARD_LOCK_OWNER_PID
      owner_identity=$FM_BOARD_LOCK_OWNER_IDENTITY
      if fm_pid_alive "$owner_pid"; then
        current_identity=$(fm_pid_identity "$owner_pid" 2>/dev/null) \
          || { fm_lock_release "$LOCK_RECLAIM"; rm -f -- "$lock_temp"; die "another fm-board-sync reconcile holds $LOCK_DIR with unverifiable ownership"; }
        if [ "$current_identity" = "$owner_identity" ]; then
          fm_lock_release "$LOCK_RECLAIM"
          rm -f -- "$lock_temp"
          die "another fm-board-sync reconcile holds $LOCK_DIR; retry once it finishes"
        fi
      fi
      rm -f -- "$LOCK_FILE"
      if ln "$lock_temp" "$LOCK_FILE" 2>/dev/null; then
        fm_lock_release "$LOCK_RECLAIM"
        break
      fi
      fm_lock_release "$LOCK_RECLAIM"
      tries=0
      continue
    fi
    sleep 0.05
  done
  rm -f -- "$lock_temp"
}

board_lock_release() {
  local owner_pid owner_identity current_pid current_identity
  board_lock_read_owner || return 0
  owner_pid=$FM_BOARD_LOCK_OWNER_PID
  owner_identity=$FM_BOARD_LOCK_OWNER_IDENTITY
  current_pid=${BASHPID:-$$}
  current_identity=$(fm_pid_identity "$current_pid" 2>/dev/null || true)
  [ "$owner_pid" = "$current_pid" ] && [ -n "$current_identity" ] \
    && [ "$owner_identity" = "$current_identity" ] || return 0
  rm -f -- "$LOCK_FILE"
}

repo_is_private() {
  local repo=$1 visibility
  visibility=$(gh api "repos/$repo" --jq '.private' 2>/dev/null) || return 1
  [ "$visibility" = true ]
}

github_mutation_guard() {
  local repo=$1
  repo_is_private "$repo" \
    || die "refusing GitHub writes: $repo is public or its visibility is unknown"
}

FM_BOARD_REPO_CONFIRMED=
FM_BOARD_REPO_REFUSED=

mapped_repo_confirmed() {
  local repo=$1
  [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  case "$FM_BOARD_REPO_CONFIRMED" in
    *"|$repo|"*) return 0 ;;
  esac
  case "$FM_BOARD_REPO_REFUSED" in
    *"|$repo|"*) return 1 ;;
  esac
  if repo_is_private "$repo"; then
    FM_BOARD_REPO_CONFIRMED="$FM_BOARD_REPO_CONFIRMED|$repo|"
    return 0
  fi
  FM_BOARD_REPO_REFUSED="$FM_BOARD_REPO_REFUSED|$repo|"
  return 1
}

board_query() {
  cat <<'GRAPHQL'
query($owner:String!,$number:Int!,$cursor:String) {
  user(login:$owner) {
    projectV2(number:$number) {
      id
      title
      field(name:"Status") {
        ... on ProjectV2SingleSelectField {
          id
          options { id name }
        }
      }
      items(first:100,after:$cursor) {
        nodes {
          id
          type
          isArchived
          updatedAt
          fieldValueByName(name:"Status") {
            ... on ProjectV2ItemFieldSingleSelectValue {
              name
              optionId
              updatedAt
            }
          }
          content {
            __typename
            ... on Issue {
              id
              number
              title
              body
              state
              url
              updatedAt
              repository { nameWithOwner isPrivate }
            }
            ... on DraftIssue { title }
          }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}
GRAPHQL
}

read_board() {
  local owner=$1 number=$2 query cursor='' page pages project page_items
  query=$(board_query)
  pages='[]'
  project=
  while :; do
    if [ -n "$cursor" ]; then
      page=$(gh api graphql -f query="$query" -f owner="$owner" -F number="$number" -f cursor="$cursor") \
        || die "cannot read GitHub project"
    else
      page=$(gh api graphql -f query="$query" -f owner="$owner" -F number="$number") \
        || die "cannot read GitHub project"
    fi
    printf '%s' "$page" | jq -e '.data.user.projectV2.id and .data.user.projectV2.field.id' >/dev/null \
      || die "GitHub project or Status field is unavailable"
    if [ -z "$project" ]; then
      project=$(printf '%s' "$page" | jq '.data.user.projectV2 | {
        id,
        title,
        status_field_id:.field.id,
        options:(.field.options | map({key:.name,value:.id}) | from_entries)
      }')
    fi
    page_items=$(printf '%s' "$page" | jq '.data.user.projectV2.items.nodes')
    pages=$(printf '%s\n' "$pages" "$page_items" | jq -n '[inputs] as [$old, $new] | $old + $new')
    [ "$(printf '%s' "$page" | jq -r '.data.user.projectV2.items.pageInfo.hasNextPage')" = true ] || break
    cursor=$(printf '%s' "$page" | jq -er '.data.user.projectV2.items.pageInfo.endCursor // empty') \
      || die "GitHub project pagination cursor is unavailable"
  done
  printf '%s\n' "$project" "$pages" | jq -n '[inputs] as [$project, $items] | {project:$project,items:$items}'
}

validate_columns() {
  local board=$1
  printf '%s' "$board" | jq -e '
    (.project.options | keys | sort) ==
      (["Ready","Held","Blocked","Under way","Waiting on you","Done"] | sort)
  ' >/dev/null || die "GitHub Status must contain exactly the six bearings columns"
}

bearings_snapshot() {
  FM_HOME="$BEARINGS_HOME" "$BEARINGS" --json \
    --all-in-flight --all-decisions --all-queued --all-landed \
    --all-reports --all-recorded-prs --include-prs --all-pr-repos
}

fleet_metadata_snapshot() {
  FM_HOME="$BEARINGS_HOME" "$FLEET_SNAPSHOT" --json
}

desired_items() {
  local snapshot=$1 metadata=$2 salt=$3 exclusions=$4 base task_id label item
  # Large JSON travels via stdin: Linux caps a single exec argument at 128KB
  # (MAX_ARG_STRLEN), which a real snapshot exceeds as --argjson.
  base=$(printf '%s\n' "$snapshot" "$metadata" | jq -n '
    [inputs] as [$root, $metadata]
    | def valid_pr_url:
      type == "string"
      and test("^https://github[.]com/[^/@?#[:space:]]+/[^/@?#[:space:]]+/pull/[1-9][0-9]*$");
    ([$root.board_items[]
        | select(.owner == "(main)")
        | select(.id != "(main-inventory)")
        | select((.id | contains("#")) | not)]
       | reduce .[] as $item ([];
           if any(.id == $item.id) then . else . + [$item] end)) as $tasks
    | [ $tasks[]
        | . as $task
        | (($metadata.backlog.records[]? | select(.id == $task.id)) // {}) as $meta
        | (($root.recorded_prs[]? | select(.id == $task.id) | .url) //
           (if (.artifact | valid_pr_url) then .artifact else null end)) as $pr
        | (($root.board_items[]?
            | select((.id | contains("#")) and .artifact == $pr)) // null) as $prrow
        | (($root.in_flight[]? | select(.id == $task.id) | .kind) //
           (if any($root.decisions_open[]?; .id == $task.id) then "captain" else null end)) as $kind
        | {
            id:.id,
            title:(if ($meta.title | type) == "string" then ($meta.title | .[0:120]) else null end),
            column:($prrow.column // .column),
            kind:($meta.kind // $kind),
            project:(if (($meta.repo // "-") == "-") then null else $meta.repo end),
            pr_url:(if ($pr | valid_pr_url) then $pr else null end)
          }
      ]
  ') || die "bearings snapshot does not provide valid board items"
  printf '%s' "$snapshot" | jq -e '
    [.board_columns[].column] == ["Ready","Held","Blocked","Under way","Waiting on you","Done"]
  ' >/dev/null || die "bearings snapshot does not provide the six canonical columns"
  while IFS= read -r item; do
    task_id=$(printf '%s' "$item" | jq -er '.id')
    label=$(sha256_text "$task_id$salt" | cut -c1-8)
    item=$(printf '%s' "$item" | jq --arg label "$label" --argjson exclusions "$exclusions" '
      . as $item
      | $item + {
        label:$label,
        excluded:($exclusions | index($item.id) != null)
      }
      | .title = (if (.title | type) == "string" and (.title | length) > 0
                  then .title
                  else "Fleet task " + .label end)
      | .body = ([
          (if .project then "project: " + .project else empty end),
          (if .kind then "kind: " + .kind else empty end),
          (if .pr_url then "PR: " + .pr_url else empty end)
        ] | join("\n"))
    ')
    printf '%s\n' "$item"
  done < <(printf '%s' "$base" | jq -c '.[]') | jq -sc '.'
}

find_live_item() {
  local board=$1 item_id=$2 issue_number=$3 repo=$4
  printf '%s' "$board" | jq -c --arg item_id "$item_id" --argjson issue_number "${issue_number:-null}" --arg repo "$repo" '
    [.items[]
     | select((.id == $item_id and $item_id != "") or
              (.content.__typename == "Issue" and .content.number == $issue_number and
               .content.repository.nameWithOwner == $repo))][0] // null
  '
}

# Single owner of the informational note set.  Notes are derived only from the
# board read and the current fleet columns, never from stored board history, so
# they state what is true now and claim nothing about who made it true.
board_notes() {
  local state=$1 board=$2 desired=$3
  printf '%s\n' "$state" "$board" "$desired" | jq -n '
    [inputs] as [$state, $board, $desired]
    | def owned_item($mapping):
      [ $board.items[]
        | select((.id == ($mapping.item_id // "") and ($mapping.item_id // "") != "")
                 or (.content.__typename == "Issue"
                     and .content.number == ($mapping.issue_number // -1)
                     and .content.repository.nameWithOwner == ($mapping.repo // ""))) ][0] // null;
    def is_mapped($item):
      [ $state.tasks[]
        | select((.item_id // "") == $item.id
                 or (.issue_number == ($item.content.number // -1)
                     and (.repo // "") == ($item.content.repository.nameWithOwner // ""))) ]
      | length > 0;
    ([ $desired[]
       | select(.excluded == false)
       | . as $want
       | ($state.tasks[$want.id] // null) as $mapping
       | select($mapping != null)
       | owned_item($mapping) as $item
       | if $item == null then
           ["board changed: task \($want.id) has no card on the board while the fleet says \"\($want.column)\"."]
         elif $item.isArchived == true then
           ["board changed: task \($want.id) has an archived card while the fleet says \"\($want.column)\"."]
         else
           (if ($item.fieldValueByName.name // null) != $want.column then
              ["board changed: task \($want.id) card is in \"\($item.fieldValueByName.name // "no column")\" while the fleet says \"\($want.column)\"."]
            else [] end)
           + (if (($item.content.state // "") | ascii_upcase) == "CLOSED" and $want.column != "Done" then
                ["board changed: task \($want.id) issue is closed while the fleet says \"\($want.column)\"."]
              else [] end)
         end ]
     | add // [])
    + [ $board.items[]
        | select(.isArchived == false)
        | . as $item
        | select(is_mapped($item) | not)
        | "board changed: an unmanaged card titled \"\(($item.content.title // "Untitled board item") | gsub("[[:space:]]+"; " "))\" is on the board in \"\($item.fieldValueByName.name // "no column")\"; it was left untouched." ]
    | unique
  ' || die "cannot derive board notes"
}

seen_signature() {
  local notes=$1
  sha256_text "$(printf '%s' "$notes" | jq -cS '.')"
}

store_seen_signature() {
  local notes=$1 count signature
  count=$(printf '%s' "$notes" | jq 'length')
  if [ "$count" -eq 0 ]; then
    rm -f -- "$SEEN_FILE"
    return 0
  fi
  signature=$(seen_signature "$notes")
  private_dir "$STATE_DIR"
  [ ! -L "$SEEN_FILE" ] || die "$SEEN_FILE must not be a symlink"
  umask 077
  printf '%s\n' "$signature" > "$SEEN_FILE" || die "cannot write poll signature"
  chmod 0600 "$SEEN_FILE" || die "cannot protect poll signature"
}

append_operation() {
  local operations=$1 operation=$2
  printf '%s\n' "$operations" "$operation" | jq -n '[inputs] as [$operations, $operation] | $operations + [$operation]'
}

append_note() {
  local notes=$1 note=$2
  jq -n --argjson notes "$notes" --arg note "$note" '$notes + [$note] | unique' \
    || die "cannot record board note"
}

issue_create() {
  local repo=$1 title=$2 body=$3
  github_mutation_guard "$repo"
  gh api --method POST "repos/$repo/issues" -f title="$title" -f body="$body"
}

issue_update() {
  local repo=$1 number=$2 title=$3 body=$4
  github_mutation_guard "$repo"
  gh api --method PATCH "repos/$repo/issues/$number" -f title="$title" -f body="$body"
}

issue_close() {
  local repo=$1 number=$2
  github_mutation_guard "$repo"
  gh api --method PATCH "repos/$repo/issues/$number" -f state=closed
}

project_add_item() {
  local repo=$1 project_id=$2 issue_id=$3
  github_mutation_guard "$repo"
  # shellcheck disable=SC2016
  gh api graphql -f query='mutation($project:ID!,$content:ID!){addProjectV2ItemById(input:{projectId:$project,contentId:$content}){item{id}}}' \
    -F project="$project_id" -F content="$issue_id"
}

project_set_column() {
  local repo=$1 project_id=$2 item_id=$3 field_id=$4 option_id=$5
  github_mutation_guard "$repo"
  # shellcheck disable=SC2016
  gh api graphql -f query='mutation($project:ID!,$item:ID!,$field:ID!,$option:String!){updateProjectV2ItemFieldValue(input:{projectId:$project,itemId:$item,fieldId:$field,value:{singleSelectOptionId:$option}}){projectV2Item{id}}}' \
    -F project="$project_id" -F item="$item_id" -F field="$field_id" -f option="$option_id"
}

record_mapping() {
  local state=$1 task_id=$2 repo=$3 issue=$4 item_id=$5
  printf '%s' "$state" | jq \
    --arg task_id "$task_id" --arg repo "$repo" \
    --arg item_id "$item_id" --argjson issue "$issue" '
    .tasks[$task_id] = {
      repo:$repo,
      issue_number:$issue.number,
      issue_id:($issue.node_id // $issue.id),
      issue_url:($issue.html_url // $issue.url),
      item_id:$item_id
    }
  '
}

reconcile() {
  local dry_run=0 config exclusions state owner number repo board snapshot metadata desired
  local project_id field_id options operations='[]' escalations excluded
  local item task_id title column body mapping live theirs issue_state
  local live_item_id mapped_repo
  local issue issue_number issue_id issue_url item_id option_id operation
  local created add_result post_board updated_state residual post_notes
  if [ "${1:-}" = --dry-run ]; then
    dry_run=1
    shift
  fi
  [ "$#" -eq 0 ] || { usage; exit 2; }
  need jq
  need gh
  config=$(load_config)
  exclusions=$(load_exclusions)
  if [ "$dry_run" -eq 1 ]; then
    if [ -e "$STATE_FILE" ] || [ -L "$STATE_FILE" ]; then
      state=$(load_state)
    else
      state=$(empty_state)
    fi
  else
    private_dir "$STATE_DIR"
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    board_lock_acquire
    trap board_lock_release EXIT
    state=$(ensure_state)
  fi
  owner=$(printf '%s' "$config" | jq -er '.owner')
  number=$(printf '%s' "$config" | jq -er '.project_number')
  repo=$(printf '%s' "$config" | jq -er '.repo')
  repo_is_private "$repo" || die "refusing GitHub writes: $repo is public or its visibility is unknown"
  board=$(read_board "$owner" "$number")
  validate_columns "$board"
  project_id=$(printf '%s' "$board" | jq -er '.project.id')
  field_id=$(printf '%s' "$board" | jq -er '.project.status_field_id')
  options=$(printf '%s' "$board" | jq '.project.options')
  snapshot=$(bearings_snapshot) || die "cannot read bearings snapshot"
  metadata=$(fleet_metadata_snapshot) || die "cannot read fleet metadata snapshot"
  desired=$(desired_items "$snapshot" "$metadata" "$(label_salt)" "$exclusions")
  excluded=$(printf '%s' "$desired" | jq -c '[.[] | select(.excluded) | .id]')
  escalations=$(board_notes "$state" "$board" "$desired")
  updated_state=$state

  while IFS= read -r item; do
    task_id=$(printf '%s' "$item" | jq -er '.id')
    title=$(printf '%s' "$item" | jq -er '.title')
    column=$(printf '%s' "$item" | jq -er '.column')
    body=$(printf '%s' "$item" | jq -er '.body')
    option_id=$(printf '%s' "$options" | jq -er --arg column "$column" '.[$column]') \
      || die "missing GitHub Status option: $column"
    mapping=$(printf '%s' "$updated_state" | jq -c --arg id "$task_id" '.tasks[$id] // null')
    item_id=$(printf '%s' "$mapping" | jq -r '.item_id // empty')
    issue_number=$(printf '%s' "$mapping" | jq -r '.issue_number // empty')
    mapped_repo=$(printf '%s' "$mapping" | jq -r '.repo // empty')
    live=$(find_live_item "$board" "$item_id" "$issue_number" "$mapped_repo")
    if [ "$live" != null ] && [ "$(printf '%s' "$live" | jq -r '.isArchived')" = true ]; then
      continue
    fi
    if [ -n "$mapped_repo" ] && [ "$mapped_repo" != "$repo" ] \
      && ! mapped_repo_confirmed "$mapped_repo"; then
      escalations=$(append_note "$escalations" \
        "board changed: task $task_id is mapped to board repository $mapped_repo, which cannot be confirmed private or reachable, so the task was skipped and left untouched.")
      continue
    fi

    if [ "$mapping" = null ]; then
      if [ "$dry_run" = 0 ]; then
        created=$(issue_create "$repo" "$title" "$body") || die "cannot create board issue"
        issue=$(printf '%s' "$created" | jq -e '{number,id,node_id,html_url,url,title,body,state}') \
          || die "GitHub issue create returned invalid data"
      else
        issue=$(jq -n --arg url "https://github.com/$repo/issues/(new)" \
          --arg title "$title" --arg body "$body" '{
          number:0,id:"(new)",node_id:"(new)",html_url:$url,url:$url,
          title:$title,body:$body,state:"OPEN"}')
      fi
      operation=$(jq -n --arg action create_issue --arg task_id "$task_id" --arg title "$title" \
        --arg body "$body" --arg column "$column" \
        '{action:$action,task_id:$task_id,title:$title,body:$body,column:$column}')
      operations=$(append_operation "$operations" "$operation")
      issue_number=$(printf '%s' "$issue" | jq -er '.number')
      issue_id=$(printf '%s' "$issue" | jq -er '.node_id // .id')
      issue_url=$(printf '%s' "$issue" | jq -er '.html_url // .url')
      item_id=
      operation=$(jq -n --arg action add_item --arg task_id "$task_id" --arg issue_url "$issue_url" \
        '{action:$action,task_id:$task_id,issue_url:$issue_url}')
      operations=$(append_operation "$operations" "$operation")
      if [ "$dry_run" = 0 ]; then
        add_result=$(project_add_item "$repo" "$project_id" "$issue_id") || die "cannot add issue to project"
        item_id=$(printf '%s' "$add_result" | jq -er '.data.addProjectV2ItemById.item.id') \
          || die "GitHub project add returned invalid data"
      fi
      updated_state=$(record_mapping "$updated_state" "$task_id" "$repo" "$issue" "$item_id")
      if [ "$dry_run" = 0 ]; then
        write_json_atomic "$STATE_FILE" "$updated_state"
      fi
      live=$(jq -n --arg id "$item_id" --argjson issue "$issue" '{
        id:$id,
        isArchived:false,
        fieldValueByName:null,
        content:{
          title:$issue.title,
          body:$issue.body,
          state:$issue.state,
          url:($issue.html_url // $issue.url)
        }
      }')
      mapping=$(printf '%s' "$updated_state" | jq -c --arg id "$task_id" '.tasks[$id]')
    fi

    issue_number=$(printf '%s' "$mapping" | jq -er '.issue_number')
    item_id=$(printf '%s' "$mapping" | jq -er '.item_id')
    mapped_repo=$(printf '%s' "$mapping" | jq -er '.repo')
    if [ "$live" != null ]; then
      live_item_id=$(printf '%s' "$live" | jq -r '.id // empty')
      if [ -n "$live_item_id" ] && [ "$live_item_id" != "$item_id" ]; then
        item_id=$live_item_id
        updated_state=$(printf '%s' "$updated_state" | jq --arg id "$task_id" --arg item_id "$item_id" \
          '.tasks[$id].item_id = $item_id')
        if [ "$dry_run" = 0 ]; then
          write_json_atomic "$STATE_FILE" "$updated_state"
        fi
      fi
    fi
    if [ "$live" = null ]; then
      issue_id=$(printf '%s' "$mapping" | jq -er '.issue_id')
      if [ "$dry_run" = 0 ]; then
        add_result=$(project_add_item "$mapped_repo" "$project_id" "$issue_id") || die "cannot restore project item"
        item_id=$(printf '%s' "$add_result" | jq -er '.data.addProjectV2ItemById.item.id') \
          || die "GitHub project add returned invalid data"
        updated_state=$(printf '%s' "$updated_state" | jq --arg id "$task_id" --arg item_id "$item_id" \
          '.tasks[$id].item_id = $item_id')
        write_json_atomic "$STATE_FILE" "$updated_state"
      fi
      operation=$(jq -n --arg action add_item --arg task_id "$task_id" \
        '{action:$action,task_id:$task_id}')
      operations=$(append_operation "$operations" "$operation")
      theirs=
      issue_state=OPEN
    else
      theirs=$(printf '%s' "$live" | jq -r '.fieldValueByName.name // empty')
      issue_state=$(printf '%s' "$live" | jq -r '(.content.state // "") | ascii_upcase')
      if [ "$(printf '%s' "$live" | jq -r '.content.title // empty')" != "$title" ] ||
        [ "$(printf '%s' "$live" | jq -r '.content.body // empty')" != "$body" ]; then
        if [ "$dry_run" = 0 ]; then
          issue_update "$mapped_repo" "$issue_number" "$title" "$body" >/dev/null \
            || die "cannot update board issue"
        fi
        operation=$(jq -n --arg action update_issue --arg task_id "$task_id" \
          '{action:$action,task_id:$task_id}')
        operations=$(append_operation "$operations" "$operation")
      fi
    fi
    if [ "$theirs" != "$column" ]; then
      if [ "$dry_run" = 0 ]; then
        project_set_column "$mapped_repo" "$project_id" "$item_id" "$field_id" "$option_id" >/dev/null \
          || die "cannot set project Status"
      fi
      operation=$(jq -n --arg action set_column --arg task_id "$task_id" --arg column "$column" \
        --arg explanation "$title set to $column to match fleet state." \
        '{action:$action,task_id:$task_id,column:$column,explanation:$explanation}')
      operations=$(append_operation "$operations" "$operation")
    fi
    if [ "$column" = Done ] && [ "$issue_state" = OPEN ]; then
      if [ "$dry_run" = 0 ]; then
        issue_close "$mapped_repo" "$issue_number" >/dev/null || die "cannot close completed board issue"
      fi
      operation=$(jq -n --arg action close_issue --arg task_id "$task_id" \
        '{action:$action,task_id:$task_id}')
      operations=$(append_operation "$operations" "$operation")
    fi
  done < <(printf '%s' "$desired" | jq -c '.[] | select(.excluded == false)')

  if [ "$dry_run" = 0 ]; then
    post_board=$(read_board "$owner" "$number")
    validate_columns "$post_board"
    updated_state=$(printf '%s' "$updated_state" | jq \
      --argjson project "$(printf '%s' "$post_board" | jq '.project')" --arg now "$NOW" '
      .project = $project | .synced_at = $now')
    write_json_atomic "$STATE_FILE" "$updated_state"
    post_notes=$(board_notes "$updated_state" "$post_board" "$desired")
    residual=$(printf '%s\n' "$post_notes" "$escalations" | jq -n '
      [inputs] as [$post, $reported]
      | [ $post[] | select(. as $note | $reported | index($note) != null) ]') \
      || die "cannot reconcile poll signature against reported notes"
    store_seen_signature "$residual"
  fi

  printf '%s\n' "$(printf '%s' "$board" | jq '.project')" "$operations" "$escalations" "$excluded" \
    | jq -n --argjson dry_run "$([ "$dry_run" = 1 ] && printf true || printf false)" \
    --arg repo "$repo" \
    '[inputs] as [$project, $operations, $escalations, $excluded]
    | {
      schema:"fm-board-sync-plan.v1",
      dry_run:$dry_run,
      repository:$repo,
      repository_private:true,
      project:$project,
      operations:$operations,
      escalations:$escalations,
      excluded:$excluded
    }'
}

poll() {
  local config exclusions state owner number board snapshot metadata desired
  local notes signature previous count
  [ "$#" -eq 0 ] || { usage; exit 2; }
  need jq
  need gh
  config=$(load_config)
  exclusions=$(load_exclusions)
  state=$(ensure_state)
  owner=$(printf '%s' "$config" | jq -er '.owner')
  number=$(printf '%s' "$config" | jq -er '.project_number')
  board=$(read_board "$owner" "$number")
  validate_columns "$board"
  snapshot=$(bearings_snapshot) || die "cannot read bearings snapshot"
  metadata=$(fleet_metadata_snapshot) || die "cannot read fleet metadata snapshot"
  desired=$(desired_items "$snapshot" "$metadata" "$(label_salt)" "$exclusions")
  notes=$(board_notes "$state" "$board" "$desired")
  count=$(printf '%s' "$notes" | jq 'length')
  if [ "$count" -eq 0 ]; then
    rm -f -- "$SEEN_FILE"
    exit 0
  fi
  signature=$(seen_signature "$notes")
  previous=$(sed -n '1p' "$SEEN_FILE" 2>/dev/null || true)
  [ "$signature" != "$previous" ] || exit 0
  store_seen_signature "$notes"
  printf 'board-sync %s board change(s) pending\n' "$count"
}

arm() {
  local config state tmp
  [ "$#" -eq 0 ] || { usage; exit 2; }
  need jq
  config=$(load_config)
  load_exclusions >/dev/null
  state=$(ensure_state)
  : "$config" "$state"
  private_dir "$STATE_DIR"
  [ ! -L "$CHECK_FILE" ] || die "custom check path must not be a symlink"
  umask 077
  tmp=$(mktemp "$STATE_DIR/.fm-board-watch.XXXXXX") || die "cannot create board check"
  {
    printf '#!/bin/sh\n'
    printf 'FM_HOME=%s exec %s poll\n' "$(printf '%q' "$FM_HOME")" "$(printf '%q' "$SCRIPT_DIR/fm-board-sync.sh")"
  } > "$tmp" || { rm -f -- "$tmp"; die "cannot write board check"; }
  chmod 0700 "$tmp" || { rm -f -- "$tmp"; die "cannot protect board check"; }
  mv -f -- "$tmp" "$CHECK_FILE" || { rm -f -- "$tmp"; die "cannot install board check"; }
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE_DIR" \
    "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID"; then
    rm -f -- "$CHECK_FILE"
    die "cannot bind state/$CHECK_ID.check.sh; removed the unauthenticated check"
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

disarm() {
  [ "$#" -eq 0 ] || { usage; exit 2; }
  [ ! -L "$CHECK_FILE" ] || die "custom check path must not be a symlink"
  [ ! -L "$TRUST_FILE" ] || die "custom check trust path must not be a symlink"
  rm -f -- "$CHECK_FILE" "$TRUST_FILE" "$SEEN_FILE"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

status_cmd() {
  local config state armed=false
  [ "$#" -eq 0 ] || { usage; exit 2; }
  need jq
  config=$(load_config)
  state=$(ensure_state)
  # shellcheck source=bin/fm-pr-lib.sh
  . "$SCRIPT_DIR/fm-pr-lib.sh"
  # shellcheck source=bin/fm-check-lib.sh
  . "$SCRIPT_DIR/fm-check-lib.sh"
  if fm_custom_check_registered "$STATE_DIR" "$CHECK_ID"; then
    armed=true
  fi
  printf '%s\n' "$config" "$state" | jq -n --argjson armed "$armed" '
    [inputs] as [$config, $state]
    | {
    schema:"fm-board-sync-status.v1",
    configured:true,
    armed:$armed,
    config:$config,
    synced_at:$state.synced_at,
    mapped_tasks:($state.tasks | length)
  }'
}

command=${1:-}
[ "$#" -gt 0 ] && shift
case "$command" in
  reconcile) reconcile "$@" ;;
  poll) poll "$@" ;;
  arm) arm "$@" ;;
  disarm) disarm "$@" ;;
  status) status_cmd "$@" ;;
  -h|--help) usage ;;
  *) usage; exit 2 ;;
esac
