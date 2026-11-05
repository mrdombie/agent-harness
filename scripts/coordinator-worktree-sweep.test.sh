#!/usr/bin/env bash
# coordinator-worktree-sweep.test.sh — the coordinator's housekeeping removes finished builder
# worktrees: every coordinator.sweepEveryMin, and every pass while free disk is under the build
# floor (coordinator.disk.stopBelowGb). It logs one line per run, and an unreadable claim list
# removes nothing and is said once.
#
# 2026-11-04: the worktree root held 151 trees and 56 GB and builds parked under the 30 GB floor,
# while the sweep waited out its interval.
#
# Every tree is a real registered worktree of a scratch clone; the real housekeeping runs the real
# sweep against it, every other pass stubbed. A plant in a scratch copy of the kit removes the
# housekeeping call and shows the removal case then fails.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; FIX=$(cd "$FIX" && pwd -P)
PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rm -rf "$FIX"; }
on_exit_keep_status cleanup
G() { git -c user.email=t@example.com -c user.name=tester -c commit.gpgsign=false -c init.defaultBranch=develop "$@"; }

ORIGIN="$FIX/origin.git"; MAIN="$FIX/main"; ROOT="$FIX/wt"
fixture_path ORIGIN "$FIX"; fixture_path MAIN "$FIX"; fixture_path ROOT "$FIX"
mkdir -p "$ROOT" "$STATE/claims" "$FIX/home"
G init -q --bare "$ORIGIN"
G clone -q "$ORIGIN" "$MAIN" 2>/dev/null
mkdir -p "$MAIN/apps/web"; printf 'src\n' > "$MAIN/apps/web/page.ts"
G -C "$MAIN" add -A; G -C "$MAIN" commit -qm base; G -C "$MAIN" push -q origin HEAD:develop 2>/dev/null
export HARNESS_MAIN_REPO="$MAIN" HARNESS_REPO_ROOT="$MAIN"

