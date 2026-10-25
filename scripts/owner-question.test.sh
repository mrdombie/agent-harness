#!/usr/bin/env bash
# owner-question.test.sh — a question from a run with no question tool reaches the
# owner's channel and holds the ticket by its label; the answer, wherever it is
# given, frees it and travels with it. The tick's side (it skips a labelled ticket,
# and syncs answers) is in coordinator-tick.test.sh.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
OQ="$HERE/owner-question.sh"; W="$HERE/needsme-watch.sh"
C="$STATE/coordinator"
cat > "$BIN/notify" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "$FIX/notify.log"
SH
cat > "$BIN/gh-down" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in "issue edit") exit 1 ;; esac
exec "$BIN/gh-labels" "$@"
SH
chmod +x "$BIN/notify" "$BIN/gh-down"
export COORDINATOR_NOTIFY_CMD="$BIN/notify" SWARM_GH="$BIN/gh-labels"
unset COORDINATOR_SHADOW
fresh() { rm -rf "$C"; : > "$GH_LOG"; : > "$FIX/notify.log"; }
labels_of() { jq -r '[.labels[].name] | join(",")' "$FIX/gh/issue-$1.json"; }

echo "--- ask ---"
fresh; fix_issue 41 OPEN "status:claimed"
out=$(bash "$OQ" ask 41 "Fix A or B?" "Fix A (retry) or Fix B (drop the cache)?"); rc=$?
want "it exits 0"                          "0" "$rc"
want "the slug is made a key word"         "asked: decision:41:fix-a-or-b — #41 waits on the answer" "$out"
want_in "it reaches needs-you.md though the coordinator is in shadow" '^- \[ \] .*#41: Fix A \(retry\) or Fix B \(drop the cache\)\? <!-- key:decision:41:fix-a-or-b -->$' "$(cat "$C/needs-you.md")"
want "and pings the owner"                 "#41: Fix A (retry) or Fix B (drop the cache)?" "$(cat "$FIX/notify.log")"
want_in "the label exists before it is added" '^label create needs:owner-decision ' "$(cat "$GH_LOG")"
want "the ticket wears the label"          "needs:owner-decision,status:claimed" "$(labels_of 41)"
want_in "the question is on the ticket"    '^issue comment 41 .*Waiting on the owner' "$(cat "$GH_LOG")"
want "waiting reads the label"             "needs:owner-decision" "$(bash "$OQ" waiting 41)"
bash "$OQ" ask 41 "Fix A or B?" "Fix A (retry) or Fix B (drop the cache)?" >/dev/null
want "asked again while open: one line, not two" "1" "$(grep -c 'key:decision:41:' "$C/needs-you.md")"
fresh; fix_issue 45 OPEN ""
err=$(SWARM_GH="$BIN/gh-down" bash "$OQ" ask 45 pick "Q?" 2>&1 >/dev/null); rc=$?
want "a label that could not be added: exit 1" "1" "$rc"
want_in "and says nothing was asked"       'could not label #45 .*nothing asked' "$err"
want "and no line, which would read as answered" "" "$(cat "$C/needs-you.md" 2>/dev/null)"
fresh; fix_issue 42 OPEN ""
jq '.labels.ownerDecision = "waiting:owner"' "$HARNESS_CFG_PATH" > "$FIX/h.json" && cp "$FIX/h.json" "$HARNESS_CFG_PATH"
bash "$OQ" ask 42 pick "One or two?" >/dev/null
want "labels.ownerDecision names the label" "waiting:owner" "$(labels_of 42)"
jq 'del(.labels.ownerDecision)' "$HARNESS_CFG_PATH" > "$FIX/h.json" && cp "$FIX/h.json" "$HARNESS_CFG_PATH"
want "a question is required"              "2" "$(bash "$OQ" ask 41 x "" >/dev/null 2>&1; echo $?)"
want "a ticket number is required"         "2" "$(bash "$OQ" ask abc x "q" >/dev/null 2>&1; echo $?)"

