#!/usr/bin/env bash
# Behavioral coverage for the private GitHub Projects fleet-board sync.
set -euo pipefail

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck disable=SC2153
SCRIPT="$ROOT/bin/fm-board-sync.sh"
TESTS_RUN=0
CANONICAL_TITLE='Safe board title'
CANONICAL_BODY=$'project: demo-project\nkind: ship\nPR: https://github.com/acme/app/pull/9'

make_fixture() {
  local root home fakebin
  root=$(fm_test_tmproot fm-board-sync)
  home="$root/home"
  fakebin=$(fm_fakebin "$root")
  mkdir -p "$home/config" "$home/state"
  printf '%s\n' '{"owner":"captain","project_number":1,"repo":"captain/fleet"}' > "$home/config/board-sync.json"
  printf '%s\n' \
    '# captain-owned local exclusions' \
    'excluded-task-alpha' \
    'excluded-task-bravo' \
    'excluded-task-charlie' > "$home/config/board-exclude"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
board_repo=${GH_REPO:-captain/fleet}
{
  printf 'CALL\n'
  for arg in "$@"; do
    printf 'ARG\t%s\n' "$arg"
  done
} >> "$GH_LOG"
if [ "${1:-}" = api ] && [ "${2:-}" = "repos/$board_repo" ]; then
  visibility=${GH_PRIVATE:-true}
  if [ "${GH_PRIVATE_AFTER_FIRST:-}" = false ]; then
    privacy_count=0
    if [ -f "$GH_LOG.privacy-count" ]; then
      read -r privacy_count < "$GH_LOG.privacy-count"
    fi
    privacy_count=$((privacy_count + 1))
    printf '%s\n' "$privacy_count" > "$GH_LOG.privacy-count"
    if [ "$privacy_count" -gt 1 ]; then
      visibility=false
    fi
  fi
  printf '%s\n' "$visibility"
  exit 0
fi
if [ "${1:-}" = api ] && [ "${2:-}" = graphql ]; then
  case "$*" in
    *'query=query('* )
      owner_value=
      owner_typed=0
      previous=
      for arg in "$@"; do
        case "$arg" in
          owner=*)
            if [ "$previous" = -F ] || [ "$previous" = -f ]; then
              owner_value=${arg#owner=}
              if [ "$previous" = -F ]; then
                owner_typed=1
              fi
            fi
            ;;
        esac
        previous=$arg
      done
      case "$owner_value" in
        ''|*[!0-9]*) ;;
        *)
          if [ "$owner_typed" -eq 1 ]; then
            printf '%s\n' 'Variable $owner of type String! was provided invalid value' >&2
            exit 1
          fi
          ;;
      esac
      if [ -n "${BOARD_FIXTURE_AFTER:-}" ] && [ -f "$GH_LOG.board-read" ]; then
        cat "$BOARD_FIXTURE_AFTER"
      else
        : > "$GH_LOG.board-read"
        cat "$BOARD_FIXTURE"
      fi
      ;;
    *addProjectV2ItemById* ) printf '%s\n' '{"data":{"addProjectV2ItemById":{"item":{"id":"PVTI_NEW"}}}}' ;;
    *updateProjectV2ItemFieldValue* )
      raw_option=0
      previous=
      for arg in "$@"; do
        if [ "$previous" = -f ]; then
          case "$arg" in option=*) raw_option=1 ;; esac
        fi
        previous=$arg
      done
      [ "$raw_option" -eq 1 ] || { printf '%s\n' 'numeric-looking option was not sent as a GraphQL string' >&2; exit 1; }
      printf '%s\n' '{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"PVTI_NEW"}}}}'
      ;;
    * ) printf '%s\n' '{"data":{}}' ;;
  esac
  exit 0
fi
if [ "${1:-}" = api ] && [ "${2:-}" = --method ] && [ "${3:-}" = POST ]; then
  title= body=
  for arg in "$@"; do
    case "$arg" in
      title=*) title=${arg#title=} ;;
      body=*) body=${arg#body=} ;;
    esac
  done
  jq -n --arg title "$title" --arg body "$body" '{
    number:101,
    id:101,
    node_id:"I_NEW",
    html_url:"https://github.com/captain/fleet/issues/101",
    url:"https://api.github.com/repos/captain/fleet/issues/101",
    title:$title,
    body:$body,
    state:"OPEN"
  }'
  exit 0
fi
if [ "${1:-}" = api ] && [ "${2:-}" = --method ] && [ "${3:-}" = PATCH ]; then
  printf '%s\n' '{}'
  exit 0
fi
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
SH
  chmod +x "$fakebin/gh"
  cat > "$root/bearings" <<'SH'
#!/usr/bin/env bash
if [ -n "${BEARINGS_BLOCK_READY:-}" ]; then
  : > "$BEARINGS_BLOCK_READY"
  while [ ! -e "$BEARINGS_BLOCK_RELEASE" ]; do
    sleep 0.05
  done
fi
cat "$BEARINGS_FIXTURE"
SH
  chmod +x "$root/bearings"
  cat > "$root/fleet-snapshot" <<'SH'
#!/usr/bin/env bash
cat "$FLEET_FIXTURE"
SH
  chmod +x "$root/fleet-snapshot"
  : > "$root/gh.log"
  printf '%s\t%s\t%s\t%s\n' "$root" "$home" "$fakebin" "$root/bearings"
}

write_board() {
  local path=$1 items=$2
  jq -n --argjson items "$items" '{
    data:{user:{projectV2:{
      id:"PVT_PROJECT",
      title:"Fleet",
      field:{
        id:"PVTSSF_STATUS",
        options:[
          {id:"ready",name:"Ready"},
          {id:"held",name:"Held"},
          {id:"blocked",name:"Blocked"},
          {id:"underway",name:"Under way"},
          {id:"waiting",name:"Waiting on you"},
          {id:"98236657",name:"Done"}
        ]
      },
      items:{nodes:$items,pageInfo:{hasNextPage:false,endCursor:null}}
    }}}}
  ' > "$path"
}

# One canonical Firstmate-managed card for safe-task-internal-id.
# Usage: owned_card <item-id> <column|""> [issue-state] [archived] [updated-at] [repo]
owned_card() {
  local item_id=$1 column=$2 issue_state=${3:-OPEN} archived=${4:-false}
  local updated=${5:-2026-08-16T10:00:00Z} repo=${6:-captain/fleet}
  jq -n --arg id "$item_id" --arg column "$column" --arg state "$issue_state" \
    --argjson archived "$archived" --arg updated "$updated" --arg repo "$repo" \
    --arg title "$CANONICAL_TITLE" --arg body "$CANONICAL_BODY" '{
    id:$id,type:"ISSUE",isArchived:$archived,updatedAt:$updated,
    fieldValueByName:(if $column == "" then null
      else {name:$column,optionId:"opt",updatedAt:$updated} end),
    content:{__typename:"Issue",id:"I_ONE",number:1,title:$title,body:$body,state:$state,
      url:("https://github.com/" + $repo + "/issues/1"),updatedAt:$updated,
      repository:{nameWithOwner:$repo,isPrivate:true}}
  }'
}

