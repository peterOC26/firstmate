#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
export FM_HERDR_LAB_STATE_DIR="$ROOT/.test-lab-herdr"
SESSION=fm-lab-upstream-adapter-1107
HELPER="$ROOT/bin/fm-herdr-lab.sh"
ORIGINAL_PATH=$PATH
export FM_HOME="$ROOT/.test-herdr-home" HERDR_SESSION="$SESSION"
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME" >/dev/null
mkdir -p "$FM_HOME/shim"
cleanup() {
  PATH="$ORIGINAL_PATH" "$HELPER" teardown "$SESSION"
  rm -rf "$FM_HOME"
}
trap cleanup EXIT
"$HELPER" provision "$SESSION"
cat > "$FM_HOME/shim/herdr" <<'WRAP'
#!/usr/bin/env bash
set -eu
args=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = --session ]; then
    [ "${2:-}" = "$HERDR_SESSION" ] || exit 97
    shift 2
  else
    args+=("$1"); shift
  fi
done
PATH="$FM_LAB_ORIGINAL_PATH" exec "$FM_LAB_HELPER" run "$HERDR_SESSION" "${args[@]}"
WRAP
chmod +x "$FM_HOME/shim/herdr"
export FM_LAB_ORIGINAL_PATH="$ORIGINAL_PATH" FM_LAB_HELPER="$HELPER"
export PATH="$FM_HOME/shim:$ORIGINAL_PATH"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
fm_backend_herdr_version_check
container_raw=$(fm_backend_herdr_container_ensure "$ROOT")
container=${container_raw%%$'\t'*}
seeded=${container_raw#*$'\t'}
printf 'Created home container: %s\n' "$container"
ids=$(fm_backend_herdr_create_task "$container" fm-adapter-proof "$ROOT" "$seeded")
read -r tab pane <<< "$ids"
target="$SESSION:$pane"
printf 'Created task endpoint: %s tab=%s\n' "$target" "$tab"
fm_backend_herdr_send_text_line "$target" 'printf "FM_ADAPTER_LIVE_OK\n"; pwd'
for i in {1..30}; do
  capture=$(fm_backend_herdr_capture "$target" 30)
  case "$capture" in *$'\nFM_ADAPTER_LIVE_OK'*) break ;; esac
  sleep .1
done
printf '%s\n' "$capture"
case "$capture" in *$'\nFM_ADAPTER_LIVE_OK'*) ;; *) exit 1 ;; esac
fm_backend_herdr_kill "$target"
fm_backend_herdr_endpoint_confirmed_gone "$target"
printf 'Firstmate adapter confirmed its own endpoint gone after cleanup.\n'
