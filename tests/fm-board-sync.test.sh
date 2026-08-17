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
if [ "${1:-}" = api ] && [ "${2:-}" = --method ] && [ "${3:-}" = GET ] && [ "${4:-}" = search/issues ]; then
  if [ -n "${SEARCH_ISSUES:-}" ]; then
    cat "$SEARCH_ISSUES"
  else
    printf '%s\n' '{"items":[]}'
  fi
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
    GH_REPO="${GH_REPO:-captain/fleet}" SEARCH_ISSUES="${SEARCH_ISSUES:-}" \
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
  printf '\n' >> "$home/state/board-watch.check.sh"
  FM_HOME="$home" "$SCRIPT" status | jq -e '.armed == false' >/dev/null \
    || fail "status must reject a check whose bytes no longer match its trust binding"
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
    unmapped_items:{},pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '
    .escalations | any(contains("task excluded-task-alpha")
      and contains("still holds a live card")
      and contains("https://github.com/captain/fleet/issues/7"))
  ' >/dev/null || fail "an excluded task that still has a card must be reported to the captain"
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
    tasks:{},unmapped_items:{},
    pending:[{task_id:"safe-task-internal-id",token:$token}],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  output=$(REPO_ISSUES="$root/repo-issues.json" \
    run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '.operations | all(.action != "create_issue")' >/dev/null \
    || fail "a pending create must be recovered instead of repeated"
  assert_not_contains "$(<"$log")" $'ARG\tPOST' "a pending create must never mint a second issue"
  jq -e '.tasks["safe-task-internal-id"].issue_number == 55 and (.pending | length) == 0' \
    "$home/state/board-sync.json" >/dev/null \
    || fail "the recovered canonical issue must be rebound and the pending marker cleared"
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
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile --dry-run)
  printf '%s' "$output" | jq -e '
    .dry_run == true
    and ([.operations[].action] == ["create_issue","add_item","set_column"])
    and .operations[0].body == "project: demo-project\nkind: ship\nPR: https://github.com/acme/app/pull/9\n<!-- fm-task: " + (.operations[0].body | capture("fm-task: (?<token>[0-9a-f]{8})").token) + " -->"
  ' >/dev/null || fail "dry-run should show the complete allowlisted create/add/column plan"
  assert_not_contains "$(<"$log")" $'ARG\tPOST' "dry-run must not call issue create mutations"
  assert_not_contains "$(<"$log")" $'ARG\tPATCH' "dry-run must not call issue update mutations"
  assert_not_contains "$(<"$log")" 'mutation(' "dry-run must not call project mutations"
  [ ! -e "$home/state/board-sync.json" ] \
    || fail "dry-run must not initialize persistent mapping state"
  [ ! -e "$home/state/.board-sync.lock" ] \
    || fail "dry-run must not initialize a persistent reconcile lock"
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
    unmapped_items:{},pending:[],excluded_reported:[]
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

test_board_move_is_escalated_without_fleet_or_snapback_write() {
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
    unmapped_items:{},pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '
    (.escalations | any(contains("moved the card from Ready to Held")
      and contains("left where the captain put it")))
    and (.escalations | length == 1)
    and ([.operations[] | select(.action == "set_column")] | length == 0)
  ' >/dev/null || fail "a pure captain move should be escalated once without immediate snapback"
  assert_not_contains "$(<"$log")" 'updateProjectV2ItemFieldValue' "pure pull must not write the fleet column"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "board moves become one escalation line and never direct fleet writes"
}

test_reported_board_move_stops_rewaking_the_watcher() {
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
    unmapped_items:{},pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  first=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$first" = 'board-sync 1 board change(s) pending' ] || fail "the first sweep must wake firstmate"
  run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile >/dev/null
  jq -e '.tasks["safe-task-internal-id"].baseline.column == "Ready"' "$home/state/board-sync.json" >/dev/null \
    || fail "an unapplied board move must not silently advance the fleet baseline"
  second=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ -z "$second" ] || fail "a reported but unapplied board move must not re-wake every sweep"
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
  pass "an already-reported board move stops re-waking the watcher while a new move still wakes it"
}

