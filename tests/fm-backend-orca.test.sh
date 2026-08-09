#!/usr/bin/env bash
# tests/fm-backend-orca.test.sh - fake-Orca-CLI unit tests for the Orca
# terminal adapter primitives in bin/backends/orca.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-orca-tests)

make_orca_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_ORCA_LOG:?}"
RESP="${FM_ORCA_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
{
  printf 'orca'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = status ] && [ "${FM_ORCA_STATUS_RESPONSE:-ready}" != sequence ]; then
  printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
  exit 0
fi
n=$next
echo "$n" > "$COUNT_FILE"
if [ -f "$RESP/$n.exit" ]; then
  exit "$(cat "$RESP/$n.exit")"
fi
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$fb/orca"
  printf '%s\n' "$fb"
}

orca_case() {  # <name> -> sets CASE_DIR LOG RESP FB
  CASE_DIR="$TMP_ROOT/$1"
  mkdir -p "$CASE_DIR/responses"
  LOG="$CASE_DIR/log"
  RESP="$CASE_DIR/responses"
  : > "$LOG"
  FB=$(make_orca_fakebin "$CASE_DIR")
}

neutral_fm_root() {  # <dir> -> echoes a minimal root with a quiet guard
  local root="$1/root"
  mkdir -p "$root/bin"
  cat > "$root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$root/bin/fm-guard.sh"
  printf '%s\n' "$root"
}

add_tmux_fake() {
  local fb=$1
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_ORCA_LOG:?}"
{
  printf 'tmux'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
exit 0
SH
  chmod +x "$fb/tmux"
}

# --- remote Orca host fixtures ----------------------------------------------
#
# The numbered fake above cannot answer the remote-host flows: their terminal
# reads must echo back marker lines built from a nonce the code mints at run
# time, so a canned response can never match. This second fake instead makes the
# "host" a local bash - `terminal send` runs the sent line, `terminal read`
# replays what it printed - which exercises the real marker, base64, and exit
# status protocol rather than a stub's idea of it, and lets a real local git
# worktree stand in for the remote checkout.

FM_REMOTE_HOST=ssh:test-host-1

make_orca_remote_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_ORCA_LOG:?}"
FIX="${FM_ORCA_FIXTURES:?}"
{
  printf 'orca'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

ARGS=("$@")
get_flag() {
  local want=$1 i
  for ((i = 0; i < ${#ARGS[@]}; i++)); do
    if [ "${ARGS[$i]}" = "$want" ]; then printf '%s' "${ARGS[$((i + 1))]:-}"; return 0; fi
  done
  return 1
}

case "${1:-}" in
  status)
    printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
    exit 0
    ;;
esac

case "${1:-} ${2:-}" in
  "project setups")
    cat "$FIX/setups.json"
    exit 0
    ;;
  "worktree create")
    [ ! -f "$FIX/worktree-create.exit" ] || exit "$(cat "$FIX/worktree-create.exit")"
    cat "$FIX/worktree-create.json"
    exit 0
    ;;
  "worktree show")
    cat "$FIX/worktree-show.json"
    exit 0
    ;;
  "worktree rm")
    printf '{"ok":true,"result":{"removed":true}}\n'
    exit 0
    ;;
  "terminal create")
    if [ -f "$FIX/terminal-create.exit" ]; then exit "$(cat "$FIX/terminal-create.exit")"; fi
    n=$(( $(cat "$FIX/.termcount" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$FIX/.termcount"
    handle="term-$n"
    : > "$FIX/$handle.buf"
    host=$(cat "$FIX/terminal-host" 2>/dev/null || printf '%s' "${FM_ORCA_FAKE_HOST:-}")
    printf '{"ok":true,"result":{"terminal":{"handle":"%s","executionHostId":"%s","hostPlatform":"linux"}}}\n' \
      "$handle" "$host"
    exit 0
    ;;
  "terminal send")
    handle=$(get_flag --terminal) || handle=
    text=$(get_flag --text) || text=
    # The stand-in host: run the line and keep what it printed, exactly as a
    # real shell's scrollback would.
    if [ -n "${FM_ORCA_FAKE_HOST_PREFIX:-}" ]; then
      # The host's own paths, which do not exist on the caller's filesystem.
      # Without this the fake host shares a filesystem with the caller and a
      # local `git -C "$WT"` accidentally succeeds, hiding exactly the bugs
      # these cases exist to catch.
      text=$(printf '%s' "$text" | sed "s|${FM_ORCA_FAKE_HOST_PREFIX}|${FM_ORCA_FAKE_HOST_REAL}|g")
    fi
    if [ -n "${FM_ORCA_FAKE_HOST_PATH:-}" ]; then
      # A host whose PATH is deliberately narrower than the caller's, which is
      # how a real remote host can have an agent installed but unresolvable.
      mkdir -p "$FIX/fakehome"
      out=$(env -i PATH="$FM_ORCA_FAKE_HOST_PATH" HOME="$FIX/fakehome" bash --noprofile --norc -c "$text" 2>&1)
    else
      out=$(bash -c "$text" 2>&1)
    fi
    [ -z "$out" ] || printf '%s\n' "$out" >> "$FIX/$handle.buf"
    printf '{"ok":true,"result":{}}\n'
    exit 0
    ;;
  "terminal read")
    handle=$(get_flag --terminal) || handle=
    cursor=$(get_flag --cursor) || cursor=0
    limit=$(get_flag --limit) || limit=0
    # A host that cannot answer where the scrollback currently ends. The probe
    # for that is the only read taken without a cursor, so failing exactly it
    # models a transient position read failing while the terminal itself is
    # otherwise fine.
    if [ -f "$FIX/cursor-read.exit" ] && ! get_flag --cursor >/dev/null 2>&1; then
      exit "$(cat "$FIX/cursor-read.exit")"
    fi
    case "$cursor" in ''|*[!0-9]*) cursor=0 ;; esac
    case "$limit" in ''|*[!0-9]*) limit=0 ;; esac
    # Model the contract `orca terminal read --help` states: output is terminal
    # ROWS, --limit returns the NEWEST n of them, older rows are dropped, and
    # oldestCursor reports that a drop happened. Retention is finite, so a
    # bigger --limit recovers more rows but never rows the host already forgot.
    node -e '
const fs = require("fs");
const [file, cursorArg, limitArg, colsArg, retainArg] = process.argv.slice(1);
const cols = Number(colsArg) > 0 ? Number(colsArg) : 120;
const retain = Number(retainArg) > 0 ? Number(retainArg) : Infinity;
let raw = "";
try { raw = fs.readFileSync(file, "utf8"); } catch (e) { raw = ""; }
const lines = raw.split("\n");
if (lines.length && lines[lines.length - 1] === "") lines.pop();
// A long logical line occupies several rows on a real terminal grid.
const rows = [];
for (const line of lines) {
  if (line.length <= cols) { rows.push(line); continue; }
  for (let i = 0; i < line.length; i += cols) rows.push(line.slice(i, i + cols));
}
const total = rows.length;
const retainedFrom = Math.max(0, total - retain);
const cursor = Math.max(Number(cursorArg) || 0, retainedFrom);
let window = rows.slice(cursor);
let limited = cursor > (Number(cursorArg) || 0);
let oldest = cursor;
const limit = Number(limitArg) || 0;
if (limit > 0 && window.length > limit) {
  oldest = cursor + (window.length - limit);
  window = window.slice(-limit);
  limited = true;
}
process.stdout.write(JSON.stringify({
  ok: true,
  result: {
    terminal: {
      tail: window,
      limited,
      oldestCursor: String(oldest),
      nextCursor: String(total),
      latestCursor: String(total),
    },
  },
}) + "\n");
' "$FIX/$handle.buf" "$cursor" "$limit" "${FM_ORCA_FAKE_COLS:-120}" "${FM_ORCA_FAKE_RETAINED_ROWS:-0}"
    exit 0
    ;;
  "terminal close")
    printf '{"ok":true,"result":{}}\n'
    exit 0
    ;;
esac
printf '{"ok":true,"result":{}}\n'
exit 0
SH
  chmod +x "$fb/orca"
  printf '%s\n' "$fb"
}

orca_remote_case() {  # <name> -> sets CASE_DIR LOG FIX FB
  CASE_DIR="$TMP_ROOT/$1"
  mkdir -p "$CASE_DIR/fixtures"
  LOG="$CASE_DIR/log"
  FIX="$CASE_DIR/fixtures"
  : > "$LOG"
  FB=$(make_orca_remote_fakebin "$CASE_DIR")
  printf '%s\n' "$FM_REMOTE_HOST" > "$FIX/terminal-host"
}

write_remote_setups() {  # <fixtures> [<extra-setup-json>]
  local fix=$1 extra=${2:-}
  {
    printf '{"ok":true,"result":{"setups":['
    printf '{"id":"setup-remote","projectId":"github:acme/app","hostId":"%s","path":"/srv/app","setupState":"ready"}' "$FM_REMOTE_HOST"
    printf ',{"id":"setup-local","projectId":"github:acme/tools","hostId":"local","path":"/tmp","setupState":"ready"}'
    printf ',{"id":"setup-pending","projectId":"github:acme/pending","hostId":"%s","path":"/srv/pending","setupState":"cloning"}' "$FM_REMOTE_HOST"
    [ -z "$extra" ] || printf ',%s' "$extra"
    printf ']}}\n'
  } > "$fix/setups.json"
}

write_remote_worktree_fixtures() {  # <fixtures> <worktree-path> [<host-override>]
  local fix=$1 wt=$2 host=${3:-$FM_REMOTE_HOST}
  printf '{"ok":true,"result":{"worktree":{"id":"repo-remote::%s","path":"%s","hostId":"%s","isMainWorktree":false}}}\n' \
    "$wt" "$wt" "$host" > "$fix/worktree-create.json"
  printf '{"ok":true,"result":{"worktree":{"id":"repo-remote::%s","path":"%s","hostId":"%s","isMainWorktree":false}}}\n' \
    "$wt" "$wt" "$host" > "$fix/worktree-show.json"
}

# restricted_host_path: a PATH for a host that genuinely cannot resolve the
# caller's own tools. It shadows `bash` with a shim that refuses to read login
# profiles, so the login-shell fallback in the harness resolution cannot quietly
# re-import the developer machine's PATH and make this fixture machine-specific.
# Only the coreutils the transfer protocol itself needs stay reachable.
restricted_host_path() {  # <fixtures> -> echoes PATH
  local bin="$1/hostbin"
  mkdir -p "$bin"
  cat > "$bin/bash" <<'SH'
#!/bin/sh
exec /bin/bash --noprofile --norc "$@"
SH
  chmod +x "$bin/bash"
  printf '%s
' "$bin:/usr/bin:/bin"
}

# A stand-in for the remote agent binary, so the PATH resolution the remote
# launch depends on has something real to resolve.
add_fake_remote_harness() {  # <fakebin> <name>
  cat > "$1/$2" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$1/$2"
}


# --- remote placement through fm-spawn.sh / fm-teardown.sh ------------------

write_remote_setups_at() {  # <fixtures> <project-path>
  printf '{"ok":true,"result":{"setups":[{"id":"setup-remote","projectId":"github:acme/app","hostId":"%s","path":"%s","setupState":"ready"}]}}\n' \
    "$FM_REMOTE_HOST" "$2" > "$1/setups.json"
}

remote_spawn_case() {  # <name> <task-id> -> sets CASE_DIR LOG FIX FB PROJ WT DATA STATE CONFIG
  orca_remote_case "$1"
  PROJ="$CASE_DIR/proj"
  WT="$CASE_DIR/wt"
  DATA="$CASE_DIR/data"
  STATE="$CASE_DIR/state"
  CONFIG="$CASE_DIR/config"
  fm_git_worktree "$PROJ" "$WT" "fm/$2"
  mkdir -p "$DATA/$2" "$STATE" "$CONFIG"
  printf 'Delivery contract: mode=local-only\n\nsmoke brief body\n' > "$DATA/$2/brief.md"
  touch "$STATE/.last-watcher-beat"
  write_remote_setups_at "$FIX" "$PROJ"
  write_remote_worktree_fixtures "$FIX" "$WT"
  add_fake_remote_harness "$FB" claude
}

run_remote_spawn() {  # <task-id> [<extra spawn args>...]
  local id=$1
  shift
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    FM_ORCA_FAKE_HOST_PATH="${FM_ORCA_FAKE_HOST_PATH:-}" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$CASE_DIR/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" orca:setup:setup-remote "$@" 2>&1
}

test_spawn_places_task_on_remote_orca_host() {
  local id out mode
  id="orcaremotez1"
  remote_spawn_case remote-spawn "$id"
  out=$(run_remote_spawn "$id" claude --mode local-only --yolo off --backend orca)
  expect_code 0 $? "a remote Orca spawn should succeed"$'\n'"$out"
  assert_grep "backend=orca" "$STATE/$id.meta" "meta missing backend=orca"
  assert_grep "orca_remote=1" "$STATE/$id.meta" "meta must record that this task runs on a remote host"
  assert_grep "orca_host=$FM_REMOTE_HOST" "$STATE/$id.meta" "meta must record the task's host identity"
  assert_grep "orca_project_host_setup=setup-remote" "$STATE/$id.meta" "meta must record the project host setup"
  assert_grep "worktree=$WT" "$STATE/$id.meta" "meta must record the remote worktree path"
  assert_grep "project=$PROJ" "$STATE/$id.meta" "meta must record the remote project path"
  assert_grep "orca_remote_tasktmp=/tmp/fm-$id" "$STATE/$id.meta" "meta must record the remote task temp root"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''create'$'\x1f''--project-host-setup'$'\x1f''setup-remote' \
    "a remote spawn must pin worktree creation to the resolved host setup"
  # The brief and its encoder must exist ON the host, and the launch line must
  # read them from there rather than from this firstmate home.
  [ -f "/tmp/fm-$id/brief.md" ] || fail "the brief was not delivered to the host"
  [ -f "/tmp/fm-$id/fm-operational-input.sh" ] || fail "the operational-input encoder was not delivered to the host"
  assert_contains "$(cat "/tmp/fm-$id/brief.md")" "smoke brief body" "delivered brief lost its body"
  assert_contains "$(cat "/tmp/fm-$id/brief.md")" "Remote host addendum" \
    "the delivered brief must tell the worker its status path is unreachable from that host"
  # That brief is the worker's whole instruction set, and on the host it sits in
  # a shared /tmp rather than in anyone's home. Nobody else on that box gets to
  # read it.
  if [ "$(uname)" = Darwin ]; then mode=$(stat -f %Lp "/tmp/fm-$id"); else mode=$(stat -c %a "/tmp/fm-$id"); fi
  [ "$mode" = 700 ] \
    || fail "the remote task temp root must not be reachable by other accounts on the host, got mode '$mode'"
  assert_contains "$(cat "$LOG")" "/tmp/fm-$id/brief.md" "the launch line must read the brief from the host"
  assert_contains "$(cat "$LOG")" "$FB/claude" \
    "the launch line must name the harness's absolute path on the host, not a bare name"
  assert_contains "$(cat "$LOG")" "export GOTMPDIR=/tmp/fm-$id/gotmp" \
    "GOTMPDIR must point at the task temp root on the host"
  # Local hooks would point into this firstmate home and could never fire there.
  assert_absent "$WT/.claude/settings.local.json" "a remote task must not install a firstmate-home turn-end hook"
  assert_contains "$out" "turn-end and busy-state hooks are not installed" \
    "a remote spawn must say out loud that it is supervised by reading its pane"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh: places a task on a remote Orca host with host-pinned creation, delivered instructions, and no unreachable hooks"
}

