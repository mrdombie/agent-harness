#!/usr/bin/env bash
# merge-first.test.sh — release.mergeFirst, the one switch (the owner, 2026-10-22: merge
# first, fix after, until the release). On: a Critical still blocks and is fixed in
# place; a Major becomes a P1 follow-up at the front of the queue and the change ships; a
# Minor goes on its screen's polish list, or is a P3 follow-up when no screen takes it;
# the critic's findings refuse nothing; no hold label and no picture parity before the
# merge; a screen ticket with no picture starts, a screen:new one still waits for one.
# Off: every gate is what it was.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/review.sh" || exit 1
. "$HERE/../steps/ship.sh" || exit 1
. "$HERE/../facts.sh" || exit 1
fix_brief review superpowers:requesting-code-review "Review round {{ROUND}}. The change: {{DIFF}} Renders: {{RENDERS}}"
# Screens: a .tsx file is on the "home" screen; the critic failed the PR on one Major.
cat > "$FIX/sf" <<'SH'
#!/usr/bin/env bash
case "$1" in
  screens) [ -n "${3:-}" ] && grep -q 'tsx' "$3" && echo home ;;
  critic)  printf 'major\t1\tthe headline wraps at 390\n' ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\ncase "$1" in add) printf "%%s\\n" "$*" >> "$FIX/pl.adds" ;; esac\nexit 0\n' > "$FIX/pl"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$FIX/fu.calls"\nexit 0\n' > "$FIX/fu"
chmod +x "$FIX/sf" "$FIX/pl" "$FIX/fu"; : > "$FIX/pl.adds"; : > "$FIX/fu.calls"
export DRIVER_SCREEN_FINDINGS="$FIX/sf" DRIVER_POLISH_LIST="$FIX/pl"

BASE="$HARNESS_CFG_PATH"
jq '.release = {mergeFirst: true, done: false}' "$BASE" > "$FIX/mf-on.json"
jq '.release = {mergeFirst: false, done: false}' "$BASE" > "$FIX/mf-off.json"
jq '.release = {mergeFirst: true, done: true}' "$BASE" > "$FIX/mf-done.json"
on()  { HARNESS_CFG="$FIX/mf-on.json" "$@"; }
off() { HARNESS_CFG="$FIX/mf-off.json" "$@"; }

mf_tree() { # <ticket> — a branch with one change, claimed; P1, so merge first still reviews it
  git -C "$REPO" worktree add -q "$FIX/mf$1" -b "tkt-$1/work" develop
  printf 'a\n' > "$FIX/mf$1/a.sh"; git -C "$FIX/mf$1" add -A; git -C "$FIX/mf$1" commit -qm "feat: a"
  driver_state_init "$1" --worktree "$FIX/mf$1" --branch "tkt-$1/work"
  fix_issue "$1" OPEN "status:claimed,P1"
}
rj() { printf '%s/steps/review.json' "$(driver_state_dir "$1")"; }
fu() { printf '%s/steps/review.followups.jsonl' "$(driver_state_dir "$1")"; }
# In a file the change did not touch: a Major in one it did is fixed in place (same-file-same-change.test.sh).
major='{"verdict":"BLOCKED","findings":[{"id":"m1","file":"lib/other.sh","line":3,"grade":"major","summary":"the save is dropped","reason":"a failure shows as success","fix":"keep it"}]}'
critical='{"verdict":"BLOCKED","findings":[{"id":"c1","file":"a.sh","line":1,"grade":"critical","summary":"another workspace sees the rows","reason":"wrong data","fix":"scope it"}]}'
minors='{"verdict":"BLOCKED","findings":[
  {"id":"n1","file":"app/page.tsx","line":9,"grade":"minor","summary":"the gap is 12 not 16","reason":"r","fix":"f"},
  {"id":"n2","file":"lib/x.ts","line":2,"grade":"minor","summary":"the log line is vague","reason":"r","fix":"f"}]}'

echo "--- the switch: release.mergeFirst, off once release.done ---"
want "on"                     "0" "$(HARNESS_CFG="$FIX/mf-on.json" release_merge_first; echo $?)"
want "off"                    "1" "$(HARNESS_CFG="$FIX/mf-off.json" release_merge_first; echo $?)"
want "off once the release is done" "1" "$(HARNESS_CFG="$FIX/mf-done.json" release_merge_first; echo $?)"
want "no key is off"          "1" "$(HARNESS_CFG="$BASE" release_merge_first; echo $?)"
want "on: a Critical alone blocks"   "critical" "$(on driver_blocking_grades 1)"
want "off: round 1 is unchanged"     "critical major minor" "$(off driver_blocking_grades 1)"
want_in "on: the critic's check warns like a listed one" '"design critic"' "$(on release_nonblocking_json)"
want_in "and the picture check"      '"approved picture"' "$(on release_nonblocking_json)"
want "off: neither is added"         "[]" "$(off release_nonblocking_json)"

