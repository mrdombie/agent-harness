#!/usr/bin/env bash
# attest-spitback.test.sh — a pre-push reviewer's SPIT-BACK is findings for the fix
# round, graded like a review's own, never a terminal stop.
#
# Eight Maktura tickets parked on "the reviewer said SPIT-BACK, not SHIP" from
# 2026-10-20: #13044 on one Minor tagged `auto-fixable: no` in review round 2, and
# #13362, #13460, #13461 on Minors alone in round 2, where a Minor does not block.
#
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
fix_real_briefs
. "$HERE/../ai-step.sh" || exit 1
. "$HERE/../push-requires.sh" || exit 1
. "$HERE/../steps/review.sh" || exit 1

cat > "$FIX/sf" <<'SH'
#!/usr/bin/env bash
echo inbox
SH
cat > "$FIX/pl" <<SH
#!/usr/bin/env bash
case "\$1" in add) printf '%s\n' "\$*" >> "$FIX/pl.adds" ;; esac
exit 0
SH
chmod +x "$FIX/sf" "$FIX/pl"; : > "$FIX/pl.adds"
export DRIVER_SCREEN_FINDINGS="$FIX/sf" DRIVER_POLISH_LIST="$FIX/pl"

# The reviewer answers what $FIX/answer holds; once the driver has told it what this
# round deferred, it answers $FIX/answer.deferred when that exists. Every call is counted.
cat > "$FIX/reviewer" <<SH
#!/usr/bin/env sh
echo x >> "$FIX/reviewer.calls"
printf '%s\n' "\${DRIVER_ATTEST_ROUND:-unset} \${DRIVER_ATTEST_BLOCKING:-unset}" >> "$FIX/reviewer.env"
if [ -s "\${DRIVER_ATTEST_DEFERRED:-/nonexistent}" ] && [ -f "$FIX/answer.deferred" ]; then cat "$FIX/answer.deferred"; else cat "$FIX/answer"; fi
SH
# Stands in for scripts/record-verdict.sh: the reviewer's first VERDICT line, SHIP or refused.
cat > "$FIX/recorder" <<'SH'
#!/usr/bin/env sh
v=$(grep -oE 'VERDICT:[[:space:]]*\**(SHIP|SPIT-BACK)' | head -1 | sed -E 's/.*(SHIP|SPIT-BACK).*/\1/')
[ "$v" = "SHIP" ] || { echo "record-verdict: the reviewer said $v, not SHIP. Refusing to record it." >&2; exit 1; }
git commit --allow-empty --no-verify -q -m "chore: gate" -m "Gate: SHIP (agent)"
echo "recorded"
SH
cat > "$FIX/owed" <<'SH'
#!/usr/bin/env sh
git log -1 --format=%B | grep -q 'Gate: SHIP' && { echo "✓ attested"; exit 0; }
echo "✗ check:ui-gate-attested — no matching verdict."; exit 1
SH
chmod +x "$FIX/reviewer" "$FIX/recorder" "$FIX/owed"
jq --arg r "$FIX/reviewer" --arg w "$FIX/recorder" --arg o "$FIX/owed" \
   '.review = {"attest":{"ui-gate":{"owed":$o,"review":$r,"record":$w}}}' \
   "$HARNESS_CFG_PATH" > "$FIX/cfg.tmp" && cat "$FIX/cfg.tmp" > "$HARNESS_CFG_PATH"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "a project whose pre-push wants a ui-gate verdict"

SHIP_REVIEW='{"step":"review","skills":["superpowers:requesting-code-review"],"status":"reviewed","round":1,"verdict":"SHIP","findings":[]}'
MAJOR='VERDICT: SPIT-BACK — the Save button calls nothing.

**Critical (0):** none.

**Major (1):**
- `screens/Inbox.tsx:42` · "Save" · a person saves and nothing is kept · dead control · wire it to saveDraft · `auto-fixable: no`

**Minor (0):** none.

**Nit (1):**
- `screens/Inbox.tsx:9` · prefers a shorter prop name'
MINOR='VERDICT: SPIT-BACK. There is one Minor finding.

## 🔴 Critical (0)

None.

## 🔴 Major (0)

None.

## 🟡 Minor (1)

| Field | Detail |
|---|---|
| **Where** | `screens/Inbox.tsx:77` |
| What is wrong | the footer link stays hidden once every library is added |
| auto-fixable | **no** |'
SHIP='VERDICT: SHIP — nothing in this change blocks.'

# tkt <n> — a fresh ticket on its own branch, with a commit for the reviewer to judge.
tkt() {
  fix_issue "$1" OPEN "status:claimed,screen:inbox"
  git -C "$REPO" worktree add -q "$FIX/wt$1" -b "tkt-$1/work" develop
  git -C "$FIX/wt$1" config user.email t@e.invalid; git -C "$FIX/wt$1" config user.name T
  mkdir -p "$FIX/wt$1/screens"; printf 'x\n' > "$FIX/wt$1/screens/Inbox.tsx"
  git -C "$FIX/wt$1" add -A && git -C "$FIX/wt$1" commit -qm "feat: inbox"
  driver_state_init "$1" --worktree "$FIX/wt$1" --branch "tkt-$1/work"
  : > "$FIX/reviewer.calls"; : > "$FIX/reviewer.env"; : > "$FIX/pl.adds"; rm -f "$FIX/answer.deferred"
}
trailer() { git -C "$FIX/wt$1" log -1 --format=%B | grep -c 'Gate: SHIP'; }
calls() { wc -l < "$FIX/reviewer.calls" | tr -d ' '; }