test_spawn_refuses_orca_selector_without_orca_backend() {
  local id out status
  id="orcaremotez2"
  remote_spawn_case remote-wrong-backend "$id"
  out=$(run_remote_spawn "$id" claude --mode local-only --yolo off --backend tmux)
  status=$?
  [ "$status" -ne 0 ] || fail "an Orca selector on a non-Orca backend must refuse"
  assert_contains "$out" "is an Orca project selector but this spawn resolved backend=tmux" \
    "the refusal should name the mismatch"
  assert_absent "$STATE/$id.meta" "a refused selector must not publish task metadata"
  pass "fm-spawn.sh: refuses an Orca project selector unless the spawn is on the Orca backend"
}

test_spawn_refuses_remote_worktree_that_is_the_primary_checkout() {
  local id out status
  id="orcaremotez3"
  remote_spawn_case remote-primary "$id"
  # Orca answers with the project's own primary checkout instead of a new one.
  write_remote_worktree_fixtures "$FIX" "$PROJ"
  out=$(run_remote_spawn "$id" claude --mode local-only --yolo off --backend orca)
  status=$?
  [ "$status" -ne 0 ] || fail "a remote worktree that is the primary checkout must refuse"
  assert_contains "$out" "resolved to the primary checkout" "the refusal should name the tangle it prevents"
  assert_absent "$STATE/$id.meta" "a failed isolation check must not publish task metadata"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "a refused remote spawn must release the worktree it created"
  pass "fm-spawn.sh: refuses a remote task whose worktree is the project's primary checkout"
}

test_spawn_refuses_remote_harness_the_host_cannot_resolve() {
  local id out status
  id="orcaremotez4"
  remote_spawn_case remote-no-harness "$id"
  rm -f "$FB/claude"
  out=$(FM_ORCA_FAKE_HOST_PATH=$(restricted_host_path "$FIX") \
    run_remote_spawn "$id" claude --mode local-only --yolo off --backend orca)
  status=$?
  [ "$status" -ne 0 ] || fail "a harness the host cannot resolve must refuse before launch"
  assert_contains "$out" "is not on PATH on Orca host" "the refusal should name the host"
  assert_contains "$out" "PATH there:" "the refusal should report the PATH the host actually had"
  assert_absent "$STATE/$id.meta" "an unresolvable harness must not publish task metadata"
  # The refusal fires after the brief and the encoder are already on the host,
  # and it publishes no metadata, so fm-teardown.sh will never be run for this
  # id: if the abort does not take them back off, the task's instructions stay
  # on that host permanently.
  assert_absent "/tmp/fm-$id" "an aborted remote spawn must sweep the task temp root it created on the host"
  assert_absent "$STATE/$id.remote-brief.md" "an aborted remote spawn must not leave the staged brief behind"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh: refuses when the harness cannot be resolved on the remote host, naming that host's PATH"
}

test_spawn_launches_a_remote_harness_installed_at_a_path_with_a_space() {
  local id out status spaced
  id="orcaremotez12"
  remote_spawn_case remote-spaced-harness "$id"
  # The host has the harness, just at a path with a space in it. The launch line
  # is a command line for that host's shell, so the only proof that survives a
  # rewrite or a missing quote is whether the agent actually started.
  rm -f "$FB/claude"
  spaced="$CASE_DIR/agent tools"
  mkdir -p "$spaced"
  cat > "$spaced/claude" <<SH
#!/usr/bin/env bash
printf 'launched\n' >> "$CASE_DIR/harness-ran"
exit 0
SH
  chmod +x "$spaced/claude"
  out=$(PATH="$spaced:$PATH" run_remote_spawn "$id" claude --mode local-only --yolo off --backend orca)
  status=$?
  expect_code 0 "$status" "a harness installed at a path with a space should still spawn"$'\n'"$out"
  [ -f "$CASE_DIR/harness-ran" ] \
    || fail "the host never launched the harness at '$spaced/claude'; the launch line did not survive its own path"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh: launches a remote harness whose install path contains a space"
}

remote_teardown_meta() {  # <state> <id> <worktree> <project>
  fm_write_meta "$1/$2.meta" \
    "window=fm-$2" "endpoint_task_id=$2" "terminal=term-1" "worktree=$3" "project=$4" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" "backend=orca" \
    "orca_worktree_id=repo-remote::$3" "orca_host=$FM_REMOTE_HOST" "orca_remote=1" \
    "orca_remote_tasktmp=/tmp/fm-$2"
}

run_remote_teardown() {  # <id> [<extra args>...]
  local id=$1 neutral
  shift
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    FM_ORCA_FAKE_HOST_PREFIX="${FM_ORCA_FAKE_HOST_PREFIX:-}" FM_ORCA_FAKE_HOST_REAL="${FM_ORCA_FAKE_HOST_REAL:-}" \
    FM_ORCA_FAKE_RETAINED_ROWS="${FM_ORCA_FAKE_RETAINED_ROWS:-0}" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$ROOT/bin/fm-teardown.sh" "$id" "$@" 2>&1
}

test_remote_teardown_refuses_uncommitted_work_on_the_host() {
  local id out status
  id="orcaremotez5"
  remote_spawn_case remote-td-dirty "$id"
  remote_teardown_meta "$STATE" "$id" "$WT" "$PROJ"
  printf 'work in progress\n' > "$WT/unfinished.txt"
  out=$(run_remote_teardown "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "cleanup must refuse while the host's worktree holds uncommitted work"
  assert_contains "$out" "uncommitted changes present" "the refusal should name the uncommitted work"
  assert_contains "$out" "$WT" "the refusal should name the remote worktree it protected"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "a refused cleanup must not remove the worktree"
  assert_grep "orca_remote=1" "$STATE/$id.meta" "a refused cleanup must preserve the task record"
  pass "fm-teardown.sh: refuses to release a remote worktree that holds uncommitted work on its host"
}

test_remote_teardown_refuses_when_the_host_is_unreachable() {
  local id out status
  id="orcaremotez6"
  remote_spawn_case remote-td-unreachable "$id"
  remote_teardown_meta "$STATE" "$id" "$WT" "$PROJ"
  printf 'work in progress\n' > "$WT/unfinished.txt"
  # No inspection shell can be opened, so no protective check can run.
  printf '1\n' > "$FIX/terminal-create.exit"
  out=$(run_remote_teardown "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "an unreachable host must refuse cleanup, not be read as an empty worktree"
  assert_contains "$out" "cannot reach Orca host" "the refusal should name the unreachable host"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "an unreachable host must not lead to removing the worktree anyway"
  assert_grep "orca_remote=1" "$STATE/$id.meta" "a refused cleanup must preserve the task record"
  pass "fm-teardown.sh: refuses a remote cleanup it cannot verify, instead of treating an unreachable host as nothing to protect"
}

# The forge answers for a merged PR whose head is <head>, recording the
# repository each lookup named so a case can tell which one was asked.
add_fake_gh_merged_pr() {  # <fakebin> <head> <call-log>
  local fb=$1 head=$2 log=$3
  cat > "$fb/gh" <<SH
#!/usr/bin/env bash
repo=""
prev=""
for a in "\$@"; do
  [ "\$prev" != --repo ] || repo=\$a
  prev=\$a
done
printf '%s %s %s\n' "\${1:-}" "\${2:-}" "\$repo" >> "$log"
case "\${1:-} \${2:-}" in
  "pr list") printf '%s\n' 7 ; exit 0 ;;
  "pr view") printf '%s\t%s\n' 'MERGED' '$head' ; exit 0 ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$fb/gh"
  : > "$log"
}

test_remote_teardown_releases_a_replayed_patch_that_landed_in_the_pr() {
  local id out status pr_head equiv
  id="orcaremotez13"
  remote_spawn_case remote-td-replayed "$id"
  # The last commit is the only unpushed one, its content is NOT on the default
  # branch, and the PR landed an equivalent patch under a different sha - so the
  # ONLY thing that can release this worktree is comparing patch ids across the
  # PR's commit range. That range is a single commit, which is exactly where a
  # reply whose last line is unterminated loses everything it had to say.
  fm_git_add_origin "$PROJ" "$CASE_DIR/origin.git"
  printf 'parent\n' > "$WT/local-parent.txt"
  git -C "$WT" add local-parent.txt
  git -C "$WT" -c user.email=t@t -c user.name=t commit -qm "local parent"
  git -C "$WT" push -q origin "HEAD:refs/heads/fm/$id"
  printf 'hello\n' > "$WT/feature.txt"
  git -C "$WT" add feature.txt
  git -C "$WT" -c user.email=t@t -c user.name=t commit -qm "add feature"
  equiv="$CASE_DIR/_equiv"
  git clone -q "$CASE_DIR/origin.git" "$equiv"
  printf 'hello\n' > "$equiv/feature.txt"
  git -C "$equiv" add feature.txt
  git -C "$equiv" -c user.email=t@t -c user.name=t commit -qm "add feature"
  git -C "$equiv" push -q origin HEAD:refs/heads/pr-head
  git -C "$PROJ" fetch -q origin
  pr_head=$(git -C "$PROJ" rev-parse refs/remotes/origin/pr-head)
  add_fake_gh_merged_pr "$FB" "$pr_head" "$CASE_DIR/gh-calls"
  fm_write_meta "$STATE/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-1" \
    "worktree=$WT" "project=$PROJ" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" "backend=orca" \
    "orca_worktree_id=repo-remote::$WT" "orca_host=$FM_REMOTE_HOST" "orca_remote=1" \
    "orca_remote_tasktmp=/tmp/fm-$id" \
    "pr=https://github.com/example/repo/pull/7"

  out=$(run_remote_teardown "$id")
  status=$?
  expect_code 0 "$status" "a remote task whose patch landed in the merged PR should be releasable"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:repo-remote::'"$WT" \
    "a remote task whose patch has landed must be released through Orca"
  assert_absent "$STATE/$id.meta" "a completed cleanup should remove the task record"
  pass "fm-teardown.sh: releases a remote task whose unpushed patch is contained in the merged PR head"
}

test_remote_pr_discovery_names_the_task_s_own_forge_host() {
  local id out status head
  id="orcaremotez14"
  remote_spawn_case remote-td-forge-host "$id"
  # Nothing pushed and nothing on the default branch, and no pr= recorded, so the
  # branch-name PR lookup is the only route. A remote task has no worktree here
  # for gh to resolve a repository from, so the lookup must name one - carrying
  # the host from the task's own origin rather than assuming github.com.
  git -C "$PROJ" remote add origin https://github.acme.invalid/team/app.git
  printf 'hello\n' > "$WT/feature.txt"
  git -C "$WT" add feature.txt
  git -C "$WT" -c user.email=t@t -c user.name=t commit -qm "add feature"
  head=$(git -C "$WT" rev-parse HEAD)
  add_fake_gh_merged_pr "$FB" "$head" "$CASE_DIR/gh-calls"
  remote_teardown_meta "$STATE" "$id" "$WT" "$PROJ"
  printf 'mode=no-mistakes\n' >> "$STATE/$id.meta"

  out=$(run_remote_teardown "$id")
  status=$?
  expect_code 0 "$status" "a remote task whose PR is discoverable by branch should be releasable"$'\n'"$out"
  grep -qx 'pr list github.acme.invalid/team/app' "$CASE_DIR/gh-calls" \
    || fail "the remote PR lookup did not name the task's own repository; calls were: $(cat "$CASE_DIR/gh-calls" 2>/dev/null)"
  assert_absent "$STATE/$id.meta" "a completed cleanup should remove the task record"
  pass "fm-teardown.sh: a remote task's PR lookup names its own repository, forge host included"
}

test_remote_pr_discovery_keeps_a_forge_port() {
  local id out status head
  id="orcaremotez17"
  remote_spawn_case remote-td-forge-port "$id"
  # A self-hosted forge answering on a non-default port. The port is part of the
  # endpoint: a lookup that drops it addresses a service that is not there, and
  # the landed-work evidence silently stops being available.
  git -C "$PROJ" remote add origin https://git.acme.invalid:8443/team/app.git
  printf 'hello\n' > "$WT/feature.txt"
  git -C "$WT" add feature.txt
  git -C "$WT" -c user.email=t@t -c user.name=t commit -qm "add feature"
  head=$(git -C "$WT" rev-parse HEAD)
  add_fake_gh_merged_pr "$FB" "$head" "$CASE_DIR/gh-calls"
  remote_teardown_meta "$STATE" "$id" "$WT" "$PROJ"
  printf 'mode=no-mistakes\n' >> "$STATE/$id.meta"

  out=$(run_remote_teardown "$id")
  status=$?
  expect_code 0 "$status" "a remote task on a ported forge should still be releasable"$'\n'"$out"
  grep -qx 'pr list git.acme.invalid:8443/team/app' "$CASE_DIR/gh-calls" \
    || fail "the remote PR lookup dropped the forge's port; calls were: $(cat "$CASE_DIR/gh-calls" 2>/dev/null)"
  assert_absent "$STATE/$id.meta" "a completed cleanup should remove the task record"
  pass "fm-teardown.sh: a remote task's PR lookup keeps the forge port its origin named"
}

test_remote_pr_discovery_drops_an_ssh_transport_port() {
  local id out status head
  id="orcaremotez18"
  remote_spawn_case remote-td-ssh-port "$id"
  # The same forge, reached over ssh on a non-standard port. That port is the
  # sshd the clone travels through, not the endpoint the forge's API answers on,
  # so carrying it into the lookup would address a service that does not exist -
  # and the PR evidence a landed remote task needs would silently vanish.
  git -C "$PROJ" remote add origin ssh://git@git.acme.invalid:2222/team/app.git
  printf 'hello\n' > "$WT/feature.txt"
  git -C "$WT" add feature.txt
  git -C "$WT" -c user.email=t@t -c user.name=t commit -qm "add feature"
  head=$(git -C "$WT" rev-parse HEAD)
  add_fake_gh_merged_pr "$FB" "$head" "$CASE_DIR/gh-calls"
  remote_teardown_meta "$STATE" "$id" "$WT" "$PROJ"
  printf 'mode=no-mistakes\n' >> "$STATE/$id.meta"

  out=$(run_remote_teardown "$id")
  status=$?
  expect_code 0 "$status" "a remote task cloned over ssh on a non-standard port should still be releasable"$'\n'"$out"
  grep -qx 'pr list git.acme.invalid/team/app' "$CASE_DIR/gh-calls" \
    || fail "the remote PR lookup carried an ssh transport port into the forge repository; calls were: $(cat "$CASE_DIR/gh-calls" 2>/dev/null)"
  assert_absent "$STATE/$id.meta" "a completed cleanup should remove the task record"
  pass "fm-teardown.sh: a remote task's PR lookup drops an ssh transport port rather than addressing a service that is not there"
}