test_board_move_during_reconcile_is_never_silently_suppressed() {
  local fixture root home fakebin bearings board after log token body woke output
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
    unmapped_items:{},pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  output=$(BOARD_FIXTURE_AFTER="$after" run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '.escalations | all(contains("Held") | not)' >/dev/null \
    || fail "a move arriving after the reported read must not be back-dated into this run's escalations"
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
    unmapped_items:{},pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile --dry-run)
  printf '%s' "$output" | jq -e '
    .dry_run == true
    and ([.operations[] | select(.task_id == "safe-task-internal-id") | .action] | sort
      == ["close_issue","set_column","update_issue"])
    and (.operations | any(.action == "set_column" and .column == "Done"))
    and (.escalations | any(contains("moved the card from Ready to Held")
      and contains("the fleet advanced to Done")))
  ' >/dev/null || fail "dry-run must plan issue updates, column moves, and closes for mapped tasks"
  assert_not_contains "$(<"$log")" $'ARG\tPATCH' "dry-run must not update or close a mapped issue"
  assert_not_contains "$(<"$log")" 'mutation(' "dry-run must not move a mapped card"
  jq -e '.tasks["safe-task-internal-id"].baseline.column == "Ready" and .synced_at == null' \
    "$home/state/board-sync.json" >/dev/null \
    || fail "dry-run must not mutate baseline state"
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
    unmapped_items:{},pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '
    (.escalations | any(contains("moved the card from Ready to Held")
      and contains("the fleet advanced to Under way")
      and contains("set back to Under way")))
    and (.operations | any(.action == "set_column" and .column == "Under way"
      and (.explanation | contains("moved back to Under way"))
      and (.explanation | contains("proposal") | not)))
  ' >/dev/null || fail "both-changed conflict must escalate the board move and explain the snapback truthfully"
  assert_contains "$(<"$log")" 'updateProjectV2ItemFieldValue' "conflict must snap the card to fleet state"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "both-changed conflicts escalate the board move and explain the snapback in the same run"
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
    unmapped_items:{},pending:[],excluded_reported:[]
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
    unmapped_items:{},pending:[],excluded_reported:[]
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

test_escalations_report_only_what_the_run_observes() {
  local fixture root home fakebin bearings board log token body output
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
    unmapped_items:{},pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '
    (.escalations | length == 2)
    and (.escalations | any(contains("moved the card from Ready to Held")))
    and (.escalations | any(contains("board item PVTI_FOREIGN")
      and contains("captain-intent request")))
  ' >/dev/null || fail "reconcile must report each observed board change exactly once"

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
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '.escalations | length == 0' >/dev/null \
    || fail "a board change the captain has undone must not be reported again"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "each run escalates only the board changes it actually observes"
}

test_excluded_carded_report_retires_once_the_card_is_gone() {
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
    unmapped_items:{},pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e \
    '.escalations | any(contains("task excluded-task-alpha") and contains("still holds a live card"))' \
    >/dev/null || fail "an excluded task must be reported while its card is still live on the board"

  # The captain does the one thing the report asks and retracts the card by hand.
  write_board "$board" '[]'
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '.escalations | all(contains("still holds a live card") | not)' >/dev/null \
    || fail "the report must retire once the excluded card is actually gone"
  assert_not_contains "$(<"$log")" 'deleteProjectV2Item' "retiring the report must never delete a card"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "an excluded-task card report retires once the captain has retracted the card"
}

test_bare_github_touch_never_rewakes_the_poll() {
  local fixture root home fakebin bearings board log token body first second
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  token=$(printf '%s' 'safe-task-internal-idaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | shasum -a 256 | awk '{print substr($1,1,8)}')
  body=$(printf 'project: demo-project\nkind: ship\nPR: https://github.com/acme/app/pull/9\n<!-- fm-task: %s -->' "$token")
  write_board "$board" "$(jq -n --arg body "$body" --arg touched "2026-08-16T10:00:00Z" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
    fieldValueByName:{name:"Ready",optionId:"ready",updatedAt:"2026-08-16T10:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-16T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  },{
    id:"PVTI_FOREIGN",type:"ISSUE",isArchived:false,updatedAt:$touched,
    fieldValueByName:{name:"Blocked",optionId:"blocked",updatedAt:$touched},
    content:{__typename:"Issue",id:"I_FOREIGN",number:9,title:"Hand added card",
      body:"added on the board",state:"OPEN",
      url:"https://github.com/captain/fleet/issues/9",updatedAt:$touched,
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  jq -n --arg token "$token" '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{"safe-task-internal-id":{token:$token,repo:"captain/fleet",issue_number:1,issue_id:"I_ONE",
      issue_url:"https://github.com/captain/fleet/issues/1",item_id:"PVTI_ONE",
      baseline:{column:"Ready",option_id:"ready",issue_state:"OPEN"}}},
    unmapped_items:{},pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  first=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$first" = 'board-sync 1 board change(s) pending' ] \
    || fail "a card the sync does not own must wake firstmate when it first appears"

  # GitHub touches the card without changing its column or issue state.
  write_board "$board" "$(jq -n --arg body "$body" --arg touched "2026-08-17T04:45:12Z" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
    fieldValueByName:{name:"Ready",optionId:"ready",updatedAt:"2026-08-16T10:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-16T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  },{
    id:"PVTI_FOREIGN",type:"ISSUE",isArchived:false,updatedAt:$touched,
    fieldValueByName:{name:"Blocked",optionId:"blocked",updatedAt:$touched},
    content:{__typename:"Issue",id:"I_FOREIGN",number:9,title:"Hand added card",
      body:"added on the board",state:"OPEN",
      url:"https://github.com/captain/fleet/issues/9",updatedAt:$touched,
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  second=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ -z "$second" ] \
    || fail "a GitHub touch that changes no column or issue state must not wake firstmate again"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "the poll signature ignores GitHub timestamps, so a bare touch never re-wakes the watcher"
}

test_unmapped_change_during_reconcile_is_never_silently_absorbed() {
  local fixture root home fakebin bearings board after log token body woke
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  after="$root/board-after.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  token=$(printf '%s' 'safe-task-internal-idaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | shasum -a 256 | awk '{print substr($1,1,8)}')
  body=$(printf 'project: demo-project\nkind: ship\nPR: https://github.com/acme/app/pull/9\n<!-- fm-task: %s -->' "$token")
  # The read reconcile reports shows the foreign card in Ready and no second foreign card.
  write_board "$board" "$(jq -n --arg body "$body" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
    fieldValueByName:{name:"Ready",optionId:"ready",updatedAt:"2026-08-16T10:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-16T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  },{
    id:"PVTI_FOREIGN",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
    fieldValueByName:{name:"Ready",optionId:"ready",updatedAt:"2026-08-16T10:00:00Z"},
    content:{__typename:"Issue",id:"I_FOREIGN",number:9,title:"Hand added card",
      body:"added on the board",state:"OPEN",
      url:"https://github.com/captain/fleet/issues/9",updatedAt:"2026-08-16T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  # The captain drags that card and adds another one after the reported read but
  # before reconcile's post-write re-read.
  write_board "$after" "$(jq -n --arg body "$body" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
    fieldValueByName:{name:"Ready",optionId:"ready",updatedAt:"2026-08-16T10:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-16T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  },{
    id:"PVTI_FOREIGN",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:05:00Z",
    fieldValueByName:{name:"Done",optionId:"98236657",updatedAt:"2026-08-16T10:05:00Z"},
    content:{__typename:"Issue",id:"I_FOREIGN",number:9,title:"Hand added card",
      body:"added on the board",state:"OPEN",
      url:"https://github.com/captain/fleet/issues/9",updatedAt:"2026-08-16T10:05:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  },{
    id:"PVTI_LATE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:06:00Z",
    fieldValueByName:{name:"Held",optionId:"held",updatedAt:"2026-08-16T10:06:00Z"},
    content:{__typename:"Issue",id:"I_LATE",number:10,title:"Card added mid reconcile",
      body:"added on the board",state:"OPEN",
      url:"https://github.com/captain/fleet/issues/10",updatedAt:"2026-08-16T10:06:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  jq -n --arg token "$token" '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{"safe-task-internal-id":{token:$token,repo:"captain/fleet",issue_number:1,issue_id:"I_ONE",
      issue_url:"https://github.com/captain/fleet/issues/1",item_id:"PVTI_ONE",
      baseline:{column:"Ready",option_id:"ready",issue_state:"OPEN"}}},
    unmapped_items:{},pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  BOARD_FIXTURE_AFTER="$after" run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile >/dev/null
  jq -e '.unmapped_items["PVTI_FOREIGN"].baseline_column == "Ready"' "$home/state/board-sync.json" >/dev/null \
    || fail "the unmapped baseline must record the column this run reported, not one that arrived later"
  jq -e '.unmapped_items | has("PVTI_LATE") | not' "$home/state/board-sync.json" >/dev/null \
    || fail "a card that appeared inside the reconcile window must not be baselined as already reported"
  woke=$(BOARD_FIXTURE_AFTER="$after" run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$woke" = 'board-sync 2 board change(s) pending' ] \
    || fail "foreign-card changes landing inside the reconcile window must still wake firstmate"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "a foreign card changed or added mid-reconcile is never silently absorbed into the baseline"
}

test_snapback_over_unrecorded_baseline_is_escalated() {
  local fixture root home fakebin bearings board log token body output
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
  # A reconcile that died between recording the mapping and writing the baseline
  # leaves the mapping with no agreed column at all.
  jq -n --arg token "$token" '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{"safe-task-internal-id":{token:$token,repo:"captain/fleet",issue_number:1,issue_id:"I_ONE",
      issue_url:"https://github.com/captain/fleet/issues/1",item_id:"PVTI_ONE",baseline:null}},
    unmapped_items:{},pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '
    (.operations | any(.action == "set_column" and .task_id == "safe-task-internal-id"
      and .column == "Ready"))
    and (.escalations | any(contains("task safe-task-internal-id")
      and contains("no agreed board column is recorded")
      and contains("the card at Held was set to the fleet column Ready")))
    and (.escalations | all(contains("the captain moved the card") | not))
  ' >/dev/null || fail "a write over an unrecorded baseline must be escalated without claiming a captain move"
  assert_contains "$(<"$log")" 'updateProjectV2ItemFieldValue' \
    "the card is still set to the fleet column"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "a write over an unrecorded baseline is escalated without inventing a captain move"
}

test_cleared_status_is_escalated_in_the_run_that_restores_it() {
  local fixture root home fakebin bearings board log token body output woke
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  token=$(printf '%s' 'safe-task-internal-idaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | shasum -a 256 | awk '{print substr($1,1,8)}')
  body=$(printf 'project: demo-project\nkind: ship\nPR: https://github.com/acme/app/pull/9\n<!-- fm-task: %s -->' "$token")
  # The captain dragged the card into the "No Status" group, so the field reads null.
  write_board "$board" "$(jq -n --arg body "$body" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
    fieldValueByName:null,
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-16T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  jq -n --arg token "$token" '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{"safe-task-internal-id":{token:$token,repo:"captain/fleet",issue_number:1,issue_id:"I_ONE",
      issue_url:"https://github.com/captain/fleet/issues/1",item_id:"PVTI_ONE",
      baseline:{column:"Ready",option_id:"ready",issue_state:"OPEN"}}},
    unmapped_items:{},pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  woke=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$woke" = 'board-sync 1 board change(s) pending' ] || fail "a cleared Status must wake firstmate"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '
    (.operations | any(.action == "set_column" and .task_id == "safe-task-internal-id"
      and .column == "Ready"))
    and (.escalations | any(contains("task safe-task-internal-id")
      and contains("cleared the board Status that was Ready")
      and contains("set back to the fleet column Ready")))
  ' >/dev/null || fail "a cleared Status must be escalated by the same run that restores the column"
  assert_contains "$(<"$log")" 'updateProjectV2ItemFieldValue' "the cleared card must be given the fleet column"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "a cleared board Status is escalated by the same run that sets the column back"
}

test_archived_card_is_escalated_and_left_untouched() {
  local fixture root home fakebin bearings board log token body output woke quiet
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" 'Under way'
  token=$(printf '%s' 'safe-task-internal-idaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | shasum -a 256 | awk '{print substr($1,1,8)}')
  body=$(printf 'project: demo-project\nkind: ship\nPR: https://github.com/acme/app/pull/9\n<!-- fm-task: %s -->' "$token")
  # The captain archived, moved, and closed the card before this observation.
  write_board "$board" "$(jq -n --arg body "$body" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:true,updatedAt:"2026-08-16T10:00:00Z",
    fieldValueByName:{name:"Ready",optionId:"ready",updatedAt:"2026-08-16T10:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"CLOSED",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-16T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  jq -n --arg token "$token" '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{"safe-task-internal-id":{token:$token,repo:"captain/fleet",issue_number:1,issue_id:"I_ONE",
      issue_url:"https://github.com/captain/fleet/issues/1",item_id:"PVTI_ONE",
      baseline:{column:"Ready",option_id:"ready",issue_state:"OPEN"}}},
    unmapped_items:{},pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  woke=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$woke" = 'board-sync 1 board change(s) pending' ] \
    || fail "an archived mapped card must not be invisible to the poll"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '
    (.escalations | length == 1)
    and (.escalations[0] | contains("task safe-task-internal-id")
      and contains("the board card is archived"))
    and (.operations | all(.task_id != "safe-task-internal-id"))
  ' >/dev/null || fail "an archive must supersede simultaneous move and close details"
  assert_not_contains "$(<"$log")" 'updateProjectV2ItemFieldValue' "an archived card must not be written to"
  assert_not_contains "$(<"$log")" 'addProjectV2ItemById' "an archived card must never be auto-unarchived"
  assert_not_contains "$(<"$log")" 'deleteProjectV2Item' "an archived card must never be deleted"
  jq -e '.tasks["safe-task-internal-id"].baseline.archived == true
    and .tasks["safe-task-internal-id"].baseline.column == "Ready"
    and .tasks["safe-task-internal-id"].baseline.issue_state == "CLOSED"' \
    "$home/state/board-sync.json" >/dev/null \
    || fail "the observed archived state and column must be recorded independently of fleet state"
  woke=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ -z "$woke" ] \
    || fail "an archived card the run already reported must stop counting as pending forever"
  quiet=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$quiet" | jq -e '.escalations | length == 0' >/dev/null \
    || fail "an unchanged archived card must be escalated only once"

  # Unarchiving it is a genuine board change, so it must wake firstmate again.
  write_board "$board" "$(jq -n --arg body "$body" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T12:00:00Z",
    fieldValueByName:{name:"Ready",optionId:"ready",updatedAt:"2026-08-16T12:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-16T12:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  woke=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$woke" = 'board-sync 1 board change(s) pending' ] \
    || fail "unarchiving the card must wake firstmate again"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "an off-column archived card is escalated once and never written, unarchived, or deleted"
}

test_forward_column_write_is_not_reported_as_a_snapback() {
  local fixture root home fakebin bearings board log token body output
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" 'Under way'
  token=$(printf '%s' 'safe-task-internal-idaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | shasum -a 256 | awk '{print substr($1,1,8)}')
  body=$(printf 'project: demo-project\nkind: ship\nPR: https://github.com/acme/app/pull/9\n<!-- fm-task: %s -->' "$token")
  # The board still holds the last agreed column; only the fleet advanced.
  write_board "$board" "$(jq -n --arg body "$body" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
    fieldValueByName:{name:"Ready",optionId:"ready",updatedAt:"2026-08-16T10:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-16T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  jq -n --arg token "$token" '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{"safe-task-internal-id":{token:$token,repo:"captain/fleet",issue_number:1,issue_id:"I_ONE",
      issue_url:"https://github.com/captain/fleet/issues/1",item_id:"PVTI_ONE",
      baseline:{column:"Ready",option_id:"ready",issue_state:"OPEN"}}},
    unmapped_items:{},pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '
    (.operations | any(.action == "set_column" and .column == "Under way"
      and (.explanation | contains("set to Under way to match fleet state"))
      and (.explanation | contains("moved back") | not)))
    and (.escalations | length == 0)
  ' >/dev/null || fail "an ordinary forward write must not be described as a snapback or escalated"
  assert_contains "$(<"$log")" 'updateProjectV2ItemFieldValue' "the fleet column must still reach the board"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "an ordinary forward column write is never reported as a snapback"
}

test_new_board_card_is_reported_as_captain_intent() {
  local fixture root home fakebin bearings board log token body output
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  token=$(printf '%s' 'safe-task-internal-idaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | shasum -a 256 | awk '{print substr($1,1,8)}')
  body=$(printf 'project: demo-project\nkind: ship\nPR: https://github.com/acme/app/pull/9\n<!-- fm-task: %s -->' "$token")
  write_board "$board" "$(jq -n --arg body "$body" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
    fieldValueByName:{name:"Ready",optionId:"ready",updatedAt:"2026-08-16T10:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-16T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  },{
    id:"PVTI_NEWCARD",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
    fieldValueByName:{name:"Blocked",optionId:"blocked",updatedAt:"2026-08-16T10:00:00Z"},
    content:{__typename:"Issue",id:"I_NEWCARD",number:12,title:"Captain filed this by hand",
      body:"filed on the board",state:"OPEN",
      url:"https://github.com/other/project/issues/12",updatedAt:"2026-08-16T10:00:00Z",
      repository:{nameWithOwner:"other/project",isPrivate:true}}
  }]')"
  jq -n --arg token "$token" '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{"safe-task-internal-id":{token:$token,repo:"captain/fleet",issue_number:1,issue_id:"I_ONE",
      issue_url:"https://github.com/captain/fleet/issues/1",item_id:"PVTI_ONE",
      baseline:{column:"Ready",option_id:"ready",issue_state:"OPEN"}}},
    unmapped_items:{},pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '
    (.escalations | length == 1)
    and (.escalations[0] | contains("board item PVTI_NEWCARD")
      and contains("Captain filed this by hand")
      and contains("captain-intent request"))
  ' >/dev/null || fail "a new manual card must be reported as one captain-intent request"
  assert_not_contains "$(<"$log")" $'ARG\tPATCH' "reporting captain intent must not alter its issue"
  assert_not_contains "$(<"$log")" 'deleteProjectV2Item' "reporting captain intent must never delete anything"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "a brand-new manual card is left untouched and reported as captain intent"
}

test_hand_filed_card_never_binds_to_a_fleet_task() {
  local fixture root home fakebin bearings board log output token captain_body
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  token=$(printf '%s' 'safe-task-internal-idaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | shasum -a 256 | awk '{print substr($1,1,8)}')
  captain_body=$(printf 'filed on the board by hand\n\nsecond paragraph the captain wrote\n\n<!-- fm-task: %s -->' "$token")
  write_board "$board" "$(jq -n --arg body "$captain_body" '[{
    id:"PVTI_CAPTAIN",type:"ISSUE",isArchived:false,updatedAt:"2026-08-17T10:00:00Z",
    fieldValueByName:{name:"Blocked",optionId:"blocked",updatedAt:"2026-08-17T10:00:00Z"},
    content:{__typename:"Issue",id:"I_CAPTAIN",number:21,title:"Safe board title",
      body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/21",updatedAt:"2026-08-17T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  jq -n --arg body "$captain_body" '{items:[{
    number:21,id:21,node_id:"I_CAPTAIN",
    html_url:"https://github.com/captain/fleet/issues/21",
    url:"https://api.github.com/repos/captain/fleet/issues/21",
    title:"Safe board title",body:$body,state:"open",
    repository_url:"https://api.github.com/repos/captain/fleet"
  }]}' > "$root/search.json"
  jq -n --arg token "$token" '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{"safe-task-internal-id":{token:$token,repo:"captain/fleet",issue_number:21,
      issue_id:"I_CAPTAIN",issue_url:"https://github.com/captain/fleet/issues/21",
      item_id:"PVTI_CAPTAIN",origin:"captain",baseline:null}},
    unmapped_items:{},pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  output=$(SEARCH_ISSUES="$root/search.json" \
    run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  assert_contains "$(<"$log")" $'ARG\tPOST' \
    "a captain-authored token match must not prevent creating the canonical issue"
  printf '%s' "$output" | jq -e '
    (.operations | any(.action == "create_issue" and .task_id == "safe-task-internal-id"))
    and (.operations | any(.action == "add_item" and .task_id == "safe-task-internal-id"))
    and (.escalations | any(contains("board item PVTI_CAPTAIN")
      and contains("captain-intent request")))
  ' >/dev/null || fail "a manual card must remain separate from the canonical fleet card"
  jq -e '.tasks["safe-task-internal-id"].issue_number == 101
    and .tasks["safe-task-internal-id"].item_id == "PVTI_NEW"
    and .tasks["safe-task-internal-id"].issue_id == "I_NEW"' \
    "$home/state/board-sync.json" >/dev/null \
    || fail "the mapping must point only at the Firstmate-created canonical card"
  assert_not_contains "$(<"$log")" $'ARG\tPATCH' "a manual issue must never be rebound or rewritten"
  assert_not_contains "$(<"$log")" 'deleteProjectV2Item' "a manual card must never be deleted"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "a hand-filed card stays untouched while its fleet task gets a canonical card"
}

