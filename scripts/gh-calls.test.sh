#!/usr/bin/env bash
# gh-calls.test.sh — the forge is read once per pass, not once per ticket, and a
# token GitHub is refusing is left alone while the last good read stands in.
#
# Every builder, session and the coordinator share one token. On 2026-10-16 a
# tick made 101 gh calls (59 a `gh issue view` per queued ticket) and its
# housekeeping 89 (one label read and one PR read per claimed ticket); GitHub's
# secondary limits then refused the token and the tick, blind, started nothing.
#
# Each case below grows the thing a loop walks — the queue, the waits, the
# clashing PRs, the claimed tickets — and asserts the calls do not grow with it.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
T="$HERE/coordinator-tick.sh"
Q="$HERE/coordinator-queue.sh"
C="$STATE/coordinator"

cat > "$BIN/noop" <<'SH'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "$FIX/house.log"
SH
chmod +x "$BIN/noop"
for n in reconcile sweep wtsweep judge lane; do cp "$BIN/noop" "$BIN/$n"; done
export COORDINATOR_RECONCILE="$BIN/reconcile" COORDINATOR_SWEEP="$BIN/sweep" COORDINATOR_WORKTREE_SWEEP="$BIN/wtsweep"
export COORDINATOR_JUDGE="$BIN/judge" COORDINATOR_LANE="$BIN/lane" COORDINATOR_NOTIFY_CMD="$BIN/noop"
export COORDINATOR_HOUSEKEEPING=inline COORDINATOR_HOUSEKEEPING_EVERY_MIN=0
export COORDINATOR_REFRESH=0 COORDINATOR_FREE_GB=500 COORDINATOR_CLAIMS_CMD="cat $FIX/claims.txt"
export COORDINATOR_FIX_LOCK="$BIN/fixlock"
printf '#!/usr/bin/env bash\necho "[]"\n' > "$BIN/fixlock"; chmod +x "$BIN/fixlock"
unset COORDINATOR_SHADOW COORDINATOR_CAP
export SWARM_FREE_MEM_GB=16 SWARM_IDLE=90 SWARM_CORES=10 TEST_PID=$$
cat > "$BIN/spawn-live" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "${CLAIM_CLASS:-}" >> "$SPAWNS"
printf '{"run_id":"claim-%s-live","ticket":"%s","child_pid":%s}\n' "$1" "$1" "$TEST_PID" > "$STATE/runs/claim-$1-live.json"
SH
chmod +x "$BIN/spawn-live"

