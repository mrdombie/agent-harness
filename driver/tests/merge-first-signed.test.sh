#!/usr/bin/env bash
# merge-first-signed.test.sh — release.mergeFirst reaches the signed-off-screens rule of a
# repair already running. A run reads its config when it starts (and a coordinator pins
# a copy), so a repair begun before the switch landed on the trunk still parked a Major
# on a signed-off PR's screens for the owner, and withheld the push. The release block is
# read from the trunk as origin has it now. On: a Major there is a follow-up and the
# review ships (the push guard lets it through); a Critical still blocks and is fixed in
# place. Off: today's behaviour — it parks for the owner.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/review.sh" || exit 1
fix_brief review superpowers:requesting-code-review "Review round {{ROUND}}. The change: {{DIFF}} Renders: {{RENDERS}}"
mkdir -p "$FIX/tmp"; export TMPDIR="$FIX/tmp" HARNESS_RELEASE_FETCH_SECS=0

# The run's own config: the snapshot it took before the switch — screens, no mergeFirst.
jq '.design = {surfacePaths: ["screens/**"]} | .release = {done: false}' "$REPO/.claude/harness.json" > "$FIX/stale.json"
# The trunk, on origin: the same config with the switch as the case sets it.
git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "fixture" >/dev/null 2>&1
git init -q --bare "$FIX/origin"; git -C "$REPO" remote add origin "$FIX/origin"; git -C "$REPO" push -q origin develop
git clone -q -b develop "$FIX/origin" "$FIX/up"
git -C "$FIX/up" config user.email t@example.invalid; git -C "$FIX/up" config user.name Tester
trunk_switch() { # <true|false> — the trunk's release.mergeFirst, pushed to origin
  if [ "$1" = true ]; then
    cat > "$FIX/up/.claude/harness.json" <<'JSON'
{"release": {"mergeFirst": true, "done": false}}
JSON
  else
    cat > "$FIX/up/.claude/harness.json" <<'JSON'
{"release": {"mergeFirst": false, "done": false}}
JSON
  fi
  git -C "$FIX/up" commit -qam "release.mergeFirst $1" && git -C "$FIX/up" push -q origin develop
}

# A repair of PR #88: the PR's screen, and the repair's own commit.
git -C "$REPO" worktree add -q "$FIX/wtr" -b tkt-120/work develop
mkdir -p "$FIX/wtr/screens"; printf 'the PR change\n' > "$FIX/wtr/screens/Home.tsx"; printf 'the PR card\n' > "$FIX/wtr/screens/Card.tsx"
git -C "$FIX/wtr" add . && git -C "$FIX/wtr" commit -qm "feat: the PR"
RB=$(git -C "$FIX/wtr" rev-parse HEAD)
printf 'the repair\n' >> "$FIX/wtr/screens/Home.tsx"; git -C "$FIX/wtr" commit -qam "fix: the repair"
# The owner signed PR #88's screens.
cat > "$BIN/approval-kept" <<SH
#!/usr/bin/env bash
case "\$1" in
  signed-head) echo 1111111111111111111111111111111111111111; exit 0 ;;
  screens) exec bash "$ROOT/scripts/approval-kept.sh" screens ;;
  *) exit 9 ;;
esac
SH
chmod +x "$BIN/approval-kept"; export DRIVER_APPROVAL_KEPT="$BIN/approval-kept"
printf '#!/usr/bin/env bash\ncase "$1" in add) printf "%%s\\n" "$*" >> "$FIX/pl.adds" ;; esac\nexit 0\n' > "$FIX/pl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/sf"; chmod +x "$FIX/pl" "$FIX/sf"
export DRIVER_POLISH_LIST="$FIX/pl" DRIVER_SCREEN_FINDINGS="$FIX/sf"

# On a signed screen the repair did not touch: one in a file it did is fixed in place (same file, same change).
major='{"verdict":"BLOCKED","findings":[{"id":"m1","file":"screens/Card.tsx","line":448,"grade":"major","summary":"the notice stays up after reset","reason":"a person is misled","fix":"clear it"}]}'
critical='{"verdict":"BLOCKED","findings":[{"id":"c1","file":"screens/Home.tsx","line":4,"grade":"critical","summary":"another workspace sees the rows","reason":"wrong data","fix":"scope it"}]}'