test_remote_pr_discovery_refuses_to_guess_a_host_from_an_ssh_alias() {
  local id out status head
  id="orcaremotez15"
  remote_spawn_case remote-td-ssh-alias "$id"
  # An ssh alias names an ssh-config entry, not a forge host. There is no
  # repository this lookup can honestly name, and asking a guessed one could
  # report work as landed that never landed - so it stays fail-closed and the
  # content check, which here finds nothing, refuses.
  git -C "$PROJ" remote add origin 'git@github-work:team/app.git'
  git -C "$PROJ" config core.sshCommand /usr/bin/false
  printf 'hello\n' > "$WT/feature.txt"
  git -C "$WT" add feature.txt
  git -C "$WT" -c user.email=t@t -c user.name=t commit -qm "add feature"
  head=$(git -C "$WT" rev-parse HEAD)
  add_fake_gh_merged_pr "$FB" "$head" "$CASE_DIR/gh-calls"
  remote_teardown_meta "$STATE" "$id" "$WT" "$PROJ"
  printf 'mode=no-mistakes\n' >> "$STATE/$id.meta"

  out=$(run_remote_teardown "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "an origin that names no forge host must not be turned into a lookup that releases work"
  assert_contains "$out" "REFUSED" "the refusal should say so out loud"
  ! grep -q '^pr list ' "$CASE_DIR/gh-calls" \
    || fail "an unresolvable origin must not be turned into a forge lookup: $(cat "$CASE_DIR/gh-calls")"
  assert_grep "orca_remote=1" "$STATE/$id.meta" "a refused cleanup must preserve the task record"
  pass "fm-teardown.sh: a remote PR lookup refuses to synthesize a forge host from an ssh alias"
}

test_remote_teardown_releases_work_already_landed_on_the_host() {
  local id out status
  id="orcaremotez9"
  remote_spawn_case remote-td-landed "$id"
  # The host's paths are genuinely not on this filesystem, so anything that asks
  # THIS machine about them fails. That is the whole point: with the landed-work
  # chain still local, a remote task whose work HAS landed could never be
  # cleaned up, and the only exit offered was --force.
  FM_ORCA_FAKE_HOST_PREFIX=/fm-hostonly
  FM_ORCA_FAKE_HOST_REAL=$CASE_DIR
  write_remote_worktree_fixtures "$FIX" /fm-hostonly/wt
  printf 'landed work\n' > "$WT/landed.txt"
  git -C "$WT" add landed.txt
  git -C "$WT" -c user.email=t@example.com -c user.name=t commit -qm "landed change"
  # Fast-forwarded into the project's default branch, with no remote configured -
  # so the commit is still listed by HEAD --not --remotes and only the
  # landed-work check can tell that it is safe to release.
  git -C "$PROJ" merge --ff-only -q "fm/$id"
  [ ! -d /fm-hostonly ] || fail "the host prefix must not exist on the caller's filesystem"
  fm_write_meta "$STATE/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-1" \
    "worktree=/fm-hostonly/wt" "project=/fm-hostonly/proj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" "backend=orca" \
    "orca_worktree_id=repo-remote::/fm-hostonly/wt" "orca_host=$FM_REMOTE_HOST" "orca_remote=1" \
    "orca_remote_tasktmp=/tmp/fm-$id"
  out=$(run_remote_teardown "$id")
  status=$?
  unset FM_ORCA_FAKE_HOST_PREFIX FM_ORCA_FAKE_HOST_REAL
  expect_code 0 "$status" "work already landed on the host should be releasable"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:repo-remote::/fm-hostonly/wt' \
    "a remote task whose work has landed must be released through Orca"
  assert_absent "$STATE/$id.meta" "a completed cleanup should remove the task record"
  pass "fm-teardown.sh: releases a remote task whose work already landed, asking the host rather than this machine"
}

test_remote_force_teardown_completes_when_the_host_is_unreachable() {
  local id out status
  id="orcaremotez10"
  remote_spawn_case remote-td-force "$id"
  remote_teardown_meta "$STATE" "$id" "$WT" "$PROJ"
  printf 'work in progress\n' > "$WT/unfinished.txt"
  # No inspection shell is available, which is the state --force exists for: a
  # host that is genuinely gone. Orca's own records still answer from here, so
  # the recorded host and the exact recorded path are still proven; only the
  # on-host canonicalization is skipped.
  printf '1\n' > "$FIX/terminal-create.exit"
  out=$(run_remote_teardown "$id" --force)
  status=$?
  expect_code 0 "$status" "--force must finish cleanup when the host is unreachable"$'\n'"$out"
  assert_contains "$out" "canonicalization for" "--force should say which proof it had to skip"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:repo-remote::'"$WT" \
    "--force must release the recorded worktree once its identity is proven from Orca's records"
  assert_absent "$STATE/$id.meta" "--force must not leave the task record stuck"
  pass "fm-teardown.sh --force: completes cleanup for an unreachable host instead of dead-ending on it"
}

test_remote_force_teardown_still_refuses_a_worktree_that_is_not_the_recorded_one() {
  local id out status
  id="orcaremotez11"
  remote_spawn_case remote-td-force-mismatch "$id"
  remote_teardown_meta "$STATE" "$id" "$WT" "$PROJ"
  # Orca reports a different path than the one recorded. --force relaxes only
  # the on-host canonicalization, never the identity of what gets removed.
  write_remote_worktree_fixtures "$FIX" "$PROJ"
  printf '1\n' > "$FIX/terminal-create.exit"
  out=$(run_remote_teardown "$id" --force)
  status=$?
  [ "$status" -ne 0 ] || fail "--force must still refuse to remove a worktree that is not the recorded one"
  assert_contains "$out" "not the recorded worktree" "the refusal should name the identity mismatch"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "a mismatched identity must not be removed even under --force"
  pass "fm-teardown.sh --force: still refuses when Orca's recorded worktree is not the one in the task record"
}

test_remote_teardown_releases_a_clean_worktree() {
  local id out status
  id="orcaremotez7"
  remote_spawn_case remote-td-clean "$id"
  remote_teardown_meta "$STATE" "$id" "$WT" "$PROJ"
  mkdir -p "/tmp/fm-$id"
  printf 'scratch\n' > "/tmp/fm-$id/scratch.txt"
  out=$(run_remote_teardown "$id")
  status=$?
  expect_code 0 "$status" "a clean remote worktree should be released"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:repo-remote::'"$WT" \
    "cleanup must release the recorded remote worktree through Orca"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-1' \
    "cleanup must close the recorded remote terminal"
  assert_absent "$STATE/$id.meta" "a completed cleanup should remove the task record"
  assert_absent "/tmp/fm-$id" "cleanup should sweep the task temp root it created on the host"
  rm -rf "/tmp/fm-$id"
  pass "fm-teardown.sh: releases a clean remote worktree through Orca and sweeps its temp root on the host"
}

test_setup_resolve_reads_one_ready_setup() {
  local out
  orca_remote_case setup-resolve
  write_remote_setups "$FIX"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_setup_resolve orca:setup:setup-remote' "$ROOT" )
  [ "$out" = "setup-remote	github:acme/app	$FM_REMOTE_HOST	/srv/app" ] \
    || fail "setup resolve should print id/project/host/path, got '$out'"
  pass "fm_backend_orca_setup_resolve: resolves orca:setup:<id> to its id, project, host, and path"
}

test_setup_resolve_refuses_ambiguous_project() {
  local out status extra
  orca_remote_case setup-ambiguous
  extra='{"id":"setup-second","projectId":"github:acme/app","hostId":"local","path":"/tmp/app","setupState":"ready"}'
  write_remote_setups "$FIX" "$extra"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_setup_resolve orca:project:github:acme/app' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "a project id matching two setups must refuse rather than pick a host"
  assert_contains "$out" "matches 2 Orca project host setups" "ambiguous refusal should say how many matched"
  assert_contains "$out" "setup-remote" "ambiguous refusal should name the candidate setups"
  assert_contains "$out" "setup-second" "ambiguous refusal should name the candidate setups"
  pass "fm_backend_orca_setup_resolve: refuses an ambiguous project selector instead of choosing a host"
}

test_setup_resolve_refuses_unready_and_unknown() {
  local out status
  orca_remote_case setup-unready
  write_remote_setups "$FIX"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_setup_resolve orca:setup:setup-pending' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "a setup that is not ready must refuse"
  assert_contains "$out" "is cloning, not ready" "unready refusal should name the actual state"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_setup_resolve orca:nonsense:x' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "an unknown orca: selector form must refuse"
  assert_contains "$out" "is not an Orca project selector" "unknown form should name the accepted forms"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_setup_resolve orca:setup:absent' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "an unmatched setup id must refuse"
  assert_contains "$out" "no Orca project host setup matches" "unmatched refusal should say so"
  pass "fm_backend_orca_setup_resolve: refuses unready, unknown-form, and unmatched selectors"
}

test_worktree_create_on_setup_pins_and_verifies_host() {
  local out status
  orca_remote_case wt-on-setup
  write_remote_worktree_fixtures "$FIX" /srv/app-task
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create_on_setup setup-remote fm-t1 '"$FM_REMOTE_HOST" "$ROOT" )
  [ "$out" = "repo-remote::/srv/app-task	/srv/app-task" ] \
    || fail "create-on-setup should print the worktree id and path, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''create'$'\x1f''--project-host-setup'$'\x1f''setup-remote' \
    "create-on-setup should pin the host with --project-host-setup"

  # Same call, but Orca answers with a worktree on a different host.
  orca_remote_case wt-on-setup-wrong
  write_remote_worktree_fixtures "$FIX" /srv/app-task local
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create_on_setup setup-remote fm-t1 '"$FM_REMOTE_HOST" "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "a worktree created on the wrong host must refuse, not be used"
  assert_contains "$out" "not an additional worktree on the required host" \
    "wrong-host refusal should name the requirement"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "a wrongly placed worktree should be removed, not left behind"
  pass "fm_backend_orca_worktree_create_on_setup: pins the host and refuses a worktree that landed elsewhere"
}

test_terminal_create_refuses_wrong_execution_host() {
  local out status
  orca_remote_case term-host
  printf 'local\n' > "$FIX/terminal-host"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_terminal_create repo-remote::/srv/app-task fm-t1 '"$FM_REMOTE_HOST" "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "a terminal that came up on another host must refuse"
  assert_contains "$out" "not the required host" "wrong-host refusal should name the requirement"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "a terminal on the wrong host should be closed, not left open"
  pass "fm_backend_orca_terminal_create: refuses and closes a terminal whose execution host is not the required one"
}

test_exec_run_returns_remote_output_and_status() {
  local out status
  orca_remote_case exec-run
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    bash -c '. "$0/bin/backends/orca.sh"
h=$(fm_backend_orca_exec_open repo-remote::/srv/app-task probe '"$FM_REMOTE_HOST"') || exit 9
fm_backend_orca_exec_run "$h" "printf %s\\\\n one; printf %s\\\\n two"' "$ROOT" )
  [ "$out" = $'one\ntwo' ] || fail "exec should return the command's own output, got '$out'"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    bash -c '. "$0/bin/backends/orca.sh"
h=$(fm_backend_orca_exec_open repo-remote::/srv/app-task probe '"$FM_REMOTE_HOST"') || exit 9
fm_backend_orca_exec_run "$h" "echo problem >&2; exit 7"' "$ROOT" )
  status=$?
  expect_code 7 "$status" "exec should return the remote command's own exit status"
  [ "$out" = "problem" ] || fail "exec should return remote stderr with stdout, got '$out'"
  pass "fm_backend_orca_exec_run: returns the remote command's combined output and exit status"
}

test_exec_run_recovers_output_larger_than_one_reply() {
  local out status expected
  orca_remote_case exec-overflow
  # More output than one reply can carry, on a host that retains only a little
  # scrollback: it has to come back in pieces, and it has to come back whole.
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    FM_ORCA_FAKE_RETAINED_ROWS=60 \
    bash -c '. "$0/bin/backends/orca.sh"
h=$(fm_backend_orca_exec_open repo-remote::/srv/app-task probe '"$FM_REMOTE_HOST"') || exit 9
fm_backend_orca_exec_run "$h" "seq 1 600"' "$ROOT" )
  status=$?
  expect_code 0 "$status" "a reply fetched in pieces should still report the command's own status"
  expected=$(seq 1 600)
  [ "$out" = "$expected" ] || fail "a sliced reply must be reassembled whole, got ${#out} bytes"
  pass "fm_backend_orca_exec_run: reassembles a reply too large for one read, whole"
}

test_exec_run_never_reports_an_unreadable_reply_as_empty_success() {
  local out status
  orca_remote_case exec-unreadable
  # The exact shape of the defect this guards: the command itself exits 0 and
  # its trailing status survives, but its output cannot be read back. Reporting
  # that as "succeeded, printed nothing" is what tells the work-protection
  # checks there is nothing to protect.
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    FM_ORCA_FAKE_RETAINED_ROWS=2 \
    bash -c '. "$0/bin/backends/orca.sh"
h=$(fm_backend_orca_exec_open repo-remote::/srv/app-task probe '"$FM_REMOTE_HOST"') || exit 9
fm_backend_orca_exec_run "$h" "seq 1 600"' "$ROOT" 2>/dev/null )
  status=$?
  [ "$status" -ne 0 ] || fail "an unreadable reply must never be reported as the command's success"
  expect_code 125 "$status" "an unreadable reply must report a transport failure, not a command result"
  [ -z "$out" ] || fail "an unreadable reply must print nothing, got '$out'"
  pass "fm_backend_orca_exec_run: an unreadable reply is a transport failure, never an empty success"
}

test_exec_run_refuses_when_the_cursor_cannot_be_read() {
  local out status
  orca_remote_case exec-cursor-unreadable
  # Where this reply's window starts is what keeps an OLDER reply of the same
  # terminal out of it. An unreadable position is not a position, and treating
  # it as the start of the scrollback would answer with whatever is sitting
  # there - so it has to refuse instead of returning a result.
  printf '1\n' > "$FIX/cursor-read.exit"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    bash -c '. "$0/bin/backends/orca.sh"
h=$(fm_backend_orca_exec_open repo-remote::/srv/app-task probe '"$FM_REMOTE_HOST"') || exit 9
fm_backend_orca_exec_run "$h" "printf %s ready"' "$ROOT" 2>/dev/null )
  status=$?
  [ "$status" -ne 0 ] || fail "an unreadable cursor must never be reported as the command's own result"
  expect_code 125 "$status" "an unreadable cursor must report a transport failure"
  [ -z "$out" ] || fail "a transport failure must print nothing, got '$out'"
  pass "fm_backend_orca_exec_run: an unreadable scrollback position is a transport failure, not an answer"
}

test_exec_run_marks_every_invocation_apart() {
  local out markers
  orca_remote_case exec-nonce
  # Both calls run inside command substitutions, exactly as every real caller
  # does, so a marker built from shell state a subshell discards would come out
  # identical for both - and then a reply still sitting in the scrollback could
  # answer for a later command.
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    bash -c '. "$0/bin/backends/orca.sh"
h=$(fm_backend_orca_exec_open repo-remote::/srv/app-task probe '"$FM_REMOTE_HOST"') || exit 9
a=$(fm_backend_orca_exec_run "$h" "printf %s one") || exit 8
b=$(fm_backend_orca_exec_run "$h" "printf %s two") || exit 8
printf "%s/%s" "$a" "$b"' "$ROOT" )
  expect_code 0 $? "two successive inspection commands should both answer"$'\n'"$out"
  [ "$out" = "one/two" ] || fail "each command must return its own output, got '$out'"
  # The host's own scrollback is where the markers actually land.
  markers=$(grep -ho 'FMORCAB_[A-Za-z0-9]*' "$FIX"/term-*.buf 2>/dev/null | sort -u | wc -l | tr -d '[:space:]')
  [ "${markers:-0}" -ge 2 ] \
    || fail "two inspection commands must not share one marker (distinct markers seen: ${markers:-0})"
  pass "fm_backend_orca_exec_run: successive commands mark their replies apart, even from subshells"
}

# Break the HOST's base64 the two ways staging can fail without any single
# command reporting an error: outright failure, and a clean exit that writes
# nothing. The second is the harder one - every step "succeeds" and the staged
# file is simply empty, which is byte-for-byte what a command that genuinely
# printed nothing produces.
# A host that stages small replies fine and silently produces nothing for a
# large one - a filling disk, a quota, a partial write. This is the shape that
# actually loses data: every short verdict check still answers, so cleanup gets
# all the way to the uncommitted-work question before the reply goes missing.
add_size_limited_remote_base64() {  # <fakebin> <max-bytes>
  cat > "$1/base64" <<SH
#!/usr/bin/env bash
__t=\$(mktemp) || exit 1
cat > "\$__t"
__n=\$(wc -c < "\$__t" | tr -d '[:space:]')
if [ "\$__n" -le $2 ]; then /usr/bin/base64 < "\$__t"; fi
rm -f "\$__t"
exit 0
SH
  chmod +x "$1/base64"
}

add_broken_remote_base64() {  # <fakebin> <fail|empty>
  if [ "$2" = fail ]; then
    cat > "$1/base64" <<'SH'
#!/usr/bin/env bash
echo "base64: cannot encode" >&2
exit 1
SH
  else
    cat > "$1/base64" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  fi
  chmod +x "$1/base64"
}

test_exec_run_refuses_when_the_host_cannot_encode_the_reply() {
  local out status
  orca_remote_case exec-stage-encode-fail
  add_broken_remote_base64 "$FB" fail
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    bash -c '. "$0/bin/backends/orca.sh"
h=$(fm_backend_orca_exec_open repo-remote::/srv/app-task probe '"$FM_REMOTE_HOST"') || exit 9
fm_backend_orca_exec_run "$h" "printf %s dirty"' "$ROOT" 2>/dev/null )
  status=$?
  [ "$status" -ne 0 ] || fail "a failed encode must not be reported as the command's own success"
  expect_code 125 "$status" "a failed encode must report a transport failure"
  [ -z "$out" ] || fail "a failed encode must print nothing, got '$out'"
  pass "fm_backend_orca_exec_run: refuses when the host cannot encode the reply, instead of returning the command's status with no output"
}

test_exec_run_refuses_when_staging_writes_an_empty_file() {
  local out status
  orca_remote_case exec-stage-empty-write
  # Every step exits 0 and the staged file is empty. Only proving the write
  # against the size the encoding must produce can tell this apart from a
  # command that legitimately printed nothing.
  add_broken_remote_base64 "$FB" empty
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    bash -c '. "$0/bin/backends/orca.sh"
h=$(fm_backend_orca_exec_open repo-remote::/srv/app-task probe '"$FM_REMOTE_HOST"') || exit 9
fm_backend_orca_exec_run "$h" "printf %s dirty"' "$ROOT" 2>/dev/null )
  status=$?
  [ "$status" -ne 0 ] || fail "a silently empty staged file must not be reported as the command's success"
  expect_code 125 "$status" "a silently empty staged file must report a transport failure"
  [ -z "$out" ] || fail "a silently empty staged file must print nothing, got '$out'"
  pass "fm_backend_orca_exec_run: refuses a staged write that silently produced nothing, rather than reading it as an empty answer"
}

test_remote_teardown_refuses_when_the_host_cannot_stage_a_reply() {
  local id out status i
  id="orcaremotez16"
  remote_spawn_case remote-td-stage-fail "$id"
  # Real uncommitted work on the host, and a branch already merged into the
  # default branch so nothing else can refuse first. The ONLY thing standing
  # between this worktree and release is the uncommitted-work answer - and the
  # host cannot stage a reply that large.
  for i in $(seq 1 60); do : > "$WT/untracked-work-file-number-$i.txt"; done
  git -C "$PROJ" merge --ff-only -q "fm/$id" 2>/dev/null || true
  remote_teardown_meta "$STATE" "$id" "$WT" "$PROJ"
  add_size_limited_remote_base64 "$FB" 200
  out=$(run_remote_teardown "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "cleanup must refuse when the host cannot stage the answer to the uncommitted-work check"
  assert_contains "$out" "REFUSED" "an unstageable work check must refuse out loud"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "a worktree holding uncommitted work must not be released because its answer went missing"
  assert_grep "orca_remote=1" "$STATE/$id.meta" "a refused cleanup must preserve the task record"
  pass "fm-teardown.sh: refuses to release a remote worktree holding uncommitted work when the host cannot stage that answer"
}

test_exec_run_keeps_a_genuinely_empty_result_successful() {
  local out status
  orca_remote_case exec-empty
  # Emptiness must stay a legitimate answer: the failure signal is a missing
  # begin marker and a length mismatch, never an empty payload on its own.
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    bash -c '. "$0/bin/backends/orca.sh"
h=$(fm_backend_orca_exec_open repo-remote::/srv/app-task probe '"$FM_REMOTE_HOST"') || exit 9
fm_backend_orca_exec_run "$h" "true"' "$ROOT" )
  status=$?
  expect_code 0 "$status" "a command that really printed nothing must still succeed"
  [ -z "$out" ] || fail "a genuinely empty result should print nothing, got '$out'"
  pass "fm_backend_orca_exec_run: a command that genuinely produced no output still succeeds"
}

test_remote_teardown_refuses_when_dirty_output_cannot_be_read() {
  local id out status i name
  id="orcaremotez8"
  remote_spawn_case remote-td-truncated "$id"
  remote_teardown_meta "$STATE" "$id" "$WT" "$PROJ"
  # Real uncommitted work, and enough of it that `git status --porcelain` no
  # longer fits in the host's retained rows. The worktree is holding the
  # captain's work; the only safe answer is to refuse.
  name=$(printf 'f%.0s' $(seq 1 200))
  for i in $(seq 1 150); do : > "$WT/$name-$i.txt"; done
  out=$(FM_ORCA_FAKE_RETAINED_ROWS=10 run_remote_teardown "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "cleanup must refuse when it cannot read the host's uncommitted-work answer"
  assert_contains "$out" "REFUSED" "an unreadable work check must refuse out loud"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "a worktree holding unreadable work must not be released"
  assert_grep "orca_remote=1" "$STATE/$id.meta" "a refused cleanup must preserve the task record"
  pass "fm-teardown.sh: refuses a remote worktree whose uncommitted-work answer could not be read, instead of releasing it"
}

test_push_file_refuses_on_digest_mismatch() {
  local out status src
  orca_remote_case push-good
  src="$CASE_DIR/payload.txt"
  printf 'line one\nline two\n' > "$src"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    bash -c '. "$0/bin/backends/orca.sh"
h=$(fm_backend_orca_exec_open repo-remote::/srv/app-task probe '"$FM_REMOTE_HOST"') || exit 9
fm_backend_orca_push_file "$h" "$1" "$2/delivered.txt" && cat "$2/delivered.txt"' "$ROOT" "$src" "$CASE_DIR" 2>&1 )
  expect_code 0 $? "a clean push should succeed"$'\n'"$out"
  [ "$out" = $'line one\nline two' ] || fail "pushed file should arrive byte-identical, got '$out'"

  orca_remote_case push-corrupt
  src="$CASE_DIR/payload.txt"
  printf 'original content\n' > "$src"
  # The host writes something other than what was sent: the digest check is the
  # only thing standing between that and a worker launched on a half a brief.
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" FM_BACKEND_ORCA_PUSH_CHUNK=4 \
    bash -c '. "$0/bin/backends/orca.sh"
fm_backend_orca_push_file_orig=$(declare -f fm_backend_orca_push_file)
h=$(fm_backend_orca_exec_open repo-remote::/srv/app-task probe '"$FM_REMOTE_HOST"') || exit 9
fm_backend_orca_local_digest() { printf "%s" deadbeef; }
fm_backend_orca_push_file "$h" "$1" "$2/delivered.txt"' "$ROOT" "$src" "$CASE_DIR" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "a digest mismatch must refuse the transfer"
  assert_contains "$out" "did not arrive intact" "digest refusal should say the copy is not trustworthy"
  pass "fm_backend_orca_push_file: delivers byte-identical content and refuses on a digest mismatch"
}

test_push_file_leaves_nothing_behind_when_a_transfer_fails() {
  local out status src
  orca_remote_case push-interrupted
  src="$CASE_DIR/payload.txt"
  printf 'a brief long enough to need several chunks on the wire\n' > "$src"
  # A transfer that dies partway, the way a dropped connection does. The encoded
  # copy is scratch, and a refused transfer that leaves it behind leaves a
  # partial copy of the agent's instructions on someone else's host.
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" FM_BACKEND_ORCA_PUSH_CHUNK=4 \
    bash -c '. "$0/bin/backends/orca.sh"
eval "fm_backend_orca_send_real() $(declare -f fm_backend_orca_send_text_line | sed 1d)"
FM_SENT_CHUNKS=0
fm_backend_orca_send_text_line() {
  case "$2" in
    "printf %s "*)
      FM_SENT_CHUNKS=$((FM_SENT_CHUNKS + 1))
      [ "$FM_SENT_CHUNKS" -lt 2 ] || return 1
      ;;
  esac
  fm_backend_orca_send_real "$@"
}
h=$(fm_backend_orca_exec_open repo-remote::/srv/app-task probe '"$FM_REMOTE_HOST"') || exit 9
fm_backend_orca_push_file "$h" "$1" "$2/delivered.txt"' "$ROOT" "$src" "$CASE_DIR" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "an interrupted transfer must refuse"
  assert_contains "$out" "was interrupted" "the refusal should say the transfer did not complete"
  assert_absent "$CASE_DIR/delivered.txt.b64" \
    "a failed transfer must not leave its encoded copy on the host"
  pass "fm_backend_orca_push_file: an interrupted transfer refuses and leaves no encoded copy on the host"
}

test_remote_which_resolves_absolute_path() {
  local out status
  orca_remote_case remote-which
  add_fake_remote_harness "$FB" fmfakeagent
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    bash -c '. "$0/bin/backends/orca.sh"
h=$(fm_backend_orca_exec_open repo-remote::/srv/app-task probe '"$FM_REMOTE_HOST"') || exit 9
fm_backend_orca_remote_which "$h" fmfakeagent' "$ROOT" )
  [ "$out" = "$FB/fmfakeagent" ] || fail "remote which should return the absolute path, got '$out'"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    bash -c '. "$0/bin/backends/orca.sh"
h=$(fm_backend_orca_exec_open repo-remote::/srv/app-task probe '"$FM_REMOTE_HOST"') || exit 9
fm_backend_orca_remote_which "$h" fmdefinitelymissing' "$ROOT" )
  status=$?
  [ "$status" -ne 0 ] || fail "an unresolvable harness must fail rather than return a bare name"
  [ -z "$out" ] || fail "an unresolvable harness must print nothing, got '$out'"
  pass "fm_backend_orca_remote_which: resolves an absolute path and fails when the host cannot resolve the name"
}

test_remote_which_keeps_a_path_containing_a_space() {
  local out spaced
  orca_remote_case remote-which-spaced
  # A perfectly ordinary install location on someone else's machine. Rewriting
  # it into a shorter path that does not exist is worse than failing: the guard
  # still sees an absolute path, so the spawn proceeds and launches nothing.
  spaced="$CASE_DIR/agent tools"
  mkdir -p "$spaced"
  add_fake_remote_harness "$spaced" fmspacedagent
  out=$( PATH="$FB:$spaced:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    bash -c '. "$0/bin/backends/orca.sh"
h=$(fm_backend_orca_exec_open repo-remote::/srv/app-task probe '"$FM_REMOTE_HOST"') || exit 9
fm_backend_orca_remote_which "$h" fmspacedagent' "$ROOT" )
  [ "$out" = "$spaced/fmspacedagent" ] \
    || fail "remote which must return the host's path unaltered, got '$out'"
  [ -x "$out" ] || fail "remote which returned a path that is not the executable the host resolved: '$out'"
  pass "fm_backend_orca_remote_which: returns an install path containing a space unaltered"
}

test_remote_which_resolves_through_a_login_banner() {
  local out status agentdir
  orca_remote_case remote-which-banner
  # A host whose login profile greets every shell it starts. The harness IS
  # installed there - it just is not on the non-interactive PATH, so the login
  # shell is what resolves it, and its greeting arrives with the answer. A
  # greeting is not "not installed": refusing on it would send the spawn away
  # from a host that can run the worker.
  agentdir="$CASE_DIR/agentbin"
  mkdir -p "$agentdir" "$FIX/fakehome"
  add_fake_remote_harness "$agentdir" fmbanneragent
  cat > "$FIX/fakehome/.bash_profile" <<SH
printf 'Welcome to example-host\n'
printf '3 packages can be updated.\n'
PATH="$agentdir:\$PATH"
SH
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    FM_ORCA_FAKE_HOST_PATH="/usr/bin:/bin" \
    bash -c '. "$0/bin/backends/orca.sh"
h=$(fm_backend_orca_exec_open repo-remote::/srv/app-task probe '"$FM_REMOTE_HOST"') || exit 9
fm_backend_orca_remote_which "$h" fmbanneragent' "$ROOT" )
  status=$?
  expect_code 0 "$status" "a harness the login shell resolves must not be reported as missing because of a banner"
  [ "$out" = "$agentdir/fmbanneragent" ] \
    || fail "remote which should return the path the login shell resolved, not the banner, got '$out'"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    FM_ORCA_FAKE_HOST_PATH="/usr/bin:/bin" \
    bash -c '. "$0/bin/backends/orca.sh"
h=$(fm_backend_orca_exec_open repo-remote::/srv/app-task probe '"$FM_REMOTE_HOST"') || exit 9
fm_backend_orca_remote_which "$h" fmdefinitelymissing' "$ROOT" )
  status=$?
  [ "$status" -ne 0 ] || fail "a banner must not turn an absent harness into a resolved one"
  [ -z "$out" ] || fail "an unresolvable harness must print nothing even behind a banner, got '$out'"
  pass "fm_backend_orca_remote_which: resolves through a login banner and still refuses a harness the host does not have"
}

test_remote_which_refuses_an_absolute_looking_line_that_is_not_the_agent() {
  local out status agentdir notice notesdir
  orca_remote_case remote-which-lookalike
  # A host whose login profile leaves an exit hook - an ordinary way for a
  # profile to say something on the way out. The harness IS installed and the
  # login shell resolves it, so the reply carries the real path AND a trailing
  # line that has nothing but a path's SHAPE. Shape is not proof: returning that
  # line pins the launch to something that is not the agent, and the worker
  # terminal then fails on it instead of the spawn refusing out loud.
  agentdir="$CASE_DIR/agentbin"
  notice="$CASE_DIR/release-notes.txt"
  notesdir="$CASE_DIR/agent-notes"
  mkdir -p "$agentdir" "$notesdir" "$FIX/fakehome"
  printf 'read me first\n' > "$notice"
  chmod 644 "$notice"
  add_fake_remote_harness "$agentdir" fmtrapagent
  remote_which_under_profile() {  # <harness-name>
    PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
      FM_ORCA_FAKE_HOST_PATH="/usr/bin:/bin" \
      bash -c '. "$0/bin/backends/orca.sh"
h=$(fm_backend_orca_exec_open repo-remote::/srv/app-task probe '"$FM_REMOTE_HOST"') || exit 9
fm_backend_orca_remote_which "$h" "$1"' "$ROOT" "$1"
  }

  # Trailing line names a real file that is not executable.
  cat > "$FIX/fakehome/.bash_profile" <<SH
PATH="$agentdir:\$PATH"
trap 'printf "%s\n" "$notice"' EXIT
SH
  out=$(remote_which_under_profile fmtrapagent)
  status=$?
  expect_code 0 "$status" "the harness the host really has must still resolve behind a trailing profile line"
  [ "$out" = "$agentdir/fmtrapagent" ] \
    || fail "remote which returned a line that merely looks like a path instead of the executable the host has, got '$out'"

  # Trailing line names a real directory - which IS executable to `[ -x ]`, so
  # only rejecting directories keeps this from resolving.
  cat > "$FIX/fakehome/.bash_profile" <<SH
PATH="$agentdir:\$PATH"
trap 'printf "%s\n" "$notesdir"' EXIT
SH
  out=$(remote_which_under_profile fmtrapagent)
  status=$?
  expect_code 0 "$status" "a trailing directory line must not stop the real harness from resolving"
  [ "$out" = "$agentdir/fmtrapagent" ] \
    || fail "remote which returned a directory instead of the executable the host has, got '$out'"

  # And a harness the host genuinely does not have still resolves nothing, which
  # is what makes the spawn refuse with its concrete missing-executable message.
  out=$(remote_which_under_profile fmdefinitelymissing)
  status=$?
  [ "$status" -ne 0 ] || fail "an absent harness must not be resolved by a line the login profile printed"
  [ -z "$out" ] || fail "an absent harness must print nothing, got '$out'"
  unset -f remote_which_under_profile
  pass "fm_backend_orca_remote_which: proves its candidate is an executable on the host instead of trusting a line's shape"
}

test_isolation_verdicts_distinguish_primary_and_subdirectory() {
  local proj wt out
  orca_remote_case isolation
  proj="$CASE_DIR/proj"
  wt="$CASE_DIR/wt"
  fm_git_worktree "$proj" "$wt" fm/iso
  mkdir -p "$wt/nested"
  run_isolation() {
    PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
      bash -c '. "$0/bin/backends/orca.sh"
h=$(fm_backend_orca_exec_open repo-remote::x probe '"$FM_REMOTE_HOST"') || exit 9
fm_backend_orca_remote_worktree_isolation "$h" "$1" "$2"' "$ROOT" "$1" "$2"
  }
  out=$(run_isolation "$wt" "$proj")
  [ "$out" = ISOLATED ] || fail "a real sibling worktree should read ISOLATED, got '$out'"
  out=$(run_isolation "$proj" "$proj")
  [ "$out" = IS-PRIMARY ] || fail "the primary checkout should read IS-PRIMARY, got '$out'"
  out=$(run_isolation "$wt/nested" "$proj")
  [ "$out" = TOPLEVEL-MISMATCH ] || fail "a subdirectory of a worktree should read TOPLEVEL-MISMATCH, got '$out'"
  out=$(run_isolation "$CASE_DIR/absent" "$proj")
  [ "$out" = NOT-A-WORKTREE ] || fail "a missing path should read NOT-A-WORKTREE, got '$out'"
  pass "fm_backend_orca_remote_worktree_isolation: separates an isolated worktree from the primary, a subdirectory, and a missing path"
}

test_capture_reads_terminal_tail_json() {
  local out
  orca_case capture-tail
  printf '{"result":{"terminal":{"tail":["line one","line two"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_capture term-123 40' "$ROOT" )
  [ "$out" = $'line one\nline two' ] || fail "capture should print result.terminal.tail joined by newlines, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''read'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--limit'$'\x1f''40'$'\x1f''--json' \
    "capture did not call orca terminal read with terminal/limit/json"
  pass "fm_backend_orca_capture: parses result.terminal.tail and calls terminal read"
}

test_capture_falls_back_to_text_fields() {
  local out
  orca_case capture-text
  printf '{"result":{"text":"plain text output"}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_capture term-abc 5' "$ROOT" )
  [ "$out" = "plain text output" ] || fail "capture should fall back to result.text, got '$out'"
  pass "fm_backend_orca_capture: falls back to result text fields"
}

test_capture_fails_on_orca_error_json() {
  local out status
  orca_case capture-error-json
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_capture term-stale 5' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "capture should fail on Orca ok:false read JSON"
  assert_contains "$out" "terminal handle stale" "capture should surface the Orca read error message"
  pass "fm_backend_orca_capture: fails closed on Orca read error JSON"
}

test_runtime_check_accepts_ready_orca_status() {
  local out
  orca_case runtime-ready
  printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_ORCA_STATUS_RESPONSE=sequence \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_runtime_check' "$ROOT" )
  [ -z "$out" ] || fail "runtime_check should be quiet on ready status, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''status'$'\x1f''--json' \
    "runtime_check did not call orca status --json"
  pass "fm_backend_orca_runtime_check: accepts reachable ready runtime"
}

test_runtime_check_refuses_unready_orca_status() {
  local out status
  orca_case runtime-unready
  printf '{"ok":true,"result":{"runtime":{"reachable":false,"state":"starting"}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_ORCA_STATUS_RESPONSE=sequence \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_runtime_check' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "runtime_check should fail when Orca runtime is not ready"
  assert_contains "$out" "requires a ready Orca runtime" "runtime_check should explain the readiness requirement"
  pass "fm_backend_orca_runtime_check: fails closed when runtime is not ready"
}

test_send_text_submit_verifies_empty_composer_after_enter() {
  local out
  orca_case send-submit
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["╭──╮","│ > │","╰──╯"],"limited":true,"oldestCursor":"cursor-old"},"limited":true,"oldestCursor":"cursor-old"}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["╭──╮","│ > │","╰──╯"],"latestCursor":"cursor-new"}}}\n' > "$RESP/4.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should report empty on successful Orca send, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--text'$'\x1f''hello captain'$'\x1f''--json' \
    "send_text_submit did not type the text literally before Enter"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--text'$'\x1f\x1f''--enter'$'\x1f''--json' \
    "send_text_submit did not send Enter after typing"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''read'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--cursor'$'\x1f''cursor-old'$'\x1f''--limit' \
    "send_text_submit did not follow cursor-backed reads when Orca reports a limited page"
  pass "fm_backend_orca_send_text_submit: verifies empty composer after Enter"
}

