#!/usr/bin/env bash
# usage-step-hold.test.sh — near the plan's wall, a running build holds before its
# next step rather than run into it. On 2026-10-19 five builds hit the five-hour
# limit at once and every session died mid-step. Now, with either window at
# swarm.usageStepHold (0.95):
#   - the next step does not start: the run waits, says so, and the claim names the hold;
#   - once the window clears, the step runs, in the same run, nothing lost;
#   - a wait past its limit goes back on the queue: never a park, never a label.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
BT="$HERE/../build-ticket"
. "$HERE/../driver-env.sh" || exit 1
. "$HERE/../state.sh" || exit 1

cat > "$FIX/queue-stub.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/queue.log"
SH
export DRIVER_QUEUE="$FIX/queue-stub.sh"
export SWARM_USAGE_HOLD_FILE="$FIX/usage-hold"
export SWARM_NOW=1792347200
RESET=1792356000
fix_brief plan superpowers:writing-plans

# <use> — another build's log on this host, carrying the account's five-hour reading.
reading() {
  jq -nc --argjson u "$1" --argjson r "$RESET" \
    '{type:"rate_limit_event", rate_limit_info:{status:"allowed_warning",
      unifiedWindows:{five_hour:{utilization:$u, resetsAt:$r}}}}' > "$STATE/logs/claim-900-other.log"
}
# The wait: it records how many model calls had been made by then, then the window clears.
cat > "$FIX/wait-stub.sh" <<'SH'
#!/usr/bin/env bash
printf 'waited %s calls-so-far %s\n' "$1" "$(grep -c . "$CLAUDE_LOG")" >> "$FIX/waits.log"
[ "${WAIT_CLEARS:-1}" = 1 ] && jq -nc '{type:"rate_limit_event", rate_limit_info:{status:"allowed",
  unifiedWindows:{five_hour:{utilization:0.5, resetsAt:1792356000}}}}' > "$STATE/logs/claim-900-other.log"
exit 0
SH
chmod +x "$FIX/wait-stub.sh"
export DRIVER_USAGE_WAIT_CMD="$FIX/wait-stub.sh" DRIVER_USAGE_WAIT_SEC=60
export FIX STATE CLAUDE_LOG
reset_case() { # <ticket>
  rm -f "$SWARM_USAGE_HOLD_FILE" "$FIX/queue.log" "$FIX/waits.log"; : > "$GH_LOG"; : > "$CLAUDE_LOG"; fix_gh_ok
  rm -rf "$STATE/driver/$1"
  fix_issue "$1" OPEN "status:ready"
  driver_state_init "$1" --worktree "$REPO"
  jq -nc '{type:"result",subtype:"success",is_error:false,result:"not json"}' > "$FIX/ai/plan.jsonl"
}
labels_added() { grep -E 'issue edit .*--add-label' "$GH_LOG" || true; }

echo "--- at 96%, the next step waits; once clear, it runs ---"
reset_case 701; reading 0.96
out=$(bash "$BT" 701 --steps "plan" 2>&1); rc=$?
want "it waited once" "1" "$(grep -c . "$FIX/waits.log" 2>/dev/null)"
want "and no model call was made before the wait" "waited 60 calls-so-far 0" "$(head -1 "$FIX/waits.log" 2>/dev/null)"
want_in "it says why, and that nothing stopped" '⏸ plan: usage hold — the five_hour window is at 96%.*nothing is stopped' "$out"
want_in "then carries on" '▶ plan: the usage hold cleared after 1 min' "$out"
want "the step then ran" "1" "$( [ -s "$CLAUDE_LOG" ] && echo 1 || echo 0)"
want_not_in "the wait was not a requeue" 'requeued' "$out"

echo "--- under the hold, no wait at all ---"
reset_case 702; reading 0.80
out=$(bash "$BT" 702 --steps "plan" 2>&1)
want "no wait" "0" "$(grep -c . "$FIX/waits.log" 2>/dev/null || echo 0)"
want_not_in "and no hold said" 'usage hold' "$out"

echo "--- a hold that outlasts its limit: back on the queue, never parked ---"
reset_case 703; reading 0.97
out=$(WAIT_CLEARS=0 DRIVER_USAGE_WAIT_MAX_SEC=120 bash "$BT" 703 --steps "plan" 2>&1); rc=$?
want "two waits, then the limit" "2" "$(grep -c . "$FIX/waits.log" 2>/dev/null)"
want "it ends as a requeue" "28" "$rc"
want "no model call was made" "0" "$(grep -c . "$CLAUDE_LOG")"
want_in "it is back on the queue" '^add 703 ' "$(cat "$FIX/queue.log" 2>/dev/null)"
want_in "with the reason" 'usage window stayed at 97% for 2 min before plan' "$(driver_state_get 703 requeued)"
want "no label goes on the ticket" "" "$(labels_added)"
want_not_in "no draft pull request, no park comment" 'pr create|issue comment' "$(cat "$GH_LOG")"

echo "--- the other host's reading counts: its heartbeat in the fleet file ---"
reset_case 705; reading 0.30
mkdir -p "$STATE/coordinator"
jq -nc --argjson r "$RESET" '{hosts:[{host:"yomato", usage:{five_hour:{u:0.96, reset:$r}}}]}' > "$STATE/coordinator/fleet.json"
out=$(WAIT_CLEARS=0 DRIVER_USAGE_WAIT_MAX_SEC=60 bash "$BT" 705 --steps "plan" 2>&1)
want_in "this host's logs say 30%, the other host's heartbeat 96%: the step holds" '⏸ plan: usage hold — the five_hour window is at 96%' "$out"
rm -f "$STATE/coordinator/fleet.json"

echo "--- the seven-day window holds too ---"
reset_case 704
jq -nc --argjson r "$(( SWARM_NOW + 86400 ))" '{type:"rate_limit_event", rate_limit_info:{status:"allowed_warning",
  unifiedWindows:{five_hour:{utilization:0.2, resetsAt:1792356000}, seven_day:{utilization:0.95, resetsAt:$r}}}}' > "$STATE/logs/claim-900-other.log"
out=$(bash "$BT" 704 --steps "plan" 2>&1)
want_in "a week at 95% holds the step" '⏸ plan: usage hold — the seven_day window is at 95%' "$out"

exit "$FAILED"
