#!/usr/bin/env bash
# base-red-steps.test.sh — a red the trunk commit a branch merged has too is the trunk's at
# EVERY step that checks, not only the push: a self-check gate or a fix-step gate red, read
# on that commit (once, cached), is base-red. It is not counted against the branch, the
# step never parks or asks "wait or fix here", and the coordinator files ONE develop-red
# ticket. A red only on the branch still blocks. And under gates.localOnly no step runs,
# hands on or proves with a command the local set leaves for CI (test:changed).
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
fix_real_briefs
. "$HERE/../steps/fix.sh" || exit 1
. "$HERE/../state.sh" || exit 1
ROOT="$(cd "$HERE/../.." && pwd)"
mkdir -p "$STATE/swarm"
CFG0="$HARNESS_CFG_PATH"

# A legacy test is red in any tree carrying red-legacy; an own test in any carrying red-own.
mkdir -p "$REPO/t"
printf '[ -f red-legacy ] && { echo "boom"; exit 1; }\nexit 0\n' > "$REPO/t/legacy.test.sh"
printf '[ -f red-own ] && { echo "boom"; exit 1; }\nexit 0\n' > "$REPO/t/own.test.sh"
# The project's test gate: every test file, a FAIL line for each red one.
printf 'rc=0\nfor f in t/*.test.sh; do bash "$f" >/dev/null 2>&1 || { echo "FAIL $f"; rc=1; }; done\nexit $rc\n' > "$REPO/run-tests.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "chore: the tests"
git init -q --bare "$FIX/origin"; git -C "$REPO" remote add origin "$FIX/origin"; git -C "$REPO" push -q origin develop
jq '.gates = {local: ["sh run-tests.sh"]}' "$CFG0" > "$FIX/cfg.json"
jq '.gates = {localOnly: true, local: ["sh run-tests.sh"], changed: ["sh run-tests.sh", "npm run test:changed"]}' "$CFG0" > "$FIX/cfg-lo.json"
# Every npm call is logged: under localOnly a test:changed must never appear.
printf '#!/bin/sh\nprintf "npm %%s\\n" "$*" >> "%s/npm.log"\nexit 0\n' "$FIX" > "$BIN/npm"; chmod +x "$BIN/npm"; : > "$FIX/npm.log"
PENDING="$STATE/swarm/develop-red.tsv"

