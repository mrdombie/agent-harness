#!/usr/bin/env bash
# critic-off-until-release.test.sh — while the design critic's check is listed in
# release.nonBlockingChecks and release.done is not true, the critic is off for every
# caller, not the coordinator's sweep alone: no step is handed its findings or may start
# it, a review or fix list drops a "critic-…" finding, a repair on a signed-off PR makes
# no critic call, asks nothing and does not park, the healing brief and the owner channel
# take no critic question, and a judge run calls no model. release.done true (or
# review.judge.duringRelease true): the critic runs as before.
#
# Measured on the origin project, 22–23 Oct: 0.7.205 paused the sweep, and #12704 still
# parked on a critic-after-signoff question while #12209 re-asked about a critic toast
# three times.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/review.sh" || exit 1
mkdir -p "$FIX/tmp"; export TMPDIR="$FIX/tmp" HARNESS_RELEASE_FETCH_SECS=0

CFGF="$REPO/.claude/harness.json"
jq '.design = {surfacePaths: ["screens/**"]}' "$CFGF" > "$FIX/cfg.base"
off()  { jq '.release = {nonBlockingChecks: ["Lesson / Every fix ships a lesson", "Design critic"], done: false}' "$FIX/cfg.base" > "$CFGF"; }
done_() { jq '.release = {nonBlockingChecks: ["Lesson / Every fix ships a lesson", "Design critic"], done: true}' "$FIX/cfg.base" > "$CFGF"; }
during() { jq '.release = {nonBlockingChecks: ["Design critic"], done: false} | .review.judge.duringRelease = true' "$FIX/cfg.base" > "$CFGF"; }

# The judge's own record: PR #88's latest verdict failed on these.
export CRITIC_JUDGE_DIR="$FIX/judge"; mkdir -p "$CRITIC_JUDGE_DIR"
printf 'Major · changed · Templates card: no shot of a chosen row\nMinor · changed · a Yours marker on your own templates\n' > "$CRITIC_JUDGE_DIR/findings-88.txt"

# A repair of PR #88, whose screens the owner signed off.
git -C "$REPO" worktree add -q "$FIX/wtr" -b tkt-120/work develop
mkdir -p "$FIX/wtr/screens"; printf 'the PR change\n' > "$FIX/wtr/screens/Home.tsx"
git -C "$FIX/wtr" add . && git -C "$FIX/wtr" commit -qm "feat: the PR"
RB=$(git -C "$FIX/wtr" rev-parse HEAD)
printf 'the repair\n' >> "$FIX/wtr/screens/Home.tsx"; git -C "$FIX/wtr" commit -qam "fix: the repair"
cat > "$BIN/approval-kept" <<SH
#!/usr/bin/env bash
case "\$1" in
  signed-head) echo 1111111111111111111111111111111111111111; exit 0 ;;
  screens) exec bash "$ROOT/scripts/approval-kept.sh" screens ;;
  *) exit 9 ;;
esac
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/pl"
chmod +x "$BIN/approval-kept" "$FIX/pl"
export DRIVER_APPROVAL_KEPT="$BIN/approval-kept" DRIVER_POLISH_LIST="$FIX/pl"
fix_brief review superpowers:requesting-code-review "Review round {{ROUND}}. {{DIFF}} {{CRITIC_FINDINGS}}"
fix_brief fix "" "Fix: {{BLOCKERS}}"
fix_brief probe "" "Probe: {{CRITIC_FINDINGS}}"

CRITIC_REVIEW='{"verdict":"BLOCKED","findings":[{"id":"critic-chosen-row","file":"screens/Home.tsx","line":12,"grade":"major","summary":"no shot of a chosen row","reason":"the critic said so","fix":"add the fixture"}]}'