test_reAdded_card_under_a_new_item_id_still_reconciles() {
  local fixture root home fakebin bearings board log token body output
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" 'Under way'
  token=$(printf '%s' 'safe-task-internal-idaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | shasum -a 256 | awk '{print substr($1,1,8)}')
  body=$(printf 'project: demo-project\nkind: ship\nPR: https://github.com/acme/app/pull/9\n<!-- fm-task: %s -->' "$token")
  # The captain removed the card and re-added the same issue, which mints a new item id.
  write_board "$board" "$(jq -n --arg body "$body" '[{
    id:"PVTI_REBOUND",type:"ISSUE",isArchived:false,updatedAt:"2026-08-17T10:00:00Z",
    fieldValueByName:null,
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-17T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  jq -n --arg token "$token" '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{"safe-task-internal-id":{token:$token,repo:"captain/fleet",issue_number:1,issue_id:"I_ONE",
      issue_url:"https://github.com/captain/fleet/issues/1",item_id:"PVTI_STALE",
      baseline:{column:"Ready",option_id:"ready",issue_state:"OPEN"}}},
    unmapped_items:{},pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '.operations | any(.action == "set_column" and .column == "Under way")' \
    >/dev/null || fail "a card re-added under a new item id must still be synced to the fleet column"
  jq -e '.tasks["safe-task-internal-id"].item_id == "PVTI_REBOUND"' "$home/state/board-sync.json" >/dev/null \
    || fail "the stored mapping must use the item id the run actually resolved"
  printf '%s' "$output" | jq -e \
    '.escalations | all(contains("board item PVTI_REBOUND") | not)' >/dev/null \
    || fail "the re-added canonical card must not be reported as unowned"
  assert_contains "$(<"$log")" 'PVTI_REBOUND' "the column write must target the live item id"
  assert_not_contains "$(<"$log")" 'PVTI_STALE' "no GitHub call may target the stale item id"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "a card re-added under a new item id reconciles and rebinds instead of wedging"
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

