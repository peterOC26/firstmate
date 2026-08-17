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
# `reconcile` reads every fleet column from fm-bearings-snapshot.sh and mirrors
# those columns to real issues in the configured private board repository.
# It uses state/board-sync.json as the task mapping and last-agreed baseline.
# This script never writes fleet state, dispatches work, closes backlog items,
# merges, or tears down.
#
# A board card with no mapping is left untouched and reported once as a
# captain-intent request.  Every fleet task has a separate Firstmate-managed
# canonical issue and card.  Token recovery rebinds only an issue whose title
# and body exactly match the Firstmate-generated allowlisted shape.
#
# Every other board-side change becomes exactly one line in `escalations`,
# emitted by the same run that observed it and whether or not that run also set
# the card back to the fleet column; every run reports only what it sees.
# A cleared Status, a card removed from the board, an issue the captain closed,
# a column move, and a card with no agreed baseline each produce exactly one such
# line.  An archived card produces one archive line for the complete observation,
# with simultaneous column and issue-state details folded into that line.
#
# A mapping is retired once the sync no longer owns the task, meaning the task is
# excluded or gone from the fleet, and no live card is left for it.  Retirement
# only forgets the local mapping; no card is ever deleted, archived, or
# unarchived.  A card the captain archives under a task the fleet still owns keeps
# its mapping, and the observed archived state is recorded independently of its
# fleet column, so it reports once and stays quiet until it changes again.
#
# Writes always target the board item the run actually resolved, and the resolved
# item id is persisted as soon as it differs from the recorded one, so a card the
# captain removes and re-adds by hand cannot wedge later runs against a stale id.
#
# Fleet state wins the card.  A run that overrides a column the captain changed
# says so, while an ordinary forward write to a card still holding the last
# agreed column is not a snapback and is not described as one.
#
# `poll` performs one paginated Projects v2 read, compares it with the baseline,
# and prints only `board-sync N board change(s) pending` when a new change
# signature appears.  That signature is derived from item identity, column, and
# issue state only, never from a GitHub timestamp, so a bare touch stays quiet.
#
# `arm` creates state/board-watch.check.sh as a byte-static custom watcher check,
# initializes state/board-sync.json when absent, and binds the check with
# fm-check-register.sh.  The existing watcher sweep remains the only poller.
# `disarm` removes only that check and its trust binding.
#
# config/board-sync.json is exactly:
#   {"owner":"LOGIN","project_number":1,"repo":"OWNER/REPO"}
# config/board-exclude is one task id per line with blank lines and `#` comments
# ignored.  That captain-owned local file is the only source of excluded ids;
# reconcile refuses every GitHub call unless it is a readable regular file that
# yields at least one id.  An excluded task that still holds a live card is
# escalated, because this script never deletes or archives a card.
#
# GitHub writes fail closed unless the configured repository is confirmed
# private immediately before each GitHub mutation.  Issue bodies are built from an
# allowlist only: optional project/kind labels, an HTTPS PR URL, and the opaque
# correlation token.  Issue titles come only from the structured backlog title,
# falling back to the opaque token, never to a runtime summary.  Free-form
# detail, holds, paths, runtime metadata, and task ids never enter a GitHub
# title/body mutation.
# The token salt is a stable hash of the effective home and exact board config,
# so losing volatile state in the same home still permits token-based recovery.
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
CHECK_ID='board-watch'
CHECK_FILE="$STATE_DIR/$CHECK_ID.check.sh"
TRUST_FILE="$STATE_DIR/$CHECK_ID.check-trust"
BEARINGS="${FM_BOARD_BEARINGS:-$SCRIPT_DIR/fm-bearings-snapshot.sh}"
FLEET_SNAPSHOT="${FM_BOARD_FLEET_SNAPSHOT:-$SCRIPT_DIR/fm-fleet-snapshot.sh}"
BEARINGS_HOME="${FM_BOARD_BEARINGS_HOME:-$FM_HOME}"
NOW="${FM_BOARD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

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

new_salt() {
  local config seed
  config=$(jq -cS . "$CONFIG_FILE") || die "cannot derive board token salt"
  seed="fm-board-sync.v1:$FM_HOME:$config"
  sha256_text "$seed" | cut -c1-32
}