# A card the sync does not manage.
# Usage: foreign_card <item-id> <column> [title] [issue-number] [updated-at]
foreign_card() {
  local item_id=$1 column=$2 title=${3:-Hand added card} number=${4:-9}
  local updated=${5:-2026-08-16T10:00:00Z}
  jq -n --arg id "$item_id" --arg column "$column" --arg title "$title" \
    --argjson number "$number" --arg updated "$updated" '{
    id:$id,type:"ISSUE",isArchived:false,updatedAt:$updated,
    fieldValueByName:{name:$column,optionId:"opt",updatedAt:$updated},
    content:{__typename:"Issue",id:("I_" + $id),number:$number,title:$title,
      body:"added on the board",state:"OPEN",
      url:("https://github.com/captain/fleet/issues/" + ($number | tostring)),updatedAt:$updated,
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }'
}

# Usage: write_state <path> <tasks-object>
write_state() {
  local path=$1 tasks=$2
  jq -n --argjson tasks "$tasks" '{
    schema:"fm-board-sync.v1",project:{},synced_at:null,tasks:$tasks
  }' > "$path"
}

# Usage: mapping <item-id> [task-id] [issue-number] [repo]
mapping() {
  local item_id=$1 task_id=${2:-safe-task-internal-id} number=${3:-1} repo=${4:-captain/fleet}
  jq -n --arg item "$item_id" --arg task "$task_id" --argjson number "$number" --arg repo "$repo" '{
    ($task):{repo:$repo,issue_number:$number,issue_id:"I_ONE",
      issue_url:("https://github.com/" + $repo + "/issues/" + ($number | tostring)),
      item_id:$item}
  }'
}

write_bearings() {
  local path=$1 column=${2:-Ready}
  jq -n --arg column "$column" '{
    schema:"fm-bearings.v1",
    board_columns:[
      {column:"Ready",empty:"-"},
      {column:"Held",empty:"-"},
      {column:"Blocked",empty:"-"},
      {column:"Under way",empty:"-"},
      {column:"Waiting on you",empty:"-"},
      {column:"Done",empty:"-"}
    ],
    board_items:[
      {
        column:$column,
        id:"safe-task-internal-id",
        summary:"Safe board title",
        owner:"(main)",
        detail:"SUPERSECRET_HOLD state/private/path owner+demo@example.com/password",
        artifact:"https://github.com/acme/app/pull/9"
      },
      {
        column:"Done",
        id:"safe-task-internal-id",
        summary:"Stale duplicate row must not win",
        owner:"(main)",
        detail:"duplicate secret",
        artifact:"-"
      },
      {
        column:"Ready",
        id:"excluded-task-alpha",
        summary:"CROWN_JEWELS unannounced strategy",
        owner:"(main)",
        detail:"sensitive",
        artifact:"-"
      },
      {
        column:"Under way",
        id:"excluded-task-bravo",
        summary:"LIVE_DATABASE_PERMISSION_SEGFAULT investigation",
        owner:"(main)",
        detail:"vulnerability detail",
        artifact:"-"
      },
      {
        column:"Under way",
        id:"excluded-task-charlie",
        summary:"PRODUCTION_DOS_MITIGATION review",
        owner:"(main)",
        detail:"vulnerability review detail",
        artifact:"-"
      },
      {
        column:"Blocked",
        id:"(main-inventory)",
        summary:"internal inventory warning",
        owner:"(main)",
        detail:"internal",
        artifact:"-"
      }
    ],
    in_flight:[{id:"safe-task-internal-id",kind:"ship",state:"working",doing:"secret"}],
    decisions_open:[],
    recorded_prs:[{id:"safe-task-internal-id",url:"https://github.com/acme/app/pull/9"}],
    reports:[],
    gates:[],
    landed:[]
  }' > "$path"
  jq -n '{
    schema:"fm-fleet.v1",
    backlog:{records:[
      {id:"safe-task-internal-id",title:"Safe board title",repo:"demo-project",kind:"ship"},
      {id:"excluded-task-alpha",title:"CROWN_JEWELS unannounced strategy",repo:"secret-project",kind:"ship"},
      {id:"excluded-task-bravo",title:"LIVE_DATABASE_PERMISSION_SEGFAULT investigation",repo:"secret-project",kind:"scout"},
      {id:"excluded-task-charlie",title:"PRODUCTION_DOS_MITIGATION review",repo:"secret-project",kind:"scout"}
    ]}
  }' > "${path}.fleet"
}

write_bearings_untitled() {
  local path=$1
  jq -n '{
    schema:"fm-bearings.v1",
    board_columns:[
      {column:"Ready",empty:"-"},
      {column:"Held",empty:"-"},
      {column:"Blocked",empty:"-"},
      {column:"Under way",empty:"-"},
      {column:"Waiting on you",empty:"-"},
      {column:"Done",empty:"-"}
    ],
    board_items:[
      {
        column:"Under way",
        id:"unstructured-task-internal-id",
        summary:"RUNTIME_DETAIL_LEAK repairing state/private/path for demo@example.com",
        owner:"(main)",
        detail:"RUNTIME_DETAIL_LEAK repairing state/private/path for demo@example.com",
        artifact:"-"
      }
    ],
    in_flight:[{id:"unstructured-task-internal-id",kind:"ship",state:"working",doing:"RUNTIME_DETAIL_LEAK"}],
    decisions_open:[],
    recorded_prs:[],
    reports:[],
    gates:[],
    landed:[]
  }' > "$path"
  jq -n '{schema:"fm-fleet.v1",backlog:{records:[]}}' > "${path}.fleet"
}

run_sync() {
  local home=$1 fakebin=$2 bearings=$3 board=$4 log=$5
  shift 5
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_BOARD_BEARINGS="$bearings" \
    FM_BOARD_FLEET_SNAPSHOT="${bearings%/bearings}/fleet-snapshot" \
    BOARD_FIXTURE="$board" BEARINGS_FIXTURE="${bearings}.json" \
    FLEET_FIXTURE="${bearings}.json.fleet" GH_LOG="$log" \
    GH_REPO="${GH_REPO:-captain/fleet}" \
    BOARD_FIXTURE_AFTER="${BOARD_FIXTURE_AFTER:-}" "$SCRIPT" "$@"
}

test_arm_status_and_disarm() {
  local fixture root home fakebin bearings output
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  output=$(FM_HOME="$home" "$SCRIPT" arm)
  assert_contains "$output" 'armed: state/board-watch.check.sh' "arm should register the existing custom-check path"
  [ "$(stat -f %Lp "$home/state/board-watch.check.sh" 2>/dev/null || stat -c %a "$home/state/board-watch.check.sh")" = 700 ] \
    || fail "armed check must be mode 0700"
  jq -e '.schema == "fm-board-sync.v1" and (.tasks | length) == 0' "$home/state/board-sync.json" >/dev/null \
    || fail "arm should initialize protected mapping state"
  FM_HOME="$home" "$SCRIPT" status | jq -e '.armed == true and .mapped_tasks == 0' >/dev/null \
    || fail "status should report the armed mapping state"
  printf '\n' >> "$home/state/board-watch.check.sh"
  FM_HOME="$home" "$SCRIPT" status | jq -e '.armed == false' >/dev/null \
    || fail "status must reject a check whose bytes no longer match its trust binding"
  FM_HOME="$home" "$SCRIPT" disarm >/dev/null
  [ ! -e "$home/state/board-watch.check.sh" ] && [ ! -e "$home/state/board-watch.check-trust" ] \
    || fail "disarm should remove only custom-check artifacts"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "arm, status, and disarm use the registered custom-check mechanism"
}

