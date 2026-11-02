#!/usr/bin/env bash
# review-panel.test.sh — the review runs Claude Code's own `code-review`: finders in
# parallel, a verifier vote on each candidate. Only findings a majority agreed on are
# kept; a nit (style, cleanup) is dropped; a pre-existing defect never goes back to the
# builder or onto a ticket, it goes to the sweep queue; and no posted finding is raised
# twice. The grade effects and the round cap stay as they were.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
fix_real_briefs
. "$HERE/../steps/review.sh" || exit 1
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/sf"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/pl"
chmod +x "$FIX/sf" "$FIX/pl"
export DRIVER_SCREEN_FINDINGS="$FIX/sf" DRIVER_POLISH_LIST="$FIX/pl" SWEEP_QUEUE="$FIX/sweep.jsonl"
jq '.release = {mergeFirst: true, done: false}' "$HARNESS_CFG_PATH" > "$FIX/mf-on.json"
on() { HARNESS_CFG="$FIX/mf-on.json" HARNESS_CFG_PATH="$FIX/mf-on.json" "$@"; }

rp_tree() { # <ticket> — a P1 branch whose change touches a.sh
  git -C "$REPO" worktree add -q "$FIX/rp$1" -b "tkt-$1/work" develop
  printf 'a\n' > "$FIX/rp$1/a.sh"; git -C "$FIX/rp$1" add -A; git -C "$FIX/rp$1" commit -qm "feat: a"
  driver_state_init "$1" --worktree "$FIX/rp$1" --branch "tkt-$1/work"
  fix_issue "$1" OPEN "status:claimed,P1"
}
rj()  { printf '%s/steps/review.json' "$(driver_state_dir "$1")"; }
ids() { jq -r '[.findings[]?.id] | join(" ")' "$(rj "$1")"; }
fu()  { jq -r .id "$(driver_state_dir "$1")/steps/review.followups.jsonl" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
sweep_ids() { jq -r '.summary' "$SWEEP_QUEUE" 2>/dev/null | tr '\n' '|' | sed 's/|$//'; }
fact() { cat "$(driver_state_dir "$1")/steps/review.facts/$2" 2>/dev/null; }
# answer <round> <verdict> <findings json> — a whole answer in the shipped contract.
answer() {
  jq -nc --argjson r "$1" --arg v "$2" --argjson f "$3" \
    '{step: "review", skills: ["code-review"], status: "reviewed", round: $r, verdict: $v,
      panel: {skill: "code-review", effort: "max", hunters: 10, verifiers: ($f | length)}, findings: $f}'
}
F_AGREED='{"id":"f1","file":"a.sh","line":1,"grade":"major","tag":"important","votes":{"agree":2,"of":2},"summary":"the save is dropped on retry","reason":"a person sees saved and loses the draft","fix":"keep it"}'
F_PLAUS='{"id":"f2","file":"a.sh","line":2,"grade":"major","tag":"important","votes":{"agree":1,"of":2},"summary":"the retry may race the timer","reason":"r","fix":"f"}'
F_SWEPT='{"id":"f3","file":"a.sh","line":3,"grade":"major","tag":"important","votes":{"agree":1,"of":1},"summary":"a gap sweep thought of this","reason":"r","fix":"f"}'
F_NIT='{"id":"f4","file":"a.sh","line":4,"grade":"nit","tag":"nit","votes":{"agree":2,"of":2},"summary":"the loop could be a for-of","reason":"cleanup","fix":"f"}'
F_PRE='{"id":"f5","file":"lib/old.sh","line":9,"grade":"major","tag":"pre-existing","votes":{"agree":2,"of":2},"summary":"the old reader drops a 500 as an empty page","reason":"r","fix":"f"}'
F_MINOR='{"id":"f6","file":"lib/other.sh","line":2,"grade":"minor","tag":"important","votes":{"agree":2,"of":2},"summary":"the label is vague","reason":"r","fix":"f"}'
ALL="[$F_AGREED,$F_PLAUS,$F_SWEPT,$F_NIT,$F_PRE]"

echo "--- the review runs code-review, at the configured effort, against the trunk ---"
rp_tree 701
fix_ai review "$(answer 1 BLOCKED "$ALL")" code-review
rc=0; out=$(on driver_step_review 701 2>&1) || rc=$?
want "the agreed Major goes back to fix"           "30" "$rc"
want "the effort defaults to max"                  "max" "$(fact 701 EFFORT)"
want "the target is the trunk"                     "develop" "$(fact 701 TARGET)"

echo "--- only what a majority of the panel agreed on is kept ---"
want "kept: the agreed one alone"                  "f1" "$(ids 701)"
want_in "the unagreed are said, not dropped silently" "2 finding.s. the panel did not agree on" "$out"
want_in "a nit is dropped and said"                "1 nit" "$out"