test_draft_card_is_left_manual_while_canonical_card_is_created() {
  local fixture root home fakebin bearings board log output
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  write_board "$board" "$(jq -n '[{
    id:"PVTI_DRAFT",type:"DRAFT_ISSUE",isArchived:false,updatedAt:"2026-08-17T10:00:00Z",
    fieldValueByName:{name:"Blocked",optionId:"blocked",updatedAt:"2026-08-17T10:00:00Z"},
    content:{__typename:"DraftIssue",title:"Safe board title"}
  }]')"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  assert_contains "$(<"$log")" $'ARG\tPOST' "a manual draft must not replace the canonical issue"
  printf '%s' "$output" | jq -e '
    (.escalations | any(contains("board item PVTI_DRAFT")
      and contains("captain-intent request")))
    and (.operations | any(.action == "create_issue" and .task_id == "safe-task-internal-id"))
  ' >/dev/null || fail "a draft must stay manual while the fleet task gets a canonical card"
  jq -e '.tasks["safe-task-internal-id"].item_id == "PVTI_NEW"' "$home/state/board-sync.json" >/dev/null \
    || fail "the draft must not become the task mapping"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "a manual draft stays untouched while the fleet task gets a canonical card"
}

test_mapping_retires_once_its_card_is_legitimately_gone() {
  local fixture root home fakebin bearings board log token body output quiet
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  token=$(printf '%s' 'safe-task-internal-idaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | shasum -a 256 | awk '{print substr($1,1,8)}')
  body=$(printf 'project: demo-project\nkind: ship\nPR: https://github.com/acme/app/pull/9\n<!-- fm-task: %s -->' "$token")
  write_board "$board" "$(jq -n --arg body "$body" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
    fieldValueByName:{name:"Ready",optionId:"ready",updatedAt:"2026-08-16T10:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-16T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  },{
    id:"PVTI_EXCLUDED",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
    fieldValueByName:{name:"Ready",optionId:"ready",updatedAt:"2026-08-16T10:00:00Z"},
    content:{__typename:"Issue",id:"I_EXCLUDED",number:7,title:"CROWN_JEWELS unannounced strategy",
      body:"<!-- fm-task: deadbeef -->",state:"OPEN",
      url:"https://github.com/captain/fleet/issues/7",updatedAt:"2026-08-16T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  jq -n --arg token "$token" '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{
      "safe-task-internal-id":{token:$token,repo:"captain/fleet",issue_number:1,issue_id:"I_ONE",
        issue_url:"https://github.com/captain/fleet/issues/1",item_id:"PVTI_ONE",
        baseline:{column:"Ready",option_id:"ready",issue_state:"OPEN"}},
      "excluded-task-alpha":{token:"deadbeef",repo:"captain/fleet",issue_number:7,issue_id:"I_EXCLUDED",
        issue_url:"https://github.com/captain/fleet/issues/7",item_id:"PVTI_EXCLUDED",
        baseline:{column:"Ready",option_id:"ready",issue_state:"OPEN"}}},
    unmapped_items:{},pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"

  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e \
    '.escalations | any(contains("task excluded-task-alpha") and contains("still holds a live card"))' \
    >/dev/null || fail "an excluded task whose card is still live must be escalated"
  jq -e '.tasks | has("excluded-task-alpha")' "$home/state/board-sync.json" >/dev/null \
    || fail "a mapping whose card is still live must NOT be retired"
  quiet=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ -z "$quiet" ] || fail "a board matching every baseline must leave the poll quiet"

  # The captain does exactly what the escalation asked and retracts the excluded card.
  write_board "$board" "$(jq -n --arg body "$body" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
    fieldValueByName:{name:"Ready",optionId:"ready",updatedAt:"2026-08-16T10:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-16T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '.escalations | all(contains("still holds a live card") | not)' >/dev/null \
    || fail "the escalation must stop once the excluded card is gone"
  jq -e '.tasks | has("excluded-task-alpha") | not' "$home/state/board-sync.json" >/dev/null \
    || fail "a mapping the sync no longer owns and whose card is gone must be retired"
  FM_HOME="$home" "$SCRIPT" status | jq -e '.mapped_tasks == 1' >/dev/null \
    || fail "status must report only the mappings the sync still holds"
  quiet=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ -z "$quiet" ] || fail "the pending pointer must return to zero once the retracted card is retired"
  assert_not_contains "$(<"$log")" 'deleteProjectV2Item' "retirement must never delete a card"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "a mapping retires once the sync no longer owns it and its card is gone"
}

test_removed_card_is_escalated_once_and_truthfully() {
  local fixture root home fakebin bearings board log token body output
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  token=$(printf '%s' 'safe-task-internal-idaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | shasum -a 256 | awk '{print substr($1,1,8)}')
  body=$(printf 'project: demo-project\nkind: ship\nPR: https://github.com/acme/app/pull/9\n<!-- fm-task: %s -->' "$token")
  # The captain removed the card from the project; the issue itself still exists.
  write_board "$board" '[]'
  jq -n --arg token "$token" '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{"safe-task-internal-id":{token:$token,repo:"captain/fleet",issue_number:1,issue_id:"I_ONE",
      issue_url:"https://github.com/captain/fleet/issues/1",item_id:"PVTI_ONE",
      baseline:{column:"Ready",option_id:"ready",issue_state:"OPEN"}}},
    unmapped_items:{},pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  : "$body"
  output=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '
    (.escalations | length == 1)
    and (.escalations[0] | contains("task safe-task-internal-id")
      and contains("the card was gone from the board")
      and contains("put back at the fleet column Ready"))
    and (.escalations | all(contains("cleared the board Status") | not))
    and (.escalations | all(contains("the captain moved the card") | not))
  ' >/dev/null || fail "a removed card must produce exactly one truthful escalation"
  printf '%s' "$output" | jq -e '
    .operations | any(.action == "set_column" and .column == "Ready"
      and (.explanation | contains("set to Ready to match fleet state"))
      and (.explanation | contains("moved back") | not))
  ' >/dev/null || fail "restoring a removed card is a forward write, not a snapback"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "a card removed from the board is escalated exactly once and never as a cleared Status"
}

