#!/usr/bin/env bash
set -eu
LAB=$(cat .live-test/codex-home)
TMUX_LAB=$(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab display-message -p -t primary '#{socket_path},#{pid},0')
PANE_LAB=$(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab display-message -p -t primary '#{pane_id}')
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" TMUX="$TMUX_LAB" TMUX_PANE="$PANE_LAB" TMUX_TMPDIR="$LAB/tmux" FM_DAEMON_PRIMARY_HARNESS=codex FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=primary:0 FM_HOUSEKEEPING_TICK=5 FM_POLL=2 bin/fm-afk-launch.sh start