N=900
fresh() { # a new ticket in repair of signed-off PR #88
  N=$((N + 1)); : > "$CLAUDE_LOG"; : > "$GH_LOG"
  driver_state_init "$N" --worktree "$FIX/wtr" --branch tkt-120/work >/dev/null
  driver_state_set "$N" mode repair; driver_state_set "$N" pr 88; driver_state_set "$N" repair_base "$RB"
  fix_issue "$N" OPEN "status:in-review"
}
kit() { bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; . "$1/driver/driver-env.sh" && . "$1/driver/ai-step.sh" && '"$1" _ "${SUT_KIT:-$ROOT}" "$N" > "$FIX/out-$N" 2>&1; }
state() { driver_state_get "$N" "$1"; }

case_review() { # the reviewer copied the critic's finding off the PR
  fresh; fix_ai review "$CRITIC_REVIEW" superpowers:requesting-code-review
  local rc=0; kit '. "$1/driver/steps/review.sh" && driver_step_review "$2"' || rc=$?
  local owner=no; case "$(state park_note)" in "Needs the owner"*) owner=yes ;; esac
  R="rc=$rc owner=$owner verdict=$(jq -r .verdict "$STATE/driver/$N/steps/review.json" 2>/dev/null)"
}
case_fix() { # a fix round whose only open items are the critic's
  fresh; mkdir -p "$STATE/driver/$N/steps"; printf '%s\n' "$CRITIC_REVIEW" > "$STATE/driver/$N/steps/review.json"
  driver_state_bump "$N" review
  fix_ai fix '{"status":"fixed","cleared":[],"deferred":[{"blockerId":"critic-chosen-row","reason":"the screens are signed off"}]}'
  local rc=0; kit '. "$1/driver/steps/fix.sh" && driver_step_fix "$2"' || rc=$?
  R="rc=$rc model=$(grep -c . "$CLAUDE_LOG")"
}
case_facts() { fresh; R=$(kit_out 'driver_fact_critic_findings "$2"'); }
kit_out() { kit "$1"; cat "$FIX/out-$N"; }
case_lean() { fresh; R=$(kit_out 'driver_lean_args "$PWD" repair; printf "%s\n" "${DRIVER_LEAN_ARGS[@]}"' | grep -c 'Agent(agent-harness:design-critic)'); }
case_ask() { # the owner channel, asked about the critic
  fresh; local rc=0
  bash "${SUT_KIT:-$ROOT}/scripts/owner-question.sh" ask "$N" critic-after-signoff "PR #88 is signed off but the design critic says SLOP: ship, or fix?" > "$FIX/out-$N" 2>&1 || rc=$?
  R="rc=$rc labelled=$(grep -c "issue edit $N .*--add-label" "$GH_LOG")"
}
case_park() { # a step's critic question reaches the park
  fresh; local rc=0
  kit '. "$1/driver/steps/park.sh" && driver_park "$2" "repair asked" "the design critic says SLOP on the signed-off screens: ship or fix?" person' || rc=$?
  R="hold=$(grep -c 'needs:human-approval\|needs:owner-decision' "$GH_LOG") ready=$(grep -c 'status:ready' "$GH_LOG")"
}
case_ask_step() { # a step asks about the critic, then answers when told it is off
  fresh
  fix_ai probe '{"question":"PR #88 is signed off and the design critic says SLOP: ship as signed off, or add the fixtures?"}'
  jq -nc '{type:"result", subtype:"success", is_error:false, result:"{\"status\":\"done\"}", structured_output:{status:"done"}}' > "$FIX/ai/probe.then.jsonl"
  local rc=0; kit 'driver_ai_step "$2" probe' || rc=$?
  R="rc=$rc calls=$(grep -c . "$CLAUDE_LOG")"
  rm -f "$FIX/ai/probe.then.jsonl"
}
# The brief, out of repair-watch.sh as it ships: that script runs its whole pass when started.
cat > "$FIX/brief.sh" <<'SH'
. "$1/swarm/swarm-env.sh" >/dev/null 2>&1 || exit 1
eval "$(awk '/^repair_brief\(\) \{/ { f = 1 } f { print } f && /^}/ { exit }' "$1/swarm/repair-watch.sh")"
repair_brief 88 abcdef1234 "the design status is red"
SH
case_brief() { R=$(KIT_ROOT="${SUT_KIT:-$ROOT}" bash "$FIX/brief.sh" "${SUT_KIT:-$ROOT}" 2>&1); }
case_judge() { # a judge launched past the sweep
  fresh; local rc=0
  CRITIC_JUDGE_LAUNCHER=coordinator bash "${SUT_KIT:-$ROOT}/scripts/critic-judge.sh" run 88 > "$FIX/out-$N" 2>&1 || rc=$?
  R="pr-read=$(grep -c '^pr view 88' "$GH_LOG") model=$(grep -c . "$CLAUDE_LOG")"
}
case_sf() { R=$(bash "${SUT_KIT:-$ROOT}/scripts/screen-findings.sh" critic 88 2>/dev/null | grep -c .); }

echo "--- off until the release ---"
off
case_review
want    "a repair on a signed-off PR: the critic's finding is dropped, it ships, no park" "rc=0 owner=no verdict=SHIP" "$R"
want_in "and says why"                                  'design critic: off until the release — dropped from the review list: critic-chosen-row' "$(cat "$FIX/out-$N")"
case_fix
want    "a fix round whose only items are the critic's: dropped, no model, ships" "rc=0 model=0" "$R"
want_in "and says why"                                  'design critic: off until the release — dropped from the fix list: critic-chosen-row' "$(cat "$FIX/out-$N")"
case_facts
want_in     "a step is told the critic is off"          'off until the release' "$R"
want_not_in "and is handed none of its findings"        'chosen row' "$R"
case_sf
want    "the open findings are handed to nobody"        "0" "$R"
case_lean
want    "no step may start the design critic"           "1" "$R"
case_ask
want    "the owner channel refuses a critic question, labels nothing" "rc=5 labelled=0" "$R"
case_park
want    "a step's critic question parks for nobody: no hold, left ready" "hold=0 ready=1" "$R"
case_ask_step
want    "a step that asks about the critic is told it is off, and answers" "rc=0 calls=2" "$R"
case_brief
want_in     "the healing brief says the critic is off"  'design critic is off until the release' "$R"
want_not_in "and never that its findings are the PM's call" "PM's call" "$R"
case_judge
want    "a judge launched past the sweep reads nothing and calls no model" "pr-read=0 model=0" "$R"
want_in "and says why"                                  'paused until the release' "$(cat "$FIX/out-$N")"

