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
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
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
# The unblocker's reads are its own (unblock-waiting.test.sh): this counts the tick's.
export COORDINATOR_UNBLOCK="$BIN/noop" COORDINATOR_MACHINE_PARKS="$BIN/noop" COORDINATOR_RELEASE_BATCH="$BIN/noop"
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
fix_issue 502 OPEN "status:in-review"; bash "$Q" add 502 --class repair >/dev/null; fix_pr_for 502
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
  # The open-PR list itself is paged, a request per 25 PRs; what must not grow is the rest.
  echo "$(( $(calls) - $(grep -c 'OpenPullRequests' "$GH_LOG") ))"
}
small=$(clash_calls 3); big=$(clash_calls 40)
want "40 clashing PRs cost what 3 do"              "$small" "$big"
want "beside the open PRs, read in two pages"      "2" "$(grep -c 'OpenPullRequests' "$GH_LOG" | tr -d ' ')"
want "and every one is still offered to finish"    "40" "$(grep -c 'FINISH PR' "$FIX/claimable.out" | tr -d ' ')"
: > "$GH_LOG"; CLAIMABLE_PRS_FILE="$FIX/gh/prs-all.json" bash "$HERE/claimable-issues.sh" >/dev/null 2>&1
want_not_in "a caller's PR read is reused, not asked again" 'OpenPullRequests' "$(cat "$GH_LOG")"

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
want_in "the refusal starts a backoff"             '^[0-9]+' "$(cat "$STATE/swarm/gh-backoff" 2>/dev/null)"
# A build started inside the backoff dies at its first read (2026-10-27: 36 of 124).
want "but starts nothing while it holds"           "" "$(cat "$SPAWNS")"
want_in "and says why, with GitHub's words"        'spawn: holding — GitHub is refusing this token until .* \(primary: GraphQL: API rate limit already exceeded' "$out"
n=$(calls); : > "$GH_LOG"
out=$(bash "$T" 2>&1)
want "while it holds, nothing asks GitHub"         "0" "$(calls)"
: > "$FIX/house.log"; COORDINATOR_SHADOW=0 bash "$HERE/coordinator-housekeeping.sh" >/dev/null 2>&1
want_not_in "housekeeping skips the reconcile"     '^reconcile' "$(cat "$FIX/house.log")"
want_not_in "and the judge"                        '^judge' "$(cat "$FIX/house.log")"
want_in "the server sweep still runs (no GitHub)"  '^sweep' "$(cat "$FIX/house.log")"
export SWARM_NOW=$(( $(date +%s) + 3600 )); : > "$GH_LOG"
bash "$T" >/dev/null 2>&1
want_in "once it ends, the tick asks again"        'OpenPullRequests' "$(cat "$GH_LOG")"
rm -f "$FIX/gh/ratelimit" "$STATE/runs"/*; : > "$SPAWNS"; fix_pr_for 501
export SWARM_NOW=$(( SWARM_NOW + 3600 ))   # past the backoff that last refused tick set
SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 bash "$T" >/dev/null 2>&1
want_in "and, answered, starts work again"         '^501' "$(cat "$SPAWNS")"
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
  grep -c 'OpenPullRequests' "$GH_LOG" | tr -d ' '
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
want_in "the tick still reads the open PRs"       'OpenPullRequests' "$(cat "$GH_LOG")"
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
want "an old copy still serves the watcher below the floor" "0" "$(grep -c 'OpenPullRequests' "$GH_LOG" | tr -d ' ')"
printf '%s 5000 %s\n' 4000 $(( $(date +%s) + 1800 )) > "$FIX/gh/allowance"; bash "$T" >/dev/null 2>&1
touch -t 202601010000 "$STATE/swarm/prs.json"; : > "$GH_LOG"
bash "$HERE/needsme-watch.sh" pending >/dev/null 2>&1
want "above it, an old copy is read again"         "1" "$(grep -c 'OpenPullRequests' "$GH_LOG" | tr -d ' ')"

echo "--- blind on a spent allowance: the alarm names the rate limit and its reset ---"
fresh; queue_n repair 1
printf '0 5000 %s\n' $(( $(date +%s) + 1800 )) > "$FIX/gh/allowance"; touch "$FIX/gh/ratelimit"
rm -f "$C/snapshot/prs.json"; : > "$FIX/house.log"
out=$(SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 bash "$T" 2>&1)
want_in "the tick names the limit and when it resets" "could not be read — GitHub's hourly API allowance is spent: GraphQL 0 of 5000 left until [0-9]{2}:[0-9]{2}Z — spawning nothing" "$out"
want_in "and so does the owner's alarm"            "allowance is spent: GraphQL 0 of 5000 left until [0-9]{2}:[0-9]{2}Z" "$(cat "$FIX/house.log")"
want_not_in "not the old guess"                    'gh auth or network' "$(cat "$FIX/house.log")"
rm -f "$FIX/gh/ratelimit" "$FIX/gh/allowance"

echo "--- develop-red: 22 pending rows cost the searches 1 does ---"
# 2026-10-27: 22 rows sat in develop-red.tsv and each pass searched once or twice a row,
# 44 searches a tick against GitHub's 30 a minute; refused, no row ever left the file.
cat > "$BIN/drgh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/drgh.log"
case "$*" in *"-X GET search/issues"*) echo '{"total_count":0,"items":[]}' ;; esac
exit 0
SH
chmod +x "$BIN/drgh"
dr_searches() { # <rows> — search calls one dry develop-red pass makes for that many pending rows
  local i; fresh; : > "$FIX/drgh.log"; : > "$STATE/swarm/develop-red-filed.tsv"; : > "$STATE/swarm/develop-red.tsv"
  for i in $(seq 1 "$1"); do printf '%040d\tchk-a\t%s\t\t1\n' "$i" "$i" >> "$STATE/swarm/develop-red.tsv"; done
  DEVELOP_RED_GH="$BIN/drgh" SWARM_GH="$BIN/drgh" DEVELOP_RED_QUEUE=off bash "$HERE/develop-red.sh" file dry > "$FIX/dr.out" 2>&1
  grep -c 'search/issues' "$FIX/drgh.log" | tr -d ' '
}
small=$(dr_searches 1); big=$(dr_searches 22)
echo "  searches: 1 row → $small, 22 rows → $big"
want "22 pending rows cost the searches 1 does"    "$small" "$big"
want_in "and two at most"                          '^[0-2]$' "$big"
want "every row still answered"                    "22" "$(grep -c '^would' "$FIX/dr.out" | tr -d ' ')"

echo "--- the call log names each api call's method and endpoint ---"
# 2026-10-27: every \`api -X …\` logged as a bare "api -X" hid 574 of a tick's 1,014 calls.
fresh; rm -f "$STATE/swarm/gh-calls.log"
( . "$HERE/gh-batch.sh"
  GH_CALLER=probe gh_call api -X GET search/issues -f q=x >/dev/null 2>&1
  GH_CALLER=probe gh_call api --method PATCH '/repos/o/r/issues/9?per_page=1' -f state=closed >/dev/null 2>&1
  GH_CALLER=probe gh_call api -H 'Accept: x' --jq .x repos/o/r/pulls >/dev/null 2>&1
  GH_CALLER=probe gh_call issue view 5 --json state >/dev/null 2>&1 )
want "a search names its method and endpoint"      "api GET search/issues" "$(sed -n 1p "$STATE/swarm/gh-calls.log" | cut -f3)"
want "the query string is dropped"                 "api PATCH repos/o/r/issues/9" "$(sed -n 2p "$STATE/swarm/gh-calls.log" | cut -f3)"
want "flag values are not taken for the endpoint"  "api repos/o/r/pulls" "$(sed -n 3p "$STATE/swarm/gh-calls.log" | cut -f3)"
want "other subcommands log as before"             "issue view" "$(sed -n 4p "$STATE/swarm/gh-calls.log" | cut -f3)"

suite_end "$FAILED"