echo "--- on: a Major is a follow-up and the review ships ---"
mf_tree 701
fix_ai review "$major" superpowers:requesting-code-review
rc=0; out=$(on driver_step_review 701 2>&1) || rc=$?
want "the review finishes"          "0" "$rc"
want "the verdict ships"            "SHIP" "$(jq -r .verdict "$(rj 701)")"
want "nothing blocks"               "0" "$(on _driver_count "$(rj 701)" blocking)"
want "the Major waits to be filed"  "m1 major lib/other.sh:3" "$(jq -r '"\(.id) \(.grade) \(.file):\(.line)"' "$(fu 701)")"
want_in "and the run says so"       'filed as follow-up tickets when the PR is open' "$out"

echo "--- on: a Critical still blocks, and is fixed in place ---"
mf_tree 702
fix_ai review "$critical" superpowers:requesting-code-review
rc=0; on driver_step_review 702 >/dev/null 2>&1 || rc=$?
want "it goes to fix"               "30" "$rc"
want "the Critical blocks"          "1" "$(on _driver_count "$(rj 702)" blocking)"
want "and is never a follow-up"     "" "$(cat "$(fu 702)" 2>/dev/null)"

echo "--- on: a Minor on a screen goes on its polish list; one no screen takes is a follow-up ---"
mf_tree 703; : > "$FIX/pl.adds"
fix_ai review "$minors" superpowers:requesting-code-review
rc=0; on driver_step_review 703 >/dev/null 2>&1 || rc=$?
want "the review finishes"          "0" "$rc"
want_in "the screen's Minor is on its polish list" '^add home \[Minor\] the gap is 12 not 16' "$(cat "$FIX/pl.adds")"
want "the other is a follow-up"     "n2" "$(jq -r .id "$(fu 703)")"

echo "--- off: today's behaviour — a Major blocks and nothing is a follow-up ---"
mf_tree 704
fix_ai review "$major" superpowers:requesting-code-review
rc=0; off driver_step_review 704 >/dev/null 2>&1 || rc=$?
want "the Major goes to fix"        "30" "$rc"
want "nothing waits to be filed"    "" "$(cat "$(fu 704)" 2>/dev/null)"

echo "--- on: the critic's findings are no blocker; off they are ---"
driver_state_set 701 pr 4701
want_in "on: no critic finding reaches the step" 'design critic: off until the release' "$(on driver_fact_critic_findings 701)"
want_in "off: the critic's finding is the step's" 'the headline wraps at 390' "$(off driver_fact_critic_findings 701)"

echo "--- on: a screen ticket with no picture starts; a screen:new one still waits ---"
fix_issue 705 OPEN "status:claimed"
fix_issue 706 OPEN "status:claimed,screen:new"
want "on: an existing screen takes the baseline route" "baseline" "$(on driver_screen_route 705 | cut -f1)"
want "on: screen:new keeps the picture route"          "picture"  "$(on driver_screen_route 706 | cut -f1)"
want "off: every screen takes the picture route"       "picture"  "$(off driver_screen_route 705 | cut -f1)"

echo "--- on: ship files the follow-ups with the PR's number, adds no hold, and arms auto-merge ---"
git init -q --bare "$FIX/origin"; git -C "$REPO" remote add origin "$FIX/origin"; git -C "$REPO" push -q origin develop
driver_state_set 701 claimed_at_sha "$(git -C "$REPO" rev-parse develop)"
for st in start plan build self-check review record; do driver_state_done 701 "$st"; done
: > "$GH_LOG"; : > "$FIX/fu.calls"
rc=0; out=$(DRIVER_FOLLOW_UP="$FIX/fu" on driver_step_ship 701 2>&1) || rc=$?
want "it ships"                     "0" "$rc"
want "the follow-ups are filed against the PR" "file 701 42 $(fu 701)" "$(cat "$FIX/fu.calls")"
want_not_in "no hold label goes on"  'add-label needs:human-approval' "$(cat "$GH_LOG")"
want_in "ready"                     'pr ready' "$(cat "$GH_LOG")"
want_in "auto-merge armed"          'pr merge.*--auto' "$(cat "$GH_LOG")"
want_in "the body says merge first" 'Merge first until the release' "$(cat "$GH_LOG")"
want_in "and lists the Major as a follow-up" 'the save is dropped .*a follow-up ticket' "$(cat "$GH_LOG")"

