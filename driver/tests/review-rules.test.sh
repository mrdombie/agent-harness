#!/usr/bin/env bash
# review-rules.test.sh — the reviewer reads the repo's written rules. The hunter's prompt
# carries RULES: the root CLAUDE.md and AGENTS.md and the nearest instruction file of each
# changed file, line-numbered and capped at review.rulesMaxBytes with the cut said. A
# finding of kind breaks-rule or stale-rule cites the rule (file:line, a file in RULES);
# one that does not is refused. A stale rule never blocks: it goes to the PR notes as a
# rule to update.
# Run: env -i HOME="$HOME" PATH="$PATH" bash "$0" (a driver session's exported env points at live state)
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
fix_real_briefs
. "$HERE/../steps/review.sh" || exit 1
. "$HERE/../steps/ship.sh" || exit 1
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/sf"; chmod +x "$FIX/sf"
export DRIVER_SCREEN_FINDINGS="$FIX/sf" SWEEP_QUEUE="$FIX/sweep.jsonl"
jq '.release = {mergeFirst: true, done: false}' "$HARNESS_CFG_PATH" > "$FIX/on.json"
jq '.review.rulesMaxBytes = 120' "$FIX/on.json" > "$FIX/small.json"
on()    { HARNESS_CFG="$FIX/on.json" HARNESS_CFG_PATH="$FIX/on.json" "$@"; }
small() { HARNESS_CFG="$FIX/small.json" HARNESS_CFG_PATH="$FIX/small.json" "$@"; }

# The trunk's written rules: a root CLAUDE.md (the rule at line 3), a root AGENTS.md, one
# beside app/ (touched) and one beside lib/ (never touched).
mkdir -p "$REPO/app" "$REPO/lib"
printf '# Rules\n\nnever call fetch directly\nuse the api client\n' > "$REPO/CLAUDE.md"
printf '# Agents\nkeep commits small\n' > "$REPO/AGENTS.md"
printf '# App\nscreens read through hooks\n' > "$REPO/app/AGENTS.md"
printf '# Lib\nlib-only rule: no globals\n' > "$REPO/lib/AGENTS.md"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "docs: rules"

tree() { # <ticket> — a P1 branch whose change touches app/x.ts
  git -C "$REPO" worktree add -q "$FIX/t$1" -b "tkt-$1/work" develop
  mkdir -p "$FIX/t$1/app"; printf 'fetch("/x")\n' > "$FIX/t$1/app/x.ts"; git -C "$FIX/t$1" add -A; git -C "$FIX/t$1" commit -qm "feat: x"
  driver_state_init "$1" --worktree "$FIX/t$1" --branch "tkt-$1/work"
  fix_issue "$1" OPEN "status:claimed,P1"
}
answer() { # <verdict> <findings json>
  jq -nc --arg v "$1" --argjson f "$2" \
    '{step: "review", skills: ["code-review"], status: "reviewed", round: 1, verdict: $v,
      panel: {skill: "code-review", effort: "high"}, findings: $f}'
}
hunt() {
  local f="$FIX/ai/review.jsonl"
  jq -nc '{type:"assistant", message:{content:[{type:"tool_use", id:"toolu_skill", name:"Skill", input:{skill:"code-review", args:"high develop"}}]}}' > "$f"
  jq -nc --arg r "$1" '{type:"result", subtype:"success", is_error:false, result:$r, structured_output:($r | fromjson)}' >> "$f"
}
fresh()  { : > "$CLAUDE_LOG"; : > "$SWEEP_QUEUE"; rm -f "$FIX"/claude-stdin-*.txt; }
prompt() { cat "$FIX/claude-stdin-review.txt" 2>/dev/null; }
rj()     { printf '%s/steps/review.json' "$(driver_state_dir "$1")"; }

BREAKS='{"id":"r1","file":"app/x.ts","line":1,"grade":"major","tag":"important","kind":"breaks-rule","rule":"CLAUDE.md:3","summary":"calls fetch directly","reason":"the written rule says never call fetch directly","fix":"use the api client"}'
STALE='{"id":"s1","file":"app/x.ts","line":1,"grade":"minor","tag":"important","kind":"stale-rule","rule":"CLAUDE.md:3","summary":"the rule predates the api client","reason":"the change shows the rule is out of date","fix":"update the rule"}'
NORULE='{"id":"r2","file":"app/x.ts","line":1,"grade":"major","tag":"important","kind":"breaks-rule","summary":"calls fetch directly","reason":"r","fix":"f"}'
OUTSIDE='{"id":"r3","file":"app/x.ts","line":1,"grade":"major","tag":"important","kind":"breaks-rule","rule":"lib/AGENTS.md:2","summary":"calls fetch directly","reason":"r","fix":"f"}'

