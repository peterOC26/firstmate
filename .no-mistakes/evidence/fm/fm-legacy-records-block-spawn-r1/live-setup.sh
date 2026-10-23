#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
. "$ROOT/tests/git-config-helpers.sh"
export GIT_AUTHOR_NAME=Lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=Lab GIT_COMMITTER_EMAIL=lab@example.invalid
export TREEHOUSE_ROOT="$ROOT/.l/pool" TMPDIR="$ROOT/.l"
mkdir -p "$ROOT/.l/seed"
git -C "$ROOT/.l/seed" init -q -b main
printf 'base\n' > "$ROOT/.l/seed/README.md"
printf 'max_trees = 4\nroot = ""\n' > "$ROOT/.l/seed/treehouse.toml"
git -C "$ROOT/.l/seed" add .
git -C "$ROOT/.l/seed" commit -qm initial
git clone -q --bare "$ROOT/.l/seed" "$ROOT/.l/origin.git"
git clone -q "$ROOT/.l/origin.git" "$ROOT/.l/project"
cd "$ROOT/.l/project"
for n in 1 2 3 4; do treehouse get --lease --lease-holder "setup-$n" --json > "$ROOT/.l/allocation-$n.json"; done
for n in 1 2 3 4; do treehouse return "$(jq -r .path "$ROOT/.l/allocation-$n.json")" --force; done