trunk_set() { # <marker>… — the trunk carries exactly these markers
  git -C "$REPO" checkout -q develop; git -C "$REPO" rm -q --ignore-unmatch 'red-*' >/dev/null
  for m in "$@"; do : > "$REPO/$m"; git -C "$REPO" add "$m"; done
  git -C "$REPO" commit -qm "trunk: $*" --allow-empty; git -C "$REPO" push -q origin develop
  SHA=$(git -C "$REPO" rev-parse develop)
}
branch() { # <ticket> [marker] — a branch off the trunk with one commit
  git -C "$REPO" worktree add -q "$FIX/t$1" -b "tkt-$1/work" develop
  printf 'a\n' > "$FIX/t$1/a$1.txt"; [ -z "${2:-}" ] || : > "$FIX/t$1/$2"
  git -C "$FIX/t$1" add -A; git -C "$FIX/t$1" -c user.email=t@e.invalid -c user.name=T commit -qm "feat: a"
  driver_state_init "$1" --worktree "$FIX/t$1" --branch "tkt-$1/work"
  fix_issue "$1" OPEN "status:claimed"
}
# findings <ticket> <command> [head] — a self-check red on file, as self-check writes it.
findings() {
  local d; d="$(driver_state_dir "$1")/steps"; mkdir -p "$d"
  ( cd "$FIX/t$1" && sh run-tests.sh ) > "$d/gate-local-1.out" 2>&1
  jq -n --arg c "$2" --arg o "$(cat "$d/gate-local-1.out")" --arg f "$d/gate-local-1.out" \
    '[{id: "gate-local-1", gate: "local 1", command: $c, exit: 1, output: $o, outFile: $f}]' > "$d/self-check.findings.json"
  printf '%s\n' "${3:-$(git -C "$FIX/t$1" rev-parse HEAD)}" > "$d/self-check.findings.json.head"
}
# step <fn> <ticket> [cfg] — a driver step from ${SUT_KIT:-the kit}; R_RC its exit, R_OUT its output.
step() {
  R_RC=0
  R_OUT=$(HARNESS_CFG="${3:-$FIX/cfg.json}" HARNESS_CFG_PATH="${3:-$FIX/cfg.json}" bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT
    . "$1/driver/driver-env.sh" && . "$1/driver/ai-step.sh" && . "$1/driver/steps/self-check.sh" && . "$1/driver/steps/fix.sh" && "$2" "$3"' \
    _ "${SUT_KIT:-$ROOT}" "$1" "$2" 2>&1) || R_RC=$?
}
in_kit() { # <fn> <args…> — a kit function from ${SUT_KIT:-the kit}, under the localOnly config
  HARNESS_CFG="$FIX/cfg-lo.json" HARNESS_CFG_PATH="$FIX/cfg-lo.json" bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT
    . "$1/driver/driver-env.sh" && . "$1/driver/ai-step.sh" && . "$1/driver/steps/fix.sh" && shift && "$@"' _ "${SUT_KIT:-$ROOT}" "$@"
}
blockers() { cat "$(driver_state_dir "$1")/steps/fix.facts/BLOCKERS" 2>/dev/null; }
rows() { awk 'NF' "$PENDING" 2>/dev/null | wc -l | tr -d ' '; }
gate_answer() { # <ticket> — a gate fix naming the branch head
  jq -nc --arg c "$(git -C "$FIX/t$1" rev-parse HEAD)" '{step:"fix", skills:["superpowers:receiving-code-review"], status:"fixed", round:1,
    gateFixes:[{blockerId:"gate-local-1", change:[{path:"red-own", action:"delete"}], commit:$c}]}'
}
ask_answer() { jq -nc --arg q "$1" '{step:"fix", skills:["superpowers:receiving-code-review"], status:"park", round:1, question:$q}'; }
queue_then() { # <json> — what the NEXT fix call answers
  jq -nc '{type:"assistant", message:{content:[{type:"tool_use", name:"Skill", input:{skill:"superpowers:receiving-code-review"}}]}}' > "$FIX/ai/fix.then.jsonl"
  jq -nc --arg r "$1" '{type:"result", subtype:"success", is_error:false, result:$r, structured_output:($r|fromjson)}' >> "$FIX/ai/fix.then.jsonl"
}
reset() { : > "$PENDING"; : > "$CLAUDE_LOG"; : > "$FIX/npm.log"; rm -f "$STATE/swarm/base-checks.tsv" "$FIX/ai/fix.then.jsonl"; }

# The forge for develop-red.sh.
cat > "$FIX/fgh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"-X GET search/issues"*) echo '{"total_count":0,"items":[]}'; exit 0 ;;
  *"repos/acme/widgets/issues -X POST"*) n=$(( $(cat "$FIX/fgh.next" 2>/dev/null || echo 900) + 1 )); echo "$n" > "$FIX/fgh.next"; printf '%s\0' "$@" > "$FIX/fgh.create.$n"; echo "$n"; exit 0 ;;
esac
exit 0
SH
chmod +x "$FIX/fgh"
filed() { rm -f "$STATE/swarm/develop-red-filed.tsv" "$FIX"/fgh.create.* "$FIX/fgh.next"
  DEVELOP_RED_GH="$FIX/fgh" SWARM_GH="$FIX/fgh" DEVELOP_RED_QUEUE=off HARNESS_CFG="$FIX/cfg.json" HARNESS_CFG_PATH="$FIX/cfg.json" \
    bash "${SUT_KIT:-$ROOT}/scripts/develop-red.sh" file >/dev/null 2>&1
  ls "$FIX"/fgh.create.* 2>/dev/null | wc -l | tr -d ' '; }

