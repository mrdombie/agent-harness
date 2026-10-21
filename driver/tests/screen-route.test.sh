#!/usr/bin/env bash
# screen-route.test.sh — pictures and the AI design review only for new or redesigned
# screens (the owner, 2026-10-21). A screen ticket labelled screen:new or screen:redesign
# keeps the picture route: the binding picture at plan, the compare, the design-critic
# verdict owed after the push. Any other screen ticket takes the baseline route and skips
# all three: CI diffs its shots against the last approved shots and decides the status.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
. "$HERE/../steps/plan.sh" || exit 1
. "$HERE/../steps/compare.sh" || exit 1
. "$HERE/../steps/ship.sh" || exit 1
fix_brief plan superpowers:writing-plans
export DRIVER_LOOKUP_RETRY_SEC=0 DRIVER_LOOKUP_TRIES=1
cat > "$FIX/queue-stub.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/queue.log"
SH
export DRIVER_QUEUE="$FIX/queue-stub.sh"
CFG="$REPO/.claude/harness.json"
cfg() { jq "$1" "$CFG" > "$FIX/cfg.t" && mv "$FIX/cfg.t" "$CFG"; }
cfg '.design = {"surfacePaths": ["apps/web/**"], "baselineRoute": {"enabled": true}}
     | .review = {"attest": {"design-critic": {"owed": "exit 3", "agent": "agent-harness:design-critic", "record": "true", "needsRenders": true}}}'
git -C "$REPO" add -A && git -C "$REPO" commit -qm "screens are apps/web; the baseline route is on"

tree() { # <ticket> <labels-csv> — a fresh worktree with a screen change, and its record
  git -C "$REPO" worktree add -q "$FIX/wt$1" -b "tkt-$1/work" develop
  driver_state_init "$1" --worktree "$FIX/wt$1" --branch "tkt-$1/work"
  fix_issue "$1" OPEN "status:claimed${2:+,$2}"
  mkdir -p "$FIX/wt$1/apps/web/src"; printf 'x %s\n' "$1" > "$FIX/wt$1/apps/web/src/Home.tsx"
  git -C "$FIX/wt$1" add -A; git -C "$FIX/wt$1" commit -qm "change the home screen"
}
route_of() { driver_screen_route "$1" | cut -f1; }
# The plan names a picture that is on no machine: on the picture route that requeues.
plan_answer() {
  fix_ai plan "$(jq -nc '{step:"plan",skills:["superpowers:writing-plans"],status:"planned",designSource:"approved-picture",designRef:"/Users/elsewhere/desk-mock.html",premise:{verdict:"still-true",evidence:"a.sh:1"},tasks:[{title:"t",files:[{path:"a.sh",action:"modify"}],tests:[{file:"a.test.sh",behaviour:"b",redWhen:"r"}]}]}')" superpowers:writing-plans
}

tree 801 screen:new; tree 802 ""; tree 803 screen:redesign

echo "--- the route is read off the ticket's labels ---"
want "screen:new is the picture route"            "picture"  "$(route_of 801)"
want "no label is the baseline route"             "baseline" "$(route_of 802)"
want "screen:redesign is the picture route"       "picture"  "$(route_of 803)"
want "labels that cannot be read: picture route"  "picture"  "$(route_of 899)"
cfg '.design.baselineRoute.enabled = false'
want "a project without the route: picture route" "picture"  "$(route_of 802)"
cfg '.design.baselineRoute.enabled = true'

echo "--- plan: the binding picture is the picture route's alone ---"
plan_answer; rc=0; out=$(driver_step_plan 801 2>&1) || rc=$?
want "a new screen whose picture is unreadable goes back on the queue" "28" "$rc"
plan_answer; rc=0; out=$(driver_step_plan 802 2>&1) || rc=$?
want "an existing screen goes ahead"              "0" "$rc"
want "and binds no picture"                       "" "$(driver_state_get 802 design_ref)"
want "nor claims one"                             "ticket-body" "$(driver_state_get 802 design_source)"
want_in "saying why"                              'existing screen.*does not bind it' "$out"

echo "--- compare: no picture compare on the baseline route ---"
rc=0; driver_step_compare 802 >/dev/null 2>&1 || rc=$?
want "an existing screen finishes"                "0" "$rc"
want_in "and the record says it is the baseline route" 'existing screen' "$(driver_state_get 802 renders)"
rc=0; driver_step_compare 801 >/dev/null 2>&1 || rc=$?
want_not_in "a new screen is not sent down it"    'existing screen' "$(driver_state_get 801 renders)"

echo "--- push-requires: the critic's verdict is owed on the picture route only ---"
rc=0; out=$(driver_push_requires 802 2>&1) || rc=$?
want "an existing screen passes"                  "0" "$rc"
want "and owes no critic verdict after the push"  "" "$(driver_state_get 802 attest_after_push)"
want_in "saying why"                              'baseline route' "$out"
rc=0; driver_push_requires 801 >/dev/null 2>&1 || rc=$?
want "a new screen still owes it"                 "design-critic" "$(driver_state_get 801 attest_after_push)"
rc=0; driver_push_requires 803 >/dev/null 2>&1 || rc=$?
want "a redesign still owes it"                   "design-critic" "$(driver_state_get 803 attest_after_push)"

echo "--- ship: the body says which route ---"
want_in "an existing screen's tier line"          'Baseline route' "$(_driver_ship_tier_line 802 screen "it changes a screen")"
want_in "a new screen's tier line"                'Picture, compare' "$(_driver_ship_tier_line 801 screen "it changes a screen")"

exit $FAILED
