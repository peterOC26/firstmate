#!/usr/bin/env bash
# bin/backends/orca.sh - the Orca terminal session-provider adapter.
#
# Orca owns both the task worktree and the terminal endpoint. Escape key support
# remains unsupported until Orca exposes a terminal-send primitive for it.
#
# Target string shape: the Orca terminal id accepted by `orca terminal ...`.
#
# Remote Orca hosts
#   One federated Orca CLI addresses every host its runtime knows, so the
#   terminal, worktree, and repo primitives above are already host-agnostic.
#   What a remote host does NOT have is the caller's filesystem, so a task
#   placed there cannot be resolved, inspected, or verified with a local `cd`.
#   The remote helpers below supply the equal-strength replacements:
#     - fm_backend_orca_setup_resolve turns an explicit orca: selector into one
#       ready project host setup (id, project, host, path). Zero or several
#       matches refuse rather than guessing a host.
#     - fm_backend_orca_worktree_create_on_setup pins creation to that setup's
#       host and publishes the created worktree's own host and main-worktree
#       flag so a caller can prove where the checkout actually landed.
#     - fm_backend_orca_exec_* run a command in a throwaway shell terminal ON
#       the worktree's host and return its output and exit code. That is the
#       only remote execution seam Orca exposes (`orca exec` drives a browser,
#       not a shell), and it is what makes the isolation, git dirty, and
#       unlanded-work checks work against a host the caller cannot reach.
#     - fm_backend_orca_push_file copies a local file onto that host through
#       the same seam and verifies it by digest, so instruction delivery is
#       confirmed rather than assumed.
#   Every remote helper fails closed: an unreachable host, an unverifiable
#   digest, or a host that does not match the requested one is an error, never
#   a quiet fallback to the caller's own machine.

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule). Owned by bin/fm-composer-lib.sh, reused by
# every backend so the decision cannot drift.
# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-composer-lib.sh"

fm_backend_orca_tool_check() {
  command -v orca >/dev/null 2>&1 || { echo "error: backend=orca selected but the 'orca' CLI is not installed" >&2; return 1; }
}

fm_backend_orca_runtime_check() {
  fm_backend_orca_tool_check || return 1
  local out
  out=$(orca status --json 2>/dev/null) || {
    echo "error: backend=orca selected but 'orca status --json' failed; start Orca and wait for the runtime to be ready" >&2
    return 1
  }
  # shellcheck disable=SC2016  # Single quotes are deliberate: ${...} belongs to the Node snippet.
  printf '%s' "$out" | node -e '
const fs = require("fs");
let data;
try {
  data = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (err) {
  console.error("error: invalid Orca status JSON: " + err.message);
  process.exit(1);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  console.error("error: Orca runtime is not ready" + (msg ? ": " + msg : ""));
  process.exit(1);
}
const r = data.result || {};
const runtime = r.runtime || {};
const reachable = runtime.reachable ?? r.runtimeReachable;
const state = runtime.state || r.runtimeState || "";
if (reachable === true && state === "ready") process.exit(0);
console.error(`error: backend=orca requires a ready Orca runtime (reachable=${String(reachable)}, state=${state || "unknown"})`);
process.exit(1);
'
}

fm_backend_orca_json_get() {  # <field> ; fields: worktree-id worktree-path worktree-host worktree-is-main terminal-handle terminal-host worktree-terminal-handle repo-id
  # Terminal handles are accepted only from verified terminal result shapes:
  # result.terminal or a root terminal object with .handle. Undocumented
  # result.id and result.worktree.terminal shapes are ignored until a real Orca
  # smoke run proves them.
  local field=$1
  node -e '
const fs = require("fs");
const field = process.argv[1];
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
const wt = r.worktree || r.item || r;
const explicitTerm = r.terminal || null;
const repo = r.repo || r.repository || r;
function scalar(v) {
  return (typeof v === "string" || typeof v === "number") ? String(v) : "";
}
function handle(obj) {
  if (!obj) return "";
  if (typeof obj === "string" || typeof obj === "number") return String(obj);
  return scalar(obj.handle) || "";
}
let v = "";
if (field === "worktree-id") v = wt.id || wt.worktreeId || r.worktreeId || "";
if (field === "worktree-path") v = wt.path || (wt.git && wt.git.path) || r.path || "";
if (field === "worktree-host") v = scalar(wt.hostId) || scalar(r.hostId) || "";
if (field === "worktree-is-main") {
  const raw = (wt.isMainWorktree !== undefined) ? wt.isMainWorktree
    : (wt.git && wt.git.isMainWorktree !== undefined) ? wt.git.isMainWorktree
    : undefined;
  v = (raw === true) ? "true" : (raw === false) ? "false" : "";
}
if (field === "terminal-handle") v = handle(explicitTerm || r) || "";
if (field === "terminal-host") v = scalar((explicitTerm || {}).executionHostId) || scalar(r.executionHostId) || "";
if (field === "worktree-terminal-handle") v = handle(explicitTerm) || "";
if (field === "repo-id") v = repo.id || repo.repoId || r.repoId || "";
if (!v) process.exit(1);
process.stdout.write(String(v));
' "$field"
}

fm_backend_orca_json_ok() {
  node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8").trim();
if (!input) process.exit(0);
let data;
try {
  data = JSON.parse(input);
} catch (err) {
  console.error("invalid Orca JSON: " + err.message);
  process.exit(2);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
'
}

fm_backend_orca_run_json() {
  local out
  out=$("$@") || return 1
  printf '%s' "$out" | fm_backend_orca_json_ok
}

fm_backend_orca_repo_ensure() {  # <project-path>
  local project=$1 out repo_id
  fm_backend_orca_tool_check || return 1
  out=$(orca repo show --repo "path:$project" --json 2>/dev/null || true)
  if repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id 2>/dev/null); then
    printf '%s' "$repo_id"
    return 0
  fi
  out=$(orca repo add --path "$project" --json) || return 1
  repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id) || {
    echo "error: orca repo add did not return a repo id for $project" >&2
    return 1
  }
  printf '%s' "$repo_id"
}

# The local host id Orca reports for its own machine. Any other value names a
# host whose filesystem this process cannot reach.
FM_BACKEND_ORCA_LOCAL_HOST=local

fm_backend_orca_host_is_local() {  # <host-id>
  case "${1:-}" in
    ''|"$FM_BACKEND_ORCA_LOCAL_HOST") return 0 ;;
  esac
  return 1
}

