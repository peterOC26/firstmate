#!/usr/bin/env bash
# Behavioral coverage for the private GitHub Projects fleet-board sync.
set -euo pipefail

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck disable=SC2153
SCRIPT="$ROOT/bin/fm-board-sync.sh"
TESTS_RUN=0

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
  printf '%s\n' "${GH_PRIVATE:-true}"
  exit 0
fi
if [ "${1:-}" = api ] && [ "${2:-}" = --method ] && [ "${3:-}" = GET ] && [ "${4:-}" = search/issues ]; then
  printf '%s\n' '{"items":[]}'
  exit 0
fi
if [ "${1:-}" = api ] && [ "${2:-}" = --method ] && [ "${3:-}" = GET ] && [ "${4:-}" = "repos/$board_repo/issues" ]; then
  if [ -n "${REPO_ISSUES:-}" ]; then
    cat "$REPO_ISSUES"
  else
    printf '%s\n' '[]'
  fi
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
    REPO_ISSUES="${REPO_ISSUES:-}" BOARD_FIXTURE_AFTER="${BOARD_FIXTURE_AFTER:-}" "$SCRIPT" "$@"
}

test_arm_status_and_disarm() {
  local fixture root home fakebin bearings output
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  output=$(FM_HOME="$home" "$SCRIPT" arm)
  assert_contains "$output" 'armed: state/board-watch.check.sh' "arm should register the existing custom-check path"
  [ "$(stat -f %Lp "$home/state/board-watch.check.sh" 2>/dev/null || stat -c %a "$home/state/board-watch.check.sh")" = 700 ] \
    || fail "armed check must be mode 0700"
  jq -e '.schema == "fm-board-sync.v1" and (.salt | test("^[0-9a-f]{32}$"))' "$home/state/board-sync.json" >/dev/null \
    || fail "arm should initialize protected baseline state"
  FM_HOME="$home" "$SCRIPT" status | jq -e '.armed == true and .mapped_tasks == 0' >/dev/null \
    || fail "status should report the armed baseline"
  FM_HOME="$home" "$SCRIPT" disarm >/dev/null
  [ ! -e "$home/state/board-watch.check.sh" ] && [ ! -e "$home/state/board-watch.check-trust" ] \
    || fail "disarm should remove only custom-check artifacts"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "arm, status, and disarm use the registered custom-check mechanism"
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
  assert_contains "$(<"$log")" '<!-- fm-task: ' "opaque token should reach the issue body"
  assert_contains "$(<"$log")" 'state=closed' "a newly created Done card should close its issue explicitly"
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
  ' >/dev/null || fail "a task with no structured title should fall back to the opaque token"
  assert_not_contains "$(<"$log")" 'RUNTIME_DETAIL_LEAK' "free-form runtime detail must never reach the issue title"
  assert_not_contains "$(<"$log")" 'state/private/path' "private paths must never reach the issue title"
  assert_not_contains "$(<"$log")" 'demo@example.com' "contact detail must never reach the issue title"
  assert_not_contains "$(<"$log")" 'unstructured-task-internal-id' "internal task ids must never reach GitHub"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "a task without a structured title publishes an opaque placeholder, never runtime detail"
}