echo "--- release done: the critic runs as before ---"
done_
case_review
want    "the critic's finding on signed-off screens parks for the owner" "rc=24 owner=yes verdict=BLOCKED" "$R"
case_fix
want    "a fix round is run on it"                      "rc=24 model=1" "$R"
case_facts
want_in "a step is handed its findings"                 'chosen row' "$R"
case_sf
want    "the open findings are read"                    "2" "$R"
case_lean
want    "the critic agent is not denied"                "0" "$R"
case_ask
want    "the owner is asked"                            "rc=0 labelled=1" "$R"
case_ask_step
want    "a critic question is a question"               "rc=20 calls=1" "$R"
case_brief
want_in "the healing brief carries the critic's rule"   "PM's call" "$R"
case_judge
want    "a judge run reads the PR"                      "pr-read=1 model=0" "$R"

echo "--- review.judge.duringRelease true: it runs ---"
during
case_lean
want    "the critic agent is not denied"                "0" "$R"
case_ask
want    "the owner is asked"                            "rc=0 labelled=1" "$R"

echo "--- plants: each line out of a copy of the kit, its case fails ---"
off
KIT="$FIX/kit"
kit_copy() { rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$ROOT/driver" "$ROOT/scripts" "$ROOT/swarm" "$ROOT/shared" "$ROOT/hooks" "$KIT/"; }
plant() { # <label> <file under the kit> <first line> <last line> <case> <the result the lines prevent>
  kit_copy
  python3 -I - "$KIT/$2" "$3" "$4" <<'PY' || { bad "$1 — the planted lines are not in $2"; return; }
import sys
p, first, last = sys.argv[1:4]
lines = open(p).read().split("\n")
if lines.count(first) != 1: sys.exit(1)
i = lines.index(first)
j = lines.index(last, i)
del lines[i:j + 1]
open(p, "w").write("\n".join(lines))
PY
  grep -qxF -- "$3" "$KIT/$2" && { bad "$1 — the plant did not land"; return; }
  bash -n "$KIT/$2" || { bad "$1 — the plant broke the file's syntax"; return; }
  SUT_KIT="$KIT" "$5"
  case "$R" in *"$6"*) ok "planted ($1): $6" ;; *) bad "planted ($1) — wanted '$6', got '$R'" ;; esac
}
one() { plant "$1" "$2" "$3" "$3" "$4" "$5"; }
SQ="'"
one "the review drops no critic finding" driver/steps/review.sh \
  '  driver_drop_critic_findings "$ans_file" review && _driver_review_verdict_off_grades "$ans_file" "$(driver_blocking_grades "$round")" 1' \
  case_review "owner=yes"
one "the fix round drops no critic finding" driver/steps/fix.sh \
  '  driver_drop_critic_findings "$review" fix || true' case_fix "model=1"
plant "the facts hand the critic's findings on" driver/facts.sh \
  '  if release_critic_paused; then' '  fi' case_facts "no open finding"
one "screen-findings reads the critic's findings" scripts/screen-findings.sh \
  "    if release_critic_paused; then echo \"screen-findings: \$RELEASE_CRITIC_OFF — PR #\$2${SQ}s open critic findings are not handed on\" >&2; exit 0; fi" \
  case_sf "2"
one "steps may start the critic" driver/driver-env.sh '    deny="Agent($ja) Task($ja)"' case_lean "0"
plant "the owner channel takes a critic question" scripts/owner-question.sh \
  "  if release_critic_paused && printf ${SQ}%s %s${SQ} \"\$slug\" \"\$q\" | grep -qi ${SQ}critic${SQ}; then" '  fi' case_ask "labelled=1"
plant "a park's critic question goes to a person" driver/steps/park.sh \
  "  if [ \"\$cause\" = person ] && release_critic_paused && printf '%s %s' \"\$reason\" \"\$question\" | grep -qi 'critic'; then" \
  '  fi' case_park "hold=1"
plant "a step's critic question is not re-asked" driver/ai-step.sh \
  '  if [ "$jrc" -eq "$DRIVER_E_QUESTION" ] && release_critic_paused \' '  fi' case_ask_step "calls=1"
plant "the healing brief keeps the critic's rule" swarm/repair-watch.sh \
  '  release_critic_paused && critic="The design critic is off until the release: ignore each of its verdicts and' \
  'run the critic."' case_brief "PM's call"
one "a judge run is not paused" scripts/critic-judge.sh \
  '  if [ "${CRITIC_JUDGE_MANUAL:-}" != 1 ] && release_paused; then say "PR #$pr: $PAUSED_WHY — not judged"; return 0; fi' \
  case_judge "pr-read=1"

suite_end "$FAILED"
