#!/usr/bin/env bash
set -u
export TMPDIR="$PWD/.test-tmp"
export FM_CLAUDE_LEAN_LIVE=1
. tests/fixtures.sh
save_evidence() {
  local src mode transcript
  for src in "$TMPDIR"/fm-spawn-claude-lean.*/plugin-*; do
    [ -d "$src" ] || continue
    mode=${src##*/}
    [ ! -f "$src/stream.jsonl" ] || cp "$src/stream.jsonl" "/home/zabi/.no-mistakes/evidence/01M7A6XKEDE3MQDMAHTFHQPD5J/round2/$mode-stream.jsonl"
    for transcript in "$src"/claude-config/projects/*/*.jsonl; do
      [ ! -f "$transcript" ] || cp "$transcript" "/home/zabi/.no-mistakes/evidence/01M7A6XKEDE3MQDMAHTFHQPD5J/round2/$mode-runtime.jsonl"
    done
  done
  fm_test_cleanup
}
trap save_evidence EXIT
. tests/fm-spawn-claude-lean.test.sh