test_excluded_task_with_a_live_card_is_reported() {
  local fixture root home fakebin bearings board log output
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  write_board "$board" "$(jq -n '[{
    id:"PVTI_EXCLUDED",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
    fieldValueByName:{name:"Ready",optionId:"ready",updatedAt:"2026-08-16T10:00:00Z"},
    content:{__typename:"Issue",id:"I_EXCLUDED",number:7,title:"CROWN_JEWELS unannounced strategy",
      body:"<!-- fm-task: deadbeef -->",state:"OPEN",
      url:"https://github.com/captain/fleet/issues/7",updatedAt:"2026-08-16T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  jq -n '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{"excluded-task-alpha":{token:"deadbeef",repo:"captain/fleet",issue_number:7,issue_id:"I_EXCLUDED",
      issue_url:"https://github.com/captain/fleet/issues/7",item_id:"PVTI_EXCLUDED",
      baseline:{column:"Ready",option_id:"ready",issue_state:"OPEN"}}},
    unmapped_items:{},proposals:[],pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '
    .proposals | any(.type == "excluded_task_still_carded"
      and .task_id == "excluded-task-alpha"
      and .issue_url == "https://github.com/captain/fleet/issues/7")
  ' >/dev/null || fail "an excluded task that still has a card must be reported to the captain"
  jq -e '.proposals | any(.type == "excluded_task_still_carded")' "$home/state/board-sync.json" >/dev/null \
    || fail "the retracted-card report must be durable"
  assert_not_contains "$(<"$log")" 'deleteProjectV2Item' "a retroactive exclusion must never delete a card"
  assert_not_contains "$(<"$log")" 'CROWN_JEWELS' "a retroactive exclusion must not republish the excluded title"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "an excluded task that still holds a card is surfaced instead of silently left live"
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
  set +e
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile 2>&1)
  rc=$?
  set -e
  rmdir "$home/state/.board-sync.lock"
  [ "$rc" -ne 0 ] || fail "a held reconcile lock must refuse the second run"
  assert_contains "$output" 'holds' "a held lock should be explained"
  assert_not_contains "$(<"$log")" $'ARG\tPOST' "a refused reconcile must not create a duplicate issue"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "overlapping reconciles fail closed instead of minting duplicate issues"
}

test_pending_create_recovers_without_duplicating() {
  local fixture root home fakebin bearings board log token body output
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_board "$board" '[]'
  write_bearings "${bearings}.json" Ready
  token=$(printf '%s' 'safe-task-internal-idaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | shasum -a 256 | awk '{print substr($1,1,8)}')
  body=$(printf 'project: demo-project\nkind: ship\nPR: https://github.com/acme/app/pull/9\n<!-- fm-task: %s -->' "$token")
  jq -n --arg token "$token" --arg body "$body" '[{
    number:55,id:55,node_id:"I_CRASHED",
    html_url:"https://github.com/captain/fleet/issues/55",
    url:"https://api.github.com/repos/captain/fleet/issues/55",
    title:"Safe board title",body:$body,state:"open"
  }]' > "$root/repo-issues.json"
  jq -n --arg token "$token" '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{},unmapped_items:{},proposals:[],
    pending:[{task_id:"safe-task-internal-id",token:$token}],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  output=$(REPO_ISSUES="$root/repo-issues.json" \
    run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '.operations | all(.action != "create_issue")' >/dev/null \
    || fail "a pending create must be recovered instead of repeated"
  assert_not_contains "$(<"$log")" $'ARG\tPOST' "a pending create must never mint a second issue"
  jq -e '.tasks["safe-task-internal-id"].issue_number == 55 and (.pending | length) == 0' \
    "$home/state/board-sync.json" >/dev/null \
    || fail "the recovered issue must be adopted and the pending marker cleared"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "a crash between issue create and mapping recovers without a duplicate issue"
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

test_dry_run_has_complete_plan_and_no_mutations() {
  local fixture root home fakebin bearings board log output
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_board "$board" '[]'
  write_bearings "${bearings}.json" Ready
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile --dry-run)
  printf '%s' "$output" | jq -e '
    .dry_run == true
    and ([.operations[].action] == ["create_issue","add_item","set_column"])
    and .operations[0].body == "project: demo-project\nkind: ship\nPR: https://github.com/acme/app/pull/9\n<!-- fm-task: " + (.operations[0].body | capture("fm-task: (?<token>[0-9a-f]{8})").token) + " -->"
  ' >/dev/null || fail "dry-run should show the complete allowlisted create/add/column plan"
  assert_not_contains "$(<"$log")" $'ARG\tPOST' "dry-run must not call issue create mutations"
  assert_not_contains "$(<"$log")" $'ARG\tPATCH' "dry-run must not call issue update mutations"
  assert_not_contains "$(<"$log")" 'mutation(' "dry-run must not call project mutations"
  [ "$(jq '.tasks | length' "$home/state/board-sync.json")" -eq 0 ] \
    || fail "dry-run must not mutate mapping state"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "dry-run is complete but performs no GitHub or baseline mutations"
}