echo "--- self-check: a gate red only on a test red on the trunk commit too is base-red ---"
reset; trunk_set red-legacy; S7=$(printf '%s' "$SHA" | cut -c1-7)
branch 701; step driver_step_self_check 701
want "self-check is green"                     "0" "$R_RC"
want_in "and says why, in the brief's words"   "base-red: t/legacy.test.sh is red on develop@$S7 too. This check is red on develop itself; the develop-red ticket owns it; carry on" "$R_OUT"
want "nothing goes to fix"                     "absent" "$([ -e "$(driver_state_dir 701)/steps/self-check.findings.json" ] && echo present || echo absent)"
want "never parked"                            "" "$(driver_state_get 701 park_note)"
want "one row for the coordinator"             "$SHA	t/legacy.test.sh	701" "$(cut -f1-3 "$PENDING")"
want "the test ran once on the trunk commit"   "1" "$(grep -c "	test:t/legacy.test.sh	red	" "$STATE/swarm/base-checks.tsv")"
branch 702; step driver_step_self_check 702
want "a second branch is green too"            "0" "$R_RC"
want "on the cached run"                       "1" "$(grep -c "	test:t/legacy.test.sh	red	" "$STATE/swarm/base-checks.tsv")"
want "and ONE develop-red ticket is filed for both" "1" "$(filed)"
want_in "naming both builders"                 '#701, #702' "$(tr '\0' '\n' < "$FIX/fgh.create.901")"

echo "--- self-check: a red only on the branch still blocks ---"
reset; trunk_set
branch 703 red-own; step driver_step_self_check 703
want "it goes to fix"                          "$DRIVER_E_REWORK" "$R_RC"
want "carrying the gate"                       "gate-local-1" "$(jq -r '[.[].id] | join(",")' "$(driver_state_dir 703)/steps/self-check.findings.json" 2>/dev/null)"
want "nothing for the coordinator"             "0" "$(rows)"

echo "--- fix: a gate red on file that is red on the trunk commit too is never handed on ---"
reset; trunk_set red-legacy
branch 704; findings 704 "sh run-tests.sh"
fix_ai fix "$(ask_answer 'legacy.test.sh fails on develop too: wait or fix here?')" superpowers:receiving-code-review
step driver_step_fix 704
want "the fix step finishes"                   "0" "$R_RC"
want "no model is asked"                       "" "$(cat "$CLAUDE_LOG")"
want_in "it says base-red"                     "fix: gate-local-1 — base-red: t/legacy.test.sh is red on develop" "$R_OUT"
want "never parked"                            "" "$(driver_state_get 704 park_note)"
want "one row for the coordinator"             "$SHA	t/legacy.test.sh	704" "$(cut -f1-3 "$PENDING")"
want "and the coordinator files one ticket"    "1" "$(filed)"

echo "--- fix: a gate red only on the branch is handed on, and blocks ---"
reset; trunk_set
branch 705 red-own; findings 705 "sh run-tests.sh"
fix_ai fix "$(ask_answer 'is own.test.sh mine?')" superpowers:receiving-code-review
step driver_step_fix 705
want "the question parks, as before"           "$DRIVER_E_QUESTION" "$R_RC"
want_in "the model was handed the gate"        "gate-local-1" "$(blockers 705)"
want "nothing for the coordinator"             "0" "$(rows)"

echo "--- fix: \"wait or fix here\" about a test red on the trunk is asked once more to carry on ---"
reset; trunk_set red-legacy
branch 706 red-own; findings 706 "sh run-tests.sh"
fix_ai fix "$(ask_answer 't/legacy.test.sh fails on clean develop too. Wait for develop, or fix it here?')" superpowers:receiving-code-review
queue_then "$(gate_answer 706)"
step driver_step_fix 706
want "the fix step finishes"                   "0" "$R_RC"
want "the model was asked twice"               "2" "$(grep -c . "$CLAUDE_LOG")"
want_in "the second time told it is develop's" "This check is red on develop itself; the develop-red ticket owns it; carry on" "$(cat "$FIX/claude-stdin-fix.txt")"
want "never parked"                            "" "$(driver_state_get 706 park_note)"
want "one row for the coordinator"             "$SHA	t/legacy.test.sh	706" "$(cut -f1-3 "$PENDING")"

