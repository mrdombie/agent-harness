#!/usr/bin/env bash
# repair-wait.test.sh — a repair waiting for the machine watches its pull request.
# A repair sat 40 minutes in self-check's load wait while its PR turned CONFLICTING;
# nothing those gates proved could have landed it, and the repair for the clash could
# not start. So in repair mode every busy poll re-reads the PR, and a clash or a red
# required check that was not there when self-check began ends the run as a repair
# requeue (front of the queue, claim released, the reason logged).
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
BT="$HERE/../build-ticket"
. "$HERE/../steps/self-check.sh" || exit 1

cat > "$FIX/queue-stub.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/queue.log"
SH
export DRIVER_QUEUE="$FIX/queue-stub.sh"
# gh for the PR: its mergeable state and required checks from files a case rewrites.
cat > "$BIN/gh-pr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
q=""; prev=""; for a in "$@"; do [ "$prev" = -q ] && q="$a"; prev="$a"; done
case "$1 $2" in
  "pr view")   jq -r "${q:-.}" "$FIX/pr-77.json" ;;
  "pr checks") cat "$FIX/checks-77.json"; jq -e 'any(.[]; .bucket == "fail")' "$FIX/checks-77.json" >/dev/null && exit 1; exit 0 ;;
  *) exec "$BIN/gh" "$@" ;;
esac
SH
chmod +x "$BIN/gh-pr"
export SWARM_GH="$BIN/gh-pr"
jq --arg m "$FIX/gate-ran" '.gates = {"g": ("touch " + $m)}' "$HARNESS_CFG_PATH" > "$FIX/cfg.json" && cat "$FIX/cfg.json" > "$HARNESS_CFG_PATH"

pr_is() { printf '{"number":77,"mergeable":"%s"}\n' "$1" > "$FIX/pr-77.json"; }
checks_are() { printf '%s\n' "$1" > "$FIX/checks-77.json"; }
repair_record() { # <ticket>
  rm -rf "$STATE/driver/$1"
  driver_state_init "$1" --worktree "$REPO"
  driver_state_set "$1" mode repair
  driver_state_set "$1" pr 77
}
# run_held <ticket> — self-check under a busy machine, in the background.
run_held() {
  rm -f "$FIX/gate-ran" "$FIX/sc.rc"; echo 4 > "$FIX/idle"
  ( SWARM_IDLE_FILE="$FIX/idle" SWARM_LOAD=1 driver_step_self_check "$1" > "$FIX/sc.out" 2>&1; echo $? > "$FIX/sc.rc" ) &
}
await_rc() { local _; for _ in $(seq 30); do [ -f "$FIX/sc.rc" ] && break; sleep 1; done; cat "$FIX/sc.rc" 2>/dev/null; }

echo "--- the PR turns CONFLICTING during the wait: a repair requeue within one poll ---"
repair_record 801; pr_is MERGEABLE; checks_are '[{"name":"test","bucket":"pass"}]'
run_held 801
sleep 2
want "still waiting while the PR is clean" "" "$(cat "$FIX/sc.rc" 2>/dev/null)"
pr_is CONFLICTING
start=$(date +%s); rc=$(await_rc); took=$(( $(date +%s) - start ))
want "the step ends as a requeue" "28" "$rc"
if [ "$took" -le 4 ]; then ok "within one poll (${took}s, poll 1s)"; else bad "took ${took}s to notice"; fi
want "the gate never ran" "no" "$([ -e "$FIX/gate-ran" ] && echo yes || echo no)"
want_in "and the run says why" 'turned CONFLICTING.*waited for the machine' "$(cat "$FIX/sc.out")"
want_in "the reason is on the record" 'turned CONFLICTING' "$(driver_state_get 801 park_note)"
want "the gate slot is given back" "0" "$(find "$HARNESS_GATE_SLOT_DIR" -mindepth 1 -maxdepth 1 -name 'slot-*' | wc -l | tr -d ' ')"

echo "--- a required check goes red during the wait: the same ---"
repair_record 802; pr_is MERGEABLE; checks_are '[{"name":"test","bucket":"pending"},{"name":"approval","bucket":"fail"}]'
run_held 802
sleep 2
want "the sign-off hold's own red is not news" "" "$(cat "$FIX/sc.rc" 2>/dev/null)"
checks_are '[{"name":"test","bucket":"fail"},{"name":"approval","bucket":"fail"}]'
rc=$(await_rc)
want "a new red ends it" "28" "$rc"
want_in "naming the check" 'required check gone red \(test\)' "$(cat "$FIX/sc.out")"

echo "--- what was already CONFLICTING or red at the start is what the repair is fixing ---"
repair_record 803; pr_is CONFLICTING; checks_are '[{"name":"lint","bucket":"fail"}]'
run_held 803
sleep 3
want "it keeps waiting" "" "$(cat "$FIX/sc.rc" 2>/dev/null)"
echo 60 > "$FIX/idle"
rc=$(await_rc)
want "and runs the gates once the machine is free" "0" "$rc"
want "the gate ran" "yes" "$([ -e "$FIX/gate-ran" ] && echo yes || echo no)"

echo "--- a build (not a repair) does not read the PR while it waits ---"
rm -rf "$STATE/driver/804"; driver_state_init 804 --worktree "$REPO"; pr_is CONFLICTING
: > "$GH_LOG"
run_held 804
sleep 2; echo 60 > "$FIX/idle"
want "it waits and runs" "0" "$(await_rc)"
want_not_in "no PR read" 'pr view|pr checks' "$(cat "$GH_LOG")"

echo "--- end to end: requeued as a repair, at the front, claim released, no park ---"
fix_issue 805 OPEN "status:claimed"
repair_record 805; pr_is MERGEABLE; checks_are '[]'
# The claim is a ref on origin: a bare one, so the real lock takes and releases it.
git init -q --bare "$FIX/origin"; git -C "$REPO" remote add origin "$FIX/origin"; git -C "$REPO" push -q origin develop
( cd "$REPO" && bash "$CL" acquire 805 --branch tkt-805 >/dev/null 2>&1 )
hrc=0; bash "$CL" holds 805 >/dev/null 2>&1 || hrc=$?
want "the run holds the claim going in" "0" "$hrc"
: > "$GH_LOG"; rm -f "$FIX/queue.log" "$FIX/gate-ran"; echo 4 > "$FIX/idle"
( SWARM_IDLE_FILE="$FIX/idle" SWARM_LOAD=1 DRIVER_REPAIR_STEPS=self-check DRIVER_ALWAYS_STEPS=self-check bash "$BT" 805 --repair-class repair > "$FIX/bt.out" 2>&1; echo $? > "$FIX/bt.rc" ) &
sleep 2; pr_is CONFLICTING
for _ in $(seq 30); do [ -f "$FIX/bt.rc" ] && break; sleep 1; done
want "the run ends as a requeue" "28" "$(cat "$FIX/bt.rc" 2>/dev/null)"
want_in "as a repair, at the front" '^add 805 --class repair .*--first$|^add 805 --class repair --first$' "$(cat "$FIX/queue.log" 2>/dev/null)"
want_not_in "no park label, no park comment" 'add-label status:parked|add-label needs:|issue comment|pr create' "$(cat "$GH_LOG")"
want_in "the reason is logged" 'requeued.*turned CONFLICTING' "$(cat "$FIX/bt.out")"
hrc=0; bash "$CL" holds 805 >/dev/null 2>&1 || hrc=$?
want "the claim is released" "11" "$hrc"

suite_end "$FAILED"