test_poll_prints_only_a_deduplicated_pointer() {
  local fixture root home fakebin bearings board log token first second third rc
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  token=12345678
  write_board "$board" "$(jq -n --arg token "$token" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
    fieldValueByName:{name:"Held",optionId:"held",updatedAt:"2026-08-16T10:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",
      body:("<!-- fm-task: " + $token + " -->"),state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-16T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  jq -n '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{safe:{token:"12345678",repo:"captain/fleet",issue_number:1,issue_id:"I_ONE",
      issue_url:"https://github.com/captain/fleet/issues/1",item_id:"PVTI_ONE",
      baseline:{column:"Ready",option_id:"ready",issue_state:"OPEN"}}},
    unmapped_items:{},proposals:[],pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
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

test_board_move_becomes_proposal_without_fleet_or_snapback_write() {
  local fixture root home fakebin bearings board log token body output
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  printf '%s' 'safe-task-internal-idaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | shasum -a 256 | awk '{print substr($1,1,8)}' > "$root/token"
  token=$(<"$root/token")
  body=$(printf 'project: demo-project\nkind: ship\nPR: https://github.com/acme/app/pull/9\n<!-- fm-task: %s -->' "$token")
  write_board "$board" "$(jq -n --arg token "$token" --arg body "$body" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
    fieldValueByName:{name:"Held",optionId:"held",updatedAt:"2026-08-16T10:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-16T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  jq -n --arg token "$token" '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{"safe-task-internal-id":{token:$token,repo:"captain/fleet",issue_number:1,issue_id:"I_ONE",
      issue_url:"https://github.com/captain/fleet/issues/1",item_id:"PVTI_ONE",
      baseline:{column:"Ready",option_id:"ready",issue_state:"OPEN"}}},
    unmapped_items:{},proposals:[],pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '
    (.proposals | any(.type == "column_move" and .from == "Ready" and .to == "Held"))
    and (.proposals | all(.type != "unmapped_board_item"))
    and ([.operations[] | select(.action == "set_column")] | length == 0)
  ' >/dev/null || fail "a pure captain move should be proposed without immediate snapback"
  jq -e '.proposals | any(.type == "column_move")' "$home/state/board-sync.json" >/dev/null \
    || fail "captain move proposal must be durable"
  assert_not_contains "$(<"$log")" 'updateProjectV2ItemFieldValue' "pure pull must not write the fleet column"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "board moves become durable proposals and never direct fleet writes"
}

test_declined_proposal_stops_rewaking_the_watcher() {
  local fixture root home fakebin bearings board log token body first second third
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  token=$(printf '%s' 'safe-task-internal-idaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | shasum -a 256 | awk '{print substr($1,1,8)}')
  body=$(printf 'project: demo-project\nkind: ship\nPR: https://github.com/acme/app/pull/9\n<!-- fm-task: %s -->' "$token")
  write_board "$board" "$(jq -n --arg body "$body" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
    fieldValueByName:{name:"Held",optionId:"held",updatedAt:"2026-08-16T10:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-16T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  jq -n --arg token "$token" '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{"safe-task-internal-id":{token:$token,repo:"captain/fleet",issue_number:1,issue_id:"I_ONE",
      issue_url:"https://github.com/captain/fleet/issues/1",item_id:"PVTI_ONE",
      baseline:{column:"Ready",option_id:"ready",issue_state:"OPEN"}}},
    unmapped_items:{},proposals:[],pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  first=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$first" = 'board-sync 1 board change(s) pending' ] || fail "the first sweep must wake firstmate"
  run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile >/dev/null
  jq -e '.tasks["safe-task-internal-id"].baseline.column == "Ready"' "$home/state/board-sync.json" >/dev/null \
    || fail "an unadopted board move must not silently advance the fleet baseline"
  second=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ -z "$second" ] || fail "a reported but unadopted board move must not re-wake every sweep"
  write_board "$board" "$(jq -n --arg body "$body" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T11:00:00Z",
    fieldValueByName:{name:"Blocked",optionId:"blocked",updatedAt:"2026-08-16T11:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-16T11:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  third=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$third" = 'board-sync 1 board change(s) pending' ] || fail "a genuinely new board move must still wake firstmate"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "a declined proposal stops re-waking the watcher while a new move still wakes it"
}