echo "--- fix: a self-check red recorded at another head is another run's ---"
reset; trunk_set
branch 707 red-own; findings 707 "sh run-tests.sh" "$SHA"
step driver_step_fix 707
want "the fix step finishes"                   "0" "$R_RC"
want "no model is asked"                       "" "$(cat "$CLAUDE_LOG")"
want "nothing handed on"                       "" "$(blockers 707)"

echo "--- localOnly: no step runs or hands on test:changed ---"
reset; trunk_set
branch 708; step driver_step_self_check 708 "$FIX/cfg-lo.json"
want "self-check is green"                     "0" "$R_RC"
want_not_in "self-check ran no test:changed"   'test:changed' "$(cat "$FIX/npm.log")"
branch 709 red-own; findings 709 "npm run test:changed"
fix_ai fix "$(ask_answer 'test:changed is red on develop: wait or fix?')" superpowers:receiving-code-review
step driver_step_fix 709 "$FIX/cfg-lo.json"
want "a test:changed red on file is not handed on" "0" "$R_RC"
want "no model is asked about it"              "" "$(cat "$CLAUDE_LOG")"
want_not_in "the blockers never name it"       'test:changed' "$(blockers 709)"
want_not_in "and nothing ran it"               'test:changed' "$(cat "$FIX/npm.log")"
R=$(in_kit driver_proof_cmd_check "$FIX/t709" "npm run test:changed" t/own.test.sh >/dev/null 2>&1 && echo accepted || echo refused)
want "a proof may not run test:changed"        "refused" "$R"
R=$(in_kit driver_proof_cmd_check "$FIX/t709" "npm run test:changed -- t/own.test.sh" t/own.test.sh >/dev/null 2>&1 && echo accepted || echo refused)
want "not even with its file after it"         "refused" "$R"
R=$(in_kit driver_proof_cmd_check "$FIX/t709" "sh run-tests.sh" t/own.test.sh >/dev/null 2>&1 && echo accepted || echo refused)
want "nor a command that does not name its file" "refused" "$R"
R=$(in_kit driver_proof_cmd_check "$FIX/t709" "bash t/own.test.sh" t/own.test.sh >/dev/null 2>&1 && echo accepted || echo refused)
want "the one test file is a proof"            "accepted" "$R"
want_in "the proof limits every model step reads say so" 'never npm run test:changed' "$(in_kit driver_fact_proof_limits)"
want_not_in "and without localOnly they do not" 'never npm run test:changed' "$(HARNESS_CFG="$FIX/cfg.json" HARNESS_CFG_PATH="$FIX/cfg.json" bash -c '. "$1/driver/driver-env.sh" && . "$1/driver/ai-step.sh" && driver_fact_proof_limits' _ "$ROOT")"
want_in "the proof limits say a trunk red is carried on past" 'This check is red on develop itself; the develop-red ticket owns it; carry on' "$(in_kit driver_fact_proof_limits)"
for b in build fix repair; do
  want_in "briefs/$b.md carries the proof limits" '{{PROOF_LIMITS}}' "$(cat "$ROOT/briefs/$b.md")"
done
want_not_in "briefs/repair.md no longer says park on it" 'itself is not this PR.s to fix.\*\* Park and say so' "$(tr '\n' ' ' < "$ROOT/briefs/repair.md" | tr -s ' ')"