test_send_text_submit_keeps_current_tail_when_limited() {
  local out log_text enter_count
  orca_case send-submit-limited-current-pending
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["noise","│ > hello captain │"],"limited":true,"oldestCursor":"cursor-old"},"limited":true,"oldestCursor":"cursor-old"}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["╭──╮","│ > │","╰──╯"],"latestCursor":"cursor-new"}}}\n' > "$RESP/4.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/5.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["│ > │"]}}}\n' > "$RESP/6.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should keep the limited current tail and retry, got '$out'"
  log_text=$(cat "$LOG")
  enter_count=$(printf '%s\n' "$log_text" | grep -c $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-123\x1f--text\x1f\x1f--enter\x1f--json')
  [ "$enter_count" -eq 2 ] || fail "send_text_submit should see pending text in the current tail before older cursor text, got $enter_count Enter(s)"
  pass "fm_backend_orca_send_text_submit: preserves current tail when limited reads fetch older cursor text"
}

test_send_text_submit_retries_when_composer_stays_pending() {
  local out log_text enter_count
  orca_case send-submit-pending
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["│ > hello captain │"]}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/4.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["│ > │"]}}}\n' > "$RESP/5.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should retry Enter until the composer clears, got '$out'"
  log_text=$(cat "$LOG")
  enter_count=$(printf '%s\n' "$log_text" | grep -c $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-123\x1f--text\x1f\x1f--enter\x1f--json')
  [ "$enter_count" -eq 2 ] || fail "send_text_submit should send Enter twice when the first read is pending, got $enter_count"
  pass "fm_backend_orca_send_text_submit: retries Enter while composer remains pending"
}

