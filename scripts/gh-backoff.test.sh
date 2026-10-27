#!/usr/bin/env bash
# gh-backoff.test.sh — the shared backoff checks the real limit before it stops every
# caller. A refusal while `gh api rate_limit` shows the allowance healthy is a
# secondary limit: seconds (Retry-After when GitHub gives it), not minutes, and a
# build's start read waits it out instead of exiting. A spent or unreadable allowance
# keeps the 4-to-32-minute backoff. The file names the refusal that started it. The
# search bucket spent on its own holds search calls alone, never a start or a spawn.
#
# On 2026-10-27 one refusal held every host for 16 minutes with GraphQL at 4759/5000,
# and 36 of 124 builds died at start: three 5-second tries all fell inside it.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../driver/tests/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../driver/driver-env.sh" || exit 1

# The forge. $FIX/refuse holds how many `issue view` calls GitHub refuses, with the
# text in $FIX/refusal; $FIX/rl.json is what `gh api rate_limit` answers (absent: it fails).
# $FIX/search-spent present: every search call is refused, as when another host drains it.
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
search=0
case "$1" in search) search=1 ;; issue|pr) for a in "$@"; do [ "$a" = --search ] && search=1; done ;; esac
if [ "$search" = 1 ] && [ -f "$FIX/search-spent" ]; then echo "gh: API rate limit exceeded for user ID 1." >&2; exit 1; fi
case "$1 $2" in
  "api rate_limit") [ -s "$FIX/rl.json" ] || exit 1; cat "$FIX/rl.json" ;;
  "search issues"|"issue list") echo '[]' ;;
  "issue view")
    n=$(cat "$FIX/refuse" 2>/dev/null || echo 0)
    if [ "$n" -gt 0 ]; then echo $((n - 1)) > "$FIX/refuse"; cat "$FIX/refusal" >&2; exit 1; fi
    printf 'OPEN\001status:ready\001A title\n' ;;
esac
exit 0
SH
chmod +x "$BIN/gh"

BO="$STATE/swarm/gh-backoff"
export GH_BACKOFF_FILE="$BO" GH_ALLOWANCE_FILE="$FIX/allowance" GH_FLEET_FILE="$FIX/fleet.json"
export DRIVER_LOOKUP_RETRY_SEC=0 DRIVER_LOOKUP_TRIES=3
reset=$(( $(date +%s) + 3000 ))
healthy() { printf '{"resources":{"core":{"limit":5000,"remaining":4800,"reset":%s},"graphql":{"limit":5000,"remaining":4759,"reset":%s}}}\n' "$reset" "$reset" > "$FIX/rl.json"; }
spent()   { printf '{"resources":{"core":{"limit":5000,"remaining":4800,"reset":%s},"graphql":{"limit":5000,"remaining":0,"reset":%s}}}\n' "$reset" "$reset" > "$FIX/rl.json"; }
fresh() { rm -f "$BO" "$BO.search" "$FIX/rl.json" "$FIX/allowance" "$FIX/search-spent"; echo 0 > "$FIX/refuse"; : > "$GH_LOG"; unset SWARM_NOW; }
start_read() { # the start step's own read (driver/steps/start.sh)
  driver_gh_read swarm_gh issue view 7 --repo acme/widgets --json state,labels,title \
    -q '.state + "\u0001" + ([.labels[].name]|join(",")) + "\u0001" + .title' 2>/dev/null
}
field() { cut -f"$1" "$BO" 2>/dev/null; }

echo "--- the guard: one refusal with a healthy allowance does not stop a start read ---"
fresh; healthy; export GH_BACKOFF_SECONDARY_SEC=1
echo 1 > "$FIX/refuse"; echo "GraphQL: API rate limit already exceeded for user ID 1." > "$FIX/refusal"
meta=$(start_read); rc=$?
want "the start read answers"                         "0" "$rc"
want "with the ticket"                                "OPEN" "$(printf '%s' "$meta" | cut -d$'\001' -f1)"
want "the refusal was treated as secondary"           "secondary" "$(field 4)"
want_in "and the file names the refusal"              'API rate limit already exceeded for user ID 1' "$(field 5)"
want "GitHub was asked again after the wait"          "2" "$(grep -c '^issue view' "$GH_LOG" | tr -d ' ')"
unset GH_BACKOFF_SECONDARY_SEC

echo "--- secondary: a minute by default, Retry-After when GitHub says it ---"
fresh; healthy; export SWARM_NOW=1000000
gh_backoff_note "You have exceeded a secondary rate limit. Please wait a few minutes before you try again."
want "60 seconds, not minutes for everyone"           "60" "$(( $(field 1) - SWARM_NOW ))"
fresh; healthy; export SWARM_NOW=1000000
gh_backoff_note "$(printf 'HTTP 403: You have exceeded a secondary rate limit\nRetry-After: 7')"
want "Retry-After is honoured"                        "7" "$(( $(field 1) - SWARM_NOW ))"
want "and the text is kept on one line"               "1" "$(wc -l < "$BO" | tr -d ' ')"
want_in "the reason reads back"                       '^secondary: HTTP 403: You have exceeded a secondary rate limit Retry-After: 7$' "$(gh_backoff_reason)"
gh_backoff_note "Retry-After: 99999 secondary rate limit"
want "a huge Retry-After is capped at 5 minutes"      "300" "$(( $(field 1) - SWARM_NOW ))"

