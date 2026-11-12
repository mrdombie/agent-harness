#!/usr/bin/env bash
# coordinator-clone-prs.test.sh — a ticket built in a clone of another repo has its pull
# request in that repo, and the coordinator's red-PR pass has to reach it there.
#
# The pass read this project's open PRs only. The first ticket built in a clone shipped a
# pull request whose own new suite was red, and nothing sent it back to its builder: the
# fix rounds, the update from its base, the one park per head and the resume of an
# unfinished draft all stopped at the project's own repo.
#   - one batched read of that repo's open PRs a tick, and only while a ticket this queue
#     started there still has a PR, a claim or a run; none before, none after
#   - checks, rules and the update are asked of the clone's repo; the ticket's labels and
#     the fix round's queue entry stay in this queue's
#   - the same caps, counted in ledgers of the clone's own: PR 7 there is not PR 7 here
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
T="$HERE/coordinator-tick.sh"
Q="$HERE/coordinator-queue.sh"
C="$STATE/coordinator"
unset COORDINATOR_PACE COORDINATOR_PACE_FACTOR COORDINATOR_TOOLING_CAP SWARM_USAGE_CEILING HARNESS_REPO_CLONES

# This project is acme/widgets (trunk develop). Beside it, a clone of acme/kit (trunk main).
git init -q -b main "$FIX/kit"
git -C "$FIX/kit" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m root
git -C "$FIX/kit" remote add origin https://github.com/acme/kit.git
git -C "$FIX/kit" update-ref refs/remotes/origin/main HEAD
KIT_P=$(cd "$FIX/kit" && pwd -P)

# The stand-in GitHub, told apart by repo: acme/kit's open PRs are its own list, a ticket
# exists only in acme/widgets, and PR 7 only in acme/kit. Each call is logged with its repo.
mkdir -p "$FIX/kitgh/gh"
cat > "$BIN/gh-by-repo" <<'SH'
#!/usr/bin/env bash
repo=-; named=""; prev=""
# A call that names its repo is that repo's, whatever a comment's own words mention.
for a in "$@"; do case "$prev" in --repo|-R) named="$a" ;; esac; prev="$a"; done
case "$named" in acme/kit) set -- "$@"; repo=kit ;; acme/widgets) repo=widgets ;; esac
[ "$repo" != - ] || case " $* " in *acme/kit*|*'name:"kit"'*|*" name=kit "*) repo=kit ;; *acme/widgets*|*'name:"widgets"'*|*" name=widgets "*) repo=widgets ;; esac
case "$*" in "api rate_limit"*|"api graphql "*rateLimit*) ;; *) printf '%s\t%s\n' "$repo" "$(printf '%s' "$*" | tr '\n' ' ' | cut -c1-200)" >> "$FIX/repo.log" ;; esac
wrong() { printf '%s\n' "$*" | cut -c1-300 >> "$FIX/wrong-repo.log"; echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
case "$repo $*" in
  "kit issue "*|"kit api graphql "*issueOrPullRequest*) wrong "$@" ;;
  "widgets api "*repos/acme/widgets/pulls/7*|"widgets pr "*" 7 "*) wrong "$@" ;;
  "kit api graphql "*OpenPullRequests*) FIX="$FIX/kitgh" exec "$BIN/gh" "$@" ;;
esac
exec "$BIN/gh" "$@"
SH
chmod +x "$BIN/gh-by-repo"
printf '#!/usr/bin/env bash\n:\n' > "$BIN/judge"; chmod +x "$BIN/judge"
for s in reconcile sweep wtsweep; do printf '#!/usr/bin/env bash\n:\n' > "$BIN/$s"; chmod +x "$BIN/$s"; done
export COORDINATOR_RECONCILE="$BIN/reconcile" COORDINATOR_SWEEP="$BIN/sweep" COORDINATOR_WORKTREE_SWEEP="$BIN/wtsweep"
export COORDINATOR_JUDGE="$BIN/judge" COORDINATOR_NOTIFY_CMD=true COORDINATOR_HOST=here
export COORDINATOR_REFRESH=0 COORDINATOR_FREE_GB=500 COORDINATOR_CLAIMS_CMD="cat $FIX/claims.txt"
export COORDINATOR_HOUSEKEEPING=inline COORDINATOR_HOUSEKEEPING_EVERY_MIN=0
unset COORDINATOR_SHADOW COORDINATOR_CAP SWARM_NOW COORDINATOR_FIX_ROUNDS
export SWARM_FREE_MEM_GB=16 SWARM_IDLE=90 SWARM_CORES=10
cat > "$BIN/spawn-live" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "$(pwd -P)" >> "$SPAWNS"
SH
chmod +x "$BIN/spawn-live"
# One live tick: the rebuild clock off, the fix rounds at their default (2).
tick() { COORDINATOR_REBUILD_AFTER_MIN=0 COORDINATOR_CAP=2 SWARM_GH="$BIN/gh-by-repo" SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 bash "$T" 2>&1; }
log0() { : > "$FIX/repo.log"; : > "$FIX/wrong-repo.log"; }
kit_calls() { grep -c '^kit' "$FIX/repo.log"; }
kit_lists() { grep -c '^kit.*OpenPullRequests' "$FIX/repo.log"; }
note_of() { jq -r --argjson n "$1" '.tickets[]? | select(.n == $n) | .note' "$C/queue.json" 2>/dev/null; }