test_composer_state_popup_placeholder_fill_is_pending() {
  local out
  orca_case composer-popup-placeholder
  printf '{"ok":true,"result":{"terminal":{"tail":["  ╭──────────────────────────────────────╮","  │ ❯ /compact compaction instructions    │","  ╰──────────────── Composer ─────────────╯","","  Enter:send"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_composer_state term-123' "$ROOT" )
  [ "$out" = pending ] || fail "a popup-close-with-placeholder-fill must still read as pending (not yet submitted), got '$out'"
  pass "fm_backend_orca_composer_state: a slash-command popup's argument-hint placeholder still reads pending"
}

# Dead-shell injection safety (task fm-composer-shellglyph-safety): a pane whose
# agent has exited to a bare login shell has no bordered composer row, so the
# classifier finds nothing and reports `unknown` - NOT a safe (empty) injection
# target. Covers the same guarantee herdr/cmux/tmux tests pin for their backends.
test_composer_state_bare_shell_prompt_is_unknown() {
  local out
  orca_case composer-bare-shell
  printf '{"ok":true,"result":{"terminal":{"tail":["some earlier output","kunchen@mac firstmate $ "]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_composer_state term-123' "$ROOT" )
  [ "$out" = unknown ] || fail "a bare dead-shell prompt (no bordered composer row) must read unknown, got '$out'"
  pass "fm_backend_orca_composer_state: a bare dead-shell prompt reads unknown (unsafe-for-injection), never empty"
}

test_send_text_submit_popup_autocomplete_requires_second_enter() {
  local out log_text enter_count
  orca_case send-submit-popup-autocomplete
  # 1: literal send "/compact"
  # 2: Enter #1 closes the popup and fills the placeholder
  # 3: read - composer still holds real pending text
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["  ╭──────────────────────────────────────╮","  │ ❯ /compact compaction instructions    │","  ╰──────────────── Composer ─────────────╯","","  Enter:send"]}}}\n' > "$RESP/3.out"
  # 4: Enter #2 actually submits
  # 5: read - composer is empty
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/4.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["  ╭────────────────────────╮","  │ ❯                      │","  ╰──────── Composer ─────╯","","  Shift+Tab:mode"]}}}\n' > "$RESP/5.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "/compact" 3 0.01 1.2' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should eventually report empty once the SECOND Enter actually clears the composer, got '$out'"
  log_text=$(cat "$LOG")
  enter_count=$(printf '%s\n' "$log_text" | grep -c $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-123\x1f--text\x1f\x1f--enter\x1f--json')
  [ "$enter_count" -eq 2 ] || fail "send_text_submit must send a SECOND Enter after the popup-placeholder fill still reads pending, got $enter_count Enter(s)"
  pass "fm_backend_orca_send_text_submit: a slash-command popup's placeholder fill on Enter #1 does not short-circuit as submitted; Enter #2 is retried and lands it"
}

test_send_literal_constructs_non_enter_send() {
  orca_case send-literal
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_literal term-123 "typed only"' "$ROOT"
  expect_code 0 $? "send_literal should succeed"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--text'$'\x1f''typed only'$'\x1f''--json' \
    "send_literal did not send text without --enter"
  assert_not_contains "$(cat "$LOG")" $'\x1f''--enter' "send_literal should not submit Enter"
  pass "fm_backend_orca_send_literal: sends text without submitting"
}

test_send_text_submit_reports_send_failed() {
  local out
  orca_case send-fail
  printf '1\n' > "$RESP/1.exit"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "hello" 1 0.01 0.01' "$ROOT" )
  [ "$out" = send-failed ] || fail "failed Orca send should report send-failed, got '$out'"
  pass "fm_backend_orca_send_text_submit: reports send-failed when Orca send fails"
}

test_send_helpers_reject_orca_error_json() {
  local out status
  orca_case send-error-json
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_line term-stale "hello"' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_text_line should fail on Orca ok:false JSON"
  assert_contains "$out" "terminal handle stale" "send_text_line should surface the Orca send error"
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/2.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_literal term-stale "typed"' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_literal should fail on Orca ok:false JSON"
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-stale Enter' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_key should fail on Orca ok:false JSON"
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/4.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-stale "hello" 1 0.01 0.01' "$ROOT" 2>/dev/null )
  [ "$out" = send-failed ] || fail "send_text_submit should report send-failed on Orca ok:false JSON, got '$out'"
  pass "Orca send helpers: fail closed on ok:false JSON"
}

test_send_key_enter_and_interrupt() {
  orca_case send-key
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-123 Enter; fm_backend_orca_send_key term-123 C-c' "$ROOT"
  expect_code 0 $? "send_key Enter and C-c should succeed"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--text'$'\x1f\x1f''--enter'$'\x1f''--json' \
    "send_key Enter did not send empty text with --enter"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--interrupt'$'\x1f''--json' \
    "send_key C-c did not send --interrupt"
  pass "fm_backend_orca_send_key: Enter maps to empty enter, C-c maps to interrupt"
}

test_send_key_refuses_unknown_key() {
  local out status
  orca_case send-key-unknown
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-123 F12' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_key should refuse unsupported Orca keys"
  assert_contains "$out" "unsupported Orca key 'F12'" "send_key did not name the unsupported key"
  pass "fm_backend_orca_send_key: refuses unsupported keys loudly"
}

test_send_key_refuses_escape_until_supported() {
  local out status
  orca_case send-key-escape
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-123 Escape' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_key should refuse Escape until Orca exposes a real Escape primitive"
  assert_contains "$out" "unsupported Orca key 'Escape'" "send_key did not name Escape as unsupported"
  [ ! -s "$LOG" ] || fail "unsupported Escape should not call orca terminal send"
  pass "fm_backend_orca_send_key: refuses Escape instead of mapping it to interrupt"
}

test_kill_is_best_effort_close() {
  orca_case kill
  printf '1\n' > "$RESP/1.exit"
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_kill term-123' "$ROOT"
  expect_code 0 $? "kill should stay best-effort when Orca close fails"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--json' \
    "kill did not call orca terminal close"
  pass "fm_backend_orca_kill: calls terminal close and stays best-effort"
}

test_remove_worktree_refuses_empty_id() {
  local out status
  orca_case remove-empty
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_remove_worktree ""' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "remove_worktree should fail when the Orca worktree id is empty"
  assert_contains "$out" "missing Orca worktree id" "remove_worktree did not explain the missing id"
  [ ! -s "$LOG" ] || fail "remove_worktree should not call Orca with an empty id"
  pass "fm_backend_orca_remove_worktree: refuses empty worktree ids"
}

test_remove_worktree_rejects_orca_error_json() {
  local out status
  orca_case remove-error-json
  printf '{"ok":false,"error":{"code":"worktree_not_found","message":"worktree not found"}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_remove_worktree wt-gone' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "remove_worktree should fail on Orca ok:false JSON"
  assert_contains "$out" "worktree not found" "remove_worktree should surface the Orca removal error"
  pass "fm_backend_orca_remove_worktree: fails closed on ok:false JSON"
}

test_worktree_path_resolves_id() {
  local out
  orca_case path-resolve
  printf '{"ok":true,"result":{"worktree":{"id":"wt-123","path":"/tmp/orca-wt"}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_path wt-123' "$ROOT" )
  [ "$out" = /tmp/orca-wt ] || fail "worktree path helper should print the resolved path, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f''id:wt-123'$'\x1f''--json' \
    "worktree path helper did not call orca worktree show"
  pass "fm_backend_orca_worktree_path: resolves an Orca worktree id to its path"
}

