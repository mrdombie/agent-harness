#!/usr/bin/env bash
# person-hold.test.sh — a person's hold put on while a build runs stops it at the
# next step boundary. The labels are read fresh before every step, the step never
# runs, and the run parks with cause hold: left ready beside the person's label (so
# its removal resumes it), no PM marker, the open PR drafted, the note naming whose
# hold and since when, the claim released. A hold that cannot be read requeues.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
# A run inside a driver session inherits its state dir, kit and order: none of it is this suite's.
for _v in $(env | sed -nE 's/^((DRIVER|HARNESS|SWARM|CLAIM)_[A-Z0-9_]*)=.*/\1/p'); do unset "$_v"; done; unset KIT_ROOT
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
BT="$HERE/../build-ticket"
. "$HERE/../driver-env.sh" || exit 1
. "$HERE/../state.sh" || exit 1

cat > "$FIX/queue-stub.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/queue.log"
SH
cat > "$BIN/draft" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/draft.log"
echo "PR #$2 is back to draft with auto-merge off"
SH
chmod +x "$FIX/queue-stub.sh" "$BIN/draft"
export DRIVER_QUEUE="$FIX/queue-stub.sh" DRIVER_DRAFT="$BIN/draft"
# The claim is the real one: build-ticket takes claim-lock.sh from the kit, on a bare origin here.
CL="$HERE/../../scripts/claim-lock.sh"
git init -q --bare "$FIX/origin"; git -C "$REPO" remote add origin "$FIX/origin"; git -C "$REPO" push -q origin develop
claimed() { git -C "$REPO" ls-remote origin "refs/claims/$1" | grep -c . ; }

# The steps stand in for the agent runner: each writes its name to CLAUDE_LOG. The real park runs.
FAKE="$FIX/fakesteps"; mkdir -p "$FAKE"
for s in start size plan build; do
  printf 'driver_step_%s() { printf "%%s\\n" %s >> "$CLAUDE_LOG"; [ %s != plan ] || [ ! -f "$FIX/hold-after-plan" ] || plant_hold "$1"; return 0; }\n' "$s" "$s" "$s" > "$FAKE/$s.sh"
done
printf '. %q\n' "$HERE/../steps/park.sh" > "$FAKE/park.sh"
cat >> "$FAKE/plan.sh" <<'SH'
# A person labels the ticket while the run plans: GitHub now carries it, the snapshot does not.
plant_hold() {
  local h; h=$(cat "$FIX/hold-label" 2>/dev/null || echo status:blocked)
  jq --arg h "$h" '.labels += [{name:$h}]' "$FIX/gh/issue-$1.json" > "$FIX/issue.tmp" && mv "$FIX/issue.tmp" "$FIX/gh/issue-$1.json"
  printf '%s put on by dom at 2026-11-14T10:00:00Z\n' "$h" > "$FIX/person-hold.out"; echo 1 > "$FIX/person-hold.rc"
}
SH
reset_case() { # <ticket>
  rm -f "$FIX/queue.log" "$FIX/draft.log" "$FIX/person-hold".{rc,out,log} "$FIX/hold-after-plan" "$FIX/hold-label" "$FIX/gh/prs.json"
  : > "$GH_LOG"; : > "$CLAUDE_LOG"; fix_gh_ok
  rm -rf "$STATE/driver/$1"
  fix_issue "$1" OPEN "status:claimed"
  driver_state_init "$1" --worktree "$REPO"
  driver_state_set "$1" pr 42
  bash "$CL" acquire "$1" --branch "tkt-$1/work" >/dev/null 2>&1
}
bt() { DRIVER_STEPS_DIR="$FAKE" bash "$BT" "$@" --steps "start plan build" 2>&1; }
edits() { grep -E '^issue edit ' "$GH_LOG" || true; }

echo "--- status:blocked put on after plan: build never runs, the run parks on the hold ---"
reset_case 801; : > "$FIX/hold-after-plan"
out=$(bt 801); rc=$?
want "it parks" "20" "$rc"
want "start and plan ran; build never did" "start plan" "$(tr '\n' ' ' < "$CLAUDE_LOG" | sed 's/ $//')"
want "the hold was read fresh before every step" "3" "$(grep -c '^check 801$' "$FIX/person-hold.log" 2>/dev/null)"
want_in "the park note names the hold, who and when" 'Held by a person: status:blocked, put on by dom at 2026-11-14T10:00:00Z' "$(cat "$GH_LOG")"
want_in "the park's status write adds status:ready" '--add-label status:ready' "$(edits)"
want_not_in "and keeps status:blocked on" '--remove-label status:blocked' "$(edits)"
want_not_in "no parked status, no PM marker, no owner hold" 'status:parked|status:pm-decision|needs:human-approval' "$(edits)"
want_in "the open PR is drafted and disarmed" '^park 42$' "$(cat "$FIX/draft.log" 2>/dev/null)"
want "the claim is released" "0" "$(claimed 801)"
want_in "the run says why it stopped" 'parked \(hold\)' "$out"