fresh() {
  rm -rf "$C" "$STATE/runs"/* "$STATE/swarm/gh-backoff" "$FIX/gh/ratelimit"
  rm -f "$FIX/gh"/issue-*.json
  : > "$SPAWNS"; : > "$FIX/house.log"; : > "$FIX/claims.txt"; : > "$GH_LOG"
  printf '[]\n' > "$FIX/gh/prs-all.json"
  unset SWARM_NOW
}
# Calls that spend the allowance: reading what is left of it is free.
calls() { grep -vE '^api rate_limit|rateLimit\{' "$GH_LOG" | grep -c . | tr -d ' '; }
queue_n() { # <class> <count> — that many tickets queued, from 501 up
  local t; for t in $(seq 501 $((500 + $2))); do fix_issue "$t" OPEN "status:in-review"; bash "$Q" add "$t" --class "$1" >/dev/null; done
}
tick_calls() { : > "$GH_LOG"; bash "$T" >/dev/null 2>&1; calls; }

echo "--- a tick's reads do not grow with the queue ---"
fresh; queue_n repair 5;  small=$(tick_calls)
fresh; queue_n repair 45; big=$(tick_calls)
want "45 queued tickets cost what 5 do"            "$small" "$big"
want_in "and a handful at that"                    '^[1-5]$' "$big"
fresh; queue_n repair 120
want "120 cost one request more per 50"            "$((small + 2))" "$(tick_calls)"
want_not_in "no ticket is read on its own"         '^issue view' "$(cat "$GH_LOG")"

echo "--- the batched read still decides: a gated ticket is skipped, an open one spawns ---"
fresh; fix_issue 501 OPEN "status:in-review,needs:human-approval"; bash "$Q" add 501 --class repair >/dev/null
fix_issue 502 OPEN "status:in-review"; bash "$Q" add 502 --class repair >/dev/null
fix_issue 503 CLOSED "status:in-review"; bash "$Q" add 503 --class repair >/dev/null
out=$(SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 bash "$T" 2>&1)
want_in "the held ticket is skipped, named"        'skip #501 \(repair\): needs:human-approval' "$out"
want_in "the closed one too"                       'skip #503 \(repair\): CLOSED' "$out"
want "and only the open one spawns"                "502" "$(cut -f1 "$SPAWNS" | tr '\n' ' ' | sed 's/ $//')"
fresh; bash "$Q" add 777 --class repair >/dev/null
out=$(bash "$T" 2>&1)
want_in "a ticket the batch does not hold is unreadable, not spawnable" 'skip #777 \(repair\): could not be read' "$out"

echo "--- a waiting ticket nobody has touched is not asked for its comments ---"
waits_calls() { # <updatedAt> — calls coord_wait_new_comments makes for 20 waits ended at 21:00
  : > "$GH_LOG"
  ( . "$HERE/coordinator-env.sh"; . "$HERE/coordinator-waits.sh"
    ISSUES=$(for t in $(seq 601 620); do printf '{"%s":{"number":%s,"state":"OPEN","updatedAt":"%s","labels":[]}}\n' "$t" "$t" "$1"; done | jq -sc add)
    PRS='[]'
    for t in $(seq 601 620); do coord_wait_new_comments "$t" "2026-10-16T21:00:00Z" >/dev/null; done )
  calls
}
want "untouched since the wait began: no comment reads" "0" "$(waits_calls 2026-10-16T20:59:00Z)"
want "touched since: each one is read"             "20" "$(waits_calls 2026-10-16T21:05:00Z)"

echo "--- the claimable list reads every clashing PR's ticket in one request ---"
clash_calls() { # <count>
  local out="[]" t
  rm -f "$FIX/gh"/issue-*.json
  for t in $(seq 701 $((700 + $1))); do
    fix_issue "$t" OPEN "status:ready,P1,area:OPS"
    out=$(jq -c --argjson t "$t" '. + [{number: ($t + 5000), isDraft: false, mergeable: "CONFLICTING", title: "x", closingIssuesReferences: [{number: $t}]}]' <<<"$out")
  done
  printf '%s\n' "$out" > "$FIX/gh/prs-all.json"
  : > "$GH_LOG"; bash "$HERE/claimable-issues.sh" > "$FIX/claimable.out" 2>/dev/null
  calls
}
small=$(clash_calls 3); big=$(clash_calls 40)
want "40 clashing PRs cost what 3 do"              "$small" "$big"
want "and every one is still offered to finish"    "40" "$(grep -c 'FINISH PR' "$FIX/claimable.out" | tr -d ' ')"
: > "$GH_LOG"; CLAIMABLE_PRS_FILE="$FIX/gh/prs-all.json" bash "$HERE/claimable-issues.sh" >/dev/null 2>&1
want_not_in "a caller's PR read is reused, not asked again" 'pullRequests\(states:\[OPEN\]' "$(cat "$GH_LOG")"

echo "--- a queue refresh does not ask per scope: labels resolve once, members come with the candidates ---"
fresh; rm -f "$FIX/gh"/issue-list*.json
printf '[{"name":"project:a"},{"name":"project:b"},{"name":"project:c"}]\n' > "$FIX/gh/labels.json"
fix_issue_list "status:ready" '[{"number":901,"title":"in a","labels":[{"name":"status:ready"},{"name":"project:a"}]},
  {"number":902,"title":"in c","labels":[{"name":"status:ready"},{"name":"project:c"}]},
  {"number":903,"title":"in none","labels":[{"name":"status:ready"},{"name":"project:z"}]}]'
fix_issue_list "status:in-review" '[]'
bash "$Q" seed a,b,c >/dev/null 2>&1
: > "$GH_LOG"; bash "$Q" refresh >/dev/null 2>&1
want_not_in "no label list on a refresh"           '^label list' "$(cat "$GH_LOG")"
want_not_in "no member list per scope"             '^issue list .*--label project:' "$(cat "$GH_LOG")"
want "and the scope still decides what is queued"  "901 902" "$(jq -r '[.tickets[].n] | sort | map(tostring) | join(" ")' "$C/queue.json")"

echo "--- the reconciler reads labels and PRs once a pass, not once a claimed ticket ---"
ORIGIN="$FIX/origin.git"; git init -q --bare "$ORIGIN"
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
printf '"acme/widgets"\n' > "$FIX/gh/api-repos_acme_widgets.json"
recon_calls() { # <count> — that many tickets in review, each with a branch on the remote
  local nums="[]" t
  for t in $(seq 801 $((800 + $1))); do
    fix_issue "$t" OPEN "status:in-review"
    git -C "$REPO" push -q "$ORIGIN" "HEAD:refs/heads/tkt-$t/work" 2>/dev/null
    nums=$(jq -c --argjson t "$t" '. + [{number: $t}]' <<<"$nums")
  done
  fix_issue_list "status:in-review" "$nums"
  : > "$GH_LOG"
  CLAIM_REMOTE="$ORIGIN" NOTIFY=0 bash "$HERE/reconcile-claims.sh" --dry-run >/dev/null 2>&1
  grep -vc '^api repos/acme/widgets' "$GH_LOG" | tr -d ' '
}
small=$(recon_calls 3); big=$(recon_calls 30)
want "30 claimed tickets cost what 3 do"           "$small" "$big"
want_in "and the branches' PRs were asked for, in one batch" 'pullRequests\(headRefName:"tkt-830/work"' "$(cat "$GH_LOG")"
want_not_in "no PR is read one branch at a time"     '^pr list .*--head' "$(cat "$GH_LOG")"

echo "--- a refused token: back off, and work from the last good read ---"
fresh; queue_n repair 2
bash "$T" >/dev/null 2>&1   # a good tick, in shadow so the queue stays: the snapshot
rm -f "$STATE/runs"/*; : > "$SPAWNS"; touch "$FIX/gh/ratelimit"
out=$(SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 bash "$T" 2>&1)
want_not_in "it is not blind"                      'could not be read — spawning nothing' "$out"
want_in "it says it works from the snapshot"       'working from the snapshot taken' "$out"
want_in "and still starts work"                    '^501' "$(cat "$SPAWNS")"
want_in "the refusal starts a backoff"             '^[0-9]+' "$(cat "$STATE/swarm/gh-backoff" 2>/dev/null)"
n=$(calls); : > "$GH_LOG"
out=$(bash "$T" 2>&1)
want "while it holds, nothing asks GitHub"         "0" "$(calls)"
: > "$FIX/house.log"; COORDINATOR_SHADOW=0 bash "$HERE/coordinator-housekeeping.sh" >/dev/null 2>&1
want_not_in "housekeeping skips the reconcile"     '^reconcile' "$(cat "$FIX/house.log")"
want_not_in "and the judge"                        '^judge' "$(cat "$FIX/house.log")"
want_in "the server sweep still runs (no GitHub)"  '^sweep' "$(cat "$FIX/house.log")"
export SWARM_NOW=$(( $(date +%s) + 3600 )); : > "$GH_LOG"
bash "$T" >/dev/null 2>&1
want_in "once it ends, the tick asks again"        'pullRequests\(states:\[OPEN\]' "$(cat "$GH_LOG")"
unset SWARM_NOW

echo "--- a refusal doubles the backoff, up to a cap ---"
fresh; ( . "$HERE/../swarm/swarm-env.sh"
  export SWARM_NOW=1000000
  gh_backoff_note "GraphQL: API rate limit already exceeded for user ID 1."; a=$(cut -f1 "$STATE/swarm/gh-backoff")
  gh_backoff_note "You have exceeded a secondary rate limit"; b=$(cut -f1 "$STATE/swarm/gh-backoff")
  for i in 1 2 3 4 5; do gh_backoff_note "API rate limit exceeded"; done; c=$(cut -f1 "$STATE/swarm/gh-backoff")
  printf '%s %s %s\n' $(( (a - SWARM_NOW) / 60 )) $(( (b - SWARM_NOW) / 60 )) $(( (c - SWARM_NOW) / 60 ))
  gh_backoff_note "HTTP 404: Not Found" && echo "404 counted" || echo "404 ignored" ) > "$FIX/backoff.out"
want "4 min, then 8, capped at 32"                 "4 8 32" "$(sed -n 1p "$FIX/backoff.out")"
want "an ordinary failure is not a rate limit"     "404 ignored" "$(sed -n 2p "$FIX/backoff.out")"

echo "--- no snapshot fresh enough: still blind, never a guess ---"
fresh; queue_n repair 2
bash "$T" >/dev/null 2>&1
touch "$FIX/gh/ratelimit"
touch -t 202601010000 "$C/snapshot/prs.json"
out=$(SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 bash "$T" 2>&1)
want_in "a stale snapshot is refused"              'the open pull requests could not be read.* — spawning nothing' "$out"
want "and nothing starts"                          "" "$(cat "$SPAWNS")"

echo "--- one read of the open PRs serves the tick, the watcher, the status line, repair-watch and the live view ---"
# Every caller on its own read the open PRs: on 2026-10-17 GitHub's hourly
# allowance ran out and the tick, blind, started nothing.
fresh; unset NEEDSME_PRS_MAX_AGE SWARM_PRS_MAX_AGE SWARM_STATUS_PRS_MAX_AGE
rm -f "$STATE/swarm/prs.json" "$STATE/swarm/gh-calls.log" "$STATE/swarm/hold-prs.count" "$FIX/gh/allowance"
fix_prs "11 501 sha11 CLEAN 0 -" "12 502 sha12 CLEAN 0 -" "13 503 sha13 DIRTY 0 -"
cat > "$BIN/claim-show" <<'SH'
#!/usr/bin/env bash
printf '{"branch":"tkt-%s/work"}\n' "$2"
SH
chmod +x "$BIN/claim-show"
fix_live "" 0
budget_pass() { # every reader once, after one tick: the open-PR reads they made between them
  : > "$GH_LOG"
  bash "$T" >/dev/null 2>&1
  bash "$HERE/needsme-watch.sh" pending >/dev/null 2>&1
  bash "$HERE/../swarm/status-line.sh" --print >/dev/null 2>&1
  bash "$HERE/../swarm/repair-watch.sh" --explain --only repair >/dev/null 2>&1
  SWARM_CLAIM_LOCK="$BIN/claim-show" SWARM_GIT=false SWARM_PRS_FILE="$STATE/swarm/prs.json" SWARM_GH_CALLS="$STATE/swarm/gh-calls.log" \
    node "$HERE/../swarm/live-view/progress.mjs" --gather '{"tickets":["501","502"],"ids":[],"repo":"acme/widgets"}' > "$FIX/gather.out" 2>/dev/null
  grep -cE 'pullRequests\(states:\[OPEN\]' "$GH_LOG" | tr -d ' '
}
want "five readers, one read of the open PRs"      "1" "$(budget_pass)"
want_in "the live view read its agents' branches"   'tkt-501/work' "$(cat "$FIX/gather.out")"
want "and took their open PRs from the copy"       "11 12" "$(jq -r '[.tickets[].pr.number] | join(" ")' "$FIX/gather.out" 2>/dev/null)"
want_not_in "without asking GitHub for them"       '^pr list .*--head tkt-50[12]/' "$(cat "$GH_LOG")"
want_in "and the copy is what the status line counted" '^0$' "$(cat "$STATE/swarm/hold-prs.count" 2>/dev/null)"
out=$(bash "$T" 2>&1)
want_in "the tick says what it spent and who spent the hour" 'gh: [0-9]+ call\(s\) this tick · last hour: .*coordinator-tick [0-9]+' "$out"
want_in "the live view's calls are counted too"    'live-view' "$(cut -f2 "$STATE/swarm/gh-calls.log" | sort -u | tr '\n' ' ')"

echo "--- below 10% left, the live view's gather and titles wait; the tick keeps its read ---"
printf '%s 5000 %s\n' 300 $(( $(date +%s) + 1800 )) > "$FIX/gh/allowance"
: > "$GH_LOG"; out=$(bash "$T" 2>&1)
want_in "the tick still reads the open PRs"       'pullRequests\(states:\[OPEN\]' "$(cat "$GH_LOG")"
want_in "and reports what is left"                 'left: GraphQL 300/5000' "$out"
low=$(cd "$HERE/../swarm/live-view" && SWARM_GH_ALLOWANCE="$STATE/swarm/gh-allowance" node --input-type=module -e "
  import { allowanceLow } from './progress.mjs'; const l = allowanceLow(); console.log(l ? l.resource + ' ' + l.left : 'none')")
want "the live view sees the floor"                "graphql 300" "$low"
view_calls() { # one live-view snapshot with an agent running, its progress gathered in line
  rm -f "$STATE/swarm/progress.json" "$STATE/swarm/live-view-titles.json"; : > "$GH_LOG"
  SWARM_PROGRESS_SYNC=1 SWARM_CLAIM_LOCK="$BIN/claim-show" SWARM_GIT=false bash "$HERE/../swarm/live-view.sh" --print >/dev/null 2>&1
  calls
}
fix_running 501
want "below it, a live-view pass asks GitHub nothing" "0" "$(view_calls)"
printf 'graphql\t%s\t5000\t%s\n' 4000 $(( $(date +%s) + 1800 )) > "$STATE/swarm/gh-allowance"
want_in "above it, the same pass asks"             '^[1-9]' "$(view_calls)"
rm -f "$STATE/runs/claim-501-t.json"
printf 'graphql\t%s\t5000\t%s\n' 300 $(( $(date +%s) + 1800 )) > "$STATE/swarm/gh-allowance"
touch -t 202601010000 "$STATE/swarm/prs.json"; : > "$GH_LOG"
bash "$HERE/needsme-watch.sh" pending >/dev/null 2>&1
want "an old copy still serves the watcher below the floor" "0" "$(grep -cE 'pullRequests\(states:\[OPEN\]' "$GH_LOG" | tr -d ' ')"
printf '%s 5000 %s\n' 4000 $(( $(date +%s) + 1800 )) > "$FIX/gh/allowance"; bash "$T" >/dev/null 2>&1
touch -t 202601010000 "$STATE/swarm/prs.json"; : > "$GH_LOG"
bash "$HERE/needsme-watch.sh" pending >/dev/null 2>&1
want "above it, an old copy is read again"         "1" "$(grep -cE 'pullRequests\(states:\[OPEN\]' "$GH_LOG" | tr -d ' ')"

echo "--- blind on a spent allowance: the alarm names the rate limit and its reset ---"
fresh; queue_n repair 1
printf '0 5000 %s\n' $(( $(date +%s) + 1800 )) > "$FIX/gh/allowance"; touch "$FIX/gh/ratelimit"
rm -f "$C/snapshot/prs.json"; : > "$FIX/house.log"
out=$(SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 bash "$T" 2>&1)
want_in "the tick names the limit and when it resets" "could not be read — GitHub's hourly API allowance is spent: GraphQL 0 of 5000 left until [0-9]{2}:[0-9]{2}Z — spawning nothing" "$out"
want_in "and so does the owner's alarm"            "allowance is spent: GraphQL 0 of 5000 left until [0-9]{2}:[0-9]{2}Z" "$(cat "$FIX/house.log")"
want_not_in "not the old guess"                    'gh auth or network' "$(cat "$FIX/house.log")"
rm -f "$FIX/gh/ratelimit" "$FIX/gh/allowance"

echo "--- 81 open PRs: read in pages GitHub can answer, all or nothing ---"
# 2026-10-19: with 81 open, `gh pr list --limit 200` with the check rollups came back
# HTTP 504 every tick (it asks GitHub for 100 a page; 50 answered in 8s) and the
# coordinator started nothing for 23 minutes. This GitHub times out above 50 a page.
cat > "$BIN/gh-504" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2 $*" in
  "api graphql "*'pullRequests(states:[OPEN]'*) FAKE_PRS_504_ABOVE=50 exec bash "$GH_OPEN_PRS_FAKE" "$FIX/gh/prs-81.json" "$@" ;;
  "pr list"*) l=30; p=""; for a in "$@"; do [ "$p" = --limit ] && l="$a"; p="$a"; done
    [ "$l" -le 50 ] || { echo "HTTP 504: 504 Gateway Timeout (https://api.github.com/graphql)" >&2; exit 1; }
    jq --argjson l "$l" 'sort_by(-.number) | .[:$l]' "$FIX/gh/prs-81.json" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$BIN/gh-504"
jq -n '[range(1001; 1082) | {number: ., title: "PR \(.)", updatedAt: "2026-10-19T14:00:00Z", headRefName: "tkt-\(.)-x", headRefOid: "sha\(.)",
  baseRefName: "develop", isDraft: (. % 7 == 0), mergeable: "MERGEABLE", mergeStateStatus: "CLEAN",
  labels: [{id: "L1", name: "needs:human-approval", description: "", color: "ff0000"}],
  closingIssuesReferences: [{id: "I\(.)", number: (. - 500), url: "https://github.com/acme/widgets/issues/\(. - 500)",
    repository: {id: "R1", name: "widgets", owner: {id: "O1", login: "acme"}}}],
  statusCheckRollup: [
    {__typename: "CheckRun", name: "build", workflowName: "CI", status: "COMPLETED", conclusion: "SUCCESS",
     startedAt: "2026-10-19T13:00:00Z", completedAt: "2026-10-19T13:05:00Z", detailsUrl: "https://ci/\(.)"},
    {__typename: "StatusContext", context: "design-critic", state: "PENDING", targetUrl: "https://critic/\(.)", startedAt: "2026-10-19T13:01:00Z"}]}]' \
  > "$FIX/gh/prs-81.json"
open_prs() { # [env…] — gh_open_prs 0 against the 504-above-50 GitHub; prints the numbers, then rc=N
  local out rc
  out=$(env "$@" SWARM_GH="$BIN/gh-504" GH_REPO=acme/widgets GH_PRS_FILE="$FIX/prs-81-copy.json" \
        GH_BACKOFF_FILE="$FIX/backoff-81" GH_CALLS_FILE="$FIX/calls-81.log" \
        bash -c '. "$1" || exit 9; gh_open_prs 0' _ "$HERE/gh-batch.sh" 2>/dev/null); rc=$?
  printf '%s\n' "$out" | jq -r '[.[].number] | sort | map(tostring) | join(",")' 2>/dev/null; echo "rc=$rc"
}
pages() { grep -cE 'pullRequests\(states:\[OPEN\]' "$GH_LOG" | tr -d ' '; }
ALL81=$(jq -r '[.[].number] | sort | map(tostring) | join(",")' "$FIX/gh/prs-81.json")
rm -f "$FIX/prs-81-copy.json"; : > "$GH_LOG"
got=$(open_prs)
want "all 81 come back"                            "$ALL81
rc=0" "$got"
want "in three pages of 40"                        "3" "$(pages)"
want "and the shared copy holds all 81"            "81" "$(jq length "$FIX/prs-81-copy.json" 2>/dev/null)"
want "newest first, as gh pr list gives them"      "1081" "$(jq '.[0].number' "$FIX/prs-81-copy.json" 2>/dev/null)"
want "each PR in gh pr list's shape, every field the readers take" \
  "$(jq -cS 'sort_by(.number)' "$FIX/gh/prs-81.json")" "$(jq -cS 'sort_by(.number)' "$FIX/prs-81-copy.json" 2>/dev/null)"

echo "--- a page that times out is asked once more, smaller ---"
rm -f "$FIX/prs-81-copy.json"; : > "$GH_LOG"
got=$(open_prs GH_PRS_PAGE=80)
want "80 a page 504s; 40 a page answers all 81"    "$ALL81
rc=0" "$got"
want_in "the second ask is half the size"          'first=40' "$(grep -E 'pullRequests\(states:\[OPEN\]' "$GH_LOG" | sed -n 2p)"
: > "$GH_LOG"
got=$(open_prs GH_PRS_PAGE=160)
want "a second timeout fails the read"             "rc=1" "$(printf '%s' "$got" | tail -1)"
want "after one retry, not a third ask"            "2" "$(pages)"

echo "--- a partial read is never written as the open PRs ---"
printf '[{"number":1}]\n' > "$FIX/prs-81-copy.json"; before=$(cat "$FIX/prs-81-copy.json")
got=$(open_prs FAKE_PRS_FAIL_AFTER=c40)
want "a failed second page fails the read"         "rc=1" "$(printf '%s' "$got" | tail -1)"
want "and leaves the shared copy as it was"        "$before" "$(cat "$FIX/prs-81-copy.json")"
got=$(open_prs FAKE_PRS_TOTAL=82)
want "GitHub counting one more than it listed fails it" "rc=1" "$(printf '%s' "$got" | tail -1)"
want "and leaves the copy too"                     "$before" "$(cat "$FIX/prs-81-copy.json")"

exit $FAILED