test_archive_during_reconcile_is_not_absorbed() {
  local fixture root home fakebin bearings board after log token body output woke
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  after="$root/board-after.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  token=$(printf '%s' 'safe-task-internal-idaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | shasum -a 256 | awk '{print substr($1,1,8)}')
  body=$(printf 'project: demo-project\nkind: ship\nPR: https://github.com/acme/app/pull/9\n<!-- fm-task: %s -->' "$token")
  write_board "$board" "$(jq -n --arg body "$body" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-17T10:00:00Z",
    fieldValueByName:{name:"Ready",optionId:"ready",updatedAt:"2026-08-17T10:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-17T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  write_board "$after" "$(jq -n --arg body "$body" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:true,updatedAt:"2026-08-17T10:05:00Z",
    fieldValueByName:{name:"Ready",optionId:"ready",updatedAt:"2026-08-17T10:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-17T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  jq -n --arg token "$token" '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{"safe-task-internal-id":{token:$token,repo:"captain/fleet",issue_number:1,issue_id:"I_ONE",
      issue_url:"https://github.com/captain/fleet/issues/1",item_id:"PVTI_ONE",
      baseline:{column:"Ready",option_id:"ready",issue_state:"OPEN",archived:false}}},
    unmapped_items:{},pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  output=$(BOARD_FIXTURE_AFTER="$after" run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '.escalations | length == 0' >/dev/null \
    || fail "an archive that arrived after the reported read must not be claimed by that run"
  jq -e '.tasks["safe-task-internal-id"].baseline.archived == false' \
    "$home/state/board-sync.json" >/dev/null \
    || fail "a mid-reconcile archive must not be absorbed into the reported baseline"
  cp "$after" "$board"
  woke=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$woke" = 'board-sync 1 board change(s) pending' ] \
    || fail "a mid-reconcile archive must wake firstmate on the next poll"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "an archive arriving mid-reconcile remains pending for the next poll"
}

test_unarchive_during_reconcile_has_a_distinct_signature() {
  local fixture root home fakebin bearings board after log token body output woke
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  after="$root/board-after.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  token=$(printf '%s' 'safe-task-internal-idaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | shasum -a 256 | awk '{print substr($1,1,8)}')
  body=$(printf 'project: demo-project\nkind: ship\nPR: https://github.com/acme/app/pull/9\n<!-- fm-task: %s -->' "$token")
  write_board "$board" "$(jq -n --arg body "$body" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:true,updatedAt:"2026-08-17T10:00:00Z",
    fieldValueByName:{name:"Ready",optionId:"ready",updatedAt:"2026-08-17T10:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-17T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  write_board "$after" "$(jq -n --arg body "$body" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-17T10:05:00Z",
    fieldValueByName:{name:"Ready",optionId:"ready",updatedAt:"2026-08-17T10:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-17T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  jq -n --arg token "$token" '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{"safe-task-internal-id":{token:$token,repo:"captain/fleet",issue_number:1,issue_id:"I_ONE",
      issue_url:"https://github.com/captain/fleet/issues/1",item_id:"PVTI_ONE",
      baseline:{column:"Ready",option_id:"ready",issue_state:"OPEN",archived:false}}},
    unmapped_items:{},pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  output=$(BOARD_FIXTURE_AFTER="$after" run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '.escalations | length == 1' >/dev/null \
    || fail "the observed archive must be reported by its reconcile pass"
  cp "$after" "$board"
  woke=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$woke" = 'board-sync 1 board change(s) pending' ] \
    || fail "an unarchive arriving after an archive report must retain a distinct pending signature"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "opposite archive transitions never collide in poll signatures"
}

test_issue_close_during_reconcile_is_not_absorbed() {
  local fixture root home fakebin bearings board after log token body output woke
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  after="$root/board-after.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  token=$(printf '%s' 'safe-task-internal-idaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | shasum -a 256 | awk '{print substr($1,1,8)}')
  body=$(printf 'project: demo-project\nkind: ship\nPR: https://github.com/acme/app/pull/9\n<!-- fm-task: %s -->' "$token")
  write_board "$board" "$(jq -n --arg body "$body" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-17T10:00:00Z",
    fieldValueByName:{name:"Ready",optionId:"ready",updatedAt:"2026-08-17T10:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-17T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  write_board "$after" "$(jq -n --arg body "$body" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-17T10:05:00Z",
    fieldValueByName:{name:"Ready",optionId:"ready",updatedAt:"2026-08-17T10:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"CLOSED",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-17T10:05:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  jq -n --arg token "$token" '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{"safe-task-internal-id":{token:$token,repo:"captain/fleet",issue_number:1,issue_id:"I_ONE",
      issue_url:"https://github.com/captain/fleet/issues/1",item_id:"PVTI_ONE",
      baseline:{column:"Ready",option_id:"ready",issue_state:"OPEN",archived:false}}},
    unmapped_items:{},pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  output=$(BOARD_FIXTURE_AFTER="$after" run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile)
  printf '%s' "$output" | jq -e '.escalations | length == 0' >/dev/null \
    || fail "a close that arrived after the reported read must not be claimed by that run"
  jq -e '.tasks["safe-task-internal-id"].baseline.issue_state == "OPEN"' \
    "$home/state/board-sync.json" >/dev/null \
    || fail "a mid-reconcile issue close must not be absorbed into the reported baseline"
  cp "$after" "$board"
  woke=$(run_sync "$home" "$fakebin" "$bearings" "$board" "$log" poll)
  [ "$woke" = 'board-sync 1 board change(s) pending' ] \
    || fail "a mid-reconcile issue close must wake firstmate on the next poll"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "an issue close arriving mid-reconcile remains pending for the next poll"
}

test_dry_run_recovers_only_allowlisted_canonical_card() {
  local fixture root home fakebin bearings board log token body output
  fixture=$(make_fixture)
  IFS=$'\t' read -r root home fakebin bearings <<< "$fixture"
  board="$root/board.json"
  log="$root/gh.log"
  write_bearings "${bearings}.json" Ready
  token=$(printf '%s' 'safe-task-internal-idaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | shasum -a 256 | awk '{print substr($1,1,8)}')
  body=$(printf 'project: demo-project\nkind: ship\nPR: https://github.com/acme/app/pull/9\n<!-- fm-task: %s -->' "$token")
  write_board "$board" "$(jq -n --arg body "$body" '[{
    id:"PVTI_ONE",type:"ISSUE",isArchived:false,updatedAt:"2026-08-16T10:00:00Z",
    fieldValueByName:{name:"Ready",optionId:"ready",updatedAt:"2026-08-16T10:00:00Z"},
    content:{__typename:"Issue",id:"I_ONE",number:1,title:"Safe board title",body:$body,state:"OPEN",
      url:"https://github.com/captain/fleet/issues/1",updatedAt:"2026-08-16T10:00:00Z",
      repository:{nameWithOwner:"captain/fleet",isPrivate:true}}
  }]')"
  # The mapping was lost, but the token still joins the task to its existing issue.
  jq -n --arg body "$body" '{items:[{
    number:1,id:1,node_id:"I_ONE",
    html_url:"https://github.com/captain/fleet/issues/1",
    url:"https://api.github.com/repos/captain/fleet/issues/1",
    title:"Safe board title",body:$body,state:"open",
    repository_url:"https://api.github.com/repos/captain/fleet"
  }]}' > "$root/search.json"
  jq -n '{
    schema:"fm-board-sync.v1",salt:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",project:{},synced_at:null,
    tasks:{},unmapped_items:{},pending:[],excluded_reported:[]
  }' > "$home/state/board-sync.json"
  output=$(SEARCH_ISSUES="$root/search.json" \
    run_sync "$home" "$fakebin" "$bearings" "$board" "$log" reconcile --dry-run)
  printf '%s' "$output" | jq -e '
    .dry_run == true
    and (.operations | all(.action != "create_issue"))
    and (.operations | all(.action != "add_item"))
    and (.operations | all(.action != "set_column"))
  ' >/dev/null || fail "dry-run must recover an exact canonical card without redundant operations"
  assert_not_contains "$(<"$log")" $'ARG\tPOST' "dry-run must not create anything"
  assert_not_contains "$(<"$log")" $'ARG\tPATCH' "dry-run must not update anything"
  assert_not_contains "$(<"$log")" 'mutation(' "dry-run must not call project mutations"
  [ "$(jq '.tasks | length' "$home/state/board-sync.json")" -eq 0 ] \
    || fail "dry-run must not record a mapping"
  TESTS_RUN=$((TESTS_RUN + 1))
  pass "dry-run recovers only the exact allowlisted canonical card and retains its live column"
}