echo "--- on: a Critical stops the ship ---"
mf_tree 707
fix_ai review "$critical" superpowers:requesting-code-review
on driver_step_review 707 >/dev/null 2>&1
DRIVER_MAX_REVIEW_ROUNDS=0; export DRIVER_MAX_REVIEW_ROUNDS
driver_state_set 707 claimed_at_sha "$(git -C "$REPO" rev-parse develop)"
: > "$GH_LOG"
rc=0; on driver_step_ship 707 >/dev/null 2>&1 || rc=$?
want "the ship refuses"             "24" "$rc"
want_not_in "it is never marked ready" 'pr ready' "$(cat "$GH_LOG")"
unset DRIVER_MAX_REVIEW_ROUNDS

echo "--- the push names the head gates.local passed on, after a trunk merge too ---"
jq '.gates = {localOnly: true, local: ["echo lint-ok"]}' "$FIX/mf-off.json" > "$FIX/lg-off.json"
jq '.gates = {localOnly: true, local: ["echo lint-ok"]}' "$FIX/mf-on.json" > "$FIX/lg-on.json"
HOOKS="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/hooks"; mkdir -p "$HOOKS"
cat > "$HOOKS/pre-push" <<'SH'
#!/usr/bin/env bash
while read -r l s r rs; do printf '%s %s\n' "${HARNESS_LOCAL_GATES_HEAD:-none}" "$s" >> "$FIX/hook.log"; done
[ -f "$FIX/hook.fail" ] && { echo "✗ check:composition failed on the trunk's own files"; exit 1; }
exit 0
SH
printf "exit 0\n" > "$FIX/hooks-ok.sh"; chmod +x "$HOOKS/pre-push"; export DRIVER_ENSURE_HOOKS="$FIX/hooks-ok.sh"
ship_ready() { # <ticket> — reviewed, gates.local passed on its head, every step before ship done
  mf_tree "$1"
  driver_state_put "$1" review '{"verdict":"SHIP","findings":[]}'; driver_state_bump "$1" review
  driver_state_set "$1" claimed_at_sha "$(git -C "$REPO" rev-parse develop)"
  for st in start plan build self-check review record; do driver_state_done "$1" "$st"; done
  driver_state_set "$1" local_gates_head "$(git -C "$FIX/mf$1" rev-parse HEAD)"
}
trunk_moves() { # <ticket> — a commit lands on the trunk and the branch merges it
  printf 'trunk %s\n' "$1" > "$REPO/trunk-$1.txt"; git -C "$REPO" add "trunk-$1.txt"; git -C "$REPO" commit -qm "trunk $1"
  git -C "$REPO" push -q origin develop; git -C "$FIX/mf$1" merge -q --no-edit develop
}
case_lg() { # <cfg> — R: whether the push named the pushed head
  N=$((N + 1)); ship_ready "$N"; trunk_moves "$N"; : > "$FIX/hook.log"
  HARNESS_CFG="$1" HARNESS_CFG_PATH="$1" bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; . "$1/driver/driver-env.sh" && . "$1/driver/steps/ship.sh" && driver_step_ship "$2"' _ "${SUT_KIT:-$ROOT}" "$N" > "$FIX/ship-$N.out" 2>&1
  R=$(awk -v h="$(git -C "$FIX/mf$N" rev-parse HEAD)" '{ print ($1 == h && $2 == h) ? "named" : "not named (" $1 ")" }' "$FIX/hook.log" | tail -1)
}
ROOT="$(cd "$HERE/../.." && pwd)"; N=750
case_lg_off() { case_lg "$FIX/lg-off.json"; }
case_lg_off
want "a trunk merge after gates.local: the push names the pushed head" "named" "$R"
want_in "gates.local ran again on it"   'gates.local runs again on' "$(cat "$FIX/ship-$N.out")"