# acme/kit: main requires "tests", green on main itself; PR 7 on ticket 801's branch is red on it.
jq -n '[{type: "required_status_checks", parameters: {required_status_checks: [{context: "tests"}]}}]' > "$FIX/gh/api-repos_acme_kit_rules_branches_main.json"
printf '[{"sha":"k1"}]\n' > "$FIX/gh/api-repos_acme_kit_commits_sha_main_per_page_5.json"
printf '{"check_runs":[{"name":"tests","id":1,"status":"completed","conclusion":"success","completed_at":"2026-11-01T09:00:00Z"}]}\n' \
  > "$FIX/gh/api-repos_acme_kit_commits_k1_check-runs_per_page_100_filter_all.json"
kit_prs() { # <head sha, or nothing for no open PR>
  if [ -n "${1:-}" ]; then
    jq -n --arg h "$1" '[{number:7, headRefName:"tkt-801-x", headRefOid:$h, baseRefName:"main", isDraft:false, mergeStateStatus:"BLOCKED", labels:[],
      statusCheckRollup:[{name:"tests", status:"COMPLETED", conclusion:"FAILURE", detailsUrl:"https://github.com/acme/kit/actions/runs/9/job/1"}]},
     {number:8, headRefName:"tkt-555-someone-elses", headRefOid:"x8", baseRefName:"main", isDraft:false, mergeStateStatus:"BLOCKED", labels:[],
      statusCheckRollup:[{name:"tests", status:"COMPLETED", conclusion:"FAILURE"}]}]' > "$FIX/kitgh/gh/prs-all.json"
  else printf '[]\n' > "$FIX/kitgh/gh/prs-all.json"; fi
}
printf '[]\n' > "$FIX/gh/prs-all.json"; : > "$FIX/claims.txt"; : > "$SPAWNS"
mkdir -p "$STATE/driver/801"
jq -n '{ticket:"801", mode:"build", step:"ship", done:["start","plan","build","self-check","review","record","ship"], counters:{}}' > "$STATE/driver/801/state.json"

echo "--- nothing was built in a clone: its repo is never asked anything ---"
kit_prs h7; fix_issue 801 OPEN "P1,status:in-review,repo:kit"; log0
out=$(tick)
want "no request names the clone's repo" "0" "$(kit_calls)"

echo "--- a ticket started in the clone is noted, so its pull request there is watched ---"
fix_issue 801 OPEN "P1,status:ready,repo:kit"; bash "$Q" add 801 >/dev/null; log0
out=$(tick)
want "it starts in the clone" "801 $KIT_P" "$(cat "$SPAWNS")"
want "and the start is on the ledger" "801	kit" "$(cat "$C/clone-builds.tsv")"