echo "--- primary: a spent or unreadable allowance keeps the long backoff ---"
fresh; spent; export SWARM_NOW=1000000
gh_backoff_note "GraphQL: API rate limit already exceeded for user ID 1."
want "spent: 4 minutes"                               "240" "$(( $(field 1) - SWARM_NOW ))"
want "named primary"                                  "primary" "$(field 4)"
want_in "with its refusal"                            'already exceeded' "$(field 5)"
gh_backoff_note "API rate limit exceeded"
want "and doubled on the next"                        "480" "$(( $(field 1) - SWARM_NOW ))"
fresh; export SWARM_NOW=1000000
gh_backoff_note "API rate limit exceeded"
want "an unreadable rate_limit is never read as healthy" "primary" "$(field 4)"
fresh; healthy; export SWARM_NOW=1000000
printf 'graphql\t100\t5000\t%s\n' $(( SWARM_NOW + 1800 )) > "$FIX/allowance"
gh_backoff_note "API rate limit exceeded"
want "another reading under the floor is primary too" "primary" "$(field 4)"

echo "--- a secondary neither lengthens the primary level nor cuts a longer backoff short ---"
fresh; spent; export SWARM_NOW=1000000
gh_backoff_note "API rate limit exceeded"; p1=$(field 1)
healthy; gh_backoff_note "secondary rate limit"
want "a longer backoff another caller set stands"     "$p1" "$(field 1)"
want "the level is kept"                              "0" "$(field 2)"
export SWARM_NOW=1000600; gh_backoff_note "secondary rate limit"
want "past it, the secondary's own minute"            "60" "$(( $(field 1) - SWARM_NOW ))"
spent; export SWARM_NOW=1000700; gh_backoff_note "API rate limit exceeded"
want "the next primary doubles from the last primary" "480" "$(( $(field 1) - SWARM_NOW ))"
unset SWARM_NOW

echo "--- a long backoff is not slept out at start: the read gives up in seconds ---"
fresh; spent
echo 99 > "$FIX/refuse"; echo "API rate limit exceeded" > "$FIX/refusal"
s=$SECONDS; start_read >/dev/null; rc=$?
want "it fails"                                       "1" "$rc"
want "without waiting the 4 minutes out"              "1" "$([ $((SECONDS - s)) -lt 30 ] && echo 1 || echo 0)"
want "and asks GitHub once: the backoff refuses the rest" "1" "$(grep -c '^issue view' "$GH_LOG" | tr -d ' ')"