# fm_backend_orca_setup_resolve: resolve one explicit selector to exactly one
# READY project host setup. Prints "<setup-id>\t<project-id>\t<host-id>\t<path>".
# Several matches, no match, or a setup that is not ready all refuse: choosing
# among them would be exactly the silent host guess this backend must not make.
fm_backend_orca_setup_resolve() {  # <selector>
  local selector=${1:-} kind key out
  fm_backend_orca_tool_check || return 1
  case "$selector" in
    orca:setup:?*) kind=setup; key=${selector#orca:setup:} ;;
    orca:project:?*) kind=project; key=${selector#orca:project:} ;;
    *)
      echo "error: '$selector' is not an Orca project selector; use orca:setup:<project-host-setup-id> or orca:project:<project-id>" >&2
      return 1
      ;;
  esac
  out=$(orca project setups --json) || {
    echo "error: 'orca project setups --json' failed; cannot resolve $selector" >&2
    return 1
  }
  # shellcheck disable=SC2016  # Single quotes are deliberate: ${...} belongs to the Node snippet.
  printf '%s' "$out" | node -e '
const fs = require("fs");
const kind = process.argv[1];
const key = process.argv[2];
const selector = process.argv[3];
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  console.error("error: orca project setups failed" + (msg ? ": " + msg : ""));
  process.exit(1);
}
const setups = (data.result && data.result.setups) || [];
const matches = setups.filter((s) => kind === "setup" ? s.id === key : s.projectId === key);
if (matches.length === 0) {
  console.error(`error: no Orca project host setup matches ${selector}; run "orca project setups" to list them`);
  process.exit(1);
}
if (matches.length > 1) {
  const hosts = matches.map((s) => `${s.id} (host ${s.hostId})`).join(", ");
  console.error(`error: ${selector} matches ${matches.length} Orca project host setups: ${hosts}; name one with orca:setup:<id>`);
  process.exit(1);
}
const s = matches[0];
if (s.setupState !== "ready") {
  console.error(`error: Orca project host setup ${s.id} is ${s.setupState || "in an unknown state"}, not ready; finish its setup before dispatching work there`);
  process.exit(1);
}
if (!s.hostId || !s.path) {
  console.error(`error: Orca project host setup ${s.id} reports no host or path; cannot place work on it`);
  process.exit(1);
}
process.stdout.write([s.id, s.projectId || "", s.hostId, s.path].join("\t"));
' "$kind" "$key" "$selector"
}

# fm_backend_orca_worktree_create_result: shared post-create parse. When
# <expected-host> is given, the created worktree's OWN host and main-worktree
# flag are checked here, against the same response that produced its id - not by
# the caller, which sees only the printed id/path and could not tell a worktree
# that landed on the caller's machine from one that landed where it was asked
# for. A mismatch removes the fresh worktree and refuses.
fm_backend_orca_worktree_create_result() {  # <name> <create-json> [<expected-host>]
  local name=$1 out=$2 expected=${3:-} wt_id wt_path terminal wt_host wt_is_main
  wt_id=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-id) || {
    echo "error: orca worktree create did not return a worktree id for $name" >&2
    return 1
  }
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-terminal-handle 2>/dev/null || true)
  wt_path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree create did not return a path for $name" >&2
    [ -z "$terminal" ] || fm_backend_orca_kill "$terminal" >/dev/null 2>&1 || true
    if fm_backend_orca_remove_worktree "$wt_id" >/dev/null; then
      return 1
    fi
    if [ -n "$terminal" ]; then
      printf '%s\t\t%s' "$wt_id" "$terminal"
    else
      printf '%s\t' "$wt_id"
    fi
    return 2
  }
  if [ -n "$expected" ]; then
    wt_host=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-host 2>/dev/null || true)
    wt_is_main=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-is-main 2>/dev/null || true)
    if [ "$wt_host" != "$expected" ] || [ "$wt_is_main" != false ]; then
      echo "error: Orca created worktree $name on host '${wt_host:-unknown}' (main worktree: ${wt_is_main:-unknown}), not an additional worktree on the required host '$expected'" >&2
      [ -z "$terminal" ] || fm_backend_orca_kill "$terminal" >/dev/null 2>&1 || true
      fm_backend_orca_remove_worktree "$wt_id" >/dev/null 2>&1 \
        || echo "error: could not remove the wrongly placed Orca worktree $wt_id; remove it with 'orca worktree rm --worktree id:$wt_id'" >&2
      return 1
    fi
  fi
  printf '%s\t%s' "$wt_id" "$wt_path"
  [ -z "$terminal" ] || printf '\t%s' "$terminal"
}

fm_backend_orca_worktree_create() {  # <project-path> <name>
  local project=$1 name=$2 repo_id out
  repo_id=$(fm_backend_orca_repo_ensure "$project") || return 1
  out=$(orca worktree create --repo "id:$repo_id" --name "$name" --no-parent --setup skip --json) || return 1
  fm_backend_orca_worktree_create_result "$name" "$out"
}

# fm_backend_orca_worktree_create_on_setup: create the task worktree on the host
# the setup names. --project-host-setup is what pins the host; <expected-host> is
# what proves it, because "asked for that host" and "landed on that host" are
# different claims and only the second one is safe to build a task on.
fm_backend_orca_worktree_create_on_setup() {  # <setup-id> <name> <expected-host>
  local setup=$1 name=$2 expected=$3 out
  fm_backend_orca_tool_check || return 1
  out=$(orca worktree create --project-host-setup "$setup" --name "$name" --no-parent --setup skip --json) || return 1
  fm_backend_orca_worktree_create_result "$name" "$out" "$expected"
}

# <expected-host>, when given, is checked against the host the new terminal
# actually executes on. That is the structural proof that the agent process this
# terminal will run lives on the task's host rather than on this machine.
fm_backend_orca_terminal_create() {  # <worktree-id> <title> [<expected-host>]
  local worktree_id=$1 title=$2 expected=${3:-} out terminal term_host
  fm_backend_orca_tool_check || return 1
  out=$(orca terminal create --worktree "id:$worktree_id" --title "$title" --json) || return 1
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get terminal-handle) || {
    echo "error: orca terminal create did not return a terminal handle for $title" >&2
    return 1
  }
  if [ -n "$expected" ]; then
    term_host=$(printf '%s' "$out" | fm_backend_orca_json_get terminal-host 2>/dev/null || true)
    if [ "$term_host" != "$expected" ]; then
      echo "error: Orca opened terminal $title on host '${term_host:-unknown}', not the required host '$expected'" >&2
      fm_backend_orca_kill "$terminal"
      return 1
    fi
  fi
  printf '%s' "$terminal"
}

fm_backend_orca_send_text_line() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "$text" --enter --json
}

fm_backend_orca_send_literal() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "$text" --json
}