test_arm_leaves_no_unauthenticated_check_when_binding_fails() {
  local fixture root home fakebin bearings output rc
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  : "$fakebin" "$bearings"
  mkdir -p "$home/state/board-watch.check-trust"
  set +e
  output=$(FM_HOME="$home" "$SCRIPT" arm 2>&1)
  rc=$?
  set -e
  rmdir "$home/state/board-watch.check-trust"
  [ "$rc" -ne 0 ] || fail "arm must fail when the custom check cannot be bound"
  [ ! -e "$home/state/board-watch.check.sh" ] \
    || fail "a failed bind must leave no unauthenticated check for the watcher to reject"
  assert_contains "$output" 'removed the unauthenticated check' \
    "arm should say it withdrew the check it could not bind"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "a failed trust binding withdraws the check instead of leaving it unauthenticated"
}

test_allowlist_and_exclusions() {
  local fixture root home fakebin bearings board output log
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_board "$board" '[]'
  write_bearings "${bearings}.json" Done
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '
    .repository_private == true
    and (.operations | any(.action == "create_issue" and .title == "Safe board title"))
    and (.operations | any(.action == "close_issue" and .task_id == "safe-task-internal-id"))
    and ((.excluded | sort) == (["excluded-task-alpha","excluded-task-bravo","excluded-task-charlie"] | sort))
  ' >/dev/null || fail "reconcile should create only the non-excluded card"
  assert_contains "$(<"$log")" 'kind: ship' "allowlisted kind should reach the issue body"
  assert_contains "$(<"$log")" 'project: demo-project' "allowlisted project should reach the issue body"
  assert_contains "$(<"$log")" 'PR: https://github.com/acme/app/pull/9' "allowlisted PR URL should reach the issue body"
  assert_contains "$(<"$log")" 'state=closed' "a newly created Done card should close its issue explicitly"
  assert_not_contains "$(<"$log")" 'fm-task' "no correlation marker may be published into a board issue"
  assert_not_contains "$(<"$log")" 'search/issues' "the sync must never search GitHub to rebind a card"
  assert_not_contains "$(<"$log")" 'SUPERSECRET_HOLD' "free-form detail must never reach GitHub"
  assert_not_contains "$(<"$log")" 'state/private/path' "private paths must never reach GitHub"
  assert_not_contains "$(<"$log")" 'owner+demo@example.com/password' "credentials must never reach GitHub"
  assert_not_contains "$(<"$log")" 'CROWN_JEWELS' "excluded task title must never reach GitHub"
  assert_not_contains "$(<"$log")" 'LIVE_DATABASE_PERMISSION_SEGFAULT' "excluded segfault task title must never reach GitHub"
  assert_not_contains "$(<"$log")" 'PRODUCTION_DOS_MITIGATION' "excluded mitigation-review title must never reach GitHub"
  assert_not_contains "$(<"$log")" 'excluded-task-alpha' "excluded task id must never reach GitHub"
  assert_not_contains "$(<"$log")" 'excluded-task-bravo' "excluded task id must never reach GitHub"
  assert_not_contains "$(<"$log")" 'excluded-task-charlie' "excluded task id must never reach GitHub"
  assert_not_contains "$(<"$log")" 'safe-task-internal-id' "internal task ids must never reach GitHub"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "GitHub writes contain only allowlisted fields and skip excluded tasks"
}

test_credential_bearing_artifact_is_not_published() {
  local fixture root home fakebin bearings board output log credential_url
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_board "$board" '[]'
  write_bearings "${bearings}.json" Ready
  credential_url='https://captain:credential@github.com/acme/app/pull/9'
  jq --arg url "$credential_url" '
    .board_items |= map(if .id == "safe-task-internal-id" then .artifact = $url else . end)
    | .recorded_prs |= map(if .id == "safe-task-internal-id" then .url = $url else . end)
  ' "${bearings}.json" > "${bearings}.json.next"
  mv "${bearings}.json.next" "${bearings}.json"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '
    .operations | any(.action == "create_issue" and (.body | contains("PR:") | not))
  ' >/dev/null || fail "a credential-bearing artifact must be excluded from the published body"
  assert_not_contains "$(<"$log")" 'captain:credential@' \
    "URL userinfo must never cross the GitHub publication boundary"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "credential-bearing artifacts never enter GitHub issue bodies"
}

test_exclusion_file_is_a_hard_gate() {
  local fixture root home fakebin bearings board log output rc
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_board "$board" '[]'
  write_bearings "${bearings}.json" Ready

  rm -f "$home/config/board-exclude"
  set +e
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a missing exclude file must fail reconcile"
  assert_contains "$output" 'missing config/board-exclude' "missing exclusions should be named explicitly"
  [ ! -s "$log" ] || fail "exclusion validation must happen before every GitHub call"

  printf '%s\n' '# every id was commented out' '' > "$home/config/board-exclude"
  set +e
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an exclude file with no usable id must fail reconcile"
  assert_contains "$output" 'yields no task ids' "an empty exclusion list should be refused explicitly"
  [ ! -s "$log" ] || fail "an empty exclusion list must be refused before every GitHub call"

  printf '%s\n' 'excluded-task-alpha' > "$home/config/board-exclude"
  chmod 000 "$home/config/board-exclude"
  if [ ! -r "$home/config/board-exclude" ]; then
    set +e
    output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "an unreadable exclude file must fail reconcile"
    assert_contains "$output" 'config/board-exclude is unreadable' "unreadable exclusions should be named explicitly"
    [ ! -s "$log" ] || fail "an unreadable exclusion list must be refused before every GitHub call"
  fi
  chmod 600 "$home/config/board-exclude"

  printf '%s\n' 'excluded-task-alpha' > "$root/elsewhere"
  rm -f "$home/config/board-exclude"
  ln -s "$root/elsewhere" "$home/config/board-exclude"
  set +e
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a symlinked exclude file must fail reconcile"
  assert_contains "$output" 'must be a regular file' "a redirected exclusion list should be refused"
  [ ! -s "$log" ] || fail "a redirected exclusion list must be refused before every GitHub call"

  set +e
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the watcher poll must apply the same exclusion gate as reconcile"
  assert_contains "$output" 'must be a regular file' "poll should refuse a redirected exclusion list too"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "a missing, empty, unreadable, or redirected exclusion list fails closed before GitHub"
}

