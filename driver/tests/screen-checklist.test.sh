#!/usr/bin/env bash
# screen-checklist.test.sh — a change that touches a screen writes down, up front, how
# each screen state it touches handles loading, failed, a retry in flight, empty and
# phone width (the owner, 2026-10-23: ~38 of 64 Majors since 22 Oct were a person misled
# or stuck in exactly those states). A plan or quick answer without it is sent back
# once; the review is handed the lines to hold the shipped code to. A change that
# touches no screen is never asked.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/plan.sh" || exit 1
. "$HERE/../steps/review.sh" || exit 1
fix_brief plan superpowers:writing-plans
fix_brief review superpowers:requesting-code-review "Review round {{ROUND}}. The change: {{DIFF}} Renders: {{RENDERS}}"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/sf"; printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/pl"; chmod +x "$FIX/sf" "$FIX/pl"
export DRIVER_SCREEN_FINDINGS="$FIX/sf" DRIVER_POLISH_LIST="$FIX/pl"
jq '.design = ((.design // {}) + {surfacePaths: ["components/**"]})' "$HARNESS_CFG_PATH" > "$FIX/cfg.json"
export HARNESS_CFG="$FIX/cfg.json" HARNESS_CFG_PATH="$FIX/cfg.json"

plan() { # <file> [checklist json]
  jq -nc --arg f "$1" --argjson c "${2:-null}" '{step:"plan", skills:["superpowers:writing-plans"], status:"planned", designSource:"ticket-body",
    premise:{verdict:"still-true", evidence:"e"}, tasks:[{title:"t", files:[{path:$f, action:"modify"}],
    tests:[{file:"a.test.sh", behaviour:"b", redWhen:"r"}]}]} + (if $c then {screenChecklist:$c} else {} end)'
}
list='[{"state":"the voice card","loading":"a skeleton, Try again hidden","failed":"the error row with Try again","retry":"Checking… on the button, nothing announced until the read settles","empty":"Nothing learned yet, only once the read settles","phone":"stacks at 390px, the panel has a close button"}]'
calls() { grep -c '^plan$' "$CLAUDE_LOG"; }

echo "--- a plan that touches a screen with no checklist is sent back once ---"
fix_issue 201 OPEN "status:claimed"; driver_state_init 201 --worktree "$REPO"; : > "$CLAUDE_LOG"
fix_ai plan "$(plan components/Card.tsx "$list")" superpowers:writing-plans; mv "$FIX/ai/plan.jsonl" "$FIX/ai/plan.then.jsonl"
fix_ai plan "$(plan components/Card.tsx)" superpowers:writing-plans
rc=0; out=$(driver_step_plan 201 2>&1) || rc=$?
want "the plan finishes"                       "0" "$rc"
want "it was asked twice"                      "2" "$(calls)"
want_in "the second ask names what is missing" 'SENT BACK ONCE: this change touches a screen \(components/Card.tsx\)' "$(cat "$FIX/claude-stdin-plan.txt")"
want_in "and the run says so"                  'wrote no screen checklist — asked once more' "$out"
want_in "the checklist is on the record"       'Checking… on the button' "$(driver_state_get 201 screen_checklist)"

echo "--- still missing: it goes on, warned, never a third ask ---"
fix_issue 202 OPEN "status:claimed"; driver_state_init 202 --worktree "$REPO"; : > "$CLAUDE_LOG"
fix_ai plan "$(plan components/Card.tsx)" superpowers:writing-plans
rc=0; out=$(driver_step_plan 202 2>&1) || rc=$?
want "the plan finishes"                       "0" "$rc"
want "asked twice, not three times"            "2" "$(calls)"
want_in "and warns"                            'still no screen checklist' "$out"

echo "--- a plan that touches no screen is never asked ---"
fix_issue 203 OPEN "status:claimed"; driver_state_init 203 --worktree "$REPO"; : > "$CLAUDE_LOG"
fix_ai plan "$(plan lib/api.ts)" superpowers:writing-plans
rc=0; out=$(driver_step_plan 203 2>&1) || rc=$?
want "the plan finishes"                       "0" "$rc"
want "asked once"                              "1" "$(calls)"
want "nothing on the record"                   "" "$(driver_state_get 203 screen_checklist)"

echo "--- a plan with its checklist is asked once ---"
fix_issue 204 OPEN "status:claimed"; driver_state_init 204 --worktree "$REPO"; : > "$CLAUDE_LOG"
fix_ai plan "$(plan app/settings/page.tsx "$list")" superpowers:writing-plans
driver_step_plan 204 >/dev/null 2>&1
want "asked once"                              "1" "$(calls)"

echo "--- the review is handed the checklist to hold the code to ---"
git -C "$REPO" worktree add -q "$FIX/wt5" -b tkt-205/work develop
mkdir -p "$FIX/wt5/components"; printf 'x\n' > "$FIX/wt5/components/Card.tsx"; git -C "$FIX/wt5" add -A; git -C "$FIX/wt5" commit -qm "feat: card"
driver_state_init 205 --worktree "$FIX/wt5" --branch tkt-205/work; fix_issue 205 OPEN "status:claimed"
driver_state_set 205 screen_checklist "$list"
fix_ai review '{"verdict":"SHIP","findings":[]}' superpowers:requesting-code-review
driver_step_review 205 >/dev/null 2>&1
sent=$(cat "$FIX/claude-stdin-review.txt")
want_in "the reviewer sees the checklist"      'SCREEN CHECKLIST the plan committed to' "$sent"
want_in "line by line"                         'the voice card: loading — a skeleton.*retry in flight — Checking… on the button' "$sent"
driver_state_init 206 --worktree "$FIX/wt5" --branch tkt-205/work; fix_issue 206 OPEN "status:claimed"
driver_step_review 206 >/dev/null 2>&1
want_not_in "no checklist, no extra text"      'SCREEN CHECKLIST' "$(cat "$FIX/claude-stdin-review.txt")"

suite_end "$FAILED"