echo "--- plants: each line out of a copy of the kit, its case fails ---"
KIT="$FIX/kit"
kit_copy() { rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$ROOT/driver" "$ROOT/scripts" "$ROOT/swarm" "$ROOT/shared" "$ROOT/briefs" "$KIT/"; }
plant() { # <label> <file under the kit> <exact text to delete>
  kit_copy
  python3 -I -c 'import sys; p, l = sys.argv[1], sys.argv[2]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, "", 1)); sys.exit(0 if n == 1 else 1)' "$KIT/$2" "$3" \
    || { want "plant landed: $1" "landed" "missed"; return 1; }
}
N=720
next() { N=$((N + 1)); }
case_sc_base() { next; reset; trunk_set red-legacy; branch "$N"; SUT_KIT="$KIT" step driver_step_self_check "$N"; R="rc=$R_RC rows=$(rows)"; }
case_sc_own()  { next; reset; trunk_set; branch "$N" red-own; SUT_KIT="$KIT" step driver_step_self_check "$N"; R="rc=$R_RC"; }
case_fx_base() { next; reset; trunk_set red-legacy; branch "$N"; findings "$N" "sh run-tests.sh"
  fix_ai fix "$(ask_answer 'wait or fix?')" superpowers:receiving-code-review; SUT_KIT="$KIT" step driver_step_fix "$N"; R="rc=$R_RC rows=$(rows)"; }
case_fx_ask()  { next; reset; trunk_set red-legacy; branch "$N" red-own; findings "$N" "sh run-tests.sh"
  fix_ai fix "$(ask_answer 't/legacy.test.sh fails on develop too: wait or fix here?')" superpowers:receiving-code-review
  queue_then "$(gate_answer "$N")"; SUT_KIT="$KIT" step driver_step_fix "$N"; R="rc=$R_RC"; }
case_fx_lo()   { next; reset; trunk_set; branch "$N" red-own; findings "$N" "npm run test:changed"
  fix_ai fix "$(ask_answer 'wait or fix?')" superpowers:receiving-code-review; SUT_KIT="$KIT" step driver_step_fix "$N" "$FIX/cfg-lo.json"
  R="handed=$(blockers "$N" | grep -c 'test:changed')"; }
case_fx_stale() { next; reset; trunk_set; branch "$N" red-own; findings "$N" "sh run-tests.sh" "$SHA"
  fix_ai fix "$(ask_answer 'wait or fix?')" superpowers:receiving-code-review; SUT_KIT="$KIT" step driver_step_fix "$N"; R="rc=$R_RC"; }
case_proof()   { R=$(SUT_KIT="$KIT" in_kit driver_proof_cmd_check "$FIX/t709" "npm run test:changed -- t/own.test.sh" t/own.test.sh >/dev/null 2>&1 && echo accepted || echo refused); }
case_limits()  { R=$(SUT_KIT="$KIT" in_kit driver_fact_proof_limits | grep -c 'never npm run test:changed'); }
case_base_limits() { R=$(SUT_KIT="$KIT" in_kit driver_fact_proof_limits | grep -c 'the develop-red ticket owns it; carry on'); }
kit_copy
case_sc_base;  want "the unplanted kit: a self-check base-red is green and noted" "rc=0 rows=1" "$R"
case_sc_own;   want "the unplanted kit: a self-check branch-only red blocks"      "rc=$DRIVER_E_REWORK" "$R"
case_fx_base;  want "the unplanted kit: a fix base-red finishes and is noted"     "rc=0 rows=1" "$R"
case_fx_ask;   want "the unplanted kit: a base-red question is carried on past"   "rc=0" "$R"
case_fx_lo;    want "the unplanted kit: test:changed is not handed on"            "handed=0" "$R"
case_fx_stale; want "the unplanted kit: another head's reds are not handed on"    "rc=0" "$R"
case_proof;    want "the unplanted kit: a test:changed proof is refused"          "refused" "$R"
case_limits;   want "the unplanted kit: the proof limits say so"                  "1" "$R"
case_base_limits; want "the unplanted kit: the proof limits carry a trunk red on past" "1" "$R"
plant "self-check reads base-red" driver/steps/self-check.sh '    elif [ "$rc" -ne 126 ] && [ "$rc" -ne 127 ] \
         && bred=$(driver_base_red_gate "$wt" "$cmd" "$(driver_state_dir "$t")/steps/gate-$safe.out"); then
      DRIVER_BASE_RED_SHA=$(driver_base_red_sha "$wt")
      driver_base_red_say "$t" self-check "$name" "$bred"
' && { case_sc_base; want "planted (self-check reads base-red): it goes to fix, nothing noted" "rc=$DRIVER_E_REWORK rows=0" "$R"; }
plant "a green trunk run is the branch's" driver/base-red.sh '      green) DRIVER_BASE_RED_WHY="$c is green on $INTEGRATION_BRANCH@$s7, so this branch'"'"'s own"; return 1 ;;
      *) DRIVER_BASE_RED_WHY="$c could not be run on $INTEGRATION_BRANCH@$s7, so this branch'"'"'s own"; return 1 ;;
