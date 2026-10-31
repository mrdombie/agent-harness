#!/usr/bin/env bash
# requeue.test.sh — a stop that is nobody's to answer goes back on the queue; it
# never parks. Measured 2026-10-18: 19 of 20 driver runs parked, 7 of them on the
# plan's usage limit (read as "answered in a shape the driver cannot read" or "did
# not run the Skill") and 1 on a single failed GitHub read at start. A park is never
# retried, so each one was a ticket lost to the queue.
#
#   - a step transcript carrying the CLI's usage-limit rejection ends as a requeue:
#     the hold file the coordinator spawns by is written, the ticket is back on the
#     queue, and no label, draft PR or question goes on it;
#   - the same sentence quoted by the model is not a wall, and still parks;
#   - a GitHub read that fails at start is retried, then requeued with its reason;
#     one that fails run after run parks, said;
#   - a refusal that set no note parks with the step's own words, not "left no reason".
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
BT="$HERE/../build-ticket"
. "$HERE/../driver-env.sh" || exit 1
. "$HERE/../state.sh" || exit 1

cat > "$FIX/queue-stub.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/queue.log"
SH
export DRIVER_QUEUE="$FIX/queue-stub.sh"
export SWARM_USAGE_HOLD_FILE="$FIX/usage-hold"
export DRIVER_LOOKUP_RETRY_SEC=0
# 2026-10-18T18:13:20Z: before the transcript's reset at 1792356000 (20:40Z).
export SWARM_NOW=1792347200
fix_brief plan superpowers:writing-plans

# The shape the CLI wrote into 10422's review.log at 18:52:25Z, cut to the fields read.
limit_transcript() { # <file>
  {
    echo '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1792356000,"rateLimitType":"five_hour","utilization":0.99}}'
    echo '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1792356000,"rateLimitType":"five_hour"}}'
    echo '{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"You'"'"'ve hit your session limit · resets 9:40pm (Europe/London)"}]},"error":"rate_limit"}'
    echo '{"type":"result","subtype":"success","is_error":true,"api_error":"usage_limit_reached","result":"You'"'"'ve hit your session limit · resets 9:40pm (Europe/London)","total_cost_usd":1.1}'
  } > "$1"
}
reset_case() { # <ticket>
  rm -f "$SWARM_USAGE_HOLD_FILE" "$FIX/queue.log"; : > "$GH_LOG"; fix_gh_ok
  rm -rf "$STATE/driver/$1"
  fix_issue "$1" OPEN "status:ready"
  driver_state_init "$1" --worktree "$REPO"
}
labels_added() { grep -E 'issue edit .*--add-label' "$GH_LOG" || true; }

echo "--- the plan's usage limit mid-step: requeue, hold, no park ---"
reset_case 601
limit_transcript "$FIX/ai/plan.jsonl"
out=$(bash "$BT" 601 --steps "plan" 2>&1); rc=$?
want "it ends as a requeue, not a park" "28" "$rc"
want_in "and says so" 'requeued.*not parked' "$out"
want_not_in "it is not read as a broken answer or a skipped Skill" 'parked \(|cannot read|did not run the Skill' "$out"
want "the hold is the rejection's own reset" "1792356000" "$(cut -f1 "$SWARM_USAGE_HOLD_FILE" 2>/dev/null)"
want_in "and names the wall" 'session limit' "$(cut -f2- "$SWARM_USAGE_HOLD_FILE" 2>/dev/null)"
want_in "the ticket is back on the queue at the front" '^add 601 --class new --first$' "$(cat "$FIX/queue.log" 2>/dev/null)"
want "no label goes on the ticket" "" "$(labels_added)"
want_not_in "no draft pull request, no park comment" 'pr create|issue comment' "$(cat "$GH_LOG")"
want_in "the reason is on the record" 'usage limit' "$(driver_state_get 601 requeued)"
want "plan is not marked done, so the next run resumes there" "" "$(driver_state_get 601 'done|join(",")')"

echo "--- the coordinator holds spawning on that file until the reset ---"
want_in "swarm_usage_hold answers from it" '2026-10-18T20:40' "$(bash -c '. "$1/../../swarm/swarm-env.sh" >/dev/null 2>&1; swarm_usage_hold' _ "$HERE")"

echo "--- a later wall is kept, an earlier one does not shorten it ---"
printf '1792999999\tweekly\n' > "$SWARM_USAGE_HOLD_FILE"
fix_issue 602 OPEN "status:ready"; driver_state_init 602 --worktree "$REPO"
bash "$BT" 602 --steps "plan" >/dev/null 2>&1
want "the weekly wall stands" "1792999999" "$(cut -f1 "$SWARM_USAGE_HOLD_FILE")"