test_untitled_task_never_publishes_runtime_detail() {
  local fixture root home fakebin bearings board log output
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_board "$board" '[]'
  write_bearings_untitled "${bearings}.json"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '
    (.operations | any(.action == "create_issue"
      and (.title | test("^Fleet task [0-9a-f]{8}$"))))
  ' >/dev/null || fail "a task with no structured title should fall back to an opaque label"
  assert_not_contains "$(<"$log")" 'RUNTIME_DETAIL_LEAK' "free-form runtime detail must never reach the issue title"
  assert_not_contains "$(<"$log")" 'state/private/path' "private paths must never reach the issue title"
  assert_not_contains "$(<"$log")" 'demo@example.com' "contact detail must never reach the issue title"
  assert_not_contains "$(<"$log")" 'unstructured-task-internal-id' "internal task ids must never reach GitHub"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "a task without a structured title publishes an opaque placeholder, never runtime detail"
}

test_concurrent_reconcile_fails_closed() {
  local fixture root home fakebin bearings board log output rc
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_board "$board" '[]'
  write_bearings "${bearings}.json" Ready
  mkdir -p "$home/state/.board-sync.lock"
  printf '%s\n' 'unverifiable-owner' > "$home/state/.board-sync.lock/owner"
  set +e
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile 2>&1)
  rc=$?
  set -e
  rm "$home/state/.board-sync.lock/owner"
  rmdir "$home/state/.board-sync.lock"
  [ "$rc" -ne 0 ] || fail "a held reconcile lock must refuse the second run"
  assert_contains "$output" 'holds' "a held lock should be explained"
  assert_not_contains "$(<"$log")" $'ARG\tPOST' "a refused reconcile must not create a duplicate issue"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "overlapping reconciles fail closed instead of minting duplicate issues"
}

test_live_reconcile_lock_cannot_be_stolen() {
  local fixture root home fakebin bearings board log holder output rc dead_pid first second winner loser attempts
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_board "$board" '[]'
  write_bearings "${bearings}.json" Ready
  BEARINGS_BLOCK_READY="$root/holder-ready" BEARINGS_BLOCK_RELEASE="$root/holder-release" \
    run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile \
    > "$root/holder.out" 2> "$root/holder.err" &
  holder=$!
  while [ ! -e "$root/holder-ready" ]; do
    kill -0 "$holder" 2>/dev/null || fail "the lock holder exited before blocking"
    sleep 0.05
  done
  set +e
  output=$(FM_BOARD_LOCK_STALE_SECS=0 \
    run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "elapsed time must never let a second reconcile steal a live lock"
  assert_contains "$output" 'another fm-board-sync reconcile holds' \
    "a live lock owner should be reported explicitly"
  : > "$root/holder-release"
  wait "$holder" || fail "the original lock holder failed after the competing attempt"

  dead_pid=9999999
  while kill -0 "$dead_pid" 2>/dev/null; do
    dead_pid=$((dead_pid + 1))
  done
  mkdir -p "$home/state/.board-sync.lock"
  printf '%s\n%s\n' "$dead_pid" 'stale-process-identity' \
    > "$home/state/.board-sync.lock/owner"
  run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile >/dev/null \
    || fail "a lock whose recorded owner is confirmed dead must be reclaimed"

  cat > "$fakebin/rm" <<'SH'
#!/usr/bin/env bash
if [ "${FM_BOARD_TEST_SLOW_OWNER_REMOVE:-0}" = 1 ]; then
  for arg in "$@"; do
    case "$arg" in
      */.board-sync.lock/owner) sleep 0.2 ;;
    esac
  done
fi
exec /bin/rm "$@"
SH
  chmod +x "$fakebin/rm"
  printf '%s\n%s\n' "$dead_pid" 'stale-process-identity' \
    > "$home/state/.board-sync.lock/owner"
  FM_BOARD_TEST_SLOW_OWNER_REMOVE=1 \
    BEARINGS_BLOCK_READY="$root/first-ready" BEARINGS_BLOCK_RELEASE="$root/first-release" \
    run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile \
    > "$root/first.out" 2> "$root/first.err" &
  first=$!
  FM_BOARD_TEST_SLOW_OWNER_REMOVE=1 \
    BEARINGS_BLOCK_READY="$root/second-ready" BEARINGS_BLOCK_RELEASE="$root/second-release" \
    run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile \
    > "$root/second.out" 2> "$root/second.err" &
  second=$!
  while [ ! -e "$root/first-ready" ] && [ ! -e "$root/second-ready" ]; do
    kill -0 "$first" 2>/dev/null || kill -0 "$second" 2>/dev/null \
      || fail "both stale-lock contenders exited before either acquired the lock"
    sleep 0.05
  done
  sleep 0.4
  if [ -e "$root/first-ready" ] && [ -e "$root/second-ready" ]; then
    : > "$root/first-release"
    : > "$root/second-release"
    wait "$first" || true
    wait "$second" || true
    fail "competing stale-lock reclaimers must not both enter reconcile"
  fi
  if [ -e "$root/first-ready" ]; then
    winner=$first
    loser=$second
  else
    winner=$second
    loser=$first
  fi
  attempts=0
  while kill -0 "$loser" 2>/dev/null && [ "$attempts" -lt 60 ]; do
    attempts=$((attempts + 1))
    sleep 0.05
  done
  if kill -0 "$loser" 2>/dev/null; then
    : > "$root/first-release"
    : > "$root/second-release"
    wait "$first" || true
    wait "$second" || true
    fail "the losing stale-lock reclaimer must fail while the winner still holds the lock"
  fi
  set +e
  wait "$loser"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "one competing stale-lock reclaimer must fail closed"
  if [ "$winner" -eq "$first" ]; then
    : > "$root/first-release"
  else
    : > "$root/second-release"
  fi
  wait "$winner" || fail "the serialized stale-lock winner failed"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "live reconcile locks cannot be stolen and stale reclaimers serialize"
}

test_incomplete_lock_publication_never_wedges_reconcile() {
  local fixture root home fakebin bearings board log
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_board "$board" '[]'
  write_bearings "${bearings}.json" Ready
  mkdir -p "$home/state/.board-sync.lock"
  printf '%s\n' 'incomplete-owner' > "$home/state/.board-sync.lock/.owner.interrupted"
  run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile >/dev/null \
    || fail "an interrupted lock publication must not wedge later reconciles"
  [ ! -e "$home/state/.board-sync.lock/owner" ] \
    || fail "a completed reconcile must release its atomically published owner claim"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "an interrupted lock publication leaves no ownership claim to wedge later runs"
}