echo "--- the hunter's prompt carries RULES: root files and the changed file's nearest ---"
tree 801; fresh; hunt "$(answer SHIP '[]')"
rc=0; out=$(on driver_step_review 801 2>&1) || rc=$?
want "a clean review ships"                                "0" "$rc"
want_not_in "no placeholder reaches the hunter"            "{{RULES}}|NOT SUBSTITUTED" "$(prompt)"
want_in "it names the root CLAUDE.md"                      "CLAUDE.md" "$(prompt)"
want_in "its lines are numbered"                           "CLAUDE.md:3: never call fetch directly" "$(prompt)"
want_in "the root AGENTS.md"                               "AGENTS.md:2: keep commits small" "$(prompt)"
want_in "and the changed file's nearest instruction file"  "app/AGENTS.md:2: screens read through hooks" "$(prompt)"
want_not_in "never a folder the diff did not touch"        "lib-only rule" "$(prompt)"

echo "--- over review.rulesMaxBytes the fact is cut, and says so ---"
tree 802; fresh; hunt "$(answer SHIP '[]')"
rc=0; out=$(small driver_step_review 802 2>&1) || rc=$?
want "it still ships"                                      "0" "$rc"
want_in "the cut is said in words"                         "RULES CUT at 120 bytes of" "$(prompt)"
want_not_in "and what is past the cap is not sent"         "screens read through hooks" "$(prompt)"

echo "--- a repo with no instruction files is told there are none ---"
git -C "$REPO" rm -q CLAUDE.md AGENTS.md app/AGENTS.md lib/AGENTS.md && git -C "$REPO" commit -qm "docs: no rules"
tree 803; fresh; hunt "$(answer SHIP '[]')"
rc=0; out=$(on driver_step_review 803 2>&1) || rc=$?
want "it ships"                                            "0" "$rc"
want_in "RULES says there are none"                        "none — no CLAUDE.md, AGENTS.md or instruction file" "$(prompt)"
git -C "$REPO" revert --no-edit HEAD >/dev/null

echo "--- a breaks-rule finding cites its rule, or is refused ---"
tree 804; fresh; hunt "$(answer BLOCKED "[$BREAKS]")"
rc=0; out=$(on driver_step_review 804 2>&1) || rc=$?
want "a cited broken rule goes back to fix"                "30" "$rc"
want "it is kept"                                          "r1 CLAUDE.md:3" "$(jq -r '[.findings[] | .id, .rule] | join(" ")' "$(rj 804)")"
want_in "and posted like any finding"                      "calls fetch directly" "$(cat "$(driver_state_dir 804)/steps/review.posted.jsonl" 2>/dev/null)"
tree 805; fresh; hunt "$(answer BLOCKED "[$NORULE]")"
rc=0; out=$(on driver_step_review 805 2>&1) || rc=$?
want "a breaks-rule finding with no rule is refused"       "$DRIVER_E_SCHEMA" "$rc"
want_in "by the contract"                                  "rule" "$out"
tree 806; fresh; hunt "$(answer BLOCKED "[$OUTSIDE]")"
rc=0; out=$(on driver_step_review 806 2>&1) || rc=$?
want "a rule naming a file not in RULES is refused"        "$DRIVER_E_REFUSED" "$rc"
want_in "and says which"                                   "lib/AGENTS.md" "$out"

echo "--- a stale rule never blocks, and is a rule to update in the PR notes ---"
tree 807; fresh; hunt "$(answer BLOCKED "[$STALE]")"
rc=0; out=$(on driver_step_review 807 2>&1) || rc=$?
want "a stale rule alone ships"                            "0" "$rc"
want "it never goes back as a finding"                     "" "$(jq -r '[.findings[]?.id] | join(" ")' "$(rj 807)")"
want_in "the PR notes list it as a rule to update"         "Rules to update" "$(_driver_ship_deferred 807)"
want_in "naming the rule"                                  "CLAUDE.md:3 — the rule predates the api client" "$(_driver_ship_deferred 807)"
want_not_in "never as a dropped finding"                   "dropped, not filed" "$(_driver_ship_deferred 807)"

suite_end "$FAILED"