fm_backend_orca_remove_worktree() {  # <worktree-id>
  local worktree_id=${1:-}
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot remove worktree" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca worktree rm --worktree "id:$worktree_id" --force --json
}

fm_backend_orca_worktree_path() {
  local worktree_id=${1:-} out path
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot resolve worktree path" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  out=$(orca worktree show --worktree "id:$worktree_id" --json) || return 1
  path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree show did not return a path for $worktree_id" >&2
    return 1
  }
  printf '%s' "$path"
}

fm_backend_orca_worktree_host() {
  local worktree_id=${1:-} out host
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot resolve worktree host" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  out=$(orca worktree show --worktree "id:$worktree_id" --json) || return 1
  host=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-host) || {
    echo "error: orca worktree show did not return a host for $worktree_id" >&2
    return 1
  }
  printf '%s' "$host"
}

fm_backend_orca_capture() {  # <terminal-id> <lines>
  local terminal=$1 lines=${2:-40} out
  fm_backend_orca_tool_check || return 1
  out=$(orca terminal read --terminal "$terminal" --limit "$lines" --json) || return 1
  fm_backend_orca_json_text "$out"
}

fm_backend_orca_json_text() {  # <json>
  printf '%s' "$1" | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
if (r.terminal && Array.isArray(r.terminal.tail)) {
  process.stdout.write(r.terminal.tail.join("\n"));
} else if (Array.isArray(r.tail)) {
  process.stdout.write(r.tail.join("\n"));
} else {
  process.stdout.write(r.text || r.output || r.content || r.preview || "");
}
'
}

fm_backend_orca_json_field() {  # <field> <json>
  local field=$1
  printf '%s' "$2" | node -e '
const fs = require("fs");
const field = process.argv[1];
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) process.exit(2);
const r = data.result || {};
const term = r.terminal || {};
function scalar(v) {
  return (typeof v === "string" || typeof v === "number" || typeof v === "boolean") ? String(v) : "";
}
let v = "";
if (field === "limited") v = scalar(r.limited ?? term.limited);
if (field === "oldestCursor") v = scalar(r.oldestCursor || term.oldestCursor);
if (field === "nextCursor") v = scalar(r.nextCursor || term.nextCursor);
if (field === "latestCursor") v = scalar(r.latestCursor || term.latestCursor);
if (!v) process.exit(1);
process.stdout.write(v);
' "$field"
}

fm_backend_orca_read_text_paged() {  # <terminal-id> <limit>
  local terminal=$1 limit=${2:-200} out limited oldest cursor_out text older_text
  fm_backend_orca_tool_check || return 1
  out=$(orca terminal read --terminal "$terminal" --limit "$limit" --json) || return 1
  printf '%s' "$out" | fm_backend_orca_json_ok || return 1
  text=$(fm_backend_orca_json_text "$out") || return 1
  limited=$(fm_backend_orca_json_field limited "$out" 2>/dev/null || true)
  oldest=$(fm_backend_orca_json_field oldestCursor "$out" 2>/dev/null || true)
  if [ "$limited" = true ] && [ -n "$oldest" ]; then
    cursor_out=$(orca terminal read --terminal "$terminal" --cursor "$oldest" --limit "$limit" --json) || return 1
    printf '%s' "$cursor_out" | fm_backend_orca_json_ok || return 1
    older_text=$(fm_backend_orca_json_text "$cursor_out") || return 1
    text="${older_text}"$'\n'"${text}"
  fi
  printf '%s' "$text"
}

FM_BACKEND_ORCA_COMPOSER_LINES=${FM_BACKEND_ORCA_COMPOSER_LINES:-200}
FM_BACKEND_ORCA_IDLE_RE=${FM_BACKEND_ORCA_IDLE_RE:-'^Type a message\.\.\.$'}

# fm_backend_orca_composer_state: classify the composer's own bordered row as
# empty|pending|unknown. Real text stays pending, including a slash-command
# popup that closed by filling an argument-hint placeholder into the composer;
# that first Enter selected the popup item, it did not submit the command.
fm_backend_orca_composer_state() {  # <terminal-id> -> empty|pending|unknown
  local terminal=$1 cap line trimmed stripped="" found=0
  cap=$(fm_backend_orca_read_text_paged "$terminal" "$FM_BACKEND_ORCA_COMPOSER_LINES") || { printf 'unknown'; return 0; }
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ -n "$trimmed" ] || continue
    case "$trimmed" in
      '│'*'│'|'┃'*'┃'|'|'*'|') : ;;
      *) continue ;;
    esac
    stripped=$trimmed
    found=1
  done < <(printf '%s\n' "$cap")
  [ "$found" -eq 1 ] || { printf 'unknown'; return 0; }
  stripped=${stripped//│/}
  stripped=${stripped//┃/}
  stripped=${stripped//|/}
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  # A row was found only by the bordered shape above, so content came from a
  # genuine composer box - delegate to the shared owner with bordered=1. A bare
  # dead-shell prompt has no bordered row and already returned 'unknown' above.
  fm_composer_classify_content 1 "$stripped" "$FM_BACKEND_ORCA_IDLE_RE"
}

fm_backend_orca_send_key() {  # <terminal-id> <key>
  local terminal=$1 key=$2
  fm_backend_orca_tool_check || return 1
  case "$key" in
    C-c|ctrl+c|Ctrl-c|Ctrl-C)
      fm_backend_orca_run_json orca terminal send --terminal "$terminal" --interrupt --json
      ;;
    Enter|enter)
      fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "" --enter --json
      ;;
    *)
      echo "error: unsupported Orca key '$key'" >&2
      return 1
      ;;
  esac
}