test_private_repo_is_a_hard_gate() {
  local fixture root home fakebin bearings board log output rc
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_board "$board" '[]'
  write_bearings "${bearings}.json" Ready
  set +e
  output=$(GH_PRIVATE=false run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "public repository must fail reconcile"
  assert_contains "$output" 'public or its visibility is unknown' "visibility refusal should be explicit"
  assert_not_contains "$(<"$log")" $'ARG\tPOST' "visibility refusal must precede create mutations"
  assert_not_contains "$(<"$log")" $'ARG\tPATCH' "visibility refusal must precede update mutations"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "public or unknown repository visibility refuses every push"
}

test_private_repo_is_revalidated_at_the_mutation_boundary() {
  local fixture root home fakebin bearings board log output rc
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_board "$board" '[]'
  write_bearings "${bearings}.json" Ready
  set +e
  output=$(GH_PRIVATE_AFTER_FIRST=false \
    run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a repository made public before mutation must fail reconcile"
  assert_contains "$output" 'public or its visibility is unknown' \
    "the mutation-boundary visibility refusal should be explicit"
  [ "$(<"$log.privacy-count")" -eq 2 ] \
    || fail "repository privacy must be checked again at the mutation boundary"
  assert_not_contains "$(<"$log")" $'ARG\tPOST' \
    "visibility loss immediately before mutation must prevent issue creation"
  assert_not_contains "$(<"$log")" 'mutation(' \
    "visibility loss immediately before mutation must prevent project writes"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "repository privacy is revalidated immediately before mutation"
}

test_dry_run_has_complete_plan_and_no_mutations() {
  local fixture root home fakebin bearings board log output
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_board "$board" '[]'
  write_bearings "${bearings}.json" Ready
  rmdir "$home/state"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile --dry-run)
  printf '%s' "$output" | jq -e --arg body "$CANONICAL_BODY" '
    .dry_run == true
    and ([.operations[].action] == ["create_issue","add_item","set_column"])
    and .operations[0].body == $body
  ' >/dev/null || fail "dry-run should show the complete allowlisted create/add/column plan"
  assert_not_contains "$(<"$log")" $'ARG\tPOST' "dry-run must not call issue create mutations"
  assert_not_contains "$(<"$log")" $'ARG\tPATCH' "dry-run must not call issue update mutations"
  assert_not_contains "$(<"$log")" 'mutation(' "dry-run must not call project mutations"
  [ ! -e "$home/state" ] \
    || fail "dry-run must not initialize the persistent state directory"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "dry-run is complete but performs no GitHub or local state mutations"
}

test_dry_run_plans_pending_work_for_mapped_tasks() {
  local fixture root home fakebin bearings board log output card
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Done
  card=$(owned_card PVTI_ONE Held | jq '.content.title = "Stale card title"')
  write_board "$board" "$(jq -n --argjson card "$card" '[$card]')"
  write_state "$home/state/board-sync.json" "$(mapping PVTI_ONE)"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile --dry-run)
  printf '%s' "$output" | jq -e '
    .dry_run == true
    and ([.operations[] | select(.task_id == "safe-task-internal-id") | .action] | sort
      == ["close_issue","set_column","update_issue"])
    and (.operations | any(.action == "set_column" and .column == "Done"))
    and (.escalations | any(contains("task safe-task-internal-id")
      and contains("card is in \"Held\"")
      and contains("the fleet says \"Done\"")))
  ' >/dev/null || fail "dry-run must plan issue updates, column moves, and closes for mapped tasks"
  assert_not_contains "$(<"$log")" $'ARG\tPATCH' "dry-run must not update or close a mapped issue"
  assert_not_contains "$(<"$log")" 'mutation(' "dry-run must not move a mapped card"
  jq -e '.tasks["safe-task-internal-id"].item_id == "PVTI_ONE" and .synced_at == null' \
    "$home/state/board-sync.json" >/dev/null \
    || fail "dry-run must not mutate the recorded mapping"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "dry-run reports the complete plan for already-mapped tasks without mutating anything"
}

test_dry_run_plan_matches_the_real_operation_list() {
  local fixture root home fakebin bearings board log planned actual
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_board "$board" '[]'
  write_bearings "${bearings}.json" Done
  planned=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile --dry-run \
    | jq -c '[.operations[] | {action,task_id,column,explanation}]')
  actual=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile \
    | jq -c '[.operations[] | {action,task_id,column,explanation}]')
  [ "$planned" = "$actual" ] \
    || fail "the dry-run plan must match the real operation list exactly: $planned vs $actual"
  printf '%s' "$planned" | jq -e 'any(.action == "set_column" and .explanation != null)' >/dev/null \
    || fail "a dry-run set_column must carry the same explanation as its real counterpart"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "the dry-run plan and the real run build the same operation list from one code path"
}

test_state_holds_only_the_task_mapping() {
  local fixture root home fakebin bearings board log
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_board "$board" '[]'
  write_bearings "${bearings}.json" Ready
  run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile >/dev/null
  jq -e '(keys | sort) == ["project","schema","synced_at","tasks"]' \
    "$home/state/board-sync.json" >/dev/null \
    || fail "persisted state must hold nothing beyond the mapping, project, and sync time"
  jq -e '.tasks["safe-task-internal-id"] | (keys | sort)
    == ["issue_id","issue_number","issue_url","item_id","repo"]' \
    "$home/state/board-sync.json" >/dev/null \
    || fail "a task mapping must record only how to reach its own card"
  FM_HOME="$home" "$SCRIPT" status | jq -e '
    (keys | sort) == ["armed","config","configured","mapped_tasks","schema","synced_at"]
    and .mapped_tasks == 1' >/dev/null \
    || fail "status must report only the mapping it still holds"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "the sync persists only the mapping its one-way push needs"
}

test_poll_prints_only_a_deduplicated_pointer() {
  local fixture root home fakebin bearings board log first second third rc
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  write_board "$board" "$(jq -n --argjson card "$(owned_card PVTI_ONE Held)" '[$card]')"
  write_state "$home/state/board-sync.json" "$(mapping PVTI_ONE)"
  first=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  second=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$first" = 'board-sync 1 board change(s) pending' ] \
    || fail "poll must emit one compact pointer"
  [ -z "$second" ] || fail "poll must deduplicate the same unhandled change"
  assert_not_contains "$first" 'Safe board title' "poll wake must not contain payload"
  rm -f "$home/state/board-sync.seen"
  ln -s "$root/redirected" "$home/state/board-sync.seen"
  set +e
  third=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll 2>&1)
  rc=$?
  set -e
  rm -f "$home/state/board-sync.seen"
  [ "$rc" -ne 0 ] || fail "a redirected poll signature path must fail closed"
  assert_contains "$third" 'must not be a symlink' "a redirected signature path should be refused"
  [ ! -e "$root/redirected" ] || fail "poll must never follow a signature symlink off its state directory"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "poll emits a durable, deduplicated pointer instead of a lossy payload"
}

test_moved_card_is_pushed_back_to_the_fleet_column() {
  local fixture root home fakebin bearings board log output
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" 'Under way'
  write_board "$board" "$(jq -n --argjson card "$(owned_card PVTI_ONE Held)" '[$card]')"
  write_state "$home/state/board-sync.json" "$(mapping PVTI_ONE)"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '
    (.escalations | length == 1)
    and (.escalations[0] | startswith("board changed: ")
      and contains("card is in \"Held\"")
      and contains("the fleet says \"Under way\""))
    and (.operations | any(.action == "set_column" and .column == "Under way"
      and (.explanation | contains("set to Under way to match fleet state"))))
  ' >/dev/null || fail "a card off its fleet column must be noted and pushed back in the same run"
  assert_contains "$(<"$log")" 'updateProjectV2ItemFieldValue' "the fleet column must reach the board"
  assert_not_contains "$(<"$log")" $'ARG\tPATCH' "moving a card must not rewrite its issue"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "a card off its fleet column is noted and set back to its own task's column"
}