test_json_get_ignores_undocumented_terminal_id_shapes() {
  local out status wt_id wt_path term
  orca_case parser-pruned-terminal-shapes

  set +e
  out=$( printf '{"ok":true,"result":{"id":"term-root-id"}}\n' | \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_json_get terminal-handle' "$ROOT" )
  status=$?
  set +e
  [ "$status" -ne 0 ] || fail "terminal-handle should not treat undocumented result.id as a terminal handle, got '$out'"

  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-123"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-123","path":"/tmp/orca-wt","terminal":{"handle":"term-nested"}}}}\n' > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create /repo/path fm-task' "$ROOT" )
  wt_id=${out%%$'\t'*}
  wt_path=${out#*$'\t'}
  term=${wt_path#*$'\t'}
  wt_path=${wt_path%%$'\t'*}
  [ "$wt_id" = wt-123 ] || fail "worktree helper should still print worktree id, got '$wt_id'"
  [ "$wt_path" = /tmp/orca-wt ] || fail "worktree helper should still print worktree path, got '$wt_path'"
  [ "$term" = "$wt_path" ] || fail "worktree helper should ignore undocumented result.worktree.terminal and omit an implicit terminal, got '$out'"
  pass "fm_backend_orca_json_get: ignores undocumented terminal id shapes"
}

test_worktree_and_terminal_helpers_parse_json() {
  local out wt_id wt_path term
  orca_case lifecycle-helpers
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-123"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-123","path":"/tmp/orca-wt"}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"terminal":{"handle":"term-123"}}}\n' > "$RESP/4.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create /repo/path fm-task' "$ROOT" )
  wt_id=${out%%$'\t'*}
  wt_path=${out#*$'\t'}
  [ "$wt_id" = wt-123 ] || fail "worktree helper should print worktree id, got '$wt_id'"
  [ "$wt_path" = /tmp/orca-wt ] || fail "worktree helper should print worktree path, got '$wt_path'"
  term=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_terminal_create wt-123 fm-task' "$ROOT" )
  [ "$term" = term-123 ] || fail "terminal helper should print terminal handle, got '$term'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''repo'$'\x1f''show'$'\x1f''--repo'$'\x1f''path:/repo/path'$'\x1f''--json' \
    "worktree helper should first check repo registration"
  assert_contains "$(cat "$LOG")" $'orca\x1f''repo'$'\x1f''add'$'\x1f''--path'$'\x1f''/repo/path'$'\x1f''--json' \
    "worktree helper should register an absent repo"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''create'$'\x1f''--repo'$'\x1f''id:repo-123'$'\x1f''--name'$'\x1f''fm-task'$'\x1f''--no-parent'$'\x1f''--setup'$'\x1f''skip'$'\x1f''--json' \
    "worktree helper did not create an independent no-hook worktree"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''create'$'\x1f''--worktree'$'\x1f''id:wt-123'$'\x1f''--title'$'\x1f''fm-task'$'\x1f''--json' \
    "terminal helper did not create a titled terminal for the worktree"
  pass "Orca lifecycle helpers: register repo, create worktree, create terminal, parse stable ids"
}

test_worktree_create_removes_worktree_when_path_missing() {
  local out status
  orca_case lifecycle-missing-path
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-no-path"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-no-path"},"terminal":{"handle":"term-no-path"}}}\n' > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create /repo/path fm-task' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "worktree helper should fail when Orca omits the worktree path"
  assert_contains "$out" "orca worktree create did not return a path for fm-task" \
    "worktree helper did not explain the missing path"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-no-path'$'\x1f''--json' \
    "worktree helper did not close the implicit terminal when path parsing failed"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-no-path'$'\x1f''--force'$'\x1f''--json' \
    "worktree helper did not remove the pathless Orca worktree"
  pass "fm_backend_orca_worktree_create: removes created worktree when path is missing"
}

test_spawn_preserves_orca_metadata_when_pathless_worktree_cleanup_fails() {
  local proj data state config id out status
  id="orcapathlessz6"
  proj="$TMP_ROOT/pathless-cleanup-project"
  data="$TMP_ROOT/pathless-cleanup-data"
  state="$TMP_ROOT/pathless-cleanup-state"
  config="$TMP_ROOT/pathless-cleanup-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case pathless-cleanup-fail
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-pathless-cleanup"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-pathless-cleanup"}}}\n' > "$RESP/3.out"
  printf '{"ok":false,"error":{"code":"worktree_not_removed","message":"worktree not removed"}}\n' > "$RESP/4.out"
  printf '{"ok":false,"error":{"code":"worktree_not_removed","message":"worktree not removed"}}\n' > "$RESP/5.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Orca spawn should fail when path parsing and cleanup fail"
  assert_contains "$out" "orca worktree create did not return a path" \
    "pathless worktree failure should explain the missing path"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-pathless-cleanup'$'\x1f''--force'$'\x1f''--json' \
    "pathless cleanup should attempt helper-backed worktree removal"
  assert_present "$state/$id.meta" "failed pathless cleanup should preserve metadata"
  assert_grep "window=fm-$id" "$state/$id.meta" "preserved pathless metadata missing stable window alias"
  assert_grep "backend=orca" "$state/$id.meta" "preserved pathless metadata missing backend=orca"
  assert_grep "orca_worktree_id=wt-pathless-cleanup" "$state/$id.meta" "preserved pathless metadata missing Orca worktree id"
  assert_no_grep "terminal=" "$state/$id.meta" "preserved pathless metadata should not invent a terminal handle"
  pass "fm-spawn.sh --backend orca: preserves metadata when pathless cleanup fails"
}

test_spawn_writes_orca_metadata_and_launches_harness() {
  local proj wt data state config id out log
  id="orcaspawnz1"
  proj="$TMP_ROOT/spawn-project"
  wt="$TMP_ROOT/spawn-wt"
  data="$TMP_ROOT/spawn-data"
  state="$TMP_ROOT/spawn-state"
  config="$TMP_ROOT/spawn-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case spawn
  log="$LOG"
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-spawn"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-spawn","path":"%s"},"terminal":{"handle":"term-spawn"}}}\n' "$wt" > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  expect_code 0 $? "fm-spawn.sh --backend orca should succeed with fake Orca"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=claude kind=ship mode=no-mistakes yolo=off window=fm-$id worktree=$wt" \
    "spawn output missing Orca window/worktree summary"
  assert_grep "backend=orca" "$state/$id.meta" "meta missing backend=orca"
  assert_grep "window=fm-$id" "$state/$id.meta" "meta missing stable Orca window alias"
  assert_grep "terminal=term-spawn" "$state/$id.meta" "meta missing terminal handle"
  assert_grep "orca_worktree_id=wt-spawn" "$state/$id.meta" "meta missing Orca worktree id"
  assert_grep "worktree=$wt" "$state/$id.meta" "meta missing Orca worktree path"
  assert_not_contains "$(cat "$log")" $'orca\x1f''terminal'$'\x1f''create' \
    "spawn should reuse the implicit terminal returned by Orca worktree creation"
  assert_contains "$(cat "$log")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-spawn'$'\x1f''--text'$'\x1f''export GOTMPDIR=/tmp/fm-orcaspawnz1/gotmp'$'\x1f''--enter'$'\x1f''--json' \
    "spawn did not export GOTMPDIR through the Orca terminal"
  assert_contains "$(cat "$log")" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions" \
    "spawn did not send the selected harness launch command through Orca"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh --backend orca: reuses implicit terminal, records metadata, launches harness"
}

test_spawn_refuses_orca_secondmate_before_home_mutation() {
  local home subhome data state config id out status
  id="orcasmz1"
  home="$TMP_ROOT/secondmate-refusal-home"
  subhome="$TMP_ROOT/secondmate-refusal-subhome"
  data="$home/data"
  state="$home/state"
  config="$home/config"
  mkdir -p "$data" "$state" "$config" "$subhome/bin" "$subhome/data" "$subhome/state" "$subhome/projects"
  printf '%s\n' "$id" > "$subhome/.fm-secondmate-home"
  printf 'firstmate\n' > "$subhome/AGENTS.md"
  printf 'claude\n' > "$config/crew-harness"
  touch "$state/.last-watcher-beat"
  set +e
  out=$( FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$subhome" claude --backend orca --secondmate 2>&1 )
  status=$?
  set +e
  [ "$status" -ne 0 ] || fail "backend=orca --secondmate should be refused"
  assert_contains "$out" "backend=orca does not support --secondmate spawns yet" \
    "orca secondmate refusal should happen at backend selection"
  assert_absent "$subhome/config/crew-harness" \
    "orca secondmate refusal should not propagate inherited local material into the secondmate home"
  pass "fm-spawn.sh --backend orca --secondmate: refuses before secondmate-home mutation"
}

test_spawn_refuses_orca_when_runtime_not_ready() {
  local proj data state config id out status
  id="orcaruntimez6"
  proj="$TMP_ROOT/runtime-down-project"
  data="$TMP_ROOT/runtime-down-data"
  state="$TMP_ROOT/runtime-down-state"
  config="$TMP_ROOT/runtime-down-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case runtime-down-spawn
  printf '{"ok":true,"result":{"runtime":{"reachable":false,"state":"starting"}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_ORCA_STATUS_RESPONSE=sequence \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "fm-spawn.sh --backend orca should refuse when Orca runtime is not ready"
  assert_contains "$out" "requires a ready Orca runtime" \
    "runtime readiness refusal should explain the Orca requirement"
  assert_absent "$state/$id.meta" "runtime refusal must not record metadata"
  assert_contains "$(cat "$LOG")" $'orca\x1f''status'$'\x1f''--json' \
    "spawn did not probe Orca runtime readiness"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''repo' \
    "spawn should fail before repo/worktree creation when runtime is not ready"
  pass "fm-spawn.sh --backend orca: refuses before mutation when Orca runtime is not ready"
}

test_spawn_refuses_orca_nonisolated_worktree() {
  local proj data state config id out status
  id="orcabadwtz4"
  proj="$TMP_ROOT/bad-spawn-project"
  data="$TMP_ROOT/bad-spawn-data"
  state="$TMP_ROOT/bad-spawn-state"
  config="$TMP_ROOT/bad-spawn-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case bad-spawn
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-bad"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-bad","path":"%s"},"terminal":{"handle":"term-bad"}}}\n' "$proj" > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  expect_code 1 "$status" "fm-spawn.sh --backend orca should refuse a primary checkout worktree"
  assert_contains "$out" "orca worktree create did not yield an isolated worktree" \
    "Orca spawn should reuse the isolated-worktree guard"
  assert_absent "$state/$id.meta" "aborted Orca spawn must not record meta"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''create' \
    "Orca spawn should validate the worktree before creating a terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-bad'$'\x1f''--json' \
    "Orca spawn should close the implicit terminal after validation aborts"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-bad'$'\x1f''--force'$'\x1f''--json' \
    "Orca spawn should remove the worktree after validation aborts"
  pass "fm-spawn.sh --backend orca: refuses non-isolated worktrees and closes implicit terminals"
}

test_spawn_removes_orca_worktree_when_terminal_create_fails() {
  local proj wt data state config id out status
  id="orcatermfailz8"
  proj="$TMP_ROOT/terminal-fail-project"
  wt="$TMP_ROOT/terminal-fail-wt"
  data="$TMP_ROOT/terminal-fail-data"
  state="$TMP_ROOT/terminal-fail-state"
  config="$TMP_ROOT/terminal-fail-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case terminal-fail
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-terminal-fail"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-terminal-fail","path":"%s"}}}\n' "$wt" > "$RESP/3.out"
  printf '1\n' > "$RESP/4.exit"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Orca spawn should fail when terminal creation fails"
  assert_absent "$state/$id.meta" "terminal-create abort should not record metadata after successful cleanup"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''create'$'\x1f''--worktree'$'\x1f''id:wt-terminal-fail'$'\x1f''--title'$'\x1f'"fm-$id"$'\x1f''--json' \
    "Orca spawn should attempt terminal creation before abort cleanup"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-terminal-fail'$'\x1f''--force'$'\x1f''--json' \
    "Orca spawn should remove the worktree when terminal creation fails"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "Orca spawn should not close a terminal when no handle was recorded"
  pass "fm-spawn.sh --backend orca: removes worktree when terminal creation fails"
}

test_spawn_preserves_orca_metadata_when_abort_cleanup_fails() {
  local proj wt data state config id out status
  id="orcacleanupleakz0"
  proj="$TMP_ROOT/cleanup-fail-project"
  wt="$TMP_ROOT/cleanup-fail-wt"
  data="$TMP_ROOT/cleanup-fail-data"
  state="$TMP_ROOT/cleanup-fail-state"
  config="$TMP_ROOT/cleanup-fail-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case cleanup-fail
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-cleanup-fail"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-cleanup-fail","path":"%s"}}}\n' "$wt" > "$RESP/3.out"
  printf '1\n' > "$RESP/4.exit"
  printf '1\n' > "$RESP/5.exit"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Orca spawn should fail when terminal creation and abort cleanup fail"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-cleanup-fail'$'\x1f''--force'$'\x1f''--json' \
    "Orca spawn should attempt helper cleanup before preserving metadata"
  assert_present "$state/$id.meta" "failed Orca abort cleanup should preserve metadata"
  assert_grep "window=fm-$id" "$state/$id.meta" "preserved metadata missing stable window alias"
  assert_grep "backend=orca" "$state/$id.meta" "preserved metadata missing backend=orca"
  assert_grep "orca_worktree_id=wt-cleanup-fail" "$state/$id.meta" "preserved metadata missing Orca worktree id"
  assert_no_grep "terminal=" "$state/$id.meta" "preserved metadata should not invent a terminal handle"
  pass "fm-spawn.sh --backend orca: preserves metadata when abort cleanup fails"
}

test_spawn_releases_orca_resources_when_metadata_write_fails() {
  local proj wt data state config id out status
  id="orcametafailz9"
  proj="$TMP_ROOT/meta-fail-project"
  wt="$TMP_ROOT/meta-fail-wt"
  data="$TMP_ROOT/meta-fail-data"
  state="$TMP_ROOT/meta-fail-state"
  config="$TMP_ROOT/meta-fail-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state/$id.meta" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  orca_case meta-fail
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-meta-fail"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-meta-fail","path":"%s"}}}\n' "$wt" > "$RESP/3.out"
  printf '{"ok":true,"result":{"terminal":{"handle":"term-meta-fail"}}}\n' > "$RESP/4.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Orca spawn should fail when metadata cannot be written"
  assert_contains "$out" "Is a directory" "spawn should fail at metadata publication"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-meta-fail'$'\x1f''--json' \
    "Orca spawn should close the recorded terminal when a later abort occurs"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-meta-fail'$'\x1f''--force'$'\x1f''--json' \
    "Orca spawn should remove the recorded worktree when a later abort occurs"
  [ ! -f "$state/$id.meta" ] || fail "metadata-write abort should not publish a regular metadata file"
  pass "fm-spawn.sh --backend orca: releases terminal and worktree on later aborts"
}