# fm_backend_orca_send_text_submit: type <text> once, then retry Enter until
# the composer row reads empty. Retries send only Enter, so a slash-command
# popup placeholder fill gets the required second Enter without duplicating text.
fm_backend_orca_send_text_submit() {  # <terminal-id> <text> <retries> <enter-sleep> <settle>
  local terminal=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 i=0 state
  fm_backend_orca_tool_check || { printf 'send-failed'; return 0; }
  fm_backend_orca_send_literal "$terminal" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  while :; do
    fm_backend_orca_send_key "$terminal" Enter || true
    sleep "$sleep_s"
    state=$(fm_backend_orca_composer_state "$terminal")
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

fm_backend_orca_kill() {  # <terminal-id>
  fm_backend_orca_tool_check || return 0
  orca terminal close --terminal "$1" --json >/dev/null 2>&1 || true
}

# --- remote execution seam --------------------------------------------------
#
# A throwaway shell terminal on the worktree's own host is the only way to run a
# command where a remote task's files actually live: `orca exec` drives the
# browser, and `orca terminal create --command` discards its scrollback the
# moment the shell exits, so a long-lived shell plus marked sends is what
# survives. Each run brackets the command with markers built from a nonce AT RUN
# TIME, so the shell's echo of the sent line (which carries the printf FORMAT,
# never the expanded marker) can never be mistaken for real output. Output comes
# back base64-encoded from the remote so terminal wrapping and padding cannot
# corrupt a path, a digest, or a git status line.
FM_BACKEND_ORCA_EXEC_POLLS=${FM_BACKEND_ORCA_EXEC_POLLS:-120}
FM_BACKEND_ORCA_EXEC_INTERVAL=${FM_BACKEND_ORCA_EXEC_INTERVAL:-0.5}
# Almost every remote command here is a near-instant verdict check, so the budget
# above doubles as how fast a genuinely dead host is noticed and must stay short.
# A network-bound `git fetch` is the exception: it is bounded by the host's link
# to its forge, not by the host being alive, and timing one out reports "could
# not ask" to the landed-work chain, which then refuses a worktree whose work has
# in fact landed. Fetch-class commands therefore get their own, larger budget
# (raise this when a slow host fetch causes a refusal). Exceeding even this stays
# a transport failure that refuses - never a silent pass.
FM_BACKEND_ORCA_EXEC_FETCH_POLLS=${FM_BACKEND_ORCA_EXEC_FETCH_POLLS:-1200}
# Set for the duration of one fetch-class call; empty means the ordinary budget.
FM_BACKEND_ORCA_EXEC_POLL_BUDGET=${FM_BACKEND_ORCA_EXEC_POLL_BUDGET:-}
# Only how wide each read is, never a correctness bound - and widening it is not
# how a truncated reply is recovered. A reply the host stopped retaining comes
# back through the staging mechanism instead: it is declared with its exact
# length and fetched in bounded slices (see fm_backend_orca_exec_run), and every
# read here is already known to be small enough for that. Raising this only
# trades read size against round trips.
FM_BACKEND_ORCA_EXEC_READ_LIMIT=${FM_BACKEND_ORCA_EXEC_READ_LIMIT:-2000}
FM_BACKEND_ORCA_PUSH_CHUNK=${FM_BACKEND_ORCA_PUSH_CHUNK:-2000}
FM_BACKEND_ORCA_EXEC_SEQ=0

# The markers are what tell this reply apart from every other reply the same
# terminal is still holding, so the nonce has to be unique per INVOCATION. The
# pid and the counter cannot carry that alone: nearly every caller runs a check
# inside a command substitution, and the counter's increment dies with that
# subshell, so a parent hands out the same counter value again and again. Fresh
# entropy is read per call and kept alongside them, so two calls from the same
# shell - or from two sibling subshells of it - can never mint the same marker.
fm_backend_orca_exec_nonce() {
  local rand
  FM_BACKEND_ORCA_EXEC_SEQ=$((FM_BACKEND_ORCA_EXEC_SEQ + 1))
  rand=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -dc 'a-f0-9' || true)
  [ -n "$rand" ] || rand=$(printf '%s%s%s' "$RANDOM" "$RANDOM" "$RANDOM" | tr -dc '0-9')
  printf 'x%sx%sx%s' "$$" "$FM_BACKEND_ORCA_EXEC_SEQ" "$rand"
}

# fm_backend_orca_exec_open: open an inspection shell on <worktree-id>'s host.
# The host check is not optional here: running a "remote" check on the caller's
# own machine would report a confident verdict about the wrong filesystem.
fm_backend_orca_exec_open() {  # <worktree-id> <title> <expected-host>
  fm_backend_orca_terminal_create "$1" "$2" "$3"
}

fm_backend_orca_exec_close() {  # <handle>
  [ -z "${1:-}" ] || fm_backend_orca_kill "$1"
}

# Where in the scrollback this reply's window starts. An unreadable answer is
# NOT a position: reporting 0 would silently mean "read from the very beginning
# of the scrollback", where an older reply of this same terminal is sitting, so
# it fails instead and the caller treats it as the transport failure it is.
fm_backend_orca_exec_cursor() {  # <handle>
  local out cursor
  out=$(orca terminal read --terminal "$1" --limit 1 --json 2>/dev/null) || return 1
  cursor=$(fm_backend_orca_json_field latestCursor "$out" 2>/dev/null) || return 1
  case "$cursor" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$cursor"
}

# A terminal is a bounded scrollback, not a pipe. Verified against a live remote
# host: `orca terminal read` returned only about 6 KB of a 145 KB reply, with
# limited=false and oldestCursor=0, and raising --limit to 8,192,000 recovered no
# more. So the window is NOT the constraint and the truncation flags are not
# reliable - the host simply stops retaining. A reply therefore cannot be
# streamed through the terminal and hoped for; it has to be moved in pieces each
# small enough to be read back whole.
#
# That matters because of which way the failure falls. A too-long reply loses its
# START while its trailing exit status survives, so a naive reader sees a clean
# rc and no output - and for the two callers that matter (the uncommitted-work
# and unlanded-work checks in teardown) no output means "nothing to protect", so
# a worktree holding real work gets released. Every reply is therefore
# length-declared and length-verified: the command's output is staged in a file
# on the host, its exact base64 length comes back with the exit status, and short
# replies ride inline while longer ones are fetched in bounded slices and
# reassembled. A reply that still cannot be recovered whole is a transport
# failure, which refuses. Emptiness is never itself the failure signal, so a
# check that genuinely finds nothing still succeeds.
FM_BACKEND_ORCA_EXEC_TRANSPORT_RC=125
# Kept well under the observed retention so a slice is always recoverable.
FM_BACKEND_ORCA_EXEC_SLICE=${FM_BACKEND_ORCA_EXEC_SLICE:-2000}
FM_BACKEND_ORCA_EXEC_MAX_SLICES=${FM_BACKEND_ORCA_EXEC_MAX_SLICES:-4096}