echo "--- answer ---"
fresh; fix_issue 41 OPEN "status:ready"; bash "$OQ" ask 41 pick "Fix A or Fix B?" >/dev/null; : > "$GH_LOG"
out=$(bash "$W" answer decision:41:pick $'Fix B,\nplease'); rc=$?
want "it exits 0"                          "0" "$rc"
want "the label comes off"                 "status:ready" "$(labels_of 41)"
want_in "the answer is on the ticket, on one line" '^issue comment 41 .*The owner answered.*: Fix B, please$' "$(cat "$GH_LOG")"
want "back on the queue, new, at the front" "41 new" "$(jq -r '.tickets[0] | "\(.n) \(.class)"' "$C/queue.json")"
want_in "the note carries the answer"      'Fix B, please' "$(jq -r '.tickets[0].note' "$C/queue.json")"
want_in "the answer is logged"             $'\tdecision:41:pick\tFix B, please$' "$(cat "$C/answers.tsv")"
want "nothing left pending"                "" "$(cat "$C/answers.pending" 2>/dev/null)"
want "the line is ticked"                  "1" "$(grep -c '^- \[x\] .*key:decision:41:pick' "$C/needs-you.md")"
want "no longer waiting"                   "" "$(bash "$OQ" waiting 41)"
bash "$OQ" ask 41 pick "And now?" >/dev/null
want_in "asked again after an answer: a fresh key" 'key:decision:41:pick-2 -->' "$(grep '^- \[ \]' "$C/needs-you.md")"

fresh; fix_issue 43 OPEN ""; bash "$OQ" ask 43 pick "Q?" >/dev/null
printf '[{"number":9}]\n' > "$FIX/gh/prs-tkt-43.json"
bash "$OQ" answer decision:43:pick "yes" >/dev/null
want "a ticket with an open PR goes back as repair" "repair" "$(jq -r '.tickets[] | select(.n == 43) | .class' "$C/queue.json")"
# A draft PR a build PARKED with is not a repair: the driver's own record says the build
# is unfinished, and a repair would skip its remaining steps and ship it.
fresh; fix_issue 91 OPEN ""; bash "$OQ" ask 91 pick "Q?" >/dev/null
printf '[{"number":10}]\n' > "$FIX/gh/prs-tkt-91.json"
mkdir -p "$STATE/driver/91"; printf '{"ticket":"91","mode":"build","done":["start","plan","build","fix"]}\n' > "$STATE/driver/91/state.json"
bash "$OQ" answer decision:91:pick "yes" >/dev/null
want "an unshipped driver build goes back as new, PR or no PR" "new" "$(jq -r '.tickets[] | select(.n == 91) | .class' "$C/queue.json")"
fresh; fix_issue 92 OPEN ""; bash "$OQ" ask 92 pick "Q?" >/dev/null
printf '[{"number":11}]\n' > "$FIX/gh/prs-tkt-92.json"
mkdir -p "$STATE/driver/92"; printf '{"ticket":"92","mode":"build","done":["start","plan","build","fix","compare","self-check","review","record","ship"]}\n' > "$STATE/driver/92/state.json"
bash "$OQ" answer decision:92:pick "yes" >/dev/null
want "a SHIPPED build with an open PR still goes back as repair" "repair" "$(jq -r '.tickets[] | select(.n == 92) | .class' "$C/queue.json")"
want "a key that is not a decision is refused" "2" "$(bash "$OQ" answer blind:x "y" >/dev/null 2>&1; echo $?)"

echo "--- a failed answer stays pending, and the next sync lands it ---"
fresh; fix_issue 44 OPEN ""; bash "$OQ" ask 44 pick "Q?" >/dev/null
err=$(SWARM_GH="$BIN/gh-down" bash "$W" answer decision:44:pick "no" 2>&1 >/dev/null); rc=$?
want "a failed label change exits 1"       "1" "$rc"
want_in "and names it"                     'could not take needs:owner-decision off #44' "$err"
want_in "the answer is pending"            $'^decision:44:pick\tno$' "$(cat "$C/answers.pending")"
want_in "the line stays open"              '^- \[ \] .*key:decision:44:pick' "$(cat "$C/needs-you.md")"
want "nothing was requeued"                "" "$(jq -r '.tickets[]?.n' "$C/queue.json" 2>/dev/null)"
want "the owner is not asked again"        "" "$(bash "$W" pending --no-forge | cut -f1)"
bash "$OQ" sync >/dev/null
want "sync lands it: the label is off"     "" "$(labels_of 44)"
want_in "requeued with the answer"         'answered decision:44:pick: no' "$(jq -r '.tickets[0].note' "$C/queue.json")"
want "the line is ticked"                  "1" "$(grep -c '^- \[x\] .*key:decision:44:pick' "$C/needs-you.md")"
want "nothing left pending"                "" "$(cat "$C/answers.pending")"