' && { case_sc_own; want "planted (a green trunk run is the branch's): the branch's red passes" "rc=0" "$R"; }
plant "fix reads base-red" driver/steps/fix.sh '    if [ -n "$of" ] && [ -f "$of" ] && bred=$(driver_base_red_gate "$wt" "$cmd" "$of"); then
      DRIVER_BASE_RED_SHA=$(driver_base_red_sha "$wt")
      driver_base_red_say "$t" fix "$id" "$bred"
      continue
    fi
' && { case_fx_base; want "planted (fix reads base-red): it parks on the question, nothing noted" "rc=$DRIVER_E_QUESTION rows=0" "$R"; }
plant "fix carries on past a base-red question" driver/steps/fix.sh '  if [ "$rc" -eq "$DRIVER_E_QUESTION" ] && [ -z "${DRIVER_FIX_GATE_NOTE:-}" ] \
     && bred=$(_driver_fix_question_base_red "$t" "$wt"); then
    DRIVER_BASE_RED_SHA=$(driver_base_red_sha "$wt")
    driver_base_red_say "$t" fix "the question" "$bred"
    rc=0; DRIVER_FIX_GATE_NOTE=$(_driver_fix_base_red_note "$bred") _driver_fix_gates "$t" || rc=$?
    return "$rc"
  fi
' && { case_fx_ask; want "planted (fix carries on past a base-red question): it parks" "rc=$DRIVER_E_QUESTION" "$R"; }
plant "fix hands on no CI-only command" driver/steps/fix.sh '    if driver_cmd_ci_only "$cmd"; then
      driver_say "   fix: $id (\`$cmd\`) is not in gates.local, and gates.localOnly keeps it for CI — not run here, not handed on"
      continue
    fi
' && { case_fx_lo; want "planted (fix hands on no CI-only command): test:changed reaches the model" "handed=1" "$R"; }
plant "fix reads only this head's reds" driver/steps/fix.sh '  if [ -n "$head" ] && [ "$head" != "$now" ]; then
    driver_say "   fix: the self-check reds on file are of $(printf '"'"'%s'"'"' "$head" | cut -c1-10), not this head $(printf '"'"'%s'"'"' "$now" | cut -c1-10) — another run'"'"'s, so none is handed on; self-check runs every gate next"
    rm -f "$f" "$f.head"; return 1
  fi
' && { case_fx_stale; want "planted (fix reads only this head's reds): the stale red is asked about" "rc=$DRIVER_E_QUESTION" "$R"; }
plant "a proof runs no CI-only command" driver/steps/build.sh '  if driver_cmd_ci_only "$cmd"; then
    printf '"'"'the command is one gates.localOnly keeps for CI (it is in gates.changed, not gates.local), and a proof runs only its own test file — %s\n'"'"' "$eg"
    return 1
  fi
' && { case_proof; want "planted (a proof runs no CI-only command): test:changed is accepted" "accepted" "$R"; }
plant "the proof limits name the local set" driver/facts.sh '  ! driver_gates_local_only || _driver_fact_local_only_limits
' && { case_limits; want "planted (the proof limits name the local set): they do not say so" "0" "$R"; }
plant "the proof limits carry a trunk red on past" driver/facts.sh '  _driver_fact_base_red_limits
' && { case_base_limits; want "planted (the proof limits carry a trunk red on past): they do not say so" "0" "$R"; }

suite_end "$FAILED"