test_peek_send_and_crew_state_route_through_orca_meta() {
  local wt state id out neutral
  id="orcaiopathz2"
  wt="$TMP_ROOT/io-wt"
  fm_git_init_commit "$wt"
  state="$TMP_ROOT/io-state"; mkdir -p "$state"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-io" "worktree=$wt" "project=$wt" "harness=claude" "kind=scout" "backend=orca"
  touch "$state/.last-watcher-beat"
  orca_case io-path
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  printf '{"ok":true,"result":{"terminal":{"tail":["ready"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-peek.sh" "fm-$id" 10 )
  [ "$out" = ready ] || fail "fm-peek should read through Orca metadata, got '$out'"
  printf '{"ok":true,"result":{"send":{"handle":"term-io","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-io","accepted":true}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["│ > │"]}}}\n' > "$RESP/4.out"
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "fm-$id" "hello orca"
  printf '{"ok":true,"result":{"terminal":{"tail":["idle prompt"]}}}\n' > "$RESP/5.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-crew-state.sh" "$id" )
  assert_contains "$out" "state: unknown" "crew-state should fall back cleanly for an idle Orca scout"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''read'$'\x1f''--terminal'$'\x1f''term-io' \
    "peek/crew-state did not read the recorded Orca terminal"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''read'$'\x1f''--terminal'$'\x1f'"fm-$id" \
    "crew-state should not read the stable Orca alias as a terminal handle"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-io'$'\x1f''--text'$'\x1f''hello orca'$'\x1f''--json' \
    "send did not type through the recorded Orca terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-io'$'\x1f''--text'$'\x1f\x1f''--enter'$'\x1f''--json' \
    "send did not submit Enter through the recorded Orca terminal"
  pass "fm-peek/fm-send/fm-crew-state route through backend=orca metadata"
}

test_peek_and_crew_state_fail_closed_on_orca_error_json() {
  local wt state id out status neutral
  id="orcareaderrz7"
  wt="$TMP_ROOT/read-error-wt"
  fm_git_init_commit "$wt"
  state="$TMP_ROOT/read-error-state"; mkdir -p "$state"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-stale" "worktree=$wt" "project=$wt" "harness=claude" "kind=scout" "backend=orca"
  touch "$state/.last-watcher-beat"
  orca_case read-error-json
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-peek.sh" "fm-$id" 10 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "fm-peek should fail when Orca reports a stale terminal"
  assert_contains "$out" "terminal handle stale" "fm-peek should surface the Orca read error message"
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/2.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-crew-state.sh" "$id" )
  assert_contains "$out" "state: unknown" "crew-state should not treat an Orca read error as a live endpoint"
  assert_contains "$out" "backend target gone: term-stale" "crew-state should report the stale Orca terminal as gone"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''read'$'\x1f''--terminal'$'\x1f''term-stale' \
    "fm-peek/fm-crew-state did not read the recorded Orca terminal"
  pass "fm-peek/fm-crew-state: Orca read error JSON fails closed"
}

test_target_exists_rejects_orca_error_json() {
  local status
  orca_case target-exists-error-json
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/1.out"
  set +e
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_target_exists orca term-stale fm-task' "$ROOT"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "fm_backend_target_exists should reject Orca ok:false read JSON"
  pass "fm_backend_target_exists: Orca ok:false read JSON is not live"
}

test_scout_teardown_removes_orca_worktree_via_helper() {
  local proj wt data state config id out rc neutral
  id="orcateardownz3"
  proj="$TMP_ROOT/teardown-project"
  wt="$TMP_ROOT/teardown-wt"
  data="$TMP_ROOT/teardown-data"
  state="$TMP_ROOT/teardown-state"
  config="$TMP_ROOT/teardown-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-teardown" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-teardown" \
    "decisions_reviewed=1" "decision_keys="
  orca_case teardown
  printf '{"ok":true,"result":{"worktree":{"id":"wt-teardown","path":"%s"}}}\n' "$wt" > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "Orca scout teardown should succeed once report exists"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-teardown'$'\x1f''--json' \
    "teardown did not close the recorded Orca terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-teardown'$'\x1f''--force'$'\x1f''--json' \
    "teardown did not remove the Orca worktree through orca worktree rm"
  assert_absent "$state/$id.meta" "teardown should remove task metadata"
  pass "fm-teardown.sh backend=orca: scout report gate then helper-backed worktree removal"
}

test_scout_teardown_refuses_orca_id_path_mismatch() {
  local proj wt other_wt data state config id out rc neutral
  id="orcascoutmismatchz5"
  proj="$TMP_ROOT/scout-mismatch-project"
  wt="$TMP_ROOT/scout-mismatch-wt"
  other_wt="$TMP_ROOT/scout-mismatch-other-wt"
  data="$TMP_ROOT/scout-mismatch-data"
  state="$TMP_ROOT/scout-mismatch-state"
  config="$TMP_ROOT/scout-mismatch-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  git -C "$proj" worktree add --quiet -b "fm/$id-other" "$other_wt"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-scout-mismatch" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-scout-mismatch" \
    "decisions_reviewed=1" "decision_keys="
  orca_case scout-mismatch
  printf '{"ok":true,"result":{"worktree":{"id":"wt-scout-mismatch","path":"%s"}}}\n' "$other_wt" > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca scout teardown should refuse when id path differs from worktree="
  assert_contains "$out" "not inspected worktree" \
    "mismatched Orca scout worktree path refusal should name the mismatch"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "refused mismatched Orca scout teardown should not close terminals"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "refused mismatched Orca scout teardown should not remove worktrees"
  assert_present "$state/$id.meta" "refused mismatched scout teardown should preserve metadata"
  pass "fm-teardown.sh backend=orca: scout teardown refuses id/path mismatches"
}

test_teardown_removes_orca_worktree_when_path_missing() {
  local proj wt data state config id out rc neutral
  id="orcamissingpathz7"
  proj="$TMP_ROOT/missing-path-project"
  wt="$TMP_ROOT/missing-path-wt"
  data="$TMP_ROOT/missing-path-data"
  state="$TMP_ROOT/missing-path-state"
  config="$TMP_ROOT/missing-path-config"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-missing-path" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-missing-path" \
    "decisions_reviewed=1" "decision_keys="
  orca_case missing-path
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "Orca teardown should release helpers even when the path is absent"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-missing-path'$'\x1f''--json' \
    "teardown did not close the recorded Orca terminal when the path was absent"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-missing-path'$'\x1f''--force'$'\x1f''--json' \
    "teardown did not remove the recorded Orca worktree when the path was absent"
  assert_absent "$state/$id.meta" "successful helper cleanup should remove task metadata"
  pass "fm-teardown.sh backend=orca: releases terminal/worktree when path is absent"
}

test_teardown_preserves_metadata_when_orca_remove_error_json() {
  local proj wt data state config id out rc neutral
  id="orcaremoveerrz2"
  proj="$TMP_ROOT/remove-error-project"
  wt="$TMP_ROOT/remove-error-wt"
  data="$TMP_ROOT/remove-error-data"
  state="$TMP_ROOT/remove-error-state"
  config="$TMP_ROOT/remove-error-config"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-remove-error" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-remove-error" \
    "decisions_reviewed=1" "decision_keys="
  orca_case remove-error-teardown
  printf '{"ok":true,"result":{}}\n' > "$RESP/1.out"
  printf '{"ok":false,"error":{"code":"worktree_not_removed","message":"worktree not removed"}}\n' > "$RESP/2.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca teardown should fail when worktree removal returns ok:false JSON"
  assert_contains "$out" "worktree not removed" "teardown should surface the Orca removal error"
  assert_present "$state/$id.meta" "failed Orca removal should preserve task metadata"
  pass "fm-teardown.sh backend=orca: preserves metadata on remove ok:false JSON"
}

test_scout_teardown_refuses_orca_missing_report_when_path_missing() {
  local proj wt data state config id out rc neutral
  id="orcanoreportz4"
  proj="$TMP_ROOT/missing-report-project"
  wt="$TMP_ROOT/missing-report-wt"
  data="$TMP_ROOT/missing-report-data"
  state="$TMP_ROOT/missing-report-state"
  config="$TMP_ROOT/missing-report-config"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-missing-report" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-missing-report"
  orca_case missing-report
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca scout teardown should refuse without a report even when the path is absent"
  assert_contains "$out" "has no report" "Orca scout teardown should explain the missing report"
  [ ! -s "$LOG" ] || fail "refused Orca scout teardown should not close terminals or remove worktrees"
  assert_present "$state/$id.meta" "refused Orca scout teardown should preserve metadata"
  pass "fm-teardown.sh backend=orca: scout report gate precedes pathless helper cleanup"
}

test_ship_teardown_refuses_orca_missing_worktree_path() {
  local proj wt data state config id out rc neutral
  id="orcashipmissingz8"
  proj="$TMP_ROOT/missing-ship-project"
  wt="$TMP_ROOT/missing-ship-wt"
  data="$TMP_ROOT/missing-ship-data"
  state="$TMP_ROOT/missing-ship-state"
  config="$TMP_ROOT/missing-ship-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-missing-ship" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-missing-ship"
  orca_case missing-ship-path
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca ship teardown should refuse a missing worktree path"
  assert_contains "$out" "no inspectable git worktree" \
    "Orca ship teardown should explain the fail-closed worktree requirement"
  [ ! -s "$LOG" ] || fail "refused Orca ship teardown should not close terminals or remove worktrees"
  assert_present "$state/$id.meta" "refused Orca ship teardown should preserve metadata"
  pass "fm-teardown.sh backend=orca: ship teardown fails closed when worktree path is missing"
}

test_ship_teardown_removes_orca_worktree_when_id_path_matches() {
  local proj wt data state config id out rc neutral
  id="orcashipmatchz2"
  proj="$TMP_ROOT/ship-match-project"
  wt="$TMP_ROOT/ship-match-wt"
  data="$TMP_ROOT/ship-match-data"
  state="$TMP_ROOT/ship-match-state"
  config="$TMP_ROOT/ship-match-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-ship-match" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-ship-match"
  orca_case ship-match
  printf '{"ok":true,"result":{"worktree":{"id":"wt-ship-match","path":"%s"}}}\n' "$wt" > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "Orca ship teardown should succeed when the id path matches the inspected worktree"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f''id:wt-ship-match'$'\x1f''--json' \
    "teardown did not resolve the Orca worktree id before removal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-ship-match'$'\x1f''--json' \
    "teardown did not close the matched Orca terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-ship-match'$'\x1f''--force'$'\x1f''--json' \
    "teardown did not remove the matched Orca worktree"
  assert_absent "$state/$id.meta" "successful matched teardown should remove task metadata"
  pass "fm-teardown.sh backend=orca: ship teardown requires a matching Orca id path"
}

test_ship_teardown_refuses_orca_unresolvable_worktree_id() {
  local proj wt data state config id out rc neutral
  id="orcashipunresolvedz1"
  proj="$TMP_ROOT/ship-unresolved-project"
  wt="$TMP_ROOT/ship-unresolved-wt"
  data="$TMP_ROOT/ship-unresolved-data"
  state="$TMP_ROOT/ship-unresolved-state"
  config="$TMP_ROOT/ship-unresolved-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-ship-unresolved" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-ship-unresolved"
  orca_case ship-unresolved
  printf '1\n' > "$RESP/1.exit"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca ship teardown should refuse when the worktree id cannot be resolved"
  assert_contains "$out" "cannot resolve Orca worktree id wt-ship-unresolved" \
    "unresolvable Orca worktree id refusal should explain the fail-closed check"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f''id:wt-ship-unresolved'$'\x1f''--json' \
    "teardown did not attempt to resolve the Orca worktree id"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "refused unresolved Orca ship teardown should not close terminals"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "refused unresolved Orca ship teardown should not remove worktrees"
  assert_present "$state/$id.meta" "refused unresolved Orca ship teardown should preserve metadata"
  pass "fm-teardown.sh backend=orca: ship teardown fails closed when id resolution fails"
}

test_ship_teardown_refuses_orca_id_path_mismatch() {
  local proj wt other_wt data state config id out rc neutral
  id="orcashipmismatchz9"
  proj="$TMP_ROOT/ship-mismatch-project"
  wt="$TMP_ROOT/ship-mismatch-wt"
  other_wt="$TMP_ROOT/ship-mismatch-other-wt"
  data="$TMP_ROOT/ship-mismatch-data"
  state="$TMP_ROOT/ship-mismatch-state"
  config="$TMP_ROOT/ship-mismatch-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  git -C "$proj" worktree add --quiet -b "fm/$id-other" "$other_wt"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-ship-mismatch" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-ship-mismatch"
  orca_case ship-mismatch
  printf '{"ok":true,"result":{"worktree":{"id":"wt-ship-mismatch","path":"%s"}}}\n' "$other_wt" > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca ship teardown should refuse when the id path differs from worktree="
  assert_contains "$out" "not inspected worktree" \
    "mismatched Orca worktree path refusal should name the mismatch"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f''id:wt-ship-mismatch'$'\x1f''--json' \
    "teardown did not resolve the mismatched Orca worktree id"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "refused mismatched Orca ship teardown should not close terminals"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "refused mismatched Orca ship teardown should not remove worktrees"
  assert_present "$state/$id.meta" "refused mismatched Orca ship teardown should preserve metadata"
  pass "fm-teardown.sh backend=orca: ship teardown refuses id/path mismatches"
}

test_teardown_refuses_orca_missing_worktree_id() {
  local proj wt data state config id out rc neutral
  id="orcamissingidz5"
  proj="$TMP_ROOT/missing-id-project"
  wt="$TMP_ROOT/missing-id-wt"
  data="$TMP_ROOT/missing-id-data"
  state="$TMP_ROOT/missing-id-state"
  config="$TMP_ROOT/missing-id-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-missing-id" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" "backend=orca" \
    "decisions_reviewed=1" "decision_keys="
  orca_case missing-id
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca teardown should refuse missing orca_worktree_id"
  assert_contains "$out" "missing orca_worktree_id" "teardown did not explain the missing Orca worktree id"
  assert_present "$state/$id.meta" "failed teardown must preserve task metadata"
  [ ! -s "$LOG" ] || fail "teardown should fail before closing terminals or removing worktrees without an Orca worktree id"
  pass "fm-teardown.sh backend=orca: refuses missing worktree ids before cleanup"
}

test_teardown_refuses_orca_worktree_without_terminal_handle() {
  local proj wt data state config id out rc neutral
  id="orcanotermz0"
  proj="$TMP_ROOT/no-terminal-project"
  wt="$TMP_ROOT/no-terminal-wt"
  data="$TMP_ROOT/no-terminal-data"
  state="$TMP_ROOT/no-terminal-state"
  config="$TMP_ROOT/no-terminal-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-no-terminal" \
    "decisions_reviewed=1" "decision_keys="
  orca_case no-terminal
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca teardown accepted metadata without a terminal handle"
  assert_contains "$out" "missing terminal" "teardown did not explain the incomplete Orca endpoint"
  [ ! -s "$LOG" ] || fail "teardown dispatched to Orca before rejecting the incomplete endpoint"
  assert_present "$state/$id.meta" "missing-terminal refusal removed task metadata"
  pass "fm-teardown.sh backend=orca: refuses incomplete worktree-only endpoint metadata before runtime dispatch"
}

test_secondmate_force_teardown_removes_orca_child_via_orca() {
  local home subhome childproj childwt child_id neutral out rc
  home="$TMP_ROOT/orca-child-parent"
  subhome="$TMP_ROOT/orca-child-secondmate"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/orca-child-worktree"
  child_id="orcachildz6"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$subhome/projects"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_git_worktree "$childproj" "$childwt" "fm/$child_id"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  printf '%s\n' "- domain - Orca child cleanup (home: $subhome; scope: orca cleanup; projects: alpha; added 2026-07-03)" \
    > "$home/data/secondmates.md"
  fm_write_meta "$subhome/state/$child_id.meta" \
    "window=fm-$child_id" "endpoint_task_id=$child_id" \
    "terminal=term-child-cleanup" "worktree=$childwt" "project=$childproj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-child-cleanup"
  orca_case secondmate-child-cleanup
  printf '{"ok":true,"result":{"worktree":{"id":"wt-child-cleanup","path":"%s"}}}\n' "$childwt" > "$RESP/1.out"
  add_tmux_fake "$FB"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" domain --force 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "forced secondmate teardown should remove Orca child work through Orca"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-child-cleanup'$'\x1f''--json' \
    "child cleanup did not close the recorded Orca terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-child-cleanup'$'\x1f''--force'$'\x1f''--json' \
    "child cleanup did not remove the Orca worktree through orca worktree rm"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f'"fm-$child_id" \
    "child cleanup closed the stable alias instead of the Orca terminal"
  assert_absent "$home/state/domain.meta" "parent metadata should be removed after forced teardown"
  pass "fm-teardown.sh --force: removes Orca secondmate children through Orca"
}