echo "--- the pre-push hook's own suite is never a local gate ---"
jq '.gates = {localOnly: true, local: ["echo lint-ok", "echo suite-ran"]}' "$FIX/mf-off.json" > "$FIX/suite.json"
cp "$HOOKS/pre-push" "$FIX/pre-push.keep"; printf 'echo suite-ran\n' >> "$HOOKS/pre-push"
mf_tree 760
rc=0; out=$(HARNESS_CFG="$FIX/suite.json" driver_step_self_check 760 2>&1) || rc=$?
cp "$FIX/pre-push.keep" "$HOOKS/pre-push"
want "self-check passes"                "0" "$rc"
want_in "and names the suite it left to the hook and CI" "local 2 \(echo suite-ran\) is the pre-push hook's own suite" "$out"
want "it never ran"                     "" "$(ls "$(driver_state_dir 760)/steps/gate-local-2.out" 2>/dev/null)"

echo "--- merge first: a hook that refuses a head gates.local passed is retried once, then goes to fix ---"
: > "$FIX/hook.fail"
case_lg "$FIX/lg-on.json"
want "the hook ran twice"               "2" "$(grep -c . "$FIX/hook.log")"
want_in "it goes to fix"                'the pre-push refused the push — its output goes to fix' "$(cat "$FIX/ship-$N.out")"
want_in "with the failing check as the finding" 'check:composition failed' "$(jq -r '.[0].output' "$(driver_state_dir "$N")/steps/self-check.findings.json" 2>/dev/null)"
want "never parked, never a machine fault" "" "$(driver_state_get "$N" park_note)$(driver_state_get "$N" machine_fault)"
rm -f "$FIX/hook.fail"