echo "--- a hold that is itself a status (needs-human, external-blocked): the park keeps it, no respawn ---"
spawnable() { bash -c '. "$1/swarm/swarm-env.sh" >/dev/null 2>&1 || exit 9; swarm_spawnable "$2"' _ "$HERE/../.." "$1"; }
labels_of() { jq -r '[.labels[].name] | sort | join(",")' "$FIX/gh/issue-$1.json"; }
apply_edits() { # <ticket> — the fake gh logs edits; carry them onto its labels as GitHub would
  local rm add
  rm=$(edits | grep -oE -- '--remove-label [^ ]+' | awk '{print $2}' | jq -R . | jq -sc .)
  add=$(edits | grep -oE -- '--add-label [^ ]+' | awk '{print $2}' | jq -R . | jq -sc .)
  jq --argjson rm "$rm" --argjson add "$add" '.labels = ([.labels[].name | select(IN($rm[]) | not)] + $add | unique | map({name:.}))' \
    "$FIX/gh/issue-$1.json" > "$FIX/issue.tmp" && mv "$FIX/issue.tmp" "$FIX/gh/issue-$1.json"
}
for c in "805 status:needs-human" "806 status:external-blocked"; do
  t=${c%% *}; h=${c#* }
  reset_case "$t"; : > "$FIX/hold-after-plan"; echo "$h" > "$FIX/hold-label"
  out=$(bt "$t"); rc=$?
  want "$h: it parks" "20" "$rc"
  want_not_in "$h: the park's status write keeps it on" "--remove-label $h" "$(edits)"
  apply_edits "$t"
  want "$h: the ticket wears the hold beside ready" "$h,status:ready" "$(labels_of "$t")"
  printf '[{"number":42,"headRefName":"tkt-%s/work","isDraft":true}]\n' "$t" > "$FIX/gh/prs.json"
  spawnable "$t" >/dev/null 2>&1; want "$h: still held, it is not spawnable" "1" "$?"
done

echo "--- no hold: every step runs, as before ---"
reset_case 802
out=$(bt 802); rc=$?
want "it finishes" "0" "$rc"
want "every step ran" "start plan build" "$(tr '\n' ' ' < "$CLAUDE_LOG" | sed 's/ $//')"
want "no park note" "" "$(grep '^issue comment 802' "$GH_LOG" || true)"
want "the claim is held still" "1" "$(claimed 802)"

echo "--- the hold cannot be read: requeued, nothing parked, nothing run ---"
reset_case 803; echo 2 > "$FIX/person-hold.rc"
out=$(bt 803); rc=$?
want "it ends unread" "26" "$rc"
want "no step ran" "" "$(cat "$CLAUDE_LOG")"
want_in "it is back on the queue" '^add 803 ' "$(cat "$FIX/queue.log" 2>/dev/null)"
want "no park note" "" "$(grep '^issue comment 803' "$GH_LOG" || true)"
want "no status write" "" "$(edits)"
want "no draft" "" "$(cat "$FIX/draft.log" 2>/dev/null)"

echo "--- the hold comes off: the next run resumes at build, not from the start ---"
reset_case 804; : > "$FIX/hold-after-plan"
first=$(DRIVER_STEPS_DIR="$FAKE" DRIVER_QUICK_STEPS="start size build" bash "$BT" 804 --steps "start size plan build" 2>&1); echo "$first" | tail -5
want "the first run parked on the hold" "start size plan" "$(tr '\n' ' ' < "$CLAUDE_LOG" | sed 's/ $//')"
spawnable() { bash -c '. "$1/swarm/swarm-env.sh" >/dev/null 2>&1 || exit 9; swarm_spawnable "$2"' _ "$HERE/../.." "$1"; }
spawnable 804 >/dev/null 2>&1; want "held, it is not spawnable" "1" "$?"
jq '.labels = [{name:"status:ready"}]' "$FIX/gh/issue-804.json" > "$FIX/issue.tmp" && mv "$FIX/issue.tmp" "$FIX/gh/issue-804.json"
rm -f "$FIX/hold-after-plan" "$FIX/person-hold".{rc,out}; : > "$CLAUDE_LOG"
# The park drafted the run's PR but left it open: the swarm's open-PR probe sees it.
printf '[{"number":42,"headRefName":"tkt-804/work","isDraft":true}]\n' > "$FIX/gh/prs.json"
spawnable 804 >/dev/null 2>&1; want "the hold off, its open draft PR does not stop the spawn" "0" "$?"
mv "$STATE/driver/804/state.json" "$FIX/state-804.json"
spawnable 804 >/dev/null 2>&1; want "an open PR with no hold on the record still stops it" "1" "$?"
mv "$FIX/state-804.json" "$STATE/driver/804/state.json"
out=$(DRIVER_STEPS_DIR="$FAKE" DRIVER_QUICK_STEPS="start size build" bash "$BT" 804 --steps "start size plan build" 2>&1); rc=$?
want "the rerun finishes" "0" "$rc"
want "start re-checks, size and plan are skipped, build runs" "start build" "$(tr '\n' ' ' < "$CLAUDE_LOG" | sed 's/ $//')"
want_in "the run log says it resumed after the hold was cleared" 'resumed after the hold was cleared: status:blocked, put on by dom' "$(cat "$STATE/driver/804/log")"

suite_end "$FAILED"