test_board_move_during_reconcile_is_never_silently_suppressed() {
  local fixture root home fakebin bearings board after log token body woke
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  after="$root/board-after.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  token=$(printf '%s' 'safe-task-internal-idaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | shasum -a 256 | awk '{print substr($1,1,8)}')
  body=$(printf 'project: demo-project\nkind: ship\nPR: https://github.com/acme/app/pull/9\n<!-- fm-task: %s -->' "$token")
  # The board agrees with the fleet when reconcile reads it, so nothing is reported.
  write_board "$board" "$(jq -n --arg body "$body" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
    fieldValueByName:{name:"Ready",optionId:"ready",updatedAt:"2026-08-16T10:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-16T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  # The captain moves the card after that read but before reconcile's post-write re-read.
  write_board "$after" "$(jq -n --arg body "$body" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:05:00Z",
    fieldValueByName:{name:"Held",optionId:"held",updatedAt:"2026-08-16T10:05:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-16T10:05:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  jq -n --arg token "$token" '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{"safe-task-internal-id":{token:$token,repo:"captain/fleet",issue_number:1,issue_id:"I_ONE",
      issue_url:"https://github.com/captain/fleet/issues/1",item_id:"PVTI_ONE",
      baseline:{column:"Ready",option_id:"ready",issue_state:"OPEN"}}},
    unmapped_items:{},proposals:[],pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  BOARD_FIXTURE_AFTER="$after" run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile >/dev/null
  jq -e '[.proposals[] | select(.type == "column_move")] | length == 0' "$home/state/board-sync.json" >/dev/null \
    || fail "a move arriving after the reported read must not be back-dated into this run's proposals"
  woke=$(BOARD_FIXTURE_AFTER="$after" run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$woke" = 'board-sync 1 board change(s) pending' ] \
    || fail "a board move landing inside the reconcile window must still wake firstmate, not be marked already-reported"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "a board move landing mid-reconcile is never silently marked already-reported"
}

test_dry_run_plans_pending_work_for_mapped_tasks() {
  local fixture root home fakebin bearings board log token body output
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Done
  token=$(printf '%s' 'safe-task-internal-idaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | shasum -a 256 | awk '{print substr($1,1,8)}')
  body=$(printf 'project: demo-project\nkind: ship\nPR: https://github.com/acme/app/pull/9\n<!-- fm-task: %s -->' "$token")
  write_board "$board" "$(jq -n --arg body "$body" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
    fieldValueByName:{name:"Held",optionId:"held",updatedAt:"2026-08-16T10:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Stale card title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-16T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  jq -n --arg token "$token" '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{"safe-task-internal-id":{token:$token,repo:"captain/fleet",issue_number:1,issue_id:"I_ONE",
      issue_url:"https://github.com/captain/fleet/issues/1",item_id:"PVTI_ONE",
      baseline:{column:"Ready",option_id:"ready",issue_state:"OPEN"}}},
    unmapped_items:{},proposals:[],pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile --dry-run)
  printf '%s' "$output" | jq -e '
    .dry_run == true
    and ([.operations[] | select(.task_id == "safe-task-internal-id") | .action] | sort
      == ["close_issue","set_column","update_issue"])
    and (.operations | any(.action == "set_column" and .column == "Done"))
    and (.proposals | any(.type == "column_move" and .to == "Held" and .fleet_column == "Done"))
  ' >/dev/null || fail "dry-run must plan issue updates, column moves, and closes for mapped tasks"
  assert_not_contains "$(<"$log")" $'ARG\tPATCH' "dry-run must not update or close a mapped issue"
  assert_not_contains "$(<"$log")" 'mutation(' "dry-run must not move a mapped card"
  jq -e '.tasks["safe-task-internal-id"].baseline.column == "Ready" and (.proposals | length) == 0
    and .synced_at == null' "$home/state/board-sync.json" >/dev/null \
    || fail "dry-run must not mutate baseline or proposal state"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "dry-run reports the complete plan for already-mapped tasks without mutating anything"
}