test_cleared_status_is_restored_and_noted() {
  local fixture root home fakebin bearings board log output woke
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  # The card was dragged into the "No Status" group, so the field reads null.
  write_board "$board" "$(jq -n --argjson card "$(owned_card PVTI_ONE '')" '[$card]')"
  write_state "$home/state/board-sync.json" "$(mapping PVTI_ONE)"
  woke=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$woke" = 'board-sync 1 board change(s) pending' ] || fail "a cleared Status must wake firstmate"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '
    (.operations | any(.action == "set_column" and .task_id == "safe-task-internal-id"
      and .column == "Ready"))
    and (.escalations | any(contains("task safe-task-internal-id")
      and contains("card is in \"no column\"")
      and contains("the fleet says \"Ready\"")))
  ' >/dev/null || fail "a cleared Status must be noted by the same run that restores the column"
  assert_contains "$(<"$log")" 'updateProjectV2ItemFieldValue' "the cleared card must be given the fleet column"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "a cleared board Status is noted and set back to the fleet column"
}

test_removed_card_is_restored_and_noted() {
  local fixture root home fakebin bearings board log output
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  # The card was removed from the project; the issue itself still exists.
  write_board "$board" '[]'
  write_state "$home/state/board-sync.json" "$(mapping PVTI_ONE)"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '
    (.escalations | length == 1)
    and (.escalations[0] | contains("task safe-task-internal-id")
      and contains("has no card on the board")
      and contains("the fleet says \"Ready\""))
    and (.operations | any(.action == "add_item" and .task_id == "safe-task-internal-id"))
    and (.operations | any(.action == "set_column" and .column == "Ready"
      and (.explanation | contains("set to Ready to match fleet state"))))
  ' >/dev/null || fail "a card removed from the board must be noted once and put back"
  jq -e '.tasks["safe-task-internal-id"].item_id == "PVTI_NEW"' "$home/state/board-sync.json" >/dev/null \
    || fail "the restored card's item id must be recorded"
  assert_not_contains "$(<"$log")" $'ARG\tPOST' "restoring a card must not mint a second issue"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "a card removed from the board is noted once and restored at its fleet column"
}

test_archived_card_is_noted_and_left_untouched() {
  local fixture root home fakebin bearings board log output woke again
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" 'Under way'
  # The card was archived, moved, and closed before this observation.
  write_board "$board" "$(jq -n --argjson card "$(owned_card PVTI_ONE Ready CLOSED true)" '[$card]')"
  write_state "$home/state/board-sync.json" "$(mapping PVTI_ONE)"
  woke=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$woke" = 'board-sync 1 board change(s) pending' ] \
    || fail "an archived mapped card must not be invisible to the poll"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '
    (.escalations | length == 1)
    and (.escalations[0] | contains("task safe-task-internal-id")
      and contains("has an archived card")
      and contains("the fleet says \"Under way\""))
    and (.operations | length == 0)
  ' >/dev/null || fail "an archived card must produce one note and no operation at all"
  assert_not_contains "$(<"$log")" 'updateProjectV2ItemFieldValue' "an archived card must not be written to"
  assert_not_contains "$(<"$log")" 'addProjectV2ItemById' "an archived card must never be auto-unarchived"
  assert_not_contains "$(<"$log")" 'deleteProjectV2Item' "an archived card must never be deleted"
  assert_not_contains "$(<"$log")" $'ARG\tPATCH' "an archived card's issue must never be rewritten or reopened"
  woke=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ -z "$woke" ] \
    || fail "an unchanged archived card must stop re-waking the watcher after it was reported"
  again=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$again" | jq -e '.escalations | length == 1' >/dev/null \
    || fail "every run must report the archived card it still observes"

  # Unarchiving it leaves an ordinary off-column card, which is a new observation.
  write_board "$board" "$(jq -n --argjson card "$(owned_card PVTI_ONE Ready)" '[$card]')"
  woke=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$woke" = 'board-sync 1 board change(s) pending' ] \
    || fail "unarchiving the card must wake firstmate again"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "an archived card is reported and never written, unarchived, or deleted"
}

test_closed_issue_is_noted_and_never_reopened() {
  local fixture root home fakebin bearings board log output
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  write_board "$board" "$(jq -n --argjson card "$(owned_card PVTI_ONE Ready CLOSED)" '[$card]')"
  write_state "$home/state/board-sync.json" "$(mapping PVTI_ONE)"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '
    (.escalations | length == 1)
    and (.escalations[0] | contains("task safe-task-internal-id")
      and contains("issue is closed")
      and contains("the fleet says \"Ready\""))
    and (.operations | length == 0)
  ' >/dev/null || fail "a closed issue under a live task must be reported and left alone"
  assert_not_contains "$(<"$log")" $'ARG\tPATCH' "the sync must never reopen or rewrite a closed board issue"
  assert_not_contains "$(<"$log")" 'mutation(' "a closed issue must not trigger any project write"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "an issue closed on the board is reported once and never reopened"
}

test_excluded_task_is_never_pushed_or_reported() {
  local fixture root home fakebin bearings board log output tasks
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  write_board "$board" "$(jq -n \
    --argjson owned "$(owned_card PVTI_ONE Ready)" \
    --argjson excluded "$(foreign_card PVTI_EXCLUDED Blocked 'CROWN_JEWELS unannounced strategy' 7)" \
    '[$owned,$excluded]')"
  tasks=$(jq -n --argjson owned "$(mapping PVTI_ONE)" \
    --argjson excluded "$(mapping PVTI_EXCLUDED excluded-task-alpha 7)" '$owned + $excluded')
  write_state "$home/state/board-sync.json" "$tasks"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '
    (.escalations | length == 0)
    and (.operations | length == 0)
    and ((.excluded | index("excluded-task-alpha")) != null)
  ' >/dev/null || fail "an excluded task must be neither pushed nor reported"
  assert_not_contains "$(<"$log")" 'CROWN_JEWELS' "an excluded task must never republish its title"
  assert_not_contains "$(<"$log")" $'ARG\tPATCH' "an excluded task's card must never be written to"
  assert_not_contains "$(<"$log")" 'deleteProjectV2Item' "an excluded task's card must never be deleted"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "an excluded task gets no card, no write, and no note"
}

test_unmanaged_card_is_noted_and_left_untouched() {
  local fixture root home fakebin bearings board log output
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  write_board "$board" "$(jq -n \
    --argjson owned "$(owned_card PVTI_ONE Ready)" \
    --argjson manual "$(foreign_card PVTI_NEWCARD Blocked 'Captain filed this by hand' 12)" \
    '[$owned,$manual]')"
  write_state "$home/state/board-sync.json" "$(mapping PVTI_ONE)"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '
    (.escalations | length == 1)
    and (.escalations[0] | startswith("board changed: ")
      and contains("unmanaged card titled \"Captain filed this by hand\"")
      and contains("left untouched"))
  ' >/dev/null || fail "a card the sync does not manage must be reported once and left alone"
  assert_not_contains "$(<"$log")" $'ARG\tPATCH' "reporting an unmanaged card must not alter its issue"
  assert_not_contains "$(<"$log")" 'deleteProjectV2Item' "reporting an unmanaged card must never delete anything"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "a card the sync does not manage is left untouched and reported as a note"
}