echo "--- plants: each merge-first line out of a copy of the kit, its case fails ---"
KIT="$FIX/kit"
kit_copy() { rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$ROOT/driver" "$ROOT/scripts" "$ROOT/swarm" "$ROOT/shared" "$KIT/"; }
N=800
case_major() { # <cfg> — a Major under that config: the step's exit and what waits to be filed
  N=$((N + 1)); mf_tree "$N"; fix_ai review "$major" superpowers:requesting-code-review
  local rc=0; HARNESS_CFG="$1" HARNESS_CFG_PATH="$1" bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; . "$1/driver/driver-env.sh" && . "$1/driver/steps/review.sh" && driver_step_review "$2"' _ "$KIT" "$N" >/dev/null 2>&1 || rc=$?
  R="rc=$rc fu=$(jq -r .id "$(fu "$N")" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
}
case_major_on()  { case_major "$FIX/mf-on.json"; }
case_major_off() { case_major "$FIX/mf-off.json"; }
case_route() { R=$(HARNESS_CFG="$FIX/mf-on.json" HARNESS_CFG_PATH="$FIX/mf-on.json" bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; . "$1/driver/driver-env.sh" && . "$1/driver/tier.sh" && driver_screen_route 705' _ "$KIT" 2>/dev/null | cut -f1); }
case_ship() { # a reviewed ticket with one follow-up waiting: what the ship hands follow-up.sh
  N=$((N + 1)); mf_tree "$N"
  driver_state_put "$N" review '{"verdict":"SHIP","findings":[]}'; driver_state_bump "$N" review
  driver_state_set "$N" claimed_at_sha "$(git -C "$REPO" rev-parse develop)"
  for st in start plan build self-check review record; do driver_state_done "$N" "$st"; done
  mkdir -p "$(driver_state_dir "$N")/steps"; printf '%s\n' '{"id":"m1","grade":"major","file":"a.sh","line":3,"summary":"s"}' > "$(fu "$N")"
  : > "$FIX/fu.calls"
  HARNESS_CFG="$FIX/mf-on.json" HARNESS_CFG_PATH="$FIX/mf-on.json" DRIVER_FOLLOW_UP="$FIX/fu" bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; . "$1/driver/driver-env.sh" && . "$1/driver/steps/ship.sh" && driver_step_ship "$2"' _ "$KIT" "$N" >/dev/null 2>&1
  R="calls=$(grep -c '^file ' "$FIX/fu.calls")"
}
kit_copy
case_major_on;  want "the unplanted kit: on, a Major ships as a follow-up" "rc=0 fu=m1" "$R"
case_major_off; want "the unplanted kit: off, a Major blocks"              "rc=30 fu=" "$R"
case_route;     want "the unplanted kit: on, an existing screen is baseline" "baseline" "$R"
case_ship;      want "the unplanted kit: on, the ship files the follow-up"  "calls=1" "$R"
plant() { # <label> <file under the kit> <exact text to delete> <case> <the result the line prevents>
  kit_copy
  python3 -I -c 'import sys; p, l = sys.argv[1], sys.argv[2]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, "", 1)); sys.exit(0 if n == 1 else 1)' "$KIT/$2" "$3" \
    || { want "plant landed: $1" "landed" "missed"; return; }
  "$4"; want "planted ($1): the case now fails" "$5" "$R"
}
plant "only a Critical blocks" driver/driver-env.sh \
  '  if driver_merge_first; then printf '"'"'%s'"'"' "$DRIVER_MERGE_FIRST_GRADES"; return 0; fi' case_major_on "rc=30 fu="
plant "the follow-up record"  driver/steps/review.sh \
  'else _driver_review_follow_up "$t" "$x" "$round" && ' case_major_on "rc=0 fu="
plant "the switch reads the config" scripts/release-checks.sh \
  '  jq -e '"'"'(.release // {}) | type == "object" and .mergeFirst == true and (.done // false) != true'"'"' "$cfg" >/dev/null 2>&1' case_major_off "rc=0 fu=m1"
plant "the baseline route"    driver/size-rules.sh '  { command -v release_merge_first >/dev/null 2>&1 && release_merge_first; } && return 0' case_route "picture"
plant "the ship files them"   driver/steps/ship.sh \
  '  if [ "$mode" = repair ]; then _driver_ship_follow_ups "$t" "$open_pr"; else _driver_ship_follow_ups "$t" "$pr_n"; fi' case_ship "calls=0"
# Under localOnly every push names its head, so the case also reads that gates.local ran on it.
case_lg_kit() { SUT_KIT="$KIT" case_lg "$FIX/lg-off.json"; unset SUT_KIT
  R="$R local=$([ "$(driver_state_get "$N" local_gates_head)" = "$(git -C "$FIX/mf$N" rev-parse HEAD)" ] && echo yes || echo no)"; }
case_fault_kit() { : > "$FIX/hook.fail"; SUT_KIT="$KIT" case_lg "$FIX/lg-on.json"; unset SUT_KIT; rm -f "$FIX/hook.fail"
  R="hooks=$(grep -c . "$FIX/hook.log") fix=$([ -s "$(driver_state_dir "$N")/steps/self-check.findings.json" ] && echo yes || echo no)"; }
case_suite_kit() { # the hook's suite listed in gates.local: R says whether self-check ran it
  N=$((N + 1)); mf_tree "$N"; printf 'echo suite-ran\n' >> "$HOOKS/pre-push"
  HARNESS_CFG="$FIX/suite.json" HARNESS_CFG_PATH="$FIX/suite.json" bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; . "$1/driver/driver-env.sh" && . "$1/driver/steps/self-check.sh" && driver_step_self_check "$2"' _ "$KIT" "$N" >/dev/null 2>&1
  cp "$FIX/pre-push.keep" "$HOOKS/pre-push"
  R="ran=$([ -f "$(driver_state_dir "$N")/steps/gate-local-2.out" ] && echo yes || echo no)"; }
kit_copy
case_lg_kit;    want "the unplanted kit: the push names the merged head, which gates.local passed" "named local=yes" "$R"
case_fault_kit; want "the unplanted kit: a refused hook is retried, then goes to fix" "hooks=2 fix=yes" "$R"
case_suite_kit; want "the unplanted kit: the hook's suite is not run locally" "ran=no" "$R"
plant "gates.local on the pushed head" driver/steps/ship.sh 'driver_step_self_check "$t" || lgrc=$?' case_lg_kit "named local=no"
plant "the hook retry" driver/steps/ship.sh ' || _driver_ship_hook_retry "$t" "$wt" "$branch"' case_fault_kit "hooks=1 fix=yes"
plant "a hook fault goes to fix" driver/steps/ship.sh '    if [ "${DRIVER_SHIP_HOOK_FAULT:-0}" = 1 ] && _driver_ship_push_to_fix "$t"; then
      driver_state_set "$t" park_note ""
      return "$DRIVER_E_REWORK"
    fi
' case_fault_kit "hooks=2 fix=no"
plant "the hook's suite skip" driver/steps/self-check.sh '    if _driver_gate_is_prepush_suite "$wt" "$cmd"; then
      driver_say "   self-check: $name ($cmd) is the pre-push hook'"'"'s own suite — not run here; CI runs it"
      continue
    fi' case_suite_kit "ran=yes"

suite_end "$FAILED"