empty_state() {
  local salt=$1
  jq -n --arg salt "$salt" '{
    schema:"fm-board-sync.v1",
    salt:$salt,
    project:{},
    synced_at:null,
    tasks:{},
    unmapped_items:{},
    pending:[],
    excluded_reported:[]
  }'
}

ensure_state() {
  local state
  private_dir "$STATE_DIR"
  if [ ! -e "$STATE_FILE" ]; then
    state=$(empty_state "$(new_salt)")
    write_json_atomic "$STATE_FILE" "$state"
  fi
  [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] || die "state file is unavailable"
  state=$(jq -c . "$STATE_FILE") || die "invalid state/board-sync.json"
  printf '%s' "$state" | jq -e '
    type == "object"
    and .schema == "fm-board-sync.v1"
    and (.salt | type == "string" and test("^[0-9a-f]{32}$"))
    and (.project | type == "object")
    and (.tasks | type == "object")
    and (.unmapped_items | type == "object")
    and (.pending | type == "array")
    and (.excluded_reported | type == "array")
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

board_lock_acquire() {
  local tries=0 owner_pid owner_identity current_identity lock_pid lock_identity
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 20 ]; then
      owner_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
      owner_identity=$(cat "$LOCK_DIR/pid-identity" 2>/dev/null || true)
      case "$owner_pid" in
        ''|*[!0-9]*)
          die "another fm-board-sync reconcile holds $LOCK_DIR with unverifiable ownership"
          ;;
      esac
      [ -n "$owner_identity" ] \
        || die "another fm-board-sync reconcile holds $LOCK_DIR with unverifiable ownership"
      if fm_pid_alive "$owner_pid"; then
        current_identity=$(fm_pid_identity "$owner_pid" 2>/dev/null) \
          || die "another fm-board-sync reconcile holds $LOCK_DIR with unverifiable ownership"
        [ "$current_identity" != "$owner_identity" ] \
          || die "another fm-board-sync reconcile holds $LOCK_DIR; retry once it finishes"
      fi
      rm -f -- "$LOCK_DIR/pid" "$LOCK_DIR/pid-identity"
      rmdir "$LOCK_DIR" 2>/dev/null || true
      tries=0
      continue
    fi
    sleep 0.05
  done
  lock_pid=$(fm_current_pid)
  lock_identity=$(fm_pid_identity "$lock_pid" 2>/dev/null) \
    || { rmdir "$LOCK_DIR" 2>/dev/null || true; die "cannot identify reconcile lock owner"; }
  if ! printf '%s\n' "$lock_pid" > "$LOCK_DIR/pid" \
    || ! printf '%s\n' "$lock_identity" > "$LOCK_DIR/pid-identity"; then
    rm -f -- "$LOCK_DIR/pid" "$LOCK_DIR/pid-identity"
    rmdir "$LOCK_DIR" 2>/dev/null || true
    die "cannot record reconcile lock owner"
  fi
}