echo "--- the wall's text with no event still holds, from the reset it names ---"
reset_case 603
grep -v rate_limit_event "$FIX/ai/plan.jsonl" > "$FIX/ai/plan.tmp" && mv "$FIX/ai/plan.tmp" "$FIX/ai/plan.jsonl"
bash "$BT" 603 --steps "plan" >/dev/null 2>&1; rc=$?
want "a requeue still" "28" "$rc"
e=$(cut -f1 "$SWARM_USAGE_HOLD_FILE" 2>/dev/null)
case "$e" in ''|*[!0-9]*) bad "a hold epoch was written — got '$e'" ;;
  *) if [ "$e" -gt "$SWARM_NOW" ]; then ok "the hold is in the future"; else bad "the hold is in the future — $e"; fi ;; esac

echo "--- the sentence quoted by the model is not a wall ---"
reset_case 604
jq -nc '{type:"assistant",message:{model:"claude-opus",content:[{type:"text",text:"The CI log said: You have hit your session limit · resets 9:40pm"}]}}' > "$FIX/ai/plan.jsonl"
jq -nc '{type:"result",subtype:"success",is_error:false,result:"not json"}' >> "$FIX/ai/plan.jsonl"
out=$(bash "$BT" 604 --steps "plan" 2>&1); rc=$?
want "it parks as before" "20" "$rc"
want "and writes no hold" "no" "$([ -f "$SWARM_USAGE_HOLD_FILE" ] && echo yes || echo no)"

echo "--- a GitHub read that fails at start: retried, then requeued with its reason ---"
reset_case 605
fix_gh_fail "issue view"
out=$(bash "$BT" 605 --steps "start" 2>&1); rc=$?
want "it ends as unread, left for the next tick" "26" "$rc"
want "the read was tried three times" "3" "$(grep -c '^issue view 605' "$GH_LOG")"
want_in "the reason is said" 'requeued.*could not read #605' "$out"
want_in "and kept on the record" 'could not read #605' "$(driver_state_get 605 requeued)"
want "no label goes on the ticket" "" "$(labels_added)"
want_in "it is back on the queue" '^add 605 ' "$(cat "$FIX/queue.log" 2>/dev/null)"

echo "--- one that fails run after run parks, said ---"
DRIVER_MAX_REQUEUES=1 bash "$BT" 605 --steps "start" >/dev/null 2>&1; rc=$?
want "the second in a row with a ceiling of 1 parks" "20" "$rc"
want_in "naming the requeues" 'start could not go on for 1 requeued runs in a row' "$(cat "$STATE/driver/605/log")"

echo "--- start re-running on every pass is not progress: the requeue cap still trips ---"
# 17008 (2026-10-31): plan requeued it 43 times in 4 hours under a cap of 3, because the
# always-run start step finished OK on each pass and reset the count.
FAKE="$FIX/fake-steps"; mkdir -p "$FAKE"
printf '%s\n' '#!/usr/bin/env bash' 'driver_step_start() { return 0; }' > "$FAKE/start.sh"
printf '%s\n' '#!/usr/bin/env bash' 'driver_step_plan() { driver_state_set "$1" park_note "the picture is not here"; return "$DRIVER_E_REQUEUE"; }' > "$FAKE/plan.sh"
printf '%s\n' '#!/usr/bin/env bash' 'driver_park() { printf "PARK %s\n" "$2" >> "$FIX/park.log"; return 20; }' > "$FAKE/park.sh"
reset_case 607; : > "$FIX/park.log"
DRIVER_STEPS_DIR="$FAKE" DRIVER_MAX_REQUEUES=1 bash "$BT" 607 --steps "start plan" >/dev/null 2>&1; rc=$?
want "the first pass requeues"                  "28" "$rc"
DRIVER_STEPS_DIR="$FAKE" DRIVER_MAX_REQUEUES=1 bash "$BT" 607 --steps "start plan" >/dev/null 2>&1; rc=$?
want "the second in a row, past a ceiling of 1, parks" "20" "$rc"
want_in "naming the step that kept requeueing"  'plan could not go on for 1 requeued runs in a row' "$(cat "$FIX/park.log")"

echo "--- a refusal that set no note parks with the step's own words ---"
reset_case 606
fix_issue 606 CLOSED "status:ready"
out=$(bash "$BT" 606 --steps "start" 2>&1); rc=$?
want "a closed ticket still parks" "20" "$rc"
want_in "with the step's reason" '#606 is CLOSED' "$out"
want_not_in "not 'left no reason'" 'left no reason' "$out"

suite_end "$FAILED"
