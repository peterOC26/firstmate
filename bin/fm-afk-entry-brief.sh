#!/usr/bin/env bash
# fm-afk-entry-brief.sh - read-only inventory printed when away mode is entered.
#
# Usage:
#   fm-afk-entry-brief.sh
#       Print the entry inventory and the read-back checklist.
#   fm-afk-entry-brief.sh not-started
#       Print one line per live task that has an explicit next command.
#   fm-afk-entry-brief.sh --register-future <id>
#       Register a one-shot check for a future hold date. A date that is
#       already due is named and not registered.
#   fm-afk-entry-brief.sh future-check <id>
#       Print one line once the hold date has arrived. The check shim runs this.
#   fm-afk-entry-brief.sh --help
#
# The inventory reads live task records and the backlog. It does not parse
# away words, does not mark a job seen, and does not create a backlog file.
# An unreadable backlog is reported and the command still exits 0.
# FM_AFK_ENTRY_TODAY (YYYY-MM-DD) pins "today" for tests.
# The next command is an explicit "Next: bin/..." line in the status file or
# the backlog body when one exists. A held row without that command is not
# repeated. Finished work has no inferred next command.
# An open blocked event stays out of the not-started list.
# A future-date check fires once for a hold date. Deferring the same task to a
# later date fires again when that date arrives.
# The backlog is read once per render. A per-row read makes entry and return
# wait on one process per backlog row.
# Nonempty inventory sections list live jobs (including paused and finished
# records), captain holds, queued jobs with a completed blocking dependency,
# status-recorded green PRs, hold dates, and consecutive failed checks.
# Hold dates use UTC calendar days; today's date is already due. Future-date
# checks are offered only, until --register-future is explicitly requested.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-hold-reason-lib.sh
. "$SCRIPT_DIR/fm-hold-reason-lib.sh"

declare -A TASK_STATE TASK_HELD TASK_REASON TASK_UNTIL TASK_BLOCKED TASK_BLOCKED_BY TASK_DEPS TASK_BODY

# Bash 5.2 treats ${#name[@]} on an empty associative array as unbound under
# set -u, so the empty check has to drop that option for the length read.
assoc_any() {  # <TASK_STATE|TASK_HELD|TASK_DEPS|TASK_UNTIL>
  local n=0
  set +u
  case "$1" in
    TASK_STATE) n=${#TASK_STATE[@]} ;;
    TASK_HELD) n=${#TASK_HELD[@]} ;;
    TASK_DEPS) n=${#TASK_DEPS[@]} ;;
    TASK_UNTIL) n=${#TASK_UNTIL[@]} ;;
  esac
  set -u
  [ "$n" -gt 0 ]
}

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
}

today() {
  case "${FM_AFK_ENTRY_TODAY:-}" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) printf '%s\n' "$FM_AFK_ENTRY_TODAY" ;;
    *) date -u +%Y-%m-%d ;;
  esac
}

unquote_field() {  # <value>
  local v=$1
  case "$v" in
    \"*\") v=${v#\"}; v=${v%\"} ;;
  esac
  printf '%s' "${v//\\n/$'\n'}"
}

warn_backlog() {  # <text>
  case "${BRIEF_MODE:-inventory}" in
    register)
      printf 'entry inventory: %s\n' "$1" >&2
      ;;
    not-started)
      # The return brief keeps this command's stdout and drops stderr, so the
      # read failure has to be part of the section or the brief says nothing
      # was left.
      printf '  entry inventory: %s\n' "$1"
      ;;
    *)
      printf 'entry inventory: %s\n' "$1"
      ;;
  esac
}

parse_show() {  # <id> <show-text>
  local id=$1 text=$2 line rest key val
  text=$(printf '%s\n' "$text" | fm_hold_reason_decode_stream)
  while IFS= read -r line; do
    case "$line" in
      '  '[a-z_]*:*) ;;
      *) continue ;;
    esac
    rest=${line#  }
    key=${rest%%:*}
    val=${rest#*: }
    val=${val# }
    val=$(unquote_field "$val")
    case "$key" in
      state) TASK_STATE[$id]=$val ;;
      held) TASK_HELD[$id]=$val ;;
      hold_reason) TASK_REASON[$id]=$val ;;
      hold_until) TASK_UNTIL[$id]=$val ;;
      blocked) TASK_BLOCKED[$id]=$val ;;
      blocked_by) TASK_BLOCKED_BY[$id]=$val ;;
      deps) TASK_DEPS[$id]=$val ;;
      body) TASK_BODY[$id]=$val ;;
    esac
  done <<EOF
$text
EOF
}