# fm_backend_orca_exec_marked: send one command and read back its marked reply.
# Used only for replies already known to be small - the staging command and each
# slice - so that this layer never has to solve the retention problem itself.
# Prints "<rc> <declared-len> <payload>"; returns non-zero only on transport
# failure, so a caller can tell "could not ask" from "asked, and the answer was".
fm_backend_orca_exec_marked() {  # <handle> <command>
  local handle=$1 command=$2 nonce start wrapped out text payload rc declared i=0 budget
  budget=${FM_BACKEND_ORCA_EXEC_POLL_BUDGET:-$FM_BACKEND_ORCA_EXEC_POLLS}
  case "$budget" in
    ''|*[!0-9]*) budget=$FM_BACKEND_ORCA_EXEC_POLLS ;;
  esac
  nonce=$(fm_backend_orca_exec_nonce)
  start=$(fm_backend_orca_exec_cursor "$handle") || {
    echo "error: could not read the current cursor of Orca terminal $handle; refusing to read a reply from an unknown point in its scrollback" >&2
    return "$FM_BACKEND_ORCA_EXEC_TRANSPORT_RC"
  }
  wrapped="__fmb=\$( { $command ; } ); __fmr=\$?; printf 'FMORCAB_%s\\n' '$nonce'; printf '%s\\n' \"\$__fmb\"; printf 'FMORCAE_%s_rc=%s_len=%s\\n' '$nonce' \"\$__fmr\" \"\${#__fmb}\""
  fm_backend_orca_send_text_line "$handle" "$wrapped" >/dev/null || {
    echo "error: could not send an inspection command to Orca terminal $handle" >&2
    return "$FM_BACKEND_ORCA_EXEC_TRANSPORT_RC"
  }
  while :; do
    out=$(orca terminal read --terminal "$handle" --cursor "$start" --limit "$FM_BACKEND_ORCA_EXEC_READ_LIMIT" --json 2>/dev/null) || out=
    if [ -n "$out" ]; then
      text=$(fm_backend_orca_json_text "$out" 2>/dev/null || true)
      case "$text" in
        *"FMORCAE_${nonce}_rc="*) break ;;
      esac
    fi
    i=$((i + 1))
    if [ "$i" -ge "$budget" ]; then
      echo "error: Orca inspection command did not complete on terminal $handle within the poll budget" >&2
      return "$FM_BACKEND_ORCA_EXEC_TRANSPORT_RC"
    fi
    sleep "$FM_BACKEND_ORCA_EXEC_INTERVAL"
  done
  rc=$(printf '%s\n' "$text" | sed -n "s/.*FMORCAE_${nonce}_rc=\([0-9][0-9]*\)_len=[0-9][0-9]*.*/\1/p" | tail -1 || true)
  declared=$(printf '%s\n' "$text" | sed -n "s/.*FMORCAE_${nonce}_rc=[0-9][0-9]*_len=\([0-9][0-9]*\).*/\1/p" | tail -1 || true)
  payload=
  case "$text" in
    *"FMORCAB_$nonce"*)
      payload=$(printf '%s\n' "$text" | awk -v bm="FMORCAB_$nonce" -v em="FMORCAE_${nonce}_rc=" '
        !cap && index($0, bm) { cap = 1; next }
        cap && index($0, em) { exit }
        cap { printf "%s", $0 }
      ' | tr -d '[:space:]' || true)
      ;;
    *)
      echo "error: the reply to an Orca inspection command on terminal $handle lost its start marker; the host did not retain it" >&2
      return "$FM_BACKEND_ORCA_EXEC_TRANSPORT_RC"
      ;;
  esac
  if [ -z "$rc" ] || [ -z "$declared" ] || [ "${#payload}" -ne "$declared" ]; then
    echo "error: an Orca inspection reply on terminal $handle was not recovered whole (declared ${declared:-unknown}, recovered ${#payload})" >&2
    return "$FM_BACKEND_ORCA_EXEC_TRANSPORT_RC"
  fi
  printf '%s %s %s' "$rc" "$declared" "$payload"
}

# Best effort, and called on every path that leaves a staged reply behind, so a
# transport failure never also leaks the host's stage directory.
#
# It carries its own short budget rather than the one the failing call was
# running under. The sweep is reached exactly when that call has already given
# up - often with the host's shell still blocked on the command that timed out,
# so no answer is coming - and inheriting a network-sized budget there would
# make an already-failing teardown wait a second full budget per sweep before
# saying anything. A short bound cannot lose data: this is cleanup, not a
# verdict, and it stays best effort either way.
FM_BACKEND_ORCA_EXEC_SWEEP_POLLS=${FM_BACKEND_ORCA_EXEC_SWEEP_POLLS:-20}
fm_backend_orca_exec_stage_discard() {  # <handle> <already-quoted-dir-or-empty>
  local FM_BACKEND_ORCA_EXEC_POLL_BUDGET=$FM_BACKEND_ORCA_EXEC_SWEEP_POLLS
  [ -n "${2:-}" ] || return 0
  fm_backend_orca_exec_marked "$1" "rm -rf $2; printf ''" >/dev/null 2>&1 || true
}