echo "--- a pre-existing defect goes to the sweep queue, never to fix or a ticket ---"
want "it is in the sweep queue"                    "the old reader drops a 500 as an empty page" "$(sweep_ids)"
want "it names the ticket that found it"           "701" "$(jq -r .ticket "$SWEEP_QUEUE")"
want "it is not a follow-up ticket"                "" "$(fu 701)"
want_in "and the run says where it went"           "1 pre-existing finding.s. to the nightly sweep" "$out"

echo "--- a review whose only blocking finding is pre-existing ships ---"
rp_tree 702
fix_ai review "$(answer 1 SHIP "[$F_PRE]")" code-review
rc=0; on driver_step_review 702 >/dev/null 2>&1 || rc=$?
want "it ships"                                    "0" "$rc"
want "the verdict is SHIP"                         "SHIP" "$(jq -r .verdict "$(rj 702)")"
want "the sweep queue holds it once"               "1" "$(grep -c . "$SWEEP_QUEUE")"

echo "--- no posted finding is raised twice ---"
rp_tree 703
fix_ai review "$(answer 1 BLOCKED "[$F_AGREED]")" code-review
on driver_step_review 703 >/dev/null 2>&1
want "the posted ledger holds it"                  "a.sh|the save is dropped on retry" "$(jq -r .key "$(driver_state_dir 703)/steps/review.posted.jsonl")"
printf 'z\n' > "$FIX/rp703/z.sh"; git -C "$FIX/rp703" add -A; git -C "$FIX/rp703" commit -qm "fix: z"; driver_state_bump 703 fix
again='{"id":"g1","file":"./a.sh","line":7,"grade":"major","tag":"important","votes":{"agree":2,"of":2},"summary":"The save is dropped on RETRY.","reason":"r","fix":"f"}'
fresh='{"id":"g2","file":"z.sh","line":1,"grade":"major","tag":"important","votes":{"agree":2,"of":2},"summary":"the new helper swallows the error","reason":"r","fix":"f"}'
fix_ai review "$(answer 2 BLOCKED "[$again,$fresh]")" code-review
rc=0; out=$(on driver_step_review 703 2>&1) || rc=$?
want "round 2 still blocks on the fresh one"       "30" "$rc"
want "the repeat is gone"                          "g2" "$(ids 703)"
want_in "and said"                                 "1 finding.s. already raised on this change" "$out"
want_in "round 2 is told what was already raised"  "the save is dropped on retry" "$(fact 703 DIFF)"

echo "--- a class is one finding; a later instance of the same class is not raised again ---"
rp_tree 704
cls='{"id":"c1","file":"a.sh","line":1,"grade":"major","tag":"important","votes":{"agree":2,"of":2},"class":"a failed read shown as empty","instances":["a.sh:1","b.sh:4"],"summary":"the queue shows empty on a failed read","reason":"r","fix":"f"}'
fix_ai review "$(answer 1 BLOCKED "[$cls]")" code-review
on driver_step_review 704 >/dev/null 2>&1
printf 'z\n' > "$FIX/rp704/z.sh"; git -C "$FIX/rp704" add -A; git -C "$FIX/rp704" commit -qm "fix: z"; driver_state_bump 704 fix
cls2='{"id":"c2","file":"z.sh","line":3,"grade":"major","tag":"important","votes":{"agree":2,"of":2},"class":"A failed read shown as empty","summary":"the rail shows empty on a failed read","reason":"r","fix":"f"}'
fix_ai review "$(answer 2 BLOCKED "[$cls2]")" code-review
rc=0; on driver_step_review 704 >/dev/null 2>&1 || rc=$?
want "the class already raised does not block again" "0" "$rc"

echo "--- grade effects stand: under merge first a kept Major elsewhere is a follow-up, a Minor too ---"
rp_tree 705
fix_ai review "$(answer 1 BLOCKED "[$F_MINOR]")" code-review
rc=0; on driver_step_review 705 >/dev/null 2>&1 || rc=$?
want "a Minor in a file the change did not touch ships" "0" "$rc"
want "and is filed as before"                      "f6" "$(fu 705)"

echo "--- the quorum is a setting: review.quorum 1 keeps a single vote ---"
rp_tree 706
jq '.review.quorum = 1' "$FIX/mf-on.json" > "$FIX/q1.json"
fix_ai review "$(answer 1 BLOCKED "[$F_SWEPT]")" code-review
rc=0; HARNESS_CFG="$FIX/q1.json" HARNESS_CFG_PATH="$FIX/q1.json" driver_step_review 706 >/dev/null 2>&1 || rc=$?
want "one agreeing vote of one is kept"            "30" "$rc"
want "it is the finding"                           "f3" "$(ids 706)"
fix_ai review "$(answer 1 BLOCKED "[$F_PLAUS]")" code-review
rp_tree 707
rc=0; HARNESS_CFG="$FIX/q1.json" HARNESS_CFG_PATH="$FIX/q1.json" driver_step_review 707 >/dev/null 2>&1 || rc=$?
want "but one of two is still no majority"         "0" "$rc"