echo "--- its pull request there is red: it goes back to its builder, as one here would ---"
fix_issue 801 OPEN "P1,status:in-review,repo:kit"; : > "$SPAWNS"; log0
out=$(tick)
want "one batched read of the clone repo's open PRs" "1" "$(kit_lists)"
want_in "the pass says what it found there" 'rebuild: acme/kit — 1 open PR\(s\) on ticket\(s\) this queue built there' "$out"
want_in "the red PR goes back to its builder" 'rebuild: PR #7 goes back to its builder on tkt-801-x — fix round 1 of 2 \(required check\(s\) failed: tests\)' "$out"
want_not_in "a PR there on a ticket this queue did not build is left alone" 'PR #8' "$out"
want "nothing about the ticket or the pull request was asked of the wrong repo" "" "$(cat "$FIX/wrong-repo.log")"
want_in "the base's required checks are read in the clone's repo" 'api repos/acme/kit/rules/branches/main' "$(cat "$FIX/repo.log")"
want_in "the update from its base is asked there first" 'api repos/acme/kit/pulls/7/update-branch' "$(cat "$FIX/repo.log")"
want "the ticket is set ready in this queue's repo, and only there" "" "$(grep 'issue edit 801' "$FIX/repo.log" | grep -v '^widgets')"
want_in "it was set" 'issue edit 801' "$(cat "$FIX/repo.log")"
want "the round is counted in the clone's own ledger" "7 1 h7 queued" "$(tr '\t' ' ' < "$C/fix-rounds.did.kit.tsv")"
want "never in this project's, where PR 7 is another pull request" "" "$(cat "$C/fix-rounds.did.tsv" 2>/dev/null)"
want_in "the fix round is on this queue, with the PR's own brief" '^Fix: PR #7 — required check\(s\) failed: tests' "$(note_of 801)"
want_in "naming the failed check's job log" 'tests: https://github.com/acme/kit/actions/runs/9/job/1' "$(note_of 801)"

echo "--- the round starts in the clone, and is spent there ---"
fix_issue 801 OPEN "P1,status:ready,repo:kit"; log0
out=$(tick)
want "the fix run starts in the clone" "801 $KIT_P" "$(cat "$SPAWNS")"
want_not_in "it is not thrown off the queue as a round for a PR that is gone" 'not open any more' "$out"
want "the round is spent, in the clone's ledger" "7 1 h7 started" "$(tr '\t' ' ' < "$C/fix-rounds.did.kit.tsv")"
want "still one read of that repo's open PRs a tick" "1" "$(kit_lists)"

echo "--- the cap is the same: after the rounds it parks once for the PM, the PR left open ---"
printf '7\t2\th7\tstarted\n' > "$C/fix-rounds.did.kit.tsv"
fix_issue 801 OPEN "P1,status:in-review,repo:kit"; : > "$SPAWNS"; log0
out=$(tick)
want_in "two rounds spent on a head still red: parked for the PM" 'PR #7' "$(printf '%s\n' "$out" | grep -i 'park')"
want "no builder is sent a third time" "" "$(cat "$SPAWNS")"
want "the park is written once for that head, in the clone's ledger" "7 h7" "$(cut -f1,2 "$C/fix-parks.did.kit.tsv" | tr '\t' ' ')"
want "and the ticket's park goes to this queue's repo" "" "$(grep 'issue \(edit\|comment\) 801' "$FIX/repo.log" | grep -v '^widgets')"
want "nothing was asked of the wrong repo" "" "$(cat "$FIX/wrong-repo.log")"

echo "--- the pull request is gone and nothing works the ticket: the clone's repo is asked no more ---"
kit_prs; fix_issue 801 OPEN "P1,status:in-review,repo:kit"; log0
out=$(tick)
want "that tick still reads it once" "1" "$(kit_lists)"
want "and drops the ticket from the ledger" "" "$(cat "$C/clone-builds.tsv")"
log0; out=$(tick)
want "the next tick asks the clone's repo nothing" "0" "$(kit_calls)"

echo "--- a ticket built in the clone before the ledger existed is found once, off this host's record ---"
rm -f "$C/clone-builds.tsv" "$C/clone-builds.seeded"
git -C "$FIX/kit" worktree add -q "$FIX/kit-wt" -b tkt-801-x main
jq --arg w "$FIX/kit-wt" '.worktree = $w' "$STATE/driver/801/state.json" > "$FIX/s.json" && mv "$FIX/s.json" "$STATE/driver/801/state.json"
kit_prs h9; fix_issue 801 OPEN "P1,status:in-review,repo:kit"; log0
out=$(tick)
want "its row is on the ledger with no spawn" "801	kit" "$(cat "$C/clone-builds.tsv")"
want_in "the tick says so" 'rebuild: #801 was built in the clone of kit before now' "$out"
want "and its pull request there is read that same tick" "1" "$(kit_lists)"
log0; out=$(tick)
want_not_in "the records are read once, not every tick" 'before now' "$out"

suite_end "$FAILED"