fm_backend_orca_exec_run() {  # <handle> <command>
  local handle=$1 command=$2 stage reply rc declared mode rest inline payload slice off i dir q_dir q_file
  fm_backend_orca_tool_check || return "$FM_BACKEND_ORCA_EXEC_TRANSPORT_RC"
  # Stage the reply on the host, then carry back its exit status, its exact
  # length, and - when it is short enough to be safe - the reply itself. A short
  # reply is the common case (a verdict token, a branch name, an empty status),
  # so it still costs exactly one round trip and leaves nothing behind.
  #
  # Every step of that staging is checked BEFORE any length is declared. An
  # unchecked encode is the same hazard as an unread reply: if base64 is missing,
  # the disk is full, or the stage path is unwritable, the file is empty or
  # partial, and a length measured from it describes the damage and then agrees
  # with itself forever after. The declared length is therefore cross-checked
  # against the length base64 must produce for the raw byte count, so a short
  # write cannot be self-consistent, and the raw output never passes through an
  # unchecked pipeline. Staging failures report their own step and are transport
  # failures - never the command's own exit status, which is what would let a
  # damaged reply read as a successful empty answer.
  #
  # The stage path is derived HERE, from this invocation's own nonce, and created
  # on the host with an atomic fail-if-exists `mkdir -m 700`. Two properties come
  # from that, and only from that: a stale or hostile directory at the path is
  # never adopted (mkdir fails and staging refuses), and the caller knows the
  # path WITHOUT having to read it back - so a reply that never arrives can still
  # be swept. A path learned only from the reply is unrecoverable in exactly the
  # case where it matters, which is how a failed transport left the host holding
  # a full `git status` listing indefinitely. The nonce carries real entropy, so
  # the name is not guessable, and the mode is right from the instant the
  # directory exists rather than one command later.
  #
  # No `case` here, deliberately: a case pattern's unbalanced `)` is a parse
  # error inside `$( )` on bash 3.2, and this whole command is sent into a
  # command substitution on a host whose shell version is not ours to choose.
  # The guards below are the same tests written without one.
  dir="/tmp/fm-orca-stage-$(fm_backend_orca_exec_nonce)"
  q_dir=$(fm_backend_orca_shell_quote "$dir")
  q_file=$(fm_backend_orca_shell_quote "$dir/final")
  stage="__fmo=\$( { $command ; } 2>&1 ); __fmr=\$?; \
command -v base64 >/dev/null 2>&1 || { printf 'E:no-base64'; exit 0; }; \
__fmd=$q_dir; \
mkdir -m 700 \"\$__fmd\" 2>/dev/null || { printf 'E:no-stage-dir'; exit 0; }; \
printf '%s' \"\$__fmo\" > \"\$__fmd/raw\" || { printf 'E:stage-write'; rm -rf \"\$__fmd\"; exit 0; }; \
__fmn=\$(wc -c < \"\$__fmd/raw\" | tr -d '[:space:]'); \
{ [ -n \"\$__fmn\" ] && [ -z \"\$(printf '%s' \"\$__fmn\" | tr -d '0-9')\" ]; } || { printf 'E:stage-measure'; rm -rf \"\$__fmd\"; exit 0; }; \
base64 < \"\$__fmd/raw\" > \"\$__fmd/b64\" || { printf 'E:stage-encode'; rm -rf \"\$__fmd\"; exit 0; }; \
tr -d '\\n' < \"\$__fmd/b64\" > \"\$__fmd/final\" || { printf 'E:stage-normalize'; rm -rf \"\$__fmd\"; exit 0; }; \
{ [ -f \"\$__fmd/final\" ] && [ -r \"\$__fmd/final\" ]; } || { printf 'E:stage-missing'; rm -rf \"\$__fmd\"; exit 0; }; \
__fml=\$(wc -c < \"\$__fmd/final\" | tr -d '[:space:]'); \
{ [ -n \"\$__fml\" ] && [ -z \"\$(printf '%s' \"\$__fml\" | tr -d '0-9')\" ]; } || { printf 'E:stage-measure'; rm -rf \"\$__fmd\"; exit 0; }; \
[ \"\$__fml\" -eq \$(( 4 * ( (__fmn + 2) / 3 ) )) ] || { printf 'E:stage-size'; rm -rf \"\$__fmd\"; exit 0; }; \
if [ \"\$__fml\" -le $FM_BACKEND_ORCA_EXEC_SLICE ]; then printf 'S:%s:%s:I:' \"\$__fmr\" \"\$__fml\"; cat \"\$__fmd/final\"; rm -rf \"\$__fmd\"; else printf 'S:%s:%s:F:' \"\$__fmr\" \"\$__fml\"; fi"
  # A reply that never arrives is exactly when the stage cannot be named by the
  # reply, so the sweep uses the path this call already chose.
  reply=$(fm_backend_orca_exec_marked "$handle" "$stage") || {
    fm_backend_orca_exec_stage_discard "$handle" "$q_dir"
    return "$FM_BACKEND_ORCA_EXEC_TRANSPORT_RC"
  }
  reply=${reply#* }
  reply=${reply#* }
  case "$reply" in
    E:*)
      echo "error: could not stage the reply to an Orca inspection command on terminal $handle (${reply#E:}); refusing rather than reporting the command's own status" >&2
      # Every staging guard past the mkdir removes its own stage, and a mkdir
      # that failed means the directory is not this call's to remove: refusing
      # to adopt a hostile or stale directory would be pointless if the refusal
      # then deleted it. Anything else is swept.
      [ "$reply" = E:no-stage-dir ] || fm_backend_orca_exec_stage_discard "$handle" "$q_dir"
      return "$FM_BACKEND_ORCA_EXEC_TRANSPORT_RC"
      ;;
    S:*) reply=${reply#S:} ;;
    *)
      echo "error: an Orca inspection command on terminal $handle returned an unrecognized staging reply" >&2
      fm_backend_orca_exec_stage_discard "$handle" "$q_dir"
      return "$FM_BACKEND_ORCA_EXEC_TRANSPORT_RC"
      ;;
  esac
  rc=${reply%%:*}
  reply=${reply#*:}
  declared=${reply%%:*}
  reply=${reply#*:}
  mode=${reply%%:*}
  rest=${reply#*:}
  case "$rc" in ''|*[!0-9]*) rc= ;; esac
  case "$declared" in ''|*[!0-9]*) declared= ;; esac
  if [ -z "$rc" ] || [ -z "$declared" ]; then
    echo "error: an Orca inspection command on terminal $handle returned no usable status or length" >&2
    fm_backend_orca_exec_stage_discard "$handle" "$q_dir"
    return "$FM_BACKEND_ORCA_EXEC_TRANSPORT_RC"
  fi
  if [ "$mode" = I ]; then
    # The host removed the stage before printing an inline reply, so there is
    # nothing left to sweep on either outcome here.
    inline=$rest
    if [ "${#inline}" -ne "$declared" ]; then
      echo "error: a short Orca inspection reply on terminal $handle did not arrive whole (declared $declared, got ${#inline})" >&2
      return "$FM_BACKEND_ORCA_EXEC_TRANSPORT_RC"
    fi
    [ -z "$inline" ] || printf '%s' "$inline" | fm_backend_orca_b64_decode
    return "$rc"
  fi
  if [ "$mode" != F ]; then
    echo "error: an Orca inspection reply on terminal $handle named no stage to read it from" >&2
    fm_backend_orca_exec_stage_discard "$handle" "$q_dir"
    return "$FM_BACKEND_ORCA_EXEC_TRANSPORT_RC"
  fi
  # Longer than one slice: fetch it a slice at a time, each small enough that the
  # host is certain to still be holding it when it is read.
  payload=
  off=0
  i=0
  while [ "$off" -lt "$declared" ]; do
    i=$((i + 1))
    if [ "$i" -gt "$FM_BACKEND_ORCA_EXEC_MAX_SLICES" ]; then
      echo "error: an Orca inspection reply on terminal $handle exceeded the slice budget (${declared} base64 bytes)" >&2
      fm_backend_orca_exec_stage_discard "$handle" "$q_dir"
      return "$FM_BACKEND_ORCA_EXEC_TRANSPORT_RC"
    fi
    slice=$(fm_backend_orca_exec_marked "$handle" \
      "tail -c +$((off + 1)) $q_file | head -c $FM_BACKEND_ORCA_EXEC_SLICE") || {
      fm_backend_orca_exec_stage_discard "$handle" "$q_dir"
      return "$FM_BACKEND_ORCA_EXEC_TRANSPORT_RC"
    }
    slice=${slice#* }
    slice=${slice#* }
    [ -n "$slice" ] || {
      echo "error: an Orca inspection reply on terminal $handle stopped short at $off of $declared base64 bytes" >&2
      fm_backend_orca_exec_stage_discard "$handle" "$q_dir"
      return "$FM_BACKEND_ORCA_EXEC_TRANSPORT_RC"
    }
    payload="$payload$slice"
    off=$((off + ${#slice}))
  done
  fm_backend_orca_exec_stage_discard "$handle" "$q_dir"
  if [ "${#payload}" -ne "$declared" ]; then
    echo "error: an Orca inspection reply on terminal $handle reassembled to ${#payload} of $declared base64 bytes; refusing rather than reporting a partial result" >&2
    return "$FM_BACKEND_ORCA_EXEC_TRANSPORT_RC"
  fi
  printf '%s' "$payload" | fm_backend_orca_b64_decode
  return "$rc"
}

fm_backend_orca_b64_decode() {
  node -e '
const fs = require("fs");
const raw = fs.readFileSync(0, "utf8").replace(/\s+/g, "");
if (!raw) process.exit(0);
process.stdout.write(Buffer.from(raw, "base64").toString("utf8"));
'
}

fm_backend_orca_local_digest() {  # <path>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 < "$1" | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | cut -d' ' -f1
  else
    echo "error: no shasum or sha256sum available to verify a remote file copy" >&2
    return 1
  fi
}

# Best effort, and called on every path that leaves an encoded copy behind, so a
# failed transfer never also leaks it onto the host.
fm_backend_orca_push_stage_discard() {  # <handle> <already-quoted-stage-path>
  [ -n "${2:-}" ] || return 0
  fm_backend_orca_exec_run "$1" "rm -f $2" >/dev/null 2>&1 || true
}

# fm_backend_orca_push_file: copy a local file to <remote-path> on the shell's
# host and prove it arrived intact. The digest comparison is the point: an
# agent's whole instruction set travels this way, and a silently truncated copy
# would look exactly like a successful launch.
fm_backend_orca_push_file() {  # <handle> <local-path> <remote-path>
  local handle=$1 local_path=$2 remote_path=$3 b64 want got off=0 part dir rc q_dir q_remote q_stage
  [ -f "$local_path" ] || { echo "error: cannot push missing file $local_path to an Orca host" >&2; return 1; }
  want=$(fm_backend_orca_local_digest "$local_path") || return 1
  b64=$(base64 < "$local_path" | tr -d '\n') || {
    echo "error: could not encode $local_path for transfer to an Orca host" >&2
    return 1
  }
  dir=$(dirname -- "$remote_path")
  # Every path handed to the host goes through the adapter's own quoter, never
  # literal quotes around an expansion: this helper takes an arbitrary remote
  # path, and one containing a quote character would otherwise close the string
  # and hand the rest of it to the remote shell as commands.
  q_dir=$(fm_backend_orca_shell_quote "$dir")
  q_remote=$(fm_backend_orca_shell_quote "$remote_path")
  q_stage=$(fm_backend_orca_shell_quote "$remote_path.b64")
  fm_backend_orca_exec_run "$handle" "mkdir -p $q_dir && : > $q_stage" >/dev/null || {
    echo "error: could not prepare $remote_path on the Orca host" >&2
    fm_backend_orca_push_stage_discard "$handle" "$q_stage"
    return 1
  }
  while [ "$off" -lt "${#b64}" ]; do
    part=${b64:$off:$FM_BACKEND_ORCA_PUSH_CHUNK}
    fm_backend_orca_send_text_line "$handle" \
      "printf %s $(fm_backend_orca_shell_quote "$part") >> $q_stage" >/dev/null || {
      echo "error: transfer of $local_path to $remote_path was interrupted" >&2
      fm_backend_orca_push_stage_discard "$handle" "$q_stage"
      return 1
    }
    off=$((off + FM_BACKEND_ORCA_PUSH_CHUNK))
  done
  got=$(fm_backend_orca_exec_run "$handle" \
    "{ base64 -d < $q_stage 2>/dev/null || base64 -D < $q_stage; } > $q_remote && { sha256sum $q_remote 2>/dev/null || shasum -a 256 $q_remote; } | cut -d' ' -f1")
  rc=$?
  # The encoded copy is the transfer's scratch, not its product, so it goes on
  # every way out of here - a decode failure or a digest mismatch would
  # otherwise leave a half-written copy of the file sitting on the host.
  fm_backend_orca_push_stage_discard "$handle" "$q_stage"
  if [ "$rc" -ne 0 ]; then
    echo "error: could not decode $remote_path on the Orca host (exit $rc)" >&2
    return 1
  fi
  got=$(printf '%s' "$got" | tr -d '[:space:]')
  if [ "$got" != "$want" ]; then
    echo "error: $remote_path did not arrive intact on the Orca host (expected $want, got ${got:-nothing})" >&2
    return 1
  fi
}

fm_backend_orca_shell_quote() {  # <word>
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# fm_backend_orca_remote_git: run git for the remote task worktree. Same command
# and same output as `git -C <worktree>` locally, so a caller keeps ONE copy of
# the policy that reads it and only the access path differs.
fm_backend_orca_remote_git() {  # <handle> <worktree-path> <git-arg>...
  local handle=$1 worktree=$2 cmd out rc arg verb='' wants_value=0
  local FM_BACKEND_ORCA_EXEC_POLL_BUDGET=${FM_BACKEND_ORCA_EXEC_POLL_BUDGET:-}
  shift 2
  cmd="git -C $(fm_backend_orca_shell_quote "$worktree")"
  # The verb is the first argument that is neither an option nor an option's
  # value, so `-c key=val` and `-C dir` in front of it do not stand in for one.
  for arg in "$@"; do
    if [ "$wants_value" = 1 ]; then
      wants_value=0
      continue
    fi
    case "$arg" in
      -c|-C|--git-dir|--work-tree|--namespace) wants_value=1 ;;
      -*) : ;;
      *) verb=$arg; break ;;
    esac
  done
  # Whether this command talks to the network is a property of the git verb, not
  # of the call site, so the wider budget is granted here rather than left for
  # each caller to remember. A fetch bounded by the verdict-check budget reports
  # "could not ask" to the landed-work chain, which then refuses work that has
  # in fact landed.
  case "$verb" in
    fetch|pull|push|clone|ls-remote) FM_BACKEND_ORCA_EXEC_POLL_BUDGET=$FM_BACKEND_ORCA_EXEC_FETCH_POLLS ;;
  esac
  while [ "$#" -gt 0 ]; do
    cmd="$cmd $(fm_backend_orca_shell_quote "$1")"
    shift
  done
  # git's own stderr is dropped on the host, exactly as every local `git -C`
  # call site already drops it, so the exit status stays the only signal and a
  # diagnostic can never be mistaken for command output.
  out=$(fm_backend_orca_exec_run "$handle" "$cmd 2>/dev/null")
  rc=$?
  # The reply crosses as exact bytes, and the transport it crosses through has
  # no trailing newline to give back - a local `git -C` always does. Without one
  # the last line of a reply fed to `read` is an unterminated line that `read`
  # reports as end of input, so a caller silently loses it. Restored here, once,
  # for every caller: non-empty output ends in exactly one newline, and empty
  # output stays empty, because "nothing" and "one blank line" are different
  # answers to the work-protection checks.
  [ -z "$out" ] || printf '%s\n' "$out"
  return "$rc"
}

# fm_backend_orca_remote_worktree_isolation: the remote equal of the local
# `cd`-and-compare isolation assertion. Every comparison runs ON the host, so a
# wrapped or padded terminal line can never turn a mismatch into a match, and
# the verdict token is short enough to survive any terminal width. Prints one of
# ISOLATED, NOT-A-WORKTREE, TOPLEVEL-MISMATCH, or IS-PRIMARY.
fm_backend_orca_remote_worktree_isolation() {  # <handle> <worktree-path> <primary-path>
  local handle=$1 worktree=$2 primary=$3 q_wt q_primary
  q_wt=$(fm_backend_orca_shell_quote "$worktree")
  q_primary=$(fm_backend_orca_shell_quote "$primary")
  fm_backend_orca_exec_run "$handle" "\
cd $q_wt >/dev/null 2>&1 || { echo NOT-A-WORKTREE; exit 0; }; \
__here=\$(pwd -P); \
__top=\$(git rev-parse --show-toplevel 2>/dev/null) || { echo NOT-A-WORKTREE; exit 0; }; \
__top=\$(cd \"\$__top\" >/dev/null 2>&1 && pwd -P) || { echo NOT-A-WORKTREE; exit 0; }; \
__primary=\$(cd $q_primary >/dev/null 2>&1 && pwd -P) || __primary=$q_primary; \
[ \"\$__here\" = \"\$__top\" ] || { echo TOPLEVEL-MISMATCH; exit 0; }; \
[ \"\$__here\" != \"\$__primary\" ] || { echo IS-PRIMARY; exit 0; }; \
echo ISOLATED"
}

# fm_backend_orca_remote_which: resolve <name> to an absolute executable path on
# the host, asking the task's own shell and then a login shell, which do not
# always agree. Prints the path; prints nothing and fails when neither resolves
# it. Callers must use the resolved path rather than the bare name: a launch
# line that trusts the remote PATH turns "not installed here" into a terminal
# that silently sits at a prompt.
fm_backend_orca_remote_which() {  # <handle> <name>
  local handle=$1 name=$2 out line last='' candidate='' probe probed='' verdict q
  out=$(fm_backend_orca_exec_run "$handle" \
    "command -v $(fm_backend_orca_shell_quote "$name") 2>/dev/null || bash -lc $(fm_backend_orca_shell_quote "command -v $name") 2>/dev/null") || return 1
  # Only the surrounding whitespace goes. Deleting every space would quietly
  # rewrite an installation path that legitimately contains one into a different
  # path that does not exist, and the launch would then be the silent
  # sits-at-a-prompt failure this resolution exists to replace.
  #
  # The login-shell fallback runs the host's profile, so a host that prints a
  # banner answers with the banner AND the path: the resolved path is usually
  # the last line, and a banner that TRAILS it leaves the first absolute line as
  # the other candidate. Shape is only how a candidate is nominated, never how
  # it is accepted - a profile can print any absolute-looking line, and
  # returning one would hand the launch a path that is not the agent. Each
  # candidate is therefore proven on the host to be an executable non-directory
  # before it is returned, and a reply with no such line resolves nothing, which
  # is the loud missing-executable refusal the caller reports.
  while IFS= read -r line; do
    line=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$line" ] || continue
    last=$line
    case "$line" in
      /?*) [ -n "$candidate" ] || candidate=$line ;;
    esac
  done <<FMEOF
$out
FMEOF
  for probe in "$last" "$candidate"; do
    [ -n "$probe" ] || continue
    [ "$probe" != "$probed" ] || continue
    case "$probe" in
      /?*) : ;;
      *) continue ;;
    esac
    probed=$probe
    q=$(fm_backend_orca_shell_quote "$probe")
    verdict=$(fm_backend_orca_exec_run "$handle" \
      "if [ -x $q ] && [ ! -d $q ]; then echo FM-EXECUTABLE; else echo FM-NOT-EXECUTABLE; fi") || continue
    verdict=$(printf '%s' "$verdict" | tr -d '[:space:]')
    [ "$verdict" = FM-EXECUTABLE ] || continue
    printf '%s' "$probe"
    return 0
  done
  return 1
}

