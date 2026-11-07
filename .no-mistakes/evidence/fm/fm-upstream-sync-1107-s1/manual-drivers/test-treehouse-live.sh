#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=/home/zabi/.no-mistakes/evidence/01M6W1RCVXS15VZT05F5RDMYXZ
LAB="$ROOT/.test-treehouse-live"
mkdir -p "$LAB"
trap 'rm -rf "$LAB"' EXIT
export TREEHOUSE_ROOT="$LAB/pool" FM_HOME="$LAB/home"
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME" >/dev/null
git init -q -b main "$LAB/project"
printf 'disposable live Treehouse project\n' > "$LAB/project/README.md"
git -C "$LAB/project" add README.md
git -C "$LAB/project" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm initial
git init -q --bare "$LAB/origin.git"
git -C "$LAB/project" remote add origin "$LAB/origin.git"
git -C "$LAB/project" push -q origin main
git -C "$LAB/origin.git" symbolic-ref HEAD refs/heads/main
. "$ROOT/bin/fm-wake-lib.sh"
(cd "$LAB/project" && treehouse get --no-fetch --lease --json --lease-holder "$FM_HOME/live-task/a1") > "$EVIDENCE/treehouse-live-allocation.json"
cat "$EVIDENCE/treehouse-live-allocation.json"
wt=$(jq -er .path "$EVIDENCE/treehouse-live-allocation.json")
lease_id=$(jq -er .lease_id "$EVIDENCE/treehouse-live-allocation.json")
holder=$(jq -er .lease_holder "$EVIDENCE/treehouse-live-allocation.json")
fm_treehouse_lease_matches "$wt" "$lease_id" "$holder"
fm_treehouse_slot_owner_claim "$wt" live-task "$FM_HOME"
if fm_treehouse_slot_owner_claim "$wt" intruder "$FM_HOME"; then echo 'Overwrote an existing claim' >&2; exit 1; fi
fm_treehouse_slot_owner_state "$wt" live-task "$FM_HOME"
[ "$FM_TREEHOUSE_SLOT_OWNER" = mine ]
printf 'Existing slot claim refused replacement and still belongs to live-task.\n'
if (cd "$LAB/project" && treehouse return --force "$wt" --if-lease-id wrong --if-lease-holder "$holder"); then
  echo 'Returned a lease with the wrong identity' >&2; exit 1
fi
fm_treehouse_lease_matches "$wt" "$lease_id" "$holder"
printf 'Wrong lease identity refused; the original live lease remains verified.\n'
fm_treehouse_slot_owner_release "$wt" live-task
(cd "$LAB/project" && treehouse return --force "$wt" --if-lease-id "$lease_id" --if-lease-holder "$holder")
fm_treehouse_legacy_unleased "$wt"
marker=$(fm_treehouse_slot_owner_marker "$wt")
[ ! -e "$marker" ]
fm_treehouse_pool_entry "$wt" > "$EVIDENCE/treehouse-live-returned.json"
cat "$EVIDENCE/treehouse-live-returned.json"
printf 'Matching return released the lease with no remaining claim.\n'