# The forge the sweep reads: merged PRs per branch ($FIX/prs.tsv: branch state number headOid).
: > "$FIX/prs.tsv"
cat > "$FIX/forge" <<'GH'
#!/usr/bin/env bash
q=""; for a in "$@"; do case "$a" in query=*) q=${a#query=} ;; esac; done
printf '%s' "$q" | grep -oE 'b[0-9]+: pullRequests\(headRefName: "[^"]*"' | sed -E 's/^(b[0-9]+): pullRequests\(headRefName: "(.*)"$/\1\t\2/' |
while IFS=$'\t' read -r k br; do
  awk -F'\t' -v b="$br" '$1==b {print $2"\t"$3"\t"$4}' "$FORGE_PRS" |
    jq -R 'split("\t") | {state: .[0], number: (.[1]|tonumber), headRefOid: .[2]}' | jq -s --arg k "$k" '{($k): {nodes: .}}'
done | jq -s '{data: {repository: (add // {})}}'
GH
chmod +x "$FIX/forge"
# The claim list: the planted file, or unreadable when there is none.
printf '#!/usr/bin/env bash\ncat "$SWEEP_CLAIMS_JSON"\n' > "$FIX/claimlist"; chmod +x "$FIX/claimlist"
# Free disk: a planted base, less 10 GB for each tree still under the root, so a removal frees 10.
printf '#!/usr/bin/env bash\nn=$(find "$WT_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l)\necho $(( $(cat "$FREE_BASE") - n * 10 ))\n' > "$FIX/df"
chmod +x "$FIX/df"
export SWEEP_WORKTREE_ROOTS="$ROOT" WT_ROOT="$ROOT" WT_CLAIM_LIST="$FIX/claimlist" SWEEP_CLAIMS_JSON="$FIX/claims.json"
export SWEEP_GH="$FIX/forge" FORGE_PRS="$FIX/prs.tsv" COORDINATOR_DF="$FIX/df" FREE_BASE="$FIX/free-base"

# Every other pass is a no-op: only the sweep is under test.
printf '#!/usr/bin/env bash\n:\n' > "$BIN/noop"; chmod +x "$BIN/noop"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/critic"; chmod +x "$BIN/critic"
export COORDINATOR_RECONCILE="$BIN/noop" COORDINATOR_SWEEP="$BIN/noop" COORDINATOR_LANE="$BIN/noop"
export COORDINATOR_KEEP_FRESH="$BIN/noop" COORDINATOR_POLISH_LIST="$BIN/noop" COORDINATOR_CLOSE_MERGED="$BIN/noop"
export COORDINATOR_CRITIC_JUDGE="$BIN/critic" COORDINATOR_CACHE="$BIN/noop" COORDINATOR_NOTIFY_CMD=true
export COORDINATOR_FOLLOW_UP=off COORDINATOR_UNBLOCK=off COORDINATOR_FEATURE_CLOSE=off COORDINATOR_RELEASE_BATCH=off
export COORDINATOR_MACHINE_PARKS=off COORDINATOR_DEVELOP_HOOKS=off COORDINATOR_PRUNE_BUNDLES=off
export COORDINATOR_SWEEP_EVERY_MIN=30 COORDINATOR_DISK_STOP_BELOW_GB=30 COORDINATOR_DISK_RESUME_AT_GB=50 COORDINATOR_MIN_FREE_GB=5
COORD="$STATE/coordinator"; STAMP="$COORD/worktree-sweep.stamp"

sit_in() { # <dir> — a process sitting in <dir>, until the suite ends
  (cd "$1" && exec sleep 300) & PIDS="$PIDS $!"
  local p=$! real; real=$(cd "$1" && pwd -P)
  for _ in $(seq 1 100); do lsof -a -p "$p" -d cwd -Fn 2>/dev/null | grep -qxF "n$real" && return 0; sleep 0.1; done
}
add_wt() { G -C "$MAIN" worktree add -q "$ROOT/$1" -b "$2" develop; }
merged() { printf '%s\tMERGED\t%s\t%s\n' "$1" "$2" "$(G -C "$MAIN" rev-parse develop)" >> "$FIX/prs.tsv"; }
there() { [ -d "$ROOT/$1" ]; }
world() { # a finished tree, a claimed one, a dirty one and one in use, all with merged PRs
  for p in $PIDS; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; PIDS=""
  rm -rf "${ROOT:?}"/* "${STATE:?}/claims"/*; G -C "$MAIN" worktree prune; : > "$FIX/prs.tsv"; printf '[]\n' > "$FIX/claims.json"
  for b in $(G -C "$MAIN" for-each-ref --format='%(refname:short)' refs/heads | grep -v '^develop$'); do G -C "$MAIN" branch -qD "$b"; done
  add_wt 901-merged tkt-901/a;  merged tkt-901/a 1901
  add_wt 902-claimed tkt-902/a; merged tkt-902/a 1902; mkdir -p "$STATE/claims/902.lock"
  add_wt 903-dirty tkt-903/a;   merged tkt-903/a 1903; printf 'wip\n' > "$ROOT/903-dirty/apps/web/page.ts"
  add_wt 904-busy tkt-904/a;    merged tkt-904/a 1904; sit_in "$ROOT/904-busy"
  rm -f "$COORD/coordinator.log" "$COORD"/*.log
}
log() { cat "$COORD"/*.log 2>/dev/null; }
hk() { # [kit] — one housekeeping pass, for real (not shadow)
  ( cd "$FIX" && HOME="$FIX/home" COORDINATOR_SHADOW=0 bash "${1:-$KIT}/scripts/coordinator-housekeeping.sh" ) > "$FIX/hk.out" 2>&1
  cat "$FIX/hk.out"
}
past_interval() { mkdir -p "$COORD"; touch -t 202001010000 "$STAMP"; }
fresh_stamp() { mkdir -p "$COORD"; touch "$STAMP"; }

echo "--- a pass past the interval removes the finished tree, keeps the rest ---"
world; echo 500 > "$FIX/free-base"; past_interval
out=$(hk)
if there 901-merged; then bad "a merged, clean, unclaimed tree survived a pass past the interval: $(log | grep -E '901|Sweep')"
else ok "a merged, clean, unclaimed tree is removed"; fi
there 902-claimed && ok "a claimed tree is kept" || bad "a claimed tree was removed"
there 903-dirty && ok "a tree with uncommitted changes is kept" || bad "a dirty tree was removed"
[ "$(cat "$ROOT/903-dirty/apps/web/page.ts" 2>/dev/null)" = wip ] && ok "  and its change survives" || bad "the dirty tree lost its change"
there 904-busy && ok "a tree a process sits in is kept" || bad "a tree in use was removed"
want_in "one line for the run: removed, kept, freed" \
  '^.*worktree sweep \(every 30 min\): removed 1, kept 3, freed 10 GB$' "$out"
want "and only one" "1" "$(printf '%s\n' "$out" | grep -c 'worktree sweep (')"
want_in "the sweep's own lines reach the coordinator log" 'remove  901-merged — PR #1901 merged' "$(log)"

echo "--- inside the interval, with room on the disk, it waits ---"
world; echo 500 > "$FIX/free-base"; fresh_stamp
out=$(hk)
there 901-merged && ok "a finished tree waits for the interval" || bad "the sweep ran inside its interval: $out"
want_not_in "and no sweep line" 'worktree sweep \(' "$out"

echo "--- under the build floor it runs at once, inside the interval ---"
world; echo 65 > "$FIX/free-base"; fresh_stamp   # 4 trees: 25 GB free, under 30
out=$(hk)
there 901-merged && bad "under the floor, the sweep waited for its interval: $out" || ok "under the floor the finished tree goes at once"
there 902-claimed && there 903-dirty && there 904-busy && ok "  and every kept tree stays" || bad "under the floor a kept tree was removed"
want_in "  and the line says why it ran" 'worktree sweep \(25 GB free, under the 30 GB build floor\): removed 1, kept 3, freed 10 GB' "$out"
world; echo 65 > "$FIX/free-base"; fresh_stamp
out=$(COORDINATOR_DISK_STOP_BELOW_GB=20 hk)
there 901-merged && ok "the floor is the guard's stopBelowGb: at 20, 25 GB free waits for the interval" || bad "the floor was not read from disk-guard: $out"

echo "--- an unreadable claim list removes nothing and is said once ---"
world; echo 500 > "$FIX/free-base"; past_interval; rm -f "$FIX/claims.json"
out=$(hk)
there 901-merged && ok "with the claim list unreadable, the finished tree is kept" || bad "it removed a tree without the claim list: $out"
want "the coordinator says so once" "1" "$(printf '%s\n' "$out" | grep -c 'the claim list could not be read, so nothing was removed')"
want "the sweep's own line is once too" "1" "$(log | grep -c '^Sweep: the claim list could not be read')"
want_in "and the run line still comes" 'worktree sweep \(every 30 min\): removed 0, kept 4, freed 0 GB' "$out"
want_in "housekeeping still finishes" 'housekeeping: done' "$out"
printf '[]\n' > "$FIX/claims.json"; past_interval
out=$(hk)
there 901-merged && bad "the next run did not read the list again: $out" || ok "the next run reads the list again and removes it"

echo "--- shadow: a dry run, nothing removed ---"
world; echo 500 > "$FIX/free-base"; past_interval
out=$( ( cd "$FIX" && HOME="$FIX/home" COORDINATOR_SHADOW=1 bash "$KIT/scripts/coordinator-housekeeping.sh" ) 2>&1)
there 901-merged && ok "under shadow nothing is removed" || bad "shadow removed a tree"
want_in "  and the line says dry" 'worktree sweep \(every 30 min\) \(dry: nothing removed\): removed 1, kept 3' "$out"

echo "--- plant: housekeeping without the sweep call leaves the finished tree ---"
PK="$FIX/kit"; mkdir -p "$PK"; cp -R "$KIT/scripts" "$KIT/swarm" "$KIT/tests" "$PK/" 2>/dev/null
[ -d "$KIT/driver" ] && cp -R "$KIT/driver" "$PK/"
cp "$PK/scripts/coordinator-housekeeping.sh" "$FIX/hk.bak"
python3 -I - "$PK/scripts/coordinator-housekeeping.sh" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
t = '  env ${WT_ENV[@]+"${WT_ENV[@]}"} bash "$WT_SWEEP" $wt_args > "$WT_OUT" 2>&1; wt_rc=$?\n'
assert s.count(t) == 1, "plant text not found once"
open(p, "w").write(s.replace(t, '  : > "$WT_OUT"; wt_rc=0\n'))
PY
if grep -qF 'bash "$WT_SWEEP" $wt_args' "$PK/scripts/coordinator-housekeeping.sh"; then bad "plant did not land"
else
  world; echo 500 > "$FIX/free-base"; past_interval
  hk "$PK" >/dev/null
  there 901-merged && ok "planted: with the call gone the finished tree stays, so the call is what removes it" \
    || bad "planted: the tree went without the sweep call — the removal case proves nothing"
fi
cp "$FIX/hk.bak" "$PK/scripts/coordinator-housekeeping.sh"

suite_end "$FAILED"