echo "--- an answer with no panel (an older reviewer) is graded exactly as before ---"
rp_tree 708
fix_ai review '{"step":"review","skills":["code-review"],"status":"reviewed","round":1,"verdict":"BLOCKED","findings":[{"id":"o1","file":"a.sh","line":1,"grade":"major","summary":"s","reason":"r","fix":"f"}]}' code-review
rc=0; on driver_step_review 708 >/dev/null 2>&1 || rc=$?
want "its Major goes to fix"                       "30" "$rc"

echo "--- plants: each line out of a copy of the kit, its case fails ---"
KIT="$FIX/kit"; N=750
kit_copy() { rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$ROOT/driver" "$ROOT/scripts" "$ROOT/swarm" "$ROOT/shared" "$ROOT/briefs" "$KIT/"; }
case_all() { # the mixed answer: the step's exit, what it kept, and what the sweep got
  N=$((N + 1)); rp_tree "$N"; : > "$SWEEP_QUEUE"; fix_ai review "$(answer 1 BLOCKED "$ALL")" code-review
  local rc=0; HARNESS_CFG="$FIX/mf-on.json" HARNESS_CFG_PATH="$FIX/mf-on.json" bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; . "$1/driver/driver-env.sh" && . "$1/driver/steps/review.sh" && driver_step_review "$2"' _ "$KIT" "$N" >/dev/null 2>&1 || rc=$?
  R="rc=$rc kept=$(ids "$N") swept=$(grep -c . "$SWEEP_QUEUE") filed=$(fu "$N")"
}
kit_copy
case_all; want "the unplanted kit" "rc=30 kept=f1 swept=1 filed=" "$R"
plant() { # <label> <file under the kit> <exact text to delete> <the result the line prevents>
  kit_copy
  python3 -I -c 'import sys; p, l = sys.argv[1], sys.argv[2]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, "", 1)); sys.exit(0 if n == 1 else 1)' "$KIT/$2" "$3" \
    || { want "plant landed: $1" "landed" "missed"; return; }
  case_all; want "planted ($1): the case now fails" "$4" "$R"
}
plant "the review runs the panel filter" driver/steps/review.sh \
  '  _driver_review_panel "$t" "$ans_file" "$round" || return "$DRIVER_E_REFUSED"' "rc=30 kept=f1 f2 f3 f4 swept=0 filed=f5"
plant "the quorum drops the unagreed" driver/steps/review.sh \
  ' | select(.votes == null or (.votes.agree >= $q and .votes.agree * 2 > .votes.of))' "rc=30 kept=f1 f2 f3 swept=1 filed="
plant "a pre-existing finding is swept" driver/steps/review.sh \
  '    printf '"'"'%s'"'"' "$pre" | bash "$sq" add "$t" "$round" >/dev/null 2>&1 || driver_say "⚠ review: the sweep queue could not take $npre pre-existing finding(s) — they are dropped from this change all the same"' "rc=30 kept=f1 swept=0 filed="
case_pre_ship() { # a SHIP whose only blocking-grade finding is pre-existing
  N=$((N + 1)); rp_tree "$N"; : > "$SWEEP_QUEUE"; fix_ai review "$(answer 1 SHIP "[$F_PRE]")" code-review
  local rc=0; HARNESS_CFG="$FIX/mf-on.json" HARNESS_CFG_PATH="$FIX/mf-on.json" bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; . "$1/driver/driver-env.sh" && . "$1/driver/steps/review.sh" && driver_step_review "$2"' _ "$KIT" "$N" >/dev/null 2>&1 || rc=$?
  R="rc=$rc"
}
kit_copy; case_pre_ship; want "the unplanted kit: a SHIP beside a pre-existing Major ships" "rc=0" "$R"
kit_copy
python3 -I -c 'import sys; p, l = sys.argv[1], sys.argv[2]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, "", 1)); sys.exit(0 if n == 1 else 1)' \
  "$KIT/driver/ai-step.sh" ' | select((.tag // "") != "pre-existing")' && {
  case_pre_ship; want "planted (the answer reader exempts pre-existing): the case now fails" "rc=22" "$R"
} || want "plant landed: the answer reader exempts pre-existing" "landed" "missed"

suite_end "$FAILED"