fm_backend_orca_remote_path_env() {  # <handle>
  # shellcheck disable=SC2016  # Single quotes are deliberate: $PATH expands on the remote host.
  fm_backend_orca_exec_run "$1" 'printf %s "$PATH"' 2>/dev/null || true
}

# fm_backend_orca_remote_paths_same: are these two paths the same directory on
# the host? Canonicalized and compared there, so a symlinked path component
# cannot make two different worktrees look identical, or one worktree look like
# two. Prints SAME, DIFFERENT, or MISSING.
fm_backend_orca_remote_paths_same() {  # <handle> <path-a> <path-b>
  local handle=$1 a b
  a=$(fm_backend_orca_shell_quote "$2")
  b=$(fm_backend_orca_shell_quote "$3")
  fm_backend_orca_exec_run "$handle" "\
__a=\$(cd $a >/dev/null 2>&1 && pwd -P) || { echo MISSING; exit 0; }; \
__b=\$(cd $b >/dev/null 2>&1 && pwd -P) || { echo MISSING; exit 0; }; \
[ \"\$__a\" = \"\$__b\" ] && echo SAME || echo DIFFERENT"
}

# fm_backend_orca_remote_dir_exists: does <path> exist as a directory on the
# host? Used where a local teardown gate says [ -d "$WT" ]; a remote path that
# is simply absent from the CALLER's disk must never answer that question.
fm_backend_orca_remote_dir_exists() {  # <handle> <path>
  local out
  out=$(fm_backend_orca_exec_run "$1" "[ -d $(fm_backend_orca_shell_quote "$2") ] && echo YES || echo NO") || return 2
  case "$(printf '%s' "$out" | tr -d '[:space:]')" in
    YES) return 0 ;;
    NO) return 1 ;;
    *) return 2 ;;
  esac
}