test_conflict_snaps_to_fleet_and_explains_it() {
  local fixture root home fakebin bearings board log token body output
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" 'Under way'
  token=$(printf '%s' 'safe-task-internal-idaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | shasum -a 256 | awk '{print substr($1,1,8)}')
  body=$(printf 'project: demo-project\nkind: ship\nPR: https://github.com/acme/app/pull/9\n<!-- fm-task: %s -->' "$token")
  write_board "$board" "$(jq -n --arg body "$body" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
    fieldValueByName:{name:"Held",optionId:"held",updatedAt:"2026-08-16T10:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-16T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  jq -n --arg token "$token" '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{"safe-task-internal-id":{token:$token,repo:"captain/fleet",issue_number:1,issue_id:"I_ONE",
      issue_url:"https://github.com/captain/fleet/issues/1",item_id:"PVTI_ONE",
      baseline:{column:"Ready",option_id:"ready",issue_state:"OPEN"}}},
    unmapped_items:{},proposals:[],pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '
    (.proposals | any(.type == "column_move" and .to == "Held" and .fleet_column == "Under way"))
    and (.operations | any(.action == "set_column" and .column == "Under way"
      and (.explanation | contains("retained as a proposal"))))
  ' >/dev/null || fail "both-changed conflict should retain intent and explain the fleet-authoritative snapback"
  assert_contains "$(<"$log")" 'updateProjectV2ItemFieldValue' "conflict must snap the card to fleet state"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "both-changed conflicts preserve the proposal and explain the snapback"
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

test_all_digit_owner_still_reads_the_board() {
  local fixture root home fakebin bearings board log output rc
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  printf '%s\n' '{"owner":"123456","project_number":1,"repo":"123456/fleet"}' \
    > "$home/config/board-sync.json"
  write_bearings "${bearings}.json" Ready
  write_board "$board" "$(jq -n '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
    fieldValueByName:{name:"Held",optionId:"held",updatedAt:"2026-08-16T10:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",
      body:"<!-- fm-task: 12345678 -->",state:"OPEN",
      url:"https://github.com/123456/fleet/issues/1",updatedAt:"2026-08-16T10:00:00Z",
      repository:{nameWithOwner:"123456/fleet",isPrivate:true}}
  }]')"
  jq -n '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{safe:{token:"12345678",repo:"123456/fleet",issue_number:1,issue_id:"I_ONE",
      issue_url:"https://github.com/123456/fleet/issues/1",item_id:"PVTI_ONE",
      baseline:{column:"Ready",option_id:"ready",issue_state:"OPEN"}}},
    unmapped_items:{},proposals:[],pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
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