# One tasks-axi list row, packed as nine unit-separated fields ending in a
# record separator. Percent-encoding keeps % and the two separators literal.
backlog_rows_pack() {
  perl -e '
    use strict;
    use warnings;
    my @cols;
    my $saw_header = 0;
    sub decode_quoted {
      my ($raw) = @_;
      return $raw if length($raw) < 2 || substr($raw, 0, 1) ne "\"";
      return $raw if substr($raw, -1, 1) ne "\"";
      my $v = substr($raw, 1, -1);
      my $out = "";
      my $i = 0;
      while ($i < length($v)) {
        my $c = substr($v, $i, 1);
        if ($c eq "\\" && $i + 1 < length($v)) {
          my $n = substr($v, $i + 1, 1);
          if ($n eq "n") { $out .= "\n"; }
          elsif ($n eq "r") { $out .= "\r"; }
          elsif ($n eq "t") { $out .= "\t"; }
          elsif ($n eq "\"") { $out .= "\""; }
          elsif ($n eq "\\") { $out .= "\\"; }
          elsif ($n eq "u" && $i + 5 < length($v) && substr($v, $i + 2, 4) =~ /^[0-9A-Fa-f]{4}$/) {
            require Encode;
            $out .= Encode::encode("UTF-8", pack("U", hex(substr($v, $i + 2, 4))));
            $i += 6;
            next;
          }
          else { $out .= $n; }
          $i += 2;
          next;
        }
        $out .= $c;
        $i++;
      }
      return $out;
    }
    sub parse_csv {
      my ($line) = @_;
      my @out;
      my $i = 0;
      my $n = length($line);
      while ($i < $n) {
        my $c = substr($line, $i, 1);
        if ($c eq "\"") {
          my $j = $i + 1;
          while ($j < $n) {
            my $ch = substr($line, $j, 1);
            if ($ch eq "\\" && $j + 1 < $n) { $j += 2; next; }
            if ($ch eq "\"") { last; }
            $j++;
          }
          die "backlog row has an unterminated quoted field\n" if $j >= $n;
          push @out, decode_quoted(substr($line, $i, $j - $i + 1));
          $i = $j + 1;
          if ($i < $n && substr($line, $i, 1) eq ",") { $i++; next; }
          last if $i >= $n;
          die "backlog row has text after a quoted field\n";
        }
        my $comma = index($line, ",", $i);
        if ($comma < 0) { push @out, substr($line, $i); last; }
        push @out, substr($line, $i, $comma - $i);
        $i = $comma + 1;
        push @out, "" if $i == $n;
      }
      return @out;
    }
    sub enc {
      my ($s) = @_;
      $s = "" unless defined $s;
      $s =~ s/%/%25/g;
      $s =~ s/\x1e/%1E/g;
      $s =~ s/\x1f/%1F/g;
      return $s;
    }
    while (my $line = <STDIN>) {
      $line =~ s/\r?\n\z//;
      if ($line =~ /^tasks\[\d+\]\{([^}]*)\}:$/) {
        @cols = split /,/, $1;
        $saw_header = 1;
        my %have = map { $_ => 1 } @cols;
        for my $need (qw(id state held hold_reason hold_until blocked blocked_by deps body)) {
          die "backlog list is missing the $need column\n" unless $have{$need};
        }
        next;
      }
      next if !$saw_header || $line !~ /^  (.+)$/;
      my $rest = $1;
      next if $rest =~ /^- /;
      my @fields = parse_csv($rest);
      die "backlog row field count does not match its header\n" if @fields < @cols;
      my %row;
      for my $i (0 .. $#cols) { $row{$cols[$i]} = $fields[$i]; }
      next if !defined $row{id} || $row{id} eq "";
      my @vals = map { $row{$_} } qw(id state held hold_reason hold_until blocked blocked_by deps body);
      print join("\x1f", map { enc($_) } @vals), "\x1e";
    }
    die "backlog list had no task table\n" unless $saw_header;
    exit 0;
  '
}