echo "--- an answer given on the ticket, or by the board walk, frees it too ---"
fresh; fix_issue 46 OPEN ""; fix_issue 47 OPEN ""; fix_issue 48 CLOSED ""
for t in 46 47 48; do bash "$OQ" ask "$t" pick "Q $t?" >/dev/null; done
fix_issue 46 OPEN "status:ready"; fix_issue 48 CLOSED ""
out=$(bash "$OQ" sync)
want_in "the label taken off on GitHub reads as answered" '^answered elsewhere: decision:46:pick — #46 back on the queue \(new\)$' "$out"
want "one still labelled is left waiting"  "1" "$(grep -c '^- \[ \] .*key:decision:47:pick' "$C/needs-you.md")"
want "a closed ticket is ticked, not requeued" "46" "$(jq -r '[.tickets[].n] | join(" ")' "$C/queue.json")"
want "its line is ticked"                  "1" "$(grep -c '^- \[x\] .*key:decision:48:pick' "$C/needs-you.md")"
fix_issue 47 OPEN ""
want "the watcher's board pass runs the sync first" "" "$(bash "$W" pending | cut -f1 | grep -x 'decision:47:pick')"
want "and the line is ticked"              "1" "$(grep -c '^- \[x\] .*key:decision:47:pick' "$C/needs-you.md")"

echo "--- the claim skill: a question never carries the sign-off hold ---"
SKILL="$HERE/../skills/claim/SKILL.md"
step=$(awk '/^\*\*Ask the owner — from a spawned run\.\*\*/{f=1} f&&/^## /{exit} f' "$SKILL" | sed -n '1,/^3\. End with/p')
want_in "the step is there"                'owner-question\.sh" ask' "$step"
want_in "it parks without the hold"        'never add `\$HOLD_LABEL`' "$step"
want_not_in "it never tells the builder to add the hold" 'add-label "\$HOLD_LABEL"' "$step"

echo "--- merge first: an Evidence capture develop does not require is nobody's question (#14601) ---"
cp "$HARNESS_CFG_PATH" "$FIX/h.bak"
jq '.release = {mergeFirst: true, done: false}' "$FIX/h.bak" > "$HARNESS_CFG_PATH"
Q14601="Evidence capture can't push: the EVIDENCE_DEPLOY_KEY push gets 'Repository not found' (PR #14722). Re-add the deploy key with write access, or say how evidence should be pinned instead?"
ev_ask() { # <kit> — R: exit and the label
  fresh; fix_issue 51 OPEN "status:in-review"
  bash "$1/scripts/owner-question.sh" ask 51 evidence-key "$Q14601" >/dev/null 2>&1; R="rc=$? labels=$(labels_of 51)"
}
fix_required "Typecheck + Unit tests"
ev_ask "$HERE/.."
want "not required: refused, nothing labelled" "rc=5 labels=status:in-review" "$R"
want "and nothing reaches the owner"         "" "$(cat "$C/needs-you.md" 2>/dev/null)"
fix_required "Typecheck + Unit tests" "Capture and pin the evidence"
ev_ask "$HERE/.."
want "required: it is asked, as before"      "rc=0 labels=needs:owner-decision,status:in-review" "$R"
fix_required "Typecheck + Unit tests"
EVK="$FIX/evkit"; rm -rf "$EVK"; mkdir -p "$EVK"; cp -R "$HERE/../scripts" "$HERE/../swarm" "$HERE/../driver" "$HERE/../shared" "$EVK/" 2>/dev/null
python3 -I -c 'import sys; p = sys.argv[1]; s = open(p).read(); o = "&& release_evidence_waived; then"; n = s.count(o); open(p, "w").write(s.replace(o, "&& false; then")); sys.exit(0 if n == 1 else 1)' "$EVK/scripts/owner-question.sh" \
  && { ev_ask "$EVK"; want "planted (no waiver): #14601's question reaches the owner again" "rc=0 labels=needs:owner-decision,status:in-review" "$R"; } || bad "plant: the waiver did not land"
jq '.release = {mergeFirst: false, done: false}' "$FIX/h.bak" > "$HARNESS_CFG_PATH"
ev_ask "$HERE/.."
want "merge first off: it is asked, as before" "rc=0 labels=needs:owner-decision,status:in-review" "$R"
cp "$FIX/h.bak" "$HARNESS_CFG_PATH"

suite_end "$FAILED"