test_unmapped_card_counts_once_and_again_only_when_it_moves() {
  local fixture root home fakebin bearings board log token body first second third fourth
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  token=$(printf '%s' 'safe-task-internal-idaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | shasum -a 256 | awk '{print substr($1,1,8)}')
  body=$(printf 'project: demo-project\nkind: ship\nPR: https://github.com/acme/app/pull/9\n<!-- fm-task: %s -->' "$token")
  write_board "$board" "$(jq -n --arg body "$body" --arg owned Ready --arg foreign Blocked \
    '[{
      id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
      fieldValueByName:{name:$owned,optionId:"ready",updatedAt:"2026-08-16T10:00:00Z"},
      content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
        url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-16T10:00:00Z",
        repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
    },{
      id:"PVTI_FOREIGN",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
      fieldValueByName:{name:$foreign,optionId:"blocked",updatedAt:"2026-08-16T10:00:00Z"},
      content:{__typename:"Issue",id:"I_FOREIGN",number:9,title:"Hand added card",
        body:"added on the board",state:"OPEN",
        url:"https://github.com/captain/fleet/issues/9",updatedAt:"2026-08-16T10:00:00Z",
        repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
    }]')"
  jq -n --arg token "$token" '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{"safe-task-internal-id":{token:$token,repo:"captain/fleet",issue_number:1,issue_id:"I_ONE",
      issue_url:"https://github.com/captain/fleet/issues/1",item_id:"PVTI_ONE",
      baseline:{column:"Ready",option_id:"ready",issue_state:"OPEN"}}},
    unmapped_items:{},proposals:[],pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"

  first=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$first" = 'board-sync 1 board change(s) pending' ] \
    || fail "a card the sync does not own must wake firstmate once when it first appears"

  run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile >/dev/null
  jq -e '.unmapped_items["PVTI_FOREIGN"].baseline_column == "Blocked"
    and .unmapped_items["PVTI_FOREIGN"].baseline_issue_state == "OPEN"' \
    "$home/state/board-sync.json" >/dev/null \
    || fail "reconcile must record the observed baseline of a card it does not own"

  second=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ -z "$second" ] || fail "an already-reported foreign card must go quiet while it is unchanged"

  write_board "$board" "$(jq -n --arg body "$body" --arg owned Held --arg foreign Blocked \
    '[{
      id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T11:00:00Z",
      fieldValueByName:{name:$owned,optionId:"held",updatedAt:"2026-08-16T11:00:00Z"},
      content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
        url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-16T11:00:00Z",
        repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
    },{
      id:"PVTI_FOREIGN",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
      fieldValueByName:{name:$foreign,optionId:"blocked",updatedAt:"2026-08-16T10:00:00Z"},
      content:{__typename:"Issue",id:"I_FOREIGN",number:9,title:"Hand added card",
        body:"added on the board",state:"OPEN",
        url:"https://github.com/captain/fleet/issues/9",updatedAt:"2026-08-16T10:00:00Z",
        repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
    }]')"
  third=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$third" = 'board-sync 1 board change(s) pending' ] \
    || fail "an unchanged foreign card must not inflate the count of genuinely pending changes"

  write_board "$board" "$(jq -n --arg body "$body" --arg owned Ready --arg foreign Done \
    '[{
      id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T12:00:00Z",
      fieldValueByName:{name:$owned,optionId:"ready",updatedAt:"2026-08-16T12:00:00Z"},
      content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
        url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-16T12:00:00Z",
        repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
    },{
      id:"PVTI_FOREIGN",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T12:00:00Z",
      fieldValueByName:{name:$foreign,optionId:"98236657",updatedAt:"2026-08-16T12:00:00Z"},
      content:{__typename:"Issue",id:"I_FOREIGN",number:9,title:"Hand added card",
        body:"added on the board",state:"OPEN",
        url:"https://github.com/captain/fleet/issues/9",updatedAt:"2026-08-16T12:00:00Z",
        repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
    }]')"
  fourth=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$fourth" = 'board-sync 1 board change(s) pending' ] \
    || fail "a foreign card that actually moves must wake firstmate again"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "a card the sync does not own counts once and then only when it really moves"
}