pct_decode() {  # <text>
  local s=$1
  s=${s//%1E/$'\x1e'}
  s=${s//%1F/$'\x1f'}
  s=${s//%25/%}
  printf '%s' "$s"
}

load_backlog() {
  local file list err parsed pack_status=0 pipefail_was_off=0 pack_err_file
  local id state held reason until blocked blocked_by deps body
  if [ ! -e "$DATA/backlog.md" ] && [ ! -f "$FM_HOME/.tasks.toml" ]; then
    return 0
  fi
  if [ -e "$DATA/backlog.md" ] && { [ -L "$DATA/backlog.md" ] || [ ! -f "$DATA/backlog.md" ] || [ ! -r "$DATA/backlog.md" ]; }; then
    warn_backlog "backlog file is unreadable"
    return 0
  fi
  if ! fm_backlog_tasks_axi_addressing "$DATA"; then
    warn_backlog "${FM_BACKLOG_TRANSITION_ERROR:-backlog cannot be addressed}"
    return 0
  fi
  file=${FM_BACKLOG_AXI_FILE:-}
  if [ -n "$file" ] && [ ! -e "$file" ]; then
    warn_backlog "backlog file is absent"
    return 0
  fi
  if [ -n "$file" ] && { [ -L "$file" ] || [ ! -r "$file" ]; }; then
    warn_backlog "backlog file is unreadable"
    return 0
  fi
  if ! list=$(fm_backlog_row_list "$DATA" --fields held,hold_reason,hold_until,blocked,blocked_by,deps,body 2>&1); then
    err=$(printf '%s\n' "$list" | head -1)
    warn_backlog "${err:-backlog listing failed}"
    return 0
  fi
  pack_err_file=$(mktemp "${TMPDIR:-/tmp}/fm-afk-entry-pack.XXXXXX") || {
    warn_backlog "backlog listing could not be read"
    return 0
  }
  if set -o | grep -q '^pipefail[[:space:]]*off$'; then
    pipefail_was_off=1
    set -o pipefail
  fi
  parsed=$(printf '%s\n' "$list" | fm_hold_reason_decode_stream | backlog_rows_pack 2>"$pack_err_file") || pack_status=$?
  if [ "$pipefail_was_off" -eq 1 ]; then
    set +o pipefail
  fi
  if [ "$pack_status" -ne 0 ]; then
    err=$(head -1 "$pack_err_file")
    rm -f "$pack_err_file"
    warn_backlog "${err:-backlog listing could not be read}"
    return 0
  fi
  rm -f "$pack_err_file"
  while IFS=$'\x1f' read -r -d $'\x1e' id state held reason until blocked blocked_by deps body || [ -n "${id:-}" ]; do
    [ -n "$id" ] || continue
    id=$(pct_decode "$id")
    fm_pr_task_id_valid "$id" || continue
    TASK_STATE[$id]=$(pct_decode "$state")
    TASK_HELD[$id]=$(pct_decode "$held")
    TASK_REASON[$id]=$(pct_decode "$reason")
    TASK_UNTIL[$id]=$(pct_decode "$until")
    TASK_BLOCKED[$id]=$(pct_decode "$blocked")
    TASK_BLOCKED_BY[$id]=$(pct_decode "$blocked_by")
    TASK_DEPS[$id]=$(pct_decode "$deps")
    TASK_BODY[$id]=$(pct_decode "$body")
  done < <(printf '%s' "$parsed")
}

load_one() {  # <id>
  local id=$1 show
  fm_pr_task_id_valid "$id" || return 1
  if ! fm_backlog_tasks_axi_addressing "$DATA"; then
    return 1
  fi
  if [ -n "${FM_BACKLOG_AXI_FILE:-}" ] && { [ ! -f "$FM_BACKLOG_AXI_FILE" ] || [ -L "$FM_BACKLOG_AXI_FILE" ] || [ ! -r "$FM_BACKLOG_AXI_FILE" ]; }; then
    return 1
  fi
  show=$(fm_backlog_row_show "$DATA" "$id" 2>&1) || return 1
  parse_show "$id" "$show"
}

live_ids() {
  local meta id kind
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta")
    id=${id%.meta}
    fm_pr_task_id_valid "$id" || continue
    kind=$(sed -n 's/^kind=//p' "$meta" | tail -1)
    [ "$kind" = secondmate ] && continue
    printf '%s\n' "$id"
  done | sort
}

task_verb() {  # <id>
  local status=$STATE/$1.status line
  [ -f "$status" ] && [ ! -L "$status" ] || return 0
  line=$(last_status_line "$status")
  status_line_verb "$line"
  printf '\n'
}

task_open_blocked() {  # <id>
  local status=$STATE/$1.status
  [ -f "$status" ] && [ ! -L "$status" ] || return 1
  status_open_decisions "$status" | awk -F '\t' '$2 == "blocked" { found = 1 } END { exit found ? 0 : 1 }'
}

next_in_text() {  # <text>
  printf '%s\n' "$1" | sed -n 's/.*Next:[[:space:]]*\(bin\/.*\)/\1/p' | tail -1
}

explicit_next() {  # <id>
  local status=$STATE/$1.status found=''
  if [ -f "$status" ] && [ ! -L "$status" ]; then
    found=$(next_in_text "$(cat "$status" 2>/dev/null || true)")
  fi
  if [ -z "$found" ]; then
    found=$(next_in_text "${TASK_BODY[$1]:-}")
  fi
  printf '%s\n' "$found"
}

green_url() {  # <status-file>
  awk '
    function verb_of(line,    v) {
      v = line
      sub(/:.*/, "", v)
      sub(/\[.*/, "", v)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      return v
    }
    verb_of($0) == "done" && index($0, "https://") && index($0, "checks green") {
      if (match($0, /https:\/\/[^[:space:]]+/)) last = substr($0, RSTART, RLENGTH)
    }
    END { if (last != "") print last }
  ' "$1"
}

fail_streak() {  # <status-file>
  awk '
    function fail_line(line,    v) {
      if (index(line, "failed check") || index(line, "check failed")) return 1
      v = line
      sub(/:.*/, "", v)
      sub(/\[.*/, "", v)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      return v == "failed"
    }
    { lines[++n] = $0 }
    END {
      streak = 0
      for (i = n; i >= 1; i--) {
        if (lines[i] ~ /^[[:space:]]*$/) continue
        if (!fail_line(lines[i])) break
        streak++
      }
      if (streak >= 3) print streak
    }
  ' "$1"
}

status_ids() {
  local status id
  [ -d "$STATE" ] || return 0
  for status in "$STATE"/*.status; do
    [ -f "$status" ] && [ ! -L "$status" ] || continue
    id=$(basename "$status")
    id=${id%.status}
    fm_pr_task_id_valid "$id" || continue
    printf '%s\n' "$id"
  done | sort
}

print_section() {  # <title> <body>
  local body=$2
  [ -n "$(printf '%s' "$body" | tr -d '[:space:]')" ] || return 0
  printf '%s\n%s\n' "$1" "$body"
}

section_live() {
  local id verb next line body=''
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    verb=$(task_verb "$id")
    [ -n "$verb" ] || verb='(no status)'
    next=$(explicit_next "$id")
    if [ -n "$next" ]; then
      line=$(printf '  %s: %s; next: %s' "$id" "$verb" "$next")
    else
      line=$(printf '  %s: %s' "$id" "$verb")
    fi
    body="${body}${line}"$'\n'
  done <<EOF
$(live_ids)
EOF
  print_section 'Live work:' "$body"
}

section_held() {
  local id reason body=''
  assoc_any TASK_HELD || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ "${TASK_HELD[$id]:-}" = yes ] || continue
    reason=${TASK_REASON[$id]:-}
    case "$reason" in ''|-) reason=held ;; esac
    body="${body}  ${id}: ${reason}"$'\n'
  done <<EOF
$(printf '%s\n' "${!TASK_HELD[@]}" | sort)
EOF
  print_section 'Held for the captain:' "$body"
}

section_cleared() {
  local id dep deps body=''
  assoc_any TASK_DEPS || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ "${TASK_STATE[$id]:-}" = queued ] || continue
    case "${TASK_BLOCKED[$id]:-}" in yes) continue ;; esac
    case "${TASK_BLOCKED_BY[$id]:-}" in ''|none|-) ;; *) continue ;; esac
    deps=${TASK_DEPS[$id]:-}
    [ -n "$deps" ] || continue
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      [ "${TASK_STATE[$dep]:-}" = "done" ] || continue
      body="${body}  ${id}: blocked-by ${dep} is done"$'\n'
    done <<EOF
$(printf '%s\n' "$deps" | grep -o 'blocked-by:[A-Za-z0-9._-]*' | sed 's/^blocked-by://' | sort -u)
EOF
  done <<EOF
$(printf '%s\n' "${!TASK_DEPS[@]}" | sort)
EOF
  print_section 'Queued, blocker cleared:' "$body"
}

section_green() {
  local id url body=''
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    url=$(green_url "$STATE/$id.status")
    [ -n "$url" ] || continue
    body="${body}  ${id}: ${url}"$'\n'
  done <<EOF
$(status_ids)
EOF
  print_section 'Green, waiting on a merge sentence:' "$body"
}

section_dates() {
  local id until day passed='' future=''
  day=$(today)
  assoc_any TASK_UNTIL || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    until=${TASK_UNTIL[$id]:-}
    case "$until" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) continue ;;
    esac
    if [ "$until" \> "$day" ]; then
      future="${future}  ${id}: hold until ${until}; bin/fm-afk-entry-brief.sh --register-future ${id}"$'\n'
    else
      passed="${passed}  ${id}: hold until ${until}"$'\n'
    fi
  done <<EOF
$(printf '%s\n' "${!TASK_UNTIL[@]}" | sort)
EOF
  print_section 'Dates that have passed:' "$passed"
  print_section 'Future dates, not registered:' "$future"
}

section_stop() {
  local id streak body=''
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    streak=$(fail_streak "$STATE/$id.status")
    [ -n "$streak" ] || continue
    body="${body}  ${id}: ${streak} consecutive failed checks"$'\n'
  done <<EOF
$(status_ids)
EOF
  print_section 'Stop point, three failed checks:' "$body"
}

print_checklist() {
  cat <<'EOF'
Read-back checklist:
  Name every green pull request and the exact sentence that would permit its merge, or say that "no merges" is a valid reading.
  A named merge still waits while a slower advisory suite has not reported.
  Name any sentence dropped when /afk is sent again with only a stop clause.
  Name any job the inventory shows with 3 or more consecutive failed checks on the same findings, and park that job.
EOF
}

not_started_lines() {
  local id explicit
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    task_open_blocked "$id" && continue
    explicit=$(explicit_next "$id")
    [ -n "$explicit" ] || continue
    printf '  - %s: %s\n' "$id" "$explicit"
  done <<EOF
$(live_ids)
EOF
}

cmd_inventory() {
  BRIEF_MODE=inventory
  load_backlog
  section_live
  section_held
  section_cleared
  section_green
  section_dates
  section_stop
  print_checklist
}

cmd_not_started() {
  BRIEF_MODE=not-started
  load_backlog
  not_started_lines
}

hold_until_of() {  # <id>
  load_one "$1" || return 1
  case "${TASK_UNTIL[$1]:-}" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) printf '%s\n' "${TASK_UNTIL[$1]}" ;;
    *) return 1 ;;
  esac
}

future_fired_has() {  # <id> <until>
  [ -f "$STATE/.afk-future-fired" ] && grep -Fxq -- "$1 $2" "$STATE/.afk-future-fired"
}

future_check_id() {  # <task-id>
  printf 'fm-afk-future-%s\n' "$1"
}

write_future_shim() {  # <task-id>
  local id=$1 check_id home want device tmp shim
  check_id=$(future_check_id "$id")
  fm_pr_task_id_valid "$check_id" || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || return 1 ;;
  esac
  shim="$STATE/$check_id.check.sh"
  device=$(fm_pr_file_device "$STATE") || return 1
  want=$(printf '%s\n' \
    '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-afk-entry-brief.sh") future-check $(printf '%q' "$id")")
  fm_pr_regular_destination_on_device_or_absent "$shim" "$device" || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-afk-future.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$want" > "$tmp" || ! chmod 0700 "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  # shellcheck source=bin/fm-check-lib.sh
  . "$SCRIPT_DIR/fm-check-lib.sh"
  if ! fm_pr_private_file_valid "$tmp" 700 "$device" \
    || ! mv -f -- "$tmp" "$shim"; then
    rm -f -- "$tmp"
    return 1
  fi
  FM_HOME="$home" "$SCRIPT_DIR/fm-check-register.sh" "$check_id" >/dev/null || {
    rm -f -- "$shim"
    return 1
  }
  printf 'registered: state/%s.check.sh\n' "$check_id"
}

cmd_register_future() {  # <id>
  local id=$1 until day
  BRIEF_MODE=register
  fm_pr_task_id_valid "$id" || { usage >&2; return 2; }
  until=$(hold_until_of "$id") || {
    warn_backlog "${id}: no hold date to register"
    return 1
  }
  day=$(today)
  if [ ! "$until" \> "$day" ]; then
    printf '%s hold until %s is already due\n' "$id" "$until"
    return 0
  fi
  write_future_shim "$id"
}

cmd_future_check() {  # <id>
  local id=$1 until day
  BRIEF_MODE="future-check"
  fm_pr_task_id_valid "$id" || return 0
  until=$(hold_until_of "$id") || return 0
  day=$(today)
  [ "$until" \> "$day" ] && return 0
  future_fired_has "$id" "$until" && return 0
  printf '%s hold until %s is due\n' "$id" "$until"
  mkdir -p "$STATE" 2>/dev/null || true
  printf '%s %s\n' "$id" "$until" >> "$STATE/.afk-future-fired" 2>/dev/null || true
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    ''|inventory) cmd_inventory ;;
    not-started) cmd_not_started ;;
    --register-future)
      [ "$#" -eq 2 ] || { usage >&2; exit 2; }
      cmd_register_future "$2" ;;
    future-check)
      [ "$#" -eq 2 ] || { usage >&2; exit 2; }
      cmd_future_check "$2" ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
fi