board_lock_release() {
  local owner_pid owner_identity current_pid current_identity
  owner_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  owner_identity=$(cat "$LOCK_DIR/pid-identity" 2>/dev/null || true)
  current_pid=$(fm_current_pid)
  current_identity=$(fm_pid_identity "$current_pid" 2>/dev/null || true)
  [ "$owner_pid" = "$current_pid" ] && [ -n "$current_identity" ] \
    && [ "$owner_identity" = "$current_identity" ] || return 0
  rm -f -- "$LOCK_DIR/pid" "$LOCK_DIR/pid-identity"
  rmdir "$LOCK_DIR" 2>/dev/null || true
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
    pages=$(jq -n --argjson old "$pages" --argjson new "$page_items" '$old + $new')
    [ "$(printf '%s' "$page" | jq -r '.data.user.projectV2.items.pageInfo.hasNextPage')" = true ] || break
    cursor=$(printf '%s' "$page" | jq -er '.data.user.projectV2.items.pageInfo.endCursor // empty') \
      || die "GitHub project pagination cursor is unavailable"
  done
  jq -n --argjson project "$project" --argjson items "$pages" '{project:$project,items:$items}'
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
  local snapshot=$1 metadata=$2 salt=$3 exclusions=$4 base task_id token item
  base=$(jq -n --argjson root "$snapshot" --argjson metadata "$metadata" '
    def valid_pr_url:
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
    token=$(sha256_text "$task_id$salt" | cut -c1-8)
    item=$(printf '%s' "$item" | jq --arg token "$token" --argjson exclusions "$exclusions" '
      . as $item
      | $item + {
        token:$token,
        excluded:($exclusions | index($item.id) != null)
      }
      | .title = (if (.title | type) == "string" and (.title | length) > 0
                  then .title
                  else "Fleet task " + .token end)
      | .body = ([
          (if .project then "project: " + .project else empty end),
          (if .kind then "kind: " + .kind else empty end),
          (if .pr_url then "PR: " + .pr_url else empty end),
          "<!-- fm-task: " + .token + " -->"
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

find_issue_by_token() {
  local repo=$1 token=$2 title=$3 body=$4 result
  result=$(gh api --method GET "search/issues" -f q="repo:$repo $token in:body" -f per_page=2) \
    || die "cannot search board issue tokens"
  printf '%s' "$result" | jq --arg repo "$repo" --arg title "$title" --arg body "$body" '
    [.items[]
     | select(.repository_url | endswith("/repos/" + $repo))
     | select(.title == $title and (.body // "") == $body)]
    | if length > 1 then error("duplicate correlation token") else .[0] // null end
  ' || die "duplicate or invalid board issue token result"
}

resolve_pending_issue() {
  local repo=$1 token=$2 title=$3 body=$4 result
  result=$(gh api --method GET "repos/$repo/issues" -f state=all -f per_page=100 \
    -f sort=created -f direction=desc) || die "cannot list board issues for pending recovery"
  printf '%s' "$result" | jq --arg token "$token" --arg title "$title" --arg body "$body" '
    [.[]
     | select(((.body // "") | contains("<!-- fm-task: " + $token + " -->")))
     | select(.title == $title and (.body // "") == $body)]
    | if length > 1 then error("duplicate correlation token") else .[0] // null end
  ' || die "duplicate or invalid pending board issue result"
}

board_changes() {
  local state=$1 board=$2
  jq -n --argjson state "$state" --argjson board "$board" '
    ([ $state.tasks | to_entries[] as $mapped
       | ([$board.items[] | select(.id == $mapped.value.item_id)][0] // null) as $item
       | (if $item == null then {column:null,issue_state:null,archived:false}
          else {column:($item.fieldValueByName.name // null),
                issue_state:($item.content.state // null),
                archived:($item.isArchived == true)} end) as $observed
       | select($observed.column != ($mapped.value.baseline.column // null) or
                $observed.issue_state != ($mapped.value.baseline.issue_state // null) or
                $observed.archived != ($mapped.value.baseline.archived // false))
       | {type:"mapped_change",task_id:$mapped.key,item_id:$mapped.value.item_id,
          column:$observed.column,
          issue_state:$observed.issue_state,
          archived:$observed.archived} ]
     +
     [ $board.items[] as $live
       | $live
       | select(.isArchived == false)
       | select(([ $state.tasks[].item_id ] | index($live.id)) == null)
       | (($state.unmapped_items // {})[$live.id] // null) as $baseline
       | select($baseline == null or
                (($live.fieldValueByName.name // null) != ($baseline.baseline_column // null)) or
                (($live.content.state // null) != ($baseline.baseline_issue_state // null)))
       | {type:"unmapped_item",item_id:.id,
          column:(.fieldValueByName.name // null),
          issue_state:(.content.state // null)} ])
    | unique_by([.type,.item_id])
  '
}

seen_signature() {
  local changes=$1
  sha256_text "$(printf '%s' "$changes" | jq -cS '.')"
}

store_seen_signature() {
  local changes=$1 count signature
  count=$(printf '%s' "$changes" | jq 'length')
  if [ "$count" -eq 0 ]; then
    rm -f -- "$SEEN_FILE"
    return 0
  fi
  signature=$(seen_signature "$changes")
  private_dir "$STATE_DIR"
  [ ! -L "$SEEN_FILE" ] || die "$SEEN_FILE must not be a symlink"
  umask 077
  printf '%s\n' "$signature" > "$SEEN_FILE" || die "cannot write poll signature"
  chmod 0600 "$SEEN_FILE" || die "cannot protect poll signature"
}

append_operation() {
  local operations=$1 operation=$2
  jq -n --argjson operations "$operations" --argjson operation "$operation" '$operations + [$operation]'
}

append_claim() {
  local claimed=$1 item_id=$2
  jq -n --argjson claimed "$claimed" --arg item_id "$item_id" '($claimed + [$item_id]) | unique'
}

append_escalation() {
  local escalations=$1 line=$2
  jq -n --argjson escalations "$escalations" --arg line "$line" '
    ($escalations + [$line])
    | reduce .[] as $one ([]; if any(. == $one) then . else . + [$one] end)
  '
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
  # shellcheck disable=SC2016
  github_mutation_guard "$repo"
  gh api graphql -f query='mutation($project:ID!,$content:ID!){addProjectV2ItemById(input:{projectId:$project,contentId:$content}){item{id}}}' \
    -F project="$project_id" -F content="$issue_id"
}

project_set_column() {
  local repo=$1 project_id=$2 item_id=$3 field_id=$4 option_id=$5
  # shellcheck disable=SC2016
  github_mutation_guard "$repo"
  gh api graphql -f query='mutation($project:ID!,$item:ID!,$field:ID!,$option:String!){updateProjectV2ItemFieldValue(input:{projectId:$project,itemId:$item,fieldId:$field,value:{singleSelectOptionId:$option}}){projectV2Item{id}}}' \
    -F project="$project_id" -F item="$item_id" -F field="$field_id" -f option="$option_id"
}

record_mapping() {
  local state=$1 task_id=$2 token=$3 repo=$4 issue=$5 item_id=$6
  printf '%s' "$state" | jq \
    --arg task_id "$task_id" --arg token "$token" --arg repo "$repo" \
    --arg item_id "$item_id" --argjson issue "$issue" '
    .tasks[$task_id] = ((.tasks[$task_id] // {}) + {
      token:$token,
      repo:$repo,
      issue_number:$issue.number,
      issue_id:($issue.node_id // $issue.id),
      issue_url:($issue.html_url // $issue.url),
      item_id:$item_id,
      baseline:(.tasks[$task_id].baseline // null)
    })
    | .pending = [.pending[] | select(.task_id != $task_id)]
  '
}

reconcile() {
  local dry_run=0 config exclusions state owner number repo board snapshot metadata desired
  local project_id field_id options operations='[]' escalations='[]' excluded='[]'
  local item task_id title column body token mapping live base theirs issue_state
  local board_moved unrecorded_baseline write_column snapback explanation line card_absent
  local claimed='[]' live_item_id archived_reported baseline_matches title_one_line
  local issue issue_number issue_id issue_url item_id option_id operation
  local created add_result post_board updated_state residual reported closed='[]'
  if [ "${1:-}" = --dry-run ]; then
    dry_run=1
    shift
  fi
  [ "$#" -eq 0 ] || { usage; exit 2; }
  need jq
  need gh
  config=$(load_config)
  exclusions=$(load_exclusions)
  private_dir "$STATE_DIR"
  board_lock_acquire
  trap board_lock_release EXIT
  state=$(ensure_state)
  state=$(printf '%s' "$state" | jq '
    .tasks |= with_entries(
      select((.value.origin // "firstmate") != "captain")
      | .value |= del(.origin))')
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
  desired=$(desired_items "$snapshot" "$metadata" "$(printf '%s' "$state" | jq -er '.salt')" "$exclusions")
  updated_state=$state

  while IFS= read -r item; do
    task_id=$(printf '%s' "$item" | jq -er '.id')
    if [ "$(printf '%s' "$item" | jq -r '.excluded')" = true ]; then
      excluded=$(jq -n --argjson old "$excluded" --arg id "$task_id" '$old + [$id]')
      mapping=$(printf '%s' "$updated_state" | jq -c --arg id "$task_id" '.tasks[$id] // null')
      if [ "$mapping" != null ]; then
        item_id=$(printf '%s' "$mapping" | jq -r '.item_id // empty')
        issue_number=$(printf '%s' "$mapping" | jq -r '.issue_number // empty')
        live=$(find_live_item "$board" "$item_id" "$issue_number" "$repo")
        if [ "$live" != null ] && [ "$(printf '%s' "$live" | jq -r '.isArchived')" != true ]; then
          claimed=$(append_claim "$claimed" "$(printf '%s' "$live" | jq -r '.id')")
          escalations=$(append_escalation "$escalations" \
            "task $task_id: excluded from the board but still holds a live card at $(printf '%s' "$mapping" | jq -r '.issue_url // "an unknown url"'); retracting it stays a manual captain action.")
        fi
      fi
      continue
    fi
    title=$(printf '%s' "$item" | jq -er '.title')
    column=$(printf '%s' "$item" | jq -er '.column')
    body=$(printf '%s' "$item" | jq -er '.body')
    token=$(printf '%s' "$item" | jq -er '.token')
    option_id=$(printf '%s' "$options" | jq -er --arg column "$column" '.[$column]') \
      || die "missing GitHub Status option: $column"
    mapping=$(printf '%s' "$updated_state" | jq -c --arg id "$task_id" '.tasks[$id] // null')
    item_id=$(printf '%s' "$mapping" | jq -r '.item_id // empty')
    issue_number=$(printf '%s' "$mapping" | jq -r '.issue_number // empty')
    live=$(find_live_item "$board" "$item_id" "$issue_number" "$repo")
    if [ "$live" != null ] && [ "$(printf '%s' "$live" | jq -r '.isArchived')" = true ]; then
      archived_reported=$(printf '%s' "$mapping" | jq -r '.baseline.archived // false')
      baseline_matches=$(jq -n --argjson mapping "$mapping" --argjson live "$live" '
        ($mapping.baseline.archived == true)
        and (($mapping.baseline.column // null) == ($live.fieldValueByName.name // null))
        and (($mapping.baseline.issue_state // null) == ($live.content.state // null))')
      if [ "$archived_reported" != true ] || [ "$baseline_matches" != true ]; then
        escalations=$(append_escalation "$escalations" \
          "task $task_id: the board card is archived so the fleet has no visible card, and the fleet says $column; restoring or retiring it stays a manual captain action.")
      fi
      continue
    fi

    if [ "$mapping" = null ]; then
      issue=$(find_issue_by_token "$repo" "$token" "$title" "$body")
      if [ "$issue" = null ] && printf '%s' "$updated_state" | jq -e \
        --arg id "$task_id" --arg token "$token" \
        '.pending | any(.task_id == $id and .token == $token)' >/dev/null; then
        issue=$(resolve_pending_issue "$repo" "$token" "$title" "$body")
      fi
      if [ "$issue" = null ]; then
        operation=$(jq -n --arg action create_issue --arg task_id "$task_id" --arg title "$title" \
          --arg body "$body" --arg column "$column" \
          '{action:$action,task_id:$task_id,title:$title,body:$body,column:$column}')
        operations=$(append_operation "$operations" "$operation")
        if [ "$dry_run" = 0 ]; then
          updated_state=$(printf '%s' "$updated_state" | jq --arg id "$task_id" --arg token "$token" \
            '.pending = ([.pending[] | select(.task_id != $id)] + [{task_id:$id,token:$token}])')
          write_json_atomic "$STATE_FILE" "$updated_state"
          created=$(issue_create "$repo" "$title" "$body") || die "cannot create board issue"
          issue=$(printf '%s' "$created" | jq -e '{number,id,node_id,html_url,url,title,body,state}') \
            || die "GitHub issue create returned invalid data"
        else
          issue='null'
        fi
      fi
      if [ "$issue" = null ]; then
        issue=$(jq -n --arg url "https://github.com/$repo/issues/(new)" \
          --arg title "$title" --arg body "$body" '{
          number:0,id:"(new)",node_id:"(new)",html_url:$url,url:$url,
          title:$title,body:$body,state:"OPEN"}')
      fi
      issue_number=$(printf '%s' "$issue" | jq -er '.number')
      issue_id=$(printf '%s' "$issue" | jq -er '.node_id // .id')
      issue_url=$(printf '%s' "$issue" | jq -er '.html_url // .url')
      live=$(printf '%s' "$board" | jq -c --arg url "$issue_url" \
        '[.items[] | select(.content.url == $url)][0] // null')
      item_id=$(printf '%s' "$live" | jq -r '.id // empty')
      if [ -z "$item_id" ]; then
        operation=$(jq -n --arg action add_item --arg task_id "$task_id" --arg issue_url "$issue_url" \
          '{action:$action,task_id:$task_id,issue_url:$issue_url}')
        operations=$(append_operation "$operations" "$operation")
        if [ "$dry_run" = 0 ]; then
          add_result=$(project_add_item "$repo" "$project_id" "$issue_id") || die "cannot add issue to project"
          item_id=$(printf '%s' "$add_result" | jq -er '.data.addProjectV2ItemById.item.id') \
            || die "GitHub project add returned invalid data"
        fi
      fi
      updated_state=$(record_mapping "$updated_state" "$task_id" "$token" "$repo" "$issue" \
        "$item_id")
      if [ "$dry_run" = 0 ]; then
        write_json_atomic "$STATE_FILE" "$updated_state"
      fi
      if [ "$live" = null ]; then
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
      fi
      mapping=$(printf '%s' "$updated_state" | jq -c --arg id "$task_id" '.tasks[$id]')
    fi

    issue_number=$(printf '%s' "$mapping" | jq -er '.issue_number')
    item_id=$(printf '%s' "$mapping" | jq -er '.item_id')
    base=$(printf '%s' "$mapping" | jq -r '.baseline.column // empty')
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
    card_absent=0
    if [ "$live" = null ]; then
      card_absent=1
      issue_id=$(printf '%s' "$mapping" | jq -er '.issue_id')
      if [ "$dry_run" = 0 ]; then
        add_result=$(project_add_item "$repo" "$project_id" "$issue_id") || die "cannot restore project item"
        item_id=$(printf '%s' "$add_result" | jq -er '.data.addProjectV2ItemById.item.id') \
          || die "GitHub project add returned invalid data"
        updated_state=$(printf '%s' "$updated_state" | jq --arg id "$task_id" --arg item_id "$item_id" \
          '.tasks[$id].item_id = $item_id')
        write_json_atomic "$STATE_FILE" "$updated_state"
      fi
      operation=$(jq -n --arg action add_item --arg task_id "$task_id" \
        '{action:$action,task_id:$task_id}')
      operations=$(append_operation "$operations" "$operation")
      escalations=$(append_escalation "$escalations" \
        "task $task_id: the card was gone from the board, so it was put back at the fleet column $column.")
      theirs=
      issue_state=OPEN
    else
      theirs=$(printf '%s' "$live" | jq -r '.fieldValueByName.name // empty')
      issue_state=$(printf '%s' "$live" | jq -r '(.content.state // "") | ascii_upcase')
      if [ "$(printf '%s' "$live" | jq -r '.content.title // empty')" != "$title" ] ||
        [ "$(printf '%s' "$live" | jq -r '.content.body // empty')" != "$body" ]; then
        if [ "$dry_run" = 0 ]; then
          issue_update "$repo" "$issue_number" "$title" "$body" >/dev/null \
            || die "cannot update board issue"
        fi
        operation=$(jq -n --arg action update_issue --arg task_id "$task_id" \
          '{action:$action,task_id:$task_id}')
        operations=$(append_operation "$operations" "$operation")
      fi
    fi
    if [ -n "$item_id" ]; then
      claimed=$(append_claim "$claimed" "$item_id")
    fi
    board_moved=0
    unrecorded_baseline=0
    if [ "$card_absent" = 0 ] && [ -n "$base" ] && [ "$theirs" != "$base" ]; then
      board_moved=1
    fi
    if [ "$card_absent" = 0 ] && [ -z "$base" ] && [ -n "$theirs" ] && [ "$theirs" != "$column" ]; then
      unrecorded_baseline=1
    fi
    write_column=0
    if [ -z "$theirs" ]; then
      write_column=1
    elif [ "$theirs" != "$column" ] &&
      ! { [ "$board_moved" = 1 ] && [ "$column" = "$base" ]; }; then
      write_column=1
    fi
    snapback=0
    if [ "$write_column" = 1 ] && [ "$board_moved" = 1 ]; then
      snapback=1
    fi
    if [ "$board_moved" = 1 ]; then
      if [ -z "$theirs" ]; then
        line="task $task_id: the captain cleared the board Status that was $base, so the card was set back to the fleet column $column."
      elif [ "$write_column" = 1 ]; then
        line="task $task_id: the captain moved the card from $base to $theirs while the fleet advanced to $column, so the card was set back to $column."
      else
        line="task $task_id: the captain moved the card from $base to $theirs and the fleet still says $column, so the card was left where the captain put it."
      fi
      escalations=$(append_escalation "$escalations" "$line")
    elif [ "$unrecorded_baseline" = 1 ]; then
      escalations=$(append_escalation "$escalations" \
        "task $task_id: no agreed board column is recorded, so the card at $theirs was set to the fleet column $column without knowing who last moved it.")
    fi
    if [ "$write_column" = 1 ]; then
      if [ "$dry_run" = 0 ]; then
        project_set_column "$repo" "$project_id" "$item_id" "$field_id" "$option_id" >/dev/null \
          || die "cannot set project Status"
      fi
      if [ "$snapback" = 1 ]; then
        explanation="$title moved back to $column because fleet state remains authoritative; this run escalates the board change."
      else
        explanation="$title set to $column to match fleet state."
      fi
      operation=$(jq -n --arg action set_column --arg task_id "$task_id" --arg column "$column" \
        --arg explanation "$explanation" \
        '{action:$action,task_id:$task_id,column:$column,explanation:$explanation}')
      operations=$(append_operation "$operations" "$operation")
    fi
    if [ "$column" = Done ] && [ "$issue_state" = OPEN ]; then
      if [ "$dry_run" = 0 ]; then
        issue_close "$repo" "$issue_number" >/dev/null || die "cannot close completed board issue"
        closed=$(jq -n --argjson closed "$closed" --arg task_id "$task_id" \
          '($closed + [$task_id]) | unique')
      fi
      operation=$(jq -n --arg action close_issue --arg task_id "$task_id" \
        '{action:$action,task_id:$task_id}')
      operations=$(append_operation "$operations" "$operation")
    elif [ "$column" != Done ] && [ "$issue_state" = CLOSED ]; then
      escalations=$(append_escalation "$escalations" \
        "task $task_id: the captain closed the board issue while the fleet says $column, so the fleet was left untouched.")
    fi
  done < <(printf '%s' "$desired" | jq -c '.[]')

  while IFS= read -r live; do
    item_id=$(printf '%s' "$live" | jq -er '.id')
    if ! printf '%s' "$updated_state" | jq -e --arg item_id "$item_id" \
      '.tasks | to_entries | any(.value.item_id == $item_id)' >/dev/null \
      && ! printf '%s' "$claimed" | jq -e --arg item_id "$item_id" \
        'index($item_id) != null' >/dev/null; then
      baseline_matches=$(printf '%s' "$updated_state" | jq -r --arg item_id "$item_id" --argjson live "$live" '
        ((.unmapped_items[$item_id] // null) as $baseline
         | $baseline != null
         and (($baseline.baseline_column // null) == ($live.fieldValueByName.name // null))
         and (($baseline.baseline_issue_state // null) == ($live.content.state // null)))')
      if [ "$baseline_matches" != true ]; then
        title_one_line=$(printf '%s' "$live" | jq -r '(.content.title // "Untitled board item")
          | gsub("[[:space:]]+"; " ")')
        escalations=$(append_escalation "$escalations" \
          "board item $item_id titled '$title_one_line' is not Firstmate-managed; leave it untouched and treat it as a captain-intent request.")
      fi
    fi
  done < <(printf '%s' "$board" | jq -c '.items[] | select(.isArchived == false)')

  if [ "$dry_run" = 0 ]; then
    post_board=$(read_board "$owner" "$number")
    validate_columns "$post_board"
    updated_state=$(printf '%s' "$updated_state" | jq \
      --argjson project "$(printf '%s' "$post_board" | jq '.project')" \
      --argjson desired "$desired" --argjson live "$(printf '%s' "$post_board" | jq '.items')" \
      --argjson reported_items "$(printf '%s' "$board" | jq '.items')" \
      --argjson excluded "$excluded" --argjson closed "$closed" --arg now "$NOW" '
      del(.proposals)
      | .project = $project
      | .synced_at = $now
      | .excluded_reported = ((.excluded_reported + $excluded) | unique)
      | ([$desired[] | select(.excluded == false) | .id]) as $owned_ids
      | .tasks = (.tasks | with_entries(
          . as $entry
          | select(($owned_ids | index($entry.key)) != null
                   or ([$live[]
                        | select(.isArchived == false)
                        | select(.id == $entry.value.item_id
                                 or (.content.number == $entry.value.issue_number
                                     and .content.repository.nameWithOwner == $entry.value.repo))]
                       | length > 0))))
      | ([.tasks[].item_id] | unique) as $task_item_ids
      | reduce ($desired[] | select(.excluded == false)) as $want (.;
          (.tasks[$want.id].item_id // "") as $mapped_id
          | ([$live[] | select(.id == $mapped_id)][0] // null) as $seen
          | ([$reported_items[] | select(.id == $mapped_id)][0] // null) as $reported
          | if $reported and $reported.isArchived == true then
              .tasks[$want.id].baseline = {
                column:($reported.fieldValueByName.name // null),
                option_id:($reported.fieldValueByName.optionId // null),
                issue_state:($reported.content.state // null),
                archived:true
              }
            elif $seen and (($seen.fieldValueByName.name // null) == $want.column) then
              .tasks[$want.id].baseline = {
                column:$want.column,
                option_id:($seen.fieldValueByName.optionId // null),
                issue_state:(if ($closed | index($want.id)) != null then "CLOSED"
                             elif $reported then ($reported.content.state // null)
                             else ($seen.content.state // null) end),
                archived:(if $reported then ($reported.isArchived == true)
                          else ($seen.isArchived == true) end)
              }
            else . end)
      | ([$live[] | select(.isArchived == false) | .id]) as $live_ids
      | .unmapped_items = (reduce ($reported_items[] | select(.isArchived == false)) as $seen ({};
          if (($task_item_ids | index($seen.id)) == null)
            and (($live_ids | index($seen.id)) != null) then
            .[$seen.id] = {
              baseline_column:($seen.fieldValueByName.name // null),
              baseline_issue_state:($seen.content.state // null),
              title:($seen.content.title // "Untitled board item")
            }
          else . end))
    ')
    write_json_atomic "$STATE_FILE" "$updated_state"
    residual=$(board_changes "$updated_state" "$post_board")
    reported=$(board_changes "$state" "$board")
    residual=$(jq -n --argjson residual "$residual" --argjson reported "$reported" '
      [ $residual[]
        | . as $change
        | select(any($reported[];
            .type == $change.type
            and .item_id == $change.item_id
            and ((.column // null) == ($change.column // null))
            and ((.issue_state // null) == ($change.issue_state // null))
            and ((.archived // false) == ($change.archived // false)))) ]
    ') || die "cannot reconcile poll signature against reported changes"
    store_seen_signature "$residual"
  fi

  jq -n --argjson dry_run "$([ "$dry_run" = 1 ] && printf true || printf false)" \
    --arg repo "$repo" --argjson project "$(printf '%s' "$board" | jq '.project')" \
    --argjson operations "$operations" --argjson escalations "$escalations" \
    --argjson excluded "$excluded" '{
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
  local config state owner number board changes signature previous count
  [ "$#" -eq 0 ] || { usage; exit 2; }
  need jq
  need gh
  config=$(load_config)
  state=$(ensure_state)
  owner=$(printf '%s' "$config" | jq -er '.owner')
  number=$(printf '%s' "$config" | jq -er '.project_number')
  board=$(read_board "$owner" "$number")
  validate_columns "$board"
  changes=$(board_changes "$state" "$board")
  count=$(printf '%s' "$changes" | jq 'length')
  if [ "$count" -eq 0 ]; then
    rm -f -- "$SEEN_FILE"
    exit 0
  fi
  signature=$(seen_signature "$changes")
  previous=$(sed -n '1p' "$SEEN_FILE" 2>/dev/null || true)
  [ "$signature" != "$previous" ] || exit 0
  store_seen_signature "$changes"
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
  jq -n --argjson config "$config" --argjson state "$state" --argjson armed "$armed" '{
    schema:"fm-board-sync-status.v1",
    configured:true,
    armed:$armed,
    config:$config,
    synced_at:$state.synced_at,
    mapped_tasks:($state.tasks | length),
    pending_creates:($state.pending | length),
    excluded_reported:($state.excluded_reported | length)
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