test_secondmate_force_teardown_refuses_orca_child_id_path_mismatch() {
  local home subhome childproj childwt other_wt child_id neutral out rc
  home="$TMP_ROOT/orca-child-mismatch-parent"
  subhome="$TMP_ROOT/orca-child-mismatch-secondmate"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/orca-child-mismatch-worktree"
  other_wt="$TMP_ROOT/orca-child-mismatch-other-worktree"
  child_id="orcachildmismatchz1"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$subhome/projects"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_git_worktree "$childproj" "$childwt" "fm/$child_id"
  git -C "$childproj" worktree add --quiet -b "fm/$child_id-other" "$other_wt"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  printf '%s\n' "- domain - Orca child cleanup (home: $subhome; scope: orca cleanup; projects: alpha; added 2026-07-03)" \
    > "$home/data/secondmates.md"
  fm_write_meta "$subhome/state/$child_id.meta" \
    "window=fm-$child_id" "endpoint_task_id=$child_id" \
    "terminal=term-child-mismatch" "worktree=$childwt" "project=$childproj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-child-mismatch"
  orca_case secondmate-child-mismatch
  printf '{"ok":true,"result":{"worktree":{"id":"wt-child-mismatch","path":"%s"}}}\n' "$other_wt" > "$RESP/1.out"
  add_tmux_fake "$FB"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" domain --force 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "forced secondmate teardown should refuse mismatched Orca child id/path"
  assert_contains "$out" "not inspected worktree" \
    "mismatched Orca child worktree path refusal should name the mismatch"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "refused mismatched Orca child cleanup should not close terminals"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "refused mismatched Orca child cleanup should not remove worktrees"
  assert_present "$home/state/domain.meta" "refused forced secondmate teardown should preserve parent metadata"
  pass "fm-teardown.sh --force: refuses Orca child id/path mismatches"
}

test_secondmate_force_teardown_refuses_partial_orca_child() {
  local home subhome childproj childwt child_id neutral out rc
  home="$TMP_ROOT/orca-partial-child-parent"
  subhome="$TMP_ROOT/orca-partial-child-secondmate"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/orca-partial-child-worktree"
  child_id="orcapartialz9"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$subhome/projects"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_git_worktree "$childproj" "$childwt" "fm/$child_id"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  printf '%s\n' "- domain - Orca partial child cleanup (home: $subhome; scope: orca cleanup; projects: alpha; added 2026-07-03)" \
    > "$home/data/secondmates.md"
  fm_write_meta "$subhome/state/$child_id.meta" \
    "window=fm-$child_id" "endpoint_task_id=$child_id" \
    "worktree=$childwt" "project=$childproj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-partial-child"
  orca_case secondmate-partial-child-cleanup
  add_tmux_fake "$FB"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" domain --force 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "forced secondmate teardown accepted a child with no terminal identity"
  assert_contains "$out" "missing terminal" "partial child refusal did not explain the incomplete endpoint"
  [ ! -s "$LOG" ] || fail "partial child refusal dispatched to Orca or tmux"
  assert_present "$home/state/domain.meta" "partial child refusal removed parent metadata"
  assert_present "$subhome/state/$child_id.meta" "partial child refusal removed child metadata"
  pass "fm-teardown.sh --force: refuses partial Orca secondmate children before runtime dispatch"
}

# The numbered fake answers in call order, and a remote child's identity proof
# asks `orca worktree show` twice (once for the path, once for the host) in each
# of the validation and cleanup passes. Every one of those calls must get the
# same answer, so the case describes the worktree once.
write_orca_worktree_show_responses() {  # <responses> <count> <worktree-id> <path> <host>
  local resp=$1 count=$2 id=$3 path=$4 host=$5 i
  for i in $(seq 1 "$count"); do
    printf '{"ok":true,"result":{"worktree":{"id":"%s","path":"%s","hostId":"%s","isMainWorktree":false}}}\n' \
      "$id" "$path" "$host" > "$resp/$i.out"
  done
}

# <state> <id> <worktree> - a crew child of a secondmate home whose files live
# on another Orca host, so nothing of it is on this filesystem.
remote_child_meta() {
  fm_write_meta "$1/$2.meta" \
    "window=fm-$2" "endpoint_task_id=$2" "terminal=term-$2" \
    "worktree=$3" "project=/srv/app" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" "backend=orca" \
    "orca_worktree_id=repo-remote::$3" "orca_host=$FM_REMOTE_HOST" "orca_remote=1" \
    "orca_remote_tasktmp=/tmp/fm-$2"
}

# <parent-home> <secondmate-home> - the parent record a forced secondmate
# teardown starts from.
remote_child_parent_home() {
  mkdir -p "$1/state" "$1/data" "$2/state" "$2/projects"
  printf 'domain\n' > "$2/.fm-secondmate-home"
  fm_write_meta "$1/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$2" "project=$2" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$2" "projects=alpha"
  printf '%s\n' "- domain - remote Orca child cleanup (home: $2; scope: orca cleanup; projects: alpha; added 2026-07-03)" \
    > "$1/data/secondmates.md"
}

test_secondmate_force_teardown_verifies_remote_orca_child_identity() {
  local home subhome child_id childwt neutral out rc

  # A child whose worktree is on another host. Asking THIS machine whether that
  # path exists asks the wrong machine, and "absent here" is not permission to
  # release what Orca still holds there - so the identity proof runs from Orca's
  # own records, and a worktree Orca reports at a different path is refused.
  child_id="orcaremotechildz1"
  childwt="/srv/fm-$child_id"
  home="$TMP_ROOT/orca-remote-child-mismatch-parent"
  subhome="$TMP_ROOT/orca-remote-child-mismatch-secondmate"
  remote_child_parent_home "$home" "$subhome"
  remote_child_meta "$subhome/state" "$child_id" "$childwt"
  orca_case secondmate-remote-child-mismatch
  write_orca_worktree_show_responses "$RESP" 6 "repo-remote::$childwt" "/srv/somewhere-else" "$FM_REMOTE_HOST"
  add_tmux_fake "$FB"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" domain --force 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "forced secondmate teardown released a remote Orca child whose recorded identity does not match Orca's"$'\n'"$out"
  assert_contains "$out" "not the recorded worktree" \
    "the refusal should name the remote child's identity mismatch"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "an unproven remote child worktree must not be removed"
  assert_present "$subhome/state/$child_id.meta" \
    "a refused remote child cleanup must preserve that child's record"
  assert_present "$home/state/domain.meta" \
    "a refused remote child cleanup must preserve the parent record"

  # The same child, with Orca reporting exactly what the child recorded: proven,
  # and released.
  child_id="orcaremotechildz2"
  childwt="/srv/fm-$child_id"
  home="$TMP_ROOT/orca-remote-child-match-parent"
  subhome="$TMP_ROOT/orca-remote-child-match-secondmate"
  remote_child_parent_home "$home" "$subhome"
  remote_child_meta "$subhome/state" "$child_id" "$childwt"
  orca_case secondmate-remote-child-match
  write_orca_worktree_show_responses "$RESP" 4 "repo-remote::$childwt" "$childwt" "$FM_REMOTE_HOST"
  add_tmux_fake "$FB"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" domain --force 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "a remote Orca child whose identity Orca confirms should still be released"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:repo-remote::'"$childwt" \
    "a proven remote child worktree must be released through Orca"
  assert_absent "$subhome/state/$child_id.meta" "a completed remote child cleanup should remove that child's record"
  assert_absent "$home/state/domain.meta" "a completed forced teardown should remove the parent record"
  pass "fm-teardown.sh --force: proves a remote Orca child's recorded identity from Orca's records before releasing it"
}

test_secondmate_force_teardown_sweeps_a_remote_orca_child_task_tmp() {
  local home subhome child_id childwt neutral out rc
  child_id="orcaremotechildz3"
  childwt="/srv/fm-$child_id"
  home="$TMP_ROOT/orca-remote-child-sweep-parent"
  subhome="$TMP_ROOT/orca-remote-child-sweep-secondmate"
  # The child's record is the only thing that knows where its temp root is, and
  # that root holds the worker's whole brief. Cleanup deletes the record, so a
  # sweep that does not happen here can never happen at all.
  orca_remote_case secondmate-remote-child-sweep
  write_remote_worktree_fixtures "$FIX" "$childwt"
  remote_child_parent_home "$home" "$subhome"
  remote_child_meta "$subhome/state" "$child_id" "$childwt"
  mkdir -p "/tmp/fm-$child_id"
  printf 'the whole task brief\n' > "/tmp/fm-$child_id/brief.md"
  add_tmux_fake "$FB"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_FIXTURES="$FIX" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" domain --force 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "a forced secondmate teardown should release its remote Orca child"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:repo-remote::'"$childwt" \
    "the remote child's worktree must still be released through Orca"
  assert_absent "/tmp/fm-$child_id" \
    "forced cleanup must sweep the remote child's task temp root before its record is deleted"
  assert_absent "$subhome/state/$child_id.meta" "a completed remote child cleanup should remove that child's record"
  rm -rf "/tmp/fm-$child_id"
  pass "fm-teardown.sh --force: sweeps a remote Orca child's task temp root on the host before deleting the record that names it"
}

test_dispatcher_sources_orca_and_routes_primitives() {
  local out
  orca_case dispatch
  printf '{"result":{"terminal":{"tail":["via dispatch"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_validate orca; fm_backend_capture orca term-123 9' "$ROOT" )
  [ "$out" = "via dispatch" ] || fail "dispatcher should route capture to the Orca adapter, got '$out'"
  pass "fm-backend dispatcher: accepts orca and routes capture through bin/backends/orca.sh"
}

test_spawn_places_task_on_remote_orca_host
test_spawn_refuses_orca_selector_without_orca_backend
test_spawn_refuses_remote_worktree_that_is_the_primary_checkout
test_spawn_refuses_remote_harness_the_host_cannot_resolve
test_spawn_launches_a_remote_harness_installed_at_a_path_with_a_space
test_remote_teardown_refuses_uncommitted_work_on_the_host
test_remote_teardown_refuses_when_the_host_is_unreachable
test_remote_teardown_releases_work_already_landed_on_the_host
test_remote_teardown_releases_a_replayed_patch_that_landed_in_the_pr
test_remote_pr_discovery_names_the_task_s_own_forge_host
test_remote_pr_discovery_keeps_a_forge_port
test_remote_pr_discovery_drops_an_ssh_transport_port
test_remote_pr_discovery_refuses_to_guess_a_host_from_an_ssh_alias
test_remote_force_teardown_completes_when_the_host_is_unreachable
test_remote_force_teardown_still_refuses_a_worktree_that_is_not_the_recorded_one
test_remote_teardown_releases_a_clean_worktree
test_setup_resolve_reads_one_ready_setup
test_setup_resolve_refuses_ambiguous_project
test_setup_resolve_refuses_unready_and_unknown
test_worktree_create_on_setup_pins_and_verifies_host
test_terminal_create_refuses_wrong_execution_host
test_exec_run_returns_remote_output_and_status
test_exec_run_recovers_output_larger_than_one_reply
test_exec_run_never_reports_an_unreadable_reply_as_empty_success
test_exec_run_refuses_when_the_cursor_cannot_be_read
test_exec_run_marks_every_invocation_apart
test_exec_run_refuses_when_the_host_cannot_encode_the_reply
test_exec_run_refuses_when_staging_writes_an_empty_file
test_remote_teardown_refuses_when_the_host_cannot_stage_a_reply
test_exec_run_keeps_a_genuinely_empty_result_successful
test_remote_teardown_refuses_when_dirty_output_cannot_be_read
test_push_file_refuses_on_digest_mismatch
test_push_file_leaves_nothing_behind_when_a_transfer_fails
test_remote_which_resolves_absolute_path
test_remote_which_keeps_a_path_containing_a_space
test_remote_which_resolves_through_a_login_banner
test_remote_which_refuses_an_absolute_looking_line_that_is_not_the_agent
test_isolation_verdicts_distinguish_primary_and_subdirectory
test_capture_reads_terminal_tail_json
test_capture_falls_back_to_text_fields
test_capture_fails_on_orca_error_json
test_runtime_check_accepts_ready_orca_status
test_runtime_check_refuses_unready_orca_status
test_send_text_submit_verifies_empty_composer_after_enter
test_send_text_submit_keeps_current_tail_when_limited
test_send_text_submit_retries_when_composer_stays_pending
test_composer_state_popup_placeholder_fill_is_pending
test_composer_state_bare_shell_prompt_is_unknown
test_send_text_submit_popup_autocomplete_requires_second_enter
test_send_literal_constructs_non_enter_send
test_send_text_submit_reports_send_failed
test_send_helpers_reject_orca_error_json
test_send_key_enter_and_interrupt
test_send_key_refuses_unknown_key
test_send_key_refuses_escape_until_supported
test_kill_is_best_effort_close
test_remove_worktree_refuses_empty_id
test_remove_worktree_rejects_orca_error_json
test_worktree_path_resolves_id
test_dispatcher_sources_orca_and_routes_primitives
test_json_get_ignores_undocumented_terminal_id_shapes
test_worktree_and_terminal_helpers_parse_json
test_worktree_create_removes_worktree_when_path_missing
test_spawn_preserves_orca_metadata_when_pathless_worktree_cleanup_fails
test_spawn_writes_orca_metadata_and_launches_harness
test_spawn_refuses_orca_secondmate_before_home_mutation
test_spawn_refuses_orca_when_runtime_not_ready
test_spawn_refuses_orca_nonisolated_worktree
test_spawn_removes_orca_worktree_when_terminal_create_fails
test_spawn_preserves_orca_metadata_when_abort_cleanup_fails
test_spawn_releases_orca_resources_when_metadata_write_fails
test_peek_send_and_crew_state_route_through_orca_meta
test_peek_and_crew_state_fail_closed_on_orca_error_json
test_target_exists_rejects_orca_error_json
test_scout_teardown_removes_orca_worktree_via_helper
test_scout_teardown_refuses_orca_id_path_mismatch
test_teardown_removes_orca_worktree_when_path_missing
test_teardown_preserves_metadata_when_orca_remove_error_json
test_scout_teardown_refuses_orca_missing_report_when_path_missing
test_ship_teardown_refuses_orca_missing_worktree_path
test_ship_teardown_removes_orca_worktree_when_id_path_matches
test_ship_teardown_refuses_orca_unresolvable_worktree_id
test_ship_teardown_refuses_orca_id_path_mismatch
test_teardown_refuses_orca_missing_worktree_id
test_teardown_refuses_orca_worktree_without_terminal_handle
test_secondmate_force_teardown_removes_orca_child_via_orca
test_secondmate_force_teardown_refuses_orca_child_id_path_mismatch
test_secondmate_force_teardown_refuses_partial_orca_child
test_secondmate_force_teardown_verifies_remote_orca_child_identity
test_secondmate_force_teardown_sweeps_a_remote_orca_child_task_tmp