test_hand_filed_card_never_binds_to_a_fleet_task() {
  local fixture root home fakebin bearings board log output card
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  # A hand-filed issue carrying the very same title as the fleet task.
  card=$(foreign_card PVTI_CAPTAIN Blocked "$CANONICAL_TITLE" 21)
  write_board "$board" "$(jq -n --argjson card "$card" '[$card]')"
  write_state "$home/state/board-sync.json" '{}'
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  assert_contains "$(<"$log")" $'ARG\tPOST' \
    "a same-title hand-filed card must not prevent creating the canonical issue"
  printf '%s' "$output" | jq -e '
    (.operations | any(.action == "create_issue" and .task_id == "safe-task-internal-id"))
    and (.operations | any(.action == "add_item" and .task_id == "safe-task-internal-id"))
    and (.escalations | any(contains("unmanaged card titled \"Safe board title\"")))
  ' >/dev/null || fail "a hand-filed card must remain separate from the canonical fleet card"
  jq -e '.tasks["safe-task-internal-id"].issue_number == 101
    and .tasks["safe-task-internal-id"].item_id == "PVTI_NEW"
    and .tasks["safe-task-internal-id"].issue_id == "I_NEW"' \
    "$home/state/board-sync.json" >/dev/null \
    || fail "the mapping must point only at the Firstmate-created canonical card"
  assert_not_contains "$(<"$log")" 'search/issues' "the sync must never search GitHub to adopt a card"
  assert_not_contains "$(<"$log")" $'ARG\tPATCH' "a hand-filed issue must never be rebound or rewritten"
  assert_not_contains "$(<"$log")" 'deleteProjectV2Item' "a hand-filed card must never be deleted"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "a hand-filed card stays untouched while its fleet task gets a canonical card"
}

test_draft_card_is_left_manual_while_canonical_card_is_created() {
  local fixture root home fakebin bearings board log output
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  write_board "$board" "$(jq -n --arg title "$CANONICAL_TITLE" '[{
    id:"PVTI_DRAFT",type:"DRAFT_ISSUE",isArchived:false,updatedAt:"2026-08-17T10:00:00Z",
    fieldValueByName:{name:"Blocked",optionId:"blocked",updatedAt:"2026-08-17T10:00:00Z"},
    content:{__typename:"DraftIssue",title:$title}
  }]')"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  assert_contains "$(<"$log")" $'ARG\tPOST' "a manual draft must not replace the canonical issue"
  printf '%s' "$output" | jq -e '
    (.escalations | any(contains("unmanaged card titled \"Safe board title\"")))
    and (.operations | any(.action == "create_issue" and .task_id == "safe-task-internal-id"))
  ' >/dev/null || fail "a draft must stay manual while the fleet task gets a canonical card"
  jq -e '.tasks["safe-task-internal-id"].item_id == "PVTI_NEW"' "$home/state/board-sync.json" >/dev/null \
    || fail "the draft must not become the task mapping"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "a manual draft stays untouched while the fleet task gets a canonical card"
}

test_reAdded_card_under_a_new_item_id_still_reconciles() {
  local fixture root home fakebin bearings board log output
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" 'Under way'
  # The card was removed and the same issue re-added, which mints a new item id.
  write_board "$board" "$(jq -n --argjson card "$(owned_card PVTI_REBOUND '')" '[$card]')"
  write_state "$home/state/board-sync.json" "$(mapping PVTI_STALE)"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '.operations | any(.action == "set_column" and .column == "Under way")' \
    >/dev/null || fail "a card re-added under a new item id must still be synced to the fleet column"
  jq -e '.tasks["safe-task-internal-id"].item_id == "PVTI_REBOUND"' "$home/state/board-sync.json" >/dev/null \
    || fail "the stored mapping must use the item id the run actually resolved"
  printf '%s' "$output" | jq -e '.escalations | all(contains("unmanaged card") | not)' >/dev/null \
    || fail "the re-added canonical card must not be reported as unmanaged"
  assert_contains "$(<"$log")" 'PVTI_REBOUND' "the column write must target the live item id"
  assert_not_contains "$(<"$log")" 'PVTI_STALE' "no GitHub call may target the stale item id"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "a card re-added under a new item id reconciles and rebinds instead of wedging"
}

test_all_digit_owner_still_reads_the_board() {
  local fixture root home fakebin bearings board log output rc
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  printf '%s\n' '{"owner":"123456","project_number":1,"repo":"123456/fleet"}' \
    > "$home/config/board-sync.json"
  write_bearings "${bearings}.json" Ready
  write_board "$board" "$(jq -n \
    --argjson card "$(owned_card PVTI_ONE Held OPEN false 2026-08-16T10:00:00Z 123456/fleet)" '[$card]')"
  write_state "$home/state/board-sync.json" "$(mapping PVTI_ONE safe-task-internal-id 1 123456/fleet)"
  set +e
  output=$(GH_REPO=123456/fleet run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "an all-digit GitHub login must still read the board instead of failing type checking: $output"
  [ "$output" = 'board-sync 1 board change(s) pending' ] \
    || fail "an all-digit GitHub login must produce the ordinary pending-change pointer"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "an all-digit GitHub login is sent as a String and still reads the board"
}

test_reported_board_state_stops_rewaking_the_watcher() {
  local fixture root home fakebin bearings board log first second third
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  # The board keeps returning the same off-column card, as if every push were undone.
  write_board "$board" "$(jq -n --argjson card "$(owned_card PVTI_ONE Held)" '[$card]')"
  write_state "$home/state/board-sync.json" "$(mapping PVTI_ONE)"
  first=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$first" = 'board-sync 1 board change(s) pending' ] || fail "the first sweep must wake firstmate"
  run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile >/dev/null
  second=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ -z "$second" ] || fail "an already-reported board difference must not re-wake every sweep"
  write_board "$board" "$(jq -n --argjson card "$(owned_card PVTI_ONE Blocked)" '[$card]')"
  third=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$third" = 'board-sync 1 board change(s) pending' ] || fail "a genuinely new board move must still wake firstmate"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "an already-reported board difference stops re-waking the watcher while a new one still wakes it"
}

