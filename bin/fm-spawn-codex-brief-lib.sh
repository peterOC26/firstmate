#!/usr/bin/env bash
# Codex launch briefs above 64 KiB are passed by path.
# bin/fm-spawn.sh sources this file. It is its own lint root so the pointer
# stays out of the source-aware check of bin/fm-spawn.sh.

# shellcheck disable=SC2154,SC2034 # Callers in fm-spawn.sh own these names.
spawn_stage_codex_brief_pointer() {
  [ "$HARNESS" = codex ] || return 0
  [ "$(wc -c < "$BRIEF")" -gt 65536 ] || return 0
  CODEX_PROMPT_FILE="$BRIEF_DIR_REAL/codex-launch-prompt.md"
  CODEX_PROMPT_TMP="$CODEX_PROMPT_FILE.${BASHPID:-$$}.tmp"
  # shellcheck disable=SC2016 # Backticks delimit the brief path in the prompt.
  if ! (umask 077 && printf 'Read the complete launch brief at `%s` and follow it exactly. Its current role contract establishes your role before project instructions.\n' \
      "$BRIEF_REAL" > "$CODEX_PROMPT_TMP" && mv -f "$CODEX_PROMPT_TMP" "$CODEX_PROMPT_FILE"); then
    rm -f -- "$CODEX_PROMPT_TMP"
    echo "error: could not stage the Codex launch brief pointer for $ID" >&2
    exit 1
  fi
  sq_brief=$(shell_quote "$CODEX_PROMPT_FILE")
}