test_arm_status_and_disarm
test_arm_leaves_no_unauthenticated_check_when_binding_fails
test_allowlist_and_exclusions
test_credential_bearing_artifact_is_not_published
test_exclusion_file_is_a_hard_gate
test_untitled_task_never_publishes_runtime_detail
test_excluded_task_with_a_live_card_is_reported
test_concurrent_reconcile_fails_closed
test_live_reconcile_lock_cannot_be_stolen
test_incomplete_lock_publication_never_wedges_reconcile
test_pending_create_recovers_without_duplicating
test_private_repo_is_a_hard_gate
test_private_repo_is_revalidated_at_the_mutation_boundary
test_dry_run_has_complete_plan_and_no_mutations
test_dry_run_plans_pending_work_for_mapped_tasks
test_poll_prints_only_a_deduplicated_pointer
test_board_move_is_escalated_without_fleet_or_snapback_write
test_reported_board_move_stops_rewaking_the_watcher
test_board_move_during_reconcile_is_never_silently_suppressed
test_conflict_snaps_to_fleet_and_explains_it
test_snapback_over_unrecorded_baseline_is_escalated
test_cleared_status_is_escalated_in_the_run_that_restores_it
test_archived_card_is_escalated_and_left_untouched
test_forward_column_write_is_not_reported_as_a_snapback
test_new_board_card_is_reported_as_captain_intent
test_hand_filed_card_never_binds_to_a_fleet_task
test_reAdded_card_under_a_new_item_id_still_reconciles
test_dry_run_plan_matches_the_real_operation_list
test_draft_card_is_left_manual_while_canonical_card_is_created
test_removed_card_is_escalated_once_and_truthfully
test_archive_during_reconcile_is_not_absorbed
test_unarchive_during_reconcile_has_a_distinct_signature
test_issue_close_during_reconcile_is_not_absorbed
test_mapping_retires_once_its_card_is_legitimately_gone
test_dry_run_recovers_only_allowlisted_canonical_card
test_all_digit_owner_still_reads_the_board
test_unmapped_card_counts_once_and_again_only_when_it_moves
test_unmapped_change_during_reconcile_is_never_silently_absorbed
test_bare_github_touch_never_rewakes_the_poll
test_escalations_report_only_what_the_run_observes
test_excluded_carded_report_retires_once_the_card_is_gone
printf 'board-sync tests: %s passed\n' "$TESTS_RUN"