test_proposals_drain_when_the_divergence_is_gone() {
  local fixture root home fakebin bearings board log token body
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  token=$(printf '%s' 'safe-task-internal-idaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | shasum -a 256 | awk '{print substr($1,1,8)}')
  body=$(printf 'project: demo-project\nkind: ship\nPR: https://github.com/acme/app/pull/9\n<!-- fm-task: %s -->' "$token")
  write_board "$board" "$(jq -n --arg body "$body" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
    fieldValueByName:{name:"Held",optionId:"held",updatedAt:"2026-08-16T10:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-16T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  },{
    id:"PVTI_FOREIGN",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
    fieldValueByName:{name:"Blocked",optionId:"blocked",updatedAt:"2026-08-16T10:00:00Z"},
    content:{__typename:"Issue",id:"I_FOREIGN",number:9,title:"Hand added card",
      body:"added on the board",state:"OPEN",
      url:"https://github.com/captain/fleet/issues/9",updatedAt:"2026-08-16T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  jq -n --arg token "$token" '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{"safe-task-internal-id":{token:$token,repo:"captain/fleet",issue_number:1,issue_id:"I_ONE",
      issue_url:"https://github.com/captain/fleet/issues/1",item_id:"PVTI_ONE",
      baseline:{column:"Ready",option_id:"ready",issue_state:"OPEN"}}},
    unmapped_items:{},proposals:[],pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile >/dev/null
  jq -e '(.proposals | length) == 2
    and (.proposals | any(.type == "column_move"))
    and (.proposals | any(.type == "unmapped_board_item"))' "$home/state/board-sync.json" >/dev/null \
    || fail "reconcile must record one proposal per live divergence"

  # GitHub touches the foreign card without changing what it means, and the captain
  # puts the moved card back where the fleet has it.
  write_board "$board" "$(jq -n --arg body "$body" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T13:00:00Z",
    fieldValueByName:{name:"Ready",optionId:"ready",updatedAt:"2026-08-16T13:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-16T13:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  },{
    id:"PVTI_FOREIGN",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T13:30:00Z",
    fieldValueByName:{name:"Blocked",optionId:"blocked",updatedAt:"2026-08-16T13:30:00Z"},
    content:{__typename:"Issue",id:"I_FOREIGN",number:9,title:"Hand added card",
      body:"added on the board",state:"OPEN",
      url:"https://github.com/captain/fleet/issues/9",updatedAt:"2026-08-16T13:30:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile >/dev/null
  jq -e '(.proposals | map(select(.type == "column_move")) | length) == 0' \
    "$home/state/board-sync.json" >/dev/null \
    || fail "a proposal whose divergence is gone must drain instead of persisting forever"
  jq -e '(.proposals | length) == 1 and (.proposals[0].type == "unmapped_board_item")' \
    "$home/state/board-sync.json" >/dev/null \
    || fail "a still-live foreign card must hold exactly one proposal, not one per GitHub touch"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "proposals drain when their divergence is gone and never accumulate per GitHub touch"
}

test_arm_status_and_disarm
test_arm_leaves_no_unauthenticated_check_when_binding_fails
test_allowlist_and_exclusions
test_exclusion_file_is_a_hard_gate
test_untitled_task_never_publishes_runtime_detail
test_excluded_task_with_a_live_card_is_reported
test_concurrent_reconcile_fails_closed
test_pending_create_recovers_without_duplicating
test_private_repo_is_a_hard_gate
test_dry_run_has_complete_plan_and_no_mutations
test_dry_run_plans_pending_work_for_mapped_tasks
test_poll_prints_only_a_deduplicated_pointer
test_board_move_becomes_proposal_without_fleet_or_snapback_write
test_declined_proposal_stops_rewaking_the_watcher
test_board_move_during_reconcile_is_never_silently_suppressed
test_conflict_snaps_to_fleet_and_explains_it
test_all_digit_owner_still_reads_the_board
test_unmapped_card_counts_once_and_again_only_when_it_moves
test_proposals_drain_when_the_divergence_is_gone
printf 'board-sync tests: %s passed\n' "$TESTS_RUN"