echo "--- the search bucket alone spent: only search calls wait, until its reset ---"
# 2026-10-27, after 0.7.286: search 0/30 every minute from a host this one cannot see,
# REST 4925/5000, GraphQL 4995/5000; the shared backoff was re-set each minute and
# held every read and every spawn.
fresh; touch "$FIX/search-spent"
sreset=$(( $(date +%s) + 40 ))
printf '{"resources":{"core":{"limit":5000,"remaining":4925,"reset":%s},"graphql":{"limit":5000,"remaining":4995,"reset":%s},"search":{"limit":30,"remaining":0,"reset":%s}}}\n' "$reset" "$reset" "$sreset" > "$FIX/rl.json"
gh_call search issues "is:open label:x" >/dev/null 2>&1
want "the refused search sets no shared backoff"      "1" "$(gh_backoff_active >/dev/null && echo 0 || echo 1)"
want "but a search one, until the search reset"       "$sreset" "$(gh_backoff_search_active)"
want_in "naming the refusal"                          '^[0-9]+	search	gh: API rate limit exceeded for user ID 1\.$' "$(cat "$BO.search" 2>/dev/null)"
cp "$BO.search" "$FIX/search-backoff.kept" 2>/dev/null; cp "$BO" "$FIX/shared-backoff.kept" 2>/dev/null
# The tick runs on the backoff files that refusal left, while they still hold.
OUTER_FIX="$FIX"
( . "$HERE/../swarm/tests/fixture.sh"; swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
  mkdir -p "$STATE/swarm"
  cp "$OUTER_FIX/search-backoff.kept" "$STATE/swarm/gh-backoff.search" 2>/dev/null
  cp "$OUTER_FIX/shared-backoff.kept" "$STATE/swarm/gh-backoff" 2>/dev/null
  cat > "$BIN/noop" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$BIN/noop"
  export COORDINATOR_RECONCILE="$BIN/noop" COORDINATOR_SWEEP="$BIN/noop" COORDINATOR_WORKTREE_SWEEP="$BIN/noop"
  export COORDINATOR_JUDGE="$BIN/noop" COORDINATOR_LANE="$BIN/noop" COORDINATOR_NOTIFY_CMD="$BIN/noop"
  export COORDINATOR_UNBLOCK="$BIN/noop" COORDINATOR_MACHINE_PARKS="$BIN/noop" COORDINATOR_RELEASE_BATCH="$BIN/noop"
  export COORDINATOR_HOUSEKEEPING=inline COORDINATOR_HOUSEKEEPING_EVERY_MIN=0
  export COORDINATOR_REFRESH=0 COORDINATOR_FREE_GB=500 COORDINATOR_CLAIMS_CMD="cat $FIX/claims.txt"
  printf '#!/usr/bin/env bash\necho "[]"\n' > "$BIN/fixlock"; chmod +x "$BIN/fixlock"; export COORDINATOR_FIX_LOCK="$BIN/fixlock"
  unset COORDINATOR_SHADOW COORDINATOR_CAP SWARM_NOW GH_BACKOFF_FILE GH_ALLOWANCE_FILE GH_FLEET_FILE
  export SWARM_FREE_MEM_GB=16 SWARM_IDLE=90 SWARM_CORES=10 TEST_PID=$$
  cat > "$BIN/spawn-live" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "${CLAIM_CLASS:-}" >> "$SPAWNS"
printf '{"run_id":"claim-%s-live","ticket":"%s","child_pid":%s}\n' "$1" "$1" "$TEST_PID" > "$STATE/runs/claim-$1-live.json"
SH
  chmod +x "$BIN/spawn-live"
  : > "$FIX/claims.txt"; : > "$SPAWNS"; printf '[]\n' > "$FIX/gh/prs-all.json"
  fix_issue 501 OPEN "status:in-review"; bash "$HERE/coordinator-queue.sh" add 501 --class repair >/dev/null; fix_pr_for 501
  out=$(SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 bash "$HERE/coordinator-tick.sh" 2>&1)
  want_in "the coordinator spawns"                    '^501' "$(cat "$SPAWNS")"
  want_not_in "and does not hold for it"              'spawn: holding' "$out"
  exit "$FAILED" ) || FAILED=1

: > "$GH_LOG"; s=$SECONDS
meta=$(start_read); rc=$?
want "a start read returns the ticket"                "0 OPEN" "$rc $(printf '%s' "$meta" | cut -d$'\001' -f1)"
want "at once, with no wait"                          "1" "$([ $((SECONDS - s)) -lt 3 ] && echo 1 || echo 0)"
gh_call issue list --repo acme/widgets --label x >/dev/null 2>&1
want "a list with no search goes ahead"               "1" "$(grep -c '^issue list --repo acme/widgets --label x' "$GH_LOG" | tr -d ' ')"
: > "$GH_LOG"
err=$(gh_call search issues "is:open" 2>&1 >/dev/null); rc=$?
want "a search call is held"                          "75" "$rc"
want_in "and says until when"                         "search calls wait until" "$err"
gh_call issue list --repo acme/widgets --search "is:open" >/dev/null 2>&1
gh_call api "search/issues?q=x" >/dev/null 2>&1
want "so is a list --search, and api search/…: GitHub is not asked" "0" "$(grep -c . "$GH_LOG" | tr -d ' ')"
SWARM_NOW=$(( sreset + 1 )) gh_call search issues "is:open" >/dev/null 2>&1
want "past the reset, search asks GitHub again"       "1" "$(grep -c '^search issues' "$GH_LOG" | tr -d ' ')"
rm -f "$FIX/search-spent" "$BO.search"
printf '{"resources":{"core":{"limit":5000,"remaining":4925,"reset":%s},"graphql":{"limit":5000,"remaining":4995,"reset":%s},"search":{"limit":30,"remaining":25,"reset":%s}}}\n' "$reset" "$reset" "$sreset" > "$FIX/rl.json"
gh_backoff_note "gh: API rate limit exceeded for user ID 1." search issues x
want "a search refusal with search healthy is a secondary, as before" "secondary" "$(field 4)"
want "and no search-only backoff"                     "1" "$(gh_backoff_search_active >/dev/null && echo 0 || echo 1)"
rm -f "$BO"; printf '{"resources":{"core":{"limit":5000,"remaining":4925,"reset":%s},"graphql":{"limit":5000,"remaining":4995,"reset":%s}}}\n' "$reset" "$reset" > "$FIX/rl.json"
gh_backoff_note "gh: API rate limit exceeded for user ID 1." search issues x
want "no search reading is never read as search spent" "1" "$(gh_backoff_search_active >/dev/null && echo 0 || echo 1)"

suite_end "$FAILED"
