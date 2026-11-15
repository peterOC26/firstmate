#!/usr/bin/env bash
# Per-run reviewer pin for a Claude-authored no-mistakes run.
#
# Usage: fm-nm-reviewer-pin.sh --writer <name>
#        fm-nm-reviewer-pin.sh --help
#
# When --writer is exactly claude, opposite-family review uses Codex. This
# command prints one line and nothing else:
#   --reviewer codex --reviewer-model gpt-5.6-sol --reviewer-effort medium
# It prints that line only when `no-mistakes axi run --help` advertises a
# --reviewer flag as its own token. --reviewer-model and --reviewer-effort do
# not count. no-mistakes is resolved on PATH.
#
# When the writer is claude and that flag is not advertised, including when
# no-mistakes is absent from PATH, the command exits 1. Its stderr names the
# missing --reviewer flag and says it is refusing to pin by editing the shared
# no-mistakes config. The command never reads or writes a config file, and the
# refusal does not describe an edit to make.
#
# Any other writer prints nothing and exits 0, whether or not the flag is
# advertised. This command does not inspect the live config and does not invent
# a pin for any other writer.
#
# Pass the printed flags only on the no-mistakes axi run that starts a run.
# Reattach with no-mistakes axi run and omit those flags.
# Extra arguments exit 2.
set -u

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
}

# 0 when help advertises a --reviewer token. A missing binary is not an
# advertisement. --reviewer-model and --reviewer-effort do not match.
nm_advertises_reviewer() {
  local bin help
  bin=$(command -v no-mistakes 2>/dev/null) || return 1
  help=$("$bin" axi run --help 2>&1) || true
  printf '%s\n' "$help" | grep -Eq '(^|[[:space:]])--reviewer([[:space:]]|$)'
}

if [ "$#" -eq 1 ] && { [ "$1" = "--help" ] || [ "$1" = "-h" ] || [ "$1" = "help" ]; }; then
  usage
  exit 0
fi

if [ "$#" -ne 2 ] || [ "$1" != "--writer" ]; then
  usage >&2
  exit 2
fi

if [ "$2" != claude ]; then
  exit 0
fi

if nm_advertises_reviewer; then
  printf '%s\n' '--reviewer codex --reviewer-model gpt-5.6-sol --reviewer-effort medium'
  exit 0
fi

printf '%s\n' 'fm-nm-reviewer-pin: no-mistakes axi run --help does not advertise --reviewer; refusing to pin by editing the shared no-mistakes config' >&2
exit 1
