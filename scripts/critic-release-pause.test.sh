#!/usr/bin/env bash
# critic-release-pause.test.sh — while the design critic's check is listed in
# release.nonBlockingChecks and release.done is not true, its verdict only reports, so
# the sweep starts no judge and housekeeping says why. release.done, the
# review.judge.duringRelease override, or the check not being listed: it runs.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
J="$HERE/critic-judge.sh"
HK="$HERE/coordinator-housekeeping.sh"
CFG="$HARNESS_CFG_PATH"; cp "$CFG" "$FIX/cfg.base"
LINE='design critic: paused until the release (report-only, release.nonBlockingChecks)'
RX='design critic: paused until the release \(report-only, release\.nonBlockingChecks\)'

# Two PRs owed a judgement.
jq -n '[41,42] | map({number:., headRefName:"tkt-\(.)-x", headRefOid:("a" * 40), isDraft:false, body:"", labels:[],
        mergeStateStatus:"CLEAN", statusCheckRollup:[{context:"Design critic", state:"PENDING"}]})' > "$FIX/gh/prs-all.json"
export CRITIC_JUDGE_DIR="$FIX/judge" CRITIC_JUDGE_ROOM=5 CRITIC_JUDGE_PRS_MAX_AGE=0

cfg() { jq "$1" "$FIX/cfg.base" > "$CFG"; }
LISTED='.release = {nonBlockingChecks: ["Lesson / Every fix ships a lesson", "Design critic"], done: false}'
starts() { bash "$J" sweep --dry-run 2>/dev/null | grep -o 'would judge PR #[0-9]*' | grep -o '[0-9]*$' | tr '\n' ' '; }

echo "--- the sweep itself ---"
cfg "$LISTED"
want    "listed and not done: no judge is started"        "" "$(starts)"
want_in "and it says why"                                 "$RX" "$(bash "$J" sweep --dry-run 2>&1)"
want_in "paused answers yes, with the line"               "^$RX\$" "$(bash "$J" paused; echo "rc=$?")"
want_in "paused exits 0"                                  'rc=0' "$(bash "$J" paused >/dev/null; echo "rc=$?")"
cfg "$LISTED"' | .release.done = true'
want    "release done: the sweep runs"                    "41 42 " "$(starts)"
want_in "and paused exits 1"                              'rc=1' "$(bash "$J" paused >/dev/null; echo "rc=$?")"
cfg "$LISTED"' | .review.judge.duringRelease = true'
want    "duringRelease true: the sweep runs"              "41 42 " "$(starts)"
cfg "$LISTED"' | .review.judge.duringRelease = false'
want    "duringRelease false: still paused"               "" "$(starts)"
cfg '.release = {nonBlockingChecks: ["Lesson / Every fix ships a lesson"], done: false}'
want    "not listed: the sweep runs"                      "41 42 " "$(starts)"
cfg "$LISTED"' | .review.judge.context = "Screen judge"'
want_in "another context, and that one not listed: runs"  'rc=1' "$(bash "$J" paused >/dev/null; echo "rc=$?")"
cfg '.'
want    "no release key: the sweep runs"                  "41 42 " "$(starts)"

echo "--- housekeeping ---"
for s in reconcile sweep wtsweep judge lane keepfresh polish; do
  printf '#!/usr/bin/env bash\n:\n' > "$BIN/$s"; chmod +x "$BIN/$s"
done
export COORDINATOR_RECONCILE="$BIN/reconcile" COORDINATOR_SWEEP="$BIN/sweep" COORDINATOR_WORKTREE_SWEEP="$BIN/wtsweep"
export COORDINATOR_JUDGE="$BIN/judge" COORDINATOR_LANE="$BIN/lane" COORDINATOR_KEEP_FRESH="$BIN/keepfresh"
export COORDINATOR_POLISH_LIST="$BIN/polish" COORDINATOR_NOTIFY_CMD=true COORDINATOR_REFRESH=0 COORDINATOR_FREE_GB=500
hk() { COORDINATOR_SHADOW=1 bash "$HK" 2>&1; }
cfg "$LISTED"
out=$(hk)
want_in     "listed and not done: housekeeping logs the one line" "$RX" "$out"
want_not_in "and starts no judge"                                  'would judge PR' "$out$(cat "$STATE"/coordinator/*.log 2>/dev/null)"
cfg "$LISTED"' | .release.done = true'
out=$(hk)
want_not_in "release done: no pause line"                          'paused until the release' "$out"
want_in     "and the sweep runs"                                   'would judge PR #41' "$(cat "$STATE"/coordinator/*.log 2>/dev/null)"
cfg "$LISTED"' | .review.judge.duringRelease = true'
out=$(hk)
want_not_in "duringRelease true: no pause line"                    'paused until the release' "$out"

suite_end "$FAILED"