N=900
case_signed() { # <kit> <answer> — a repair of the signed PR under the stale snapshot: R is the outcome
  N=$((N + 1))
  driver_state_init "$N" --worktree "$FIX/wtr" --branch tkt-120/work
  driver_state_set "$N" mode repair; driver_state_set "$N" pr 88; driver_state_set "$N" repair_base "$RB"
  fix_issue "$N" OPEN "status:in-review"
  fix_ai review "$2" superpowers:requesting-code-review
  local rc=0
  HARNESS_CFG="$FIX/stale.json" HARNESS_CFG_PATH="$FIX/stale.json" bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; . "$1/driver/driver-env.sh" && . "$1/driver/steps/review.sh" && driver_step_review "$2"' _ "$1" "$N" > "$FIX/out-$N" 2>&1 || rc=$?
  local f; f="$(driver_state_dir "$N")/steps/review.followups.jsonl"
  local owner=no; case "$(driver_state_get "$N" park_note)" in "Needs the owner"*) owner=yes ;; esac
  R="rc=$rc fu=$(jq -r .id "$f" 2>/dev/null | tr '\n' ' ' | sed 's/ $//') owner=$owner"
}
case_major()    { case_signed "${SUT_KIT:-$ROOT}" "$major"; }
case_own()      { case_signed "${SUT_KIT:-$ROOT}" "$(printf '%s' "$major" | sed 's#screens/Card.tsx#screens/Home.tsx#')"; }
case_critical() { case_signed "${SUT_KIT:-$ROOT}" "$critical"; }
case_guard() { # what the pre-push sign-off guard's first line reads, under the run's exported snapshot
  R=$(HARNESS_CFG="$FIX/stale.json" HARNESS_CFG_PATH="$FIX/stale.json" bash -c 'unset KIT_ROOT HARNESS_KIT_ROOT; . "$1/scripts/toolkit-env.sh" >/dev/null 2>&1 && release_merge_first && echo on || echo off' _ "${SUT_KIT:-$ROOT}")
}
case_flip() { # this clone last saw the switch off, then origin turned it on: only a fetch reads it
  trunk_switch false; SUT_KIT="$ROOT" case_guard; trunk_switch true; case_major; }
case_prompt() { case_major; R=$(grep -c 'MERGE FIRST UNTIL THE RELEASE (release.mergeFirst), and this overrides every sign-off line above' "$FIX/claude-stdin-review.txt"); }

echo "--- the switch lands on the trunk after the run took its config ---"
trunk_switch true
case_major
want "on: a Major on signed-off screens is a follow-up and the review ships" "rc=0 fu=m1 owner=no" "$R"
want_in "and the run says it is filed, not held"  'filed as follow-up tickets' "$(cat "$FIX/out-$N")"
want_not_in "it is never parked for the owner"    'parks for the owner' "$(cat "$FIX/out-$N")"
case_critical
want "on: a Critical on signed-off screens still blocks, fixed in place" "rc=30 fu= owner=no" "$R"
case_own
want "on: a Major in the file the repair touched is fixed in place, never held" "rc=30 fu= owner=no" "$R"
case_guard
want "on: the push guard sees the switch, so the push is not withheld" "on" "$R"
case_prompt
want "on: the step is told the sign-off lines do not hold" "1" "$R"

echo "--- off: today's behaviour ---"
trunk_switch false
case_major
want "off: a Major on signed-off screens parks for the owner" "rc=24 fu= owner=yes" "$R"
case_guard
want "off: the push guard holds"                  "off" "$R"
case_prompt
want "off: no merge-first line in the prompt"     "0" "$R"

echo "--- no release block on the trunk: the run's own config decides ---"
cat > "$FIX/up/.claude/harness.json" <<'JSON'
{}
JSON
git -C "$FIX/up" commit -qam "no release block" && git -C "$FIX/up" push -q origin develop
jq '.release = {mergeFirst: true, done: false}' "$FIX/stale.json" > "$FIX/own-on.json"
R=$(HARNESS_CFG="$FIX/own-on.json" HARNESS_CFG_PATH="$FIX/own-on.json" bash -c '. "$1/scripts/toolkit-env.sh" >/dev/null 2>&1 && release_merge_first && echo on || echo off' _ "$ROOT")
want "the run's own switch still counts" "on" "$R"

echo "--- plants: each line out of a copy of the kit, its case fails ---"
trunk_switch true
KIT="$FIX/kit"
kit_copy() { rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$ROOT/driver" "$ROOT/scripts" "$ROOT/swarm" "$ROOT/shared" "$KIT/"; }
plant() { # <label> <file under the kit> <exact text to delete> <case> <the result the line prevents>
  kit_copy
  python3 -I -c 'import sys; p, l = sys.argv[1], sys.argv[2]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, "", 1)); sys.exit(0 if n == 1 else 1)' "$KIT/$2" "$3" \
    || { want "plant landed: $1" "landed" "missed"; return; }
  SUT_KIT="$KIT" "$4"; want "planted ($1): the case now fails" "$5" "$R"
}
kit_copy
SUT_KIT="$KIT" case_major; want "the unplanted kit: on, a Major ships as a follow-up" "rc=0 fu=m1 owner=no" "$R"
plant "the release block is read from the trunk" scripts/release-checks.sh \
  '    blob=$(git -C "$repo" rev-parse --verify -q "refs/remotes/origin/$br:.claude/harness.json" 2>/dev/null)' case_major "rc=24 fu= owner=yes"
plant "the trunk ref is fetched" scripts/release-checks.sh \
  '        git -C "$repo" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=10 fetch -q origin "+refs/heads/$br:refs/remotes/origin/$br" >/dev/null 2>&1 || true' case_flip "rc=24 fu= owner=yes"
plant "only a Critical blocks, signed-off screens too" driver/driver-env.sh \
  '  if driver_merge_first; then printf '"'"'%s'"'"' "$DRIVER_MERGE_FIRST_GRADES"; return 0; fi' case_major "rc=30 fu= owner=no"
plant "the guard reads the trunk" scripts/release-checks.sh \
  '  local cfg; cfg=$(_release_cfg)
' case_guard "off"
plant "the step is told" driver/ai-step.sh \
  '  if driver_merge_first; then printf '"'"'\n---\n%s\n'"'"' "$DRIVER_MERGE_FIRST_SIGNOFF" >> "$prompt"; fi' case_prompt "0"

suite_end "$FAILED"