test_board_move_during_reconcile_is_never_silently_suppressed() {
  local fixture root home fakebin bearings board after log woke output
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  after="$root/board-after.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  # The board agrees with the fleet when reconcile reads it, so nothing is reported.
  write_board "$board" "$(jq -n --argjson card "$(owned_card PVTI_ONE Ready)" '[$card]')"
  # The card moves after that read but before reconcile's post-write re-read.
  write_board "$after" "$(jq -n --argjson card "$(owned_card PVTI_ONE Held)" '[$card]')"
  write_state "$home/state/board-sync.json" "$(mapping PVTI_ONE)"
  output=$(BOARD_FIXTURE_AFTER="$after" run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '.escalations | length == 0' >/dev/null \
    || fail "a move arriving after the reported read must not be back-dated into this run's notes"
  woke=$(BOARD_FIXTURE_AFTER="$after" run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$woke" = 'board-sync 1 board change(s) pending' ] \
    || fail "a board move landing inside the reconcile window must still wake firstmate"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "a board move landing mid-reconcile is never silently marked already-reported"
}

test_archive_during_reconcile_is_not_absorbed() {
  local fixture root home fakebin bearings board after log output woke
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  after="$root/board-after.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  write_board "$board" "$(jq -n --argjson card "$(owned_card PVTI_ONE Ready)" '[$card]')"
  write_board "$after" "$(jq -n --argjson card "$(owned_card PVTI_ONE Ready OPEN true)" '[$card]')"
  write_state "$home/state/board-sync.json" "$(mapping PVTI_ONE)"
  output=$(BOARD_FIXTURE_AFTER="$after" run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '.escalations | length == 0' >/dev/null \
    || fail "an archive that arrived after the reported read must not be claimed by that run"
  cp "$after" "$board"
  woke=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$woke" = 'board-sync 1 board change(s) pending' ] \
    || fail "a mid-reconcile archive must wake firstmate on the next poll"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "an archive arriving mid-reconcile remains pending for the next poll"
}

test_issue_close_during_reconcile_is_not_absorbed() {
  local fixture root home fakebin bearings board after log output woke
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  after="$root/board-after.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  write_board "$board" "$(jq -n --argjson card "$(owned_card PVTI_ONE Ready)" '[$card]')"
  write_board "$after" "$(jq -n --argjson card "$(owned_card PVTI_ONE Ready CLOSED)" '[$card]')"
  write_state "$home/state/board-sync.json" "$(mapping PVTI_ONE)"
  output=$(BOARD_FIXTURE_AFTER="$after" run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '.escalations | length == 0' >/dev/null \
    || fail "a close that arrived after the reported read must not be claimed by that run"
  cp "$after" "$board"
  woke=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$woke" = 'board-sync 1 board change(s) pending' ] \
    || fail "a mid-reconcile issue close must wake firstmate on the next poll"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "an issue close arriving mid-reconcile remains pending for the next poll"
}

test_unmanaged_change_during_reconcile_is_never_silently_absorbed() {
  local fixture root home fakebin bearings board after log woke
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  after="$root/board-after.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  write_board "$board" "$(jq -n \
    --argjson owned "$(owned_card PVTI_ONE Ready)" \
    --argjson foreign "$(foreign_card PVTI_FOREIGN Ready)" '[$owned,$foreign]')"
  # The foreign card is dragged and another one appears after the reported read.
  write_board "$after" "$(jq -n \
    --argjson owned "$(owned_card PVTI_ONE Ready)" \
    --argjson foreign "$(foreign_card PVTI_FOREIGN Done)" \
    --argjson late "$(foreign_card PVTI_LATE Held 'Card added mid reconcile' 10)" \
    '[$owned,$foreign,$late]')"
  write_state "$home/state/board-sync.json" "$(mapping PVTI_ONE)"
  BOARD_FIXTURE_AFTER="$after" run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile >/dev/null
  woke=$(BOARD_FIXTURE_AFTER="$after" run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$woke" = 'board-sync 2 board change(s) pending' ] \
    || fail "unmanaged-card changes landing inside the reconcile window must still wake firstmate"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "an unmanaged card changed or added mid-reconcile is never silently absorbed"
}

test_bare_github_touch_never_rewakes_the_poll() {
  local fixture root home fakebin bearings board log first second
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  write_board "$board" "$(jq -n \
    --argjson owned "$(owned_card PVTI_ONE Ready)" \
    --argjson foreign "$(foreign_card PVTI_FOREIGN Blocked 'Hand added card' 9 2026-08-16T10:00:00Z)" \
    '[$owned,$foreign]')"
  write_state "$home/state/board-sync.json" "$(mapping PVTI_ONE)"
  first=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$first" = 'board-sync 1 board change(s) pending' ] \
    || fail "a card the sync does not manage must wake firstmate when it first appears"

  # GitHub touches the card without changing its column or issue state.
  write_board "$board" "$(jq -n \
    --argjson owned "$(owned_card PVTI_ONE Ready)" \
    --argjson foreign "$(foreign_card PVTI_FOREIGN Blocked 'Hand added card' 9 2026-08-17T04:45:12Z)" \
    '[$owned,$foreign]')"
  second=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ -z "$second" ] \
    || fail "a GitHub touch that changes no column or issue state must not wake firstmate again"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "the poll signature ignores GitHub timestamps, so a bare touch never re-wakes the watcher"
}

test_notes_report_only_what_the_run_observes() {
  local fixture root home fakebin bearings board log output
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  write_board "$board" "$(jq -n \
    --argjson owned "$(owned_card PVTI_ONE Held)" \
    --argjson foreign "$(foreign_card PVTI_FOREIGN Blocked)" '[$owned,$foreign]')"
  write_state "$home/state/board-sync.json" "$(mapping PVTI_ONE)"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '
    (.escalations | length == 2)
    and (.escalations | all(startswith("board changed: ")))
    and (.escalations | any(contains("card is in \"Held\"")))
    and (.escalations | any(contains("unmanaged card titled \"Hand added card\"")))
  ' >/dev/null || fail "reconcile must report each observed board difference exactly once"

  # The card returns to its fleet column and the unmanaged card is retracted.
  write_board "$board" "$(jq -n --argjson owned "$(owned_card PVTI_ONE Ready)" '[$owned]')"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '.escalations | length == 0' >/dev/null \
    || fail "a board difference that is gone must not be reported again"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "each run reports only the board differences it actually observes"
}

test_arm_status_and_disarm
test_arm_leaves_no_unauthenticated_check_when_binding_fails
test_allowlist_and_exclusions
test_credential_bearing_artifact_is_not_published
test_exclusion_file_is_a_hard_gate
test_untitled_task_never_publishes_runtime_detail
test_concurrent_reconcile_fails_closed
test_live_reconcile_lock_cannot_be_stolen
test_incomplete_lock_publication_never_wedges_reconcile
test_private_repo_is_a_hard_gate
test_private_repo_is_revalidated_at_the_mutation_boundary
test_dry_run_has_complete_plan_and_no_mutations
test_dry_run_plans_pending_work_for_mapped_tasks
test_dry_run_plan_matches_the_real_operation_list
test_state_holds_only_the_task_mapping
test_poll_prints_only_a_deduplicated_pointer
test_moved_card_is_pushed_back_to_the_fleet_column
test_cleared_status_is_restored_and_noted
test_removed_card_is_restored_and_noted
test_archived_card_is_noted_and_left_untouched
test_closed_issue_is_noted_and_never_reopened
test_excluded_task_is_never_pushed_or_reported
test_unmanaged_card_is_noted_and_left_untouched
test_hand_filed_card_never_binds_to_a_fleet_task
test_draft_card_is_left_manual_while_canonical_card_is_created
test_reAdded_card_under_a_new_item_id_still_reconciles
test_all_digit_owner_still_reads_the_board
test_reported_board_state_stops_rewaking_the_watcher
test_board_move_during_reconcile_is_never_silently_suppressed
test_archive_during_reconcile_is_not_absorbed
test_issue_close_during_reconcile_is_not_absorbed
test_unmanaged_change_during_reconcile_is_never_silently_absorbed
test_bare_github_touch_never_rewakes_the_poll
test_notes_report_only_what_the_run_observes
printf 'board-sync tests: %s passed\n' "$TESTS_RUN"