echo "--- round 1: a SPIT-BACK with one Major goes to fix, then the gate's SHIP is recorded ---"
tkt 501
printf '%s\n' "$MAJOR" > "$FIX/answer"
fix_ai review "$SHIP_REVIEW" superpowers:requesting-code-review
rc=0; out=$(driver_step_review 501 2>&1) || rc=$?
want "the SPIT-BACK sends it back to fix" "$DRIVER_E_REWORK" "$rc"
want "its Major is on the review record at its grade, with its file and line" "major screens/Inbox.tsx 42" \
  "$(jq -r '[.findings[] | select(.id | startswith("attest-ui-gate")) | "\(.grade) \(.file) \(.line)"] | join(",")' "$(driver_state_dir 501)/steps/review.json")"
want "and it blocks" "1" "$(_driver_count "$(driver_state_dir 501)/steps/review.json" blocking)"
want "the Nit is dropped, not sent to fix" "0" "$(jq '[.findings[] | select(.grade == "nit")] | length' "$(driver_state_dir 501)/steps/review.json")"
want "'auto-fixable: no' does not park it" "" "$(driver_state_get 501 park_note)"
want "nothing was recorded" "0" "$(trailer 501)"
want_in "the gate was told round 1 blocks on Critical, Major and Minor" '^1 critical major minor$' "$(cat "$FIX/reviewer.env")"
# The fix round: a commit, and the gate passes it.
printf 'wired\n' >> "$FIX/wt501/screens/Inbox.tsx"; git -C "$FIX/wt501" commit -qam "fix: wire Save"
printf '%s\n' "$SHIP" > "$FIX/answer"
fix_ai review "$SHIP_REVIEW" superpowers:requesting-code-review
rc=0; out=$(driver_step_review 501 2>&1) || rc=$?
want "after the fix the review passes" "0" "$rc"
want "and the gate's own SHIP is recorded on the head" "1" "$(trailer 501)"

echo "--- round 2: a SPIT-BACK on a Minor alone defers it, and the gate's SHIP is recorded ---"
tkt 502; driver_state_bump 502 review
printf '%s\n' "$MINOR" > "$FIX/answer"; printf '%s\n' "$SHIP" > "$FIX/answer.deferred"
fix_ai review "$SHIP_REVIEW" superpowers:requesting-code-review
rc=0; out=$(driver_step_review 502 2>&1) || rc=$?
want "it does not park or go back" "0" "$rc"
want_in "the gate was told round 2 blocks on Critical and Major" '^2 critical major$' "$(head -1 "$FIX/reviewer.env")"
want_in "the Minor goes on the screen's polish list" '^add inbox \[Minor\] ui-gate: the footer link stays hidden once every library is added — screens/Inbox.tsx:77' "$(cat "$FIX/pl.adds")"
want "and leaves the findings" "0" "$(jq '[.findings[] | select(.grade == "minor")] | length' "$(driver_state_dir 502)/steps/review.json")"
want "the gate ran again with the deferral stated" "2" "$(calls)"
want "and its SHIP is recorded" "1" "$(trailer 502)"
want_in "the deferral is said" 'nothing that blocks in review round 2' "$out"

echo "--- round 2: a gate that insists on SPIT-BACK over a deferred Minor is never recorded ---"
tkt 503; driver_state_bump 503 review
printf '%s\n' "$MINOR" > "$FIX/answer"
fix_ai review "$SHIP_REVIEW" superpowers:requesting-code-review
rc=0; out=$(driver_step_review 503 2>&1) || rc=$?
want "it refuses" "$DRIVER_E_REFUSED" "$rc"
want "after one run again, not a loop" "2" "$(calls)"
want "the Minor went on the list once" "1" "$(grep -c '^add inbox' "$FIX/pl.adds")"
want "and nothing was recorded" "0" "$(trailer 503)"

echo "--- past the round limit, a blocking SPIT-BACK parks as before ---"
tkt 504; driver_state_bump 504 review; driver_state_bump 504 review
printf '%s\n' "$MAJOR" > "$FIX/answer"
fix_ai review "$SHIP_REVIEW" superpowers:requesting-code-review
rc=0; out=$(driver_step_review 504 2>&1) || rc=$?
want "it parks" "$DRIVER_E_REFUSED" "$rc"
want_in "saying the rounds are spent" 'review round\(s\) are spent' "$out"
want_in "carrying the recorder's own words" 'said SPIT-BACK, not SHIP' "$(driver_state_get 504 park_note)"
want "and nothing was recorded" "0" "$(trailer 504)"

echo "--- an agent reviewer is told the round's rule and what was deferred ---"
tkt 505; driver_state_bump 505 review; driver_state_bump 505 review
export DRIVER_ATTEST_ROUND=2 DRIVER_ATTEST_GROUND=2
printf -- '- [minor] screens/Inbox.tsx:77 — the footer link stays hidden\n' > "$(_driver_attest_deferred_file 505 ui-gate)"
fix_ai attest-ui-gate "$SHIP"
_driver_attest_agent 505 ui-gate agent-harness:frontend-gate "$FIX/wt505" develop "$FIX/attest-out.txt" >/dev/null 2>&1
sent=$(cat "$FIX/claude-stdin-attest-ui-gate.txt")
want_in "the prompt names the round" 'This is review round 2' "$sent"
want_in "and that only Critical and Major block in it" 'only critical, major findings block' "$sent"
want_in "and lists what was deferred" 'footer link stays hidden' "$sent"
unset DRIVER_ATTEST_ROUND DRIVER_ATTEST_GROUND

exit "$FAILED"
