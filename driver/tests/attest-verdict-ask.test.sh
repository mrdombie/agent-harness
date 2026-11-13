#!/usr/bin/env bash
# attest-verdict-ask.test.sh — a pre-push reviewer that answers with its findings and
# no verdict line is asked for that line once, in the session that reviewed, before the
# recorder reads anything.
#
# The recorder reads only the verdict line, so a review without one was thrown away and
# the build parked on "the recorder refused it": two parks measured on 2026-11-12, each
# a whole review paid for and discarded, the finished work waiting on a full re-run.
#
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../ai-step.sh" || exit 1
. "$HERE/../push-requires.sh" || exit 1

# Stands in for the project's recorder: the first verdict line, SHIP or refused. Counted.
cat > "$FIX/recorder" <<SH
#!/usr/bin/env sh
echo x >> "$FIX/recorder.calls"
printf '%s\n' "\$*" >> "$FIX/recorder.args"
v=\$(grep -oE 'VERDICT:[[:space:]]*\\**(SHIP|SPIT-BACK)' | head -1 | sed -E 's/.*(SHIP|SPIT-BACK).*/\\1/')
[ -n "\$v" ] || { echo "record-verdict: no 'VERDICT: …' line in the reviewer's output." >&2; exit 1; }
[ "\$v" = "SHIP" ] || { echo "record-verdict: the reviewer said \$v, not SHIP. Refusing to record it." >&2; exit 1; }
git commit --allow-empty --no-verify -q -m "chore: gate" -m "Gate: SHIP (agent)"
echo "recorded"
SH
cat > "$FIX/owed" <<'SH'
#!/usr/bin/env sh
git log -1 --format=%B | grep -q 'Gate: SHIP' && { echo "✓ attested"; exit 0; }
echo "✗ check:ui-gate-attested — no matching verdict."; exit 1
SH
chmod +x "$FIX/recorder" "$FIX/owed"
row() { # <jq object for the ui-gate row>
  jq --arg w "$FIX/recorder" --arg o "$FIX/owed" --arg r "$FIX/reviewer" ".review = {\"attest\":{\"ui-gate\":$1}}" \
    "$HARNESS_CFG_PATH" > "$FIX/cfg.tmp" && cat "$FIX/cfg.tmp" > "$HARNESS_CFG_PATH"
  git -C "$REPO" add -A && git -C "$REPO" commit -qm "the ui-gate row" >/dev/null
}
row '{"owed":$o,"agent":"agent-harness:frontend-gate","record":$w}'

FINDINGS='The Save button is wired and the list scrolls.

**Major (0):** none.

**Minor (0):** none.'

# said <file> <text> [session-id] — a reviewer transcript ending on <text>.
said() {
  jq -nc --arg s "${3:-}" '{type:"assistant", message:{content:[{type:"text", text:"reviewing"}]}} + (if $s == "" then {} else {session_id: $s} end)' > "$1"
  jq -nc --arg r "$2" --arg s "${3:-}" '{type:"result", subtype:"success", is_error:false, result:$r, total_cost_usd:0.2, num_turns:2}
                                        + (if $s == "" then {} else {session_id: $s} end)' >> "$1"
}
A="$FIX/ai/attest-ui-gate.jsonl"; V="$FIX/ai/attest-ui-gate-verdict.jsonl"
# tkt <n> — a fresh ticket on its own branch, with a commit for the reviewer to judge.
tkt() {
  fix_issue "$1" OPEN "status:claimed"
  git -C "$REPO" worktree add -q "$FIX/wt$1" -b "tkt-$1/work" develop
  git -C "$FIX/wt$1" config user.email t@e.invalid; git -C "$FIX/wt$1" config user.name T
  printf 'x\n' > "$FIX/wt$1/thing.txt"
  git -C "$FIX/wt$1" add -A && git -C "$FIX/wt$1" commit -qm "feat: thing"
  driver_state_init "$1" --worktree "$FIX/wt$1" --branch "tkt-$1/work"
  : > "$CLAUDE_LOG"; : > "$FIX/recorder.calls"; : > "$FIX/recorder.args"; rm -f "$A" "$V" "$FIX"/claude-args-attest-* "$FIX"/claude-stdin-attest-*
}
trailer() { git -C "$FIX/wt$1" log -1 --format=%B | grep -c 'Gate: SHIP'; }
asks() { grep -cx 'attest-ui-gate-verdict' "$CLAUDE_LOG"; }
reviews() { grep -cx 'attest-ui-gate' "$CLAUDE_LOG"; }
recorded() { wc -l < "$FIX/recorder.calls" | tr -d ' '; }
verdict_file() { cat "$(driver_state_dir "$1")/steps/verdict-ui-gate.txt"; }

echo "--- findings and no verdict line: asked once in the same session, and the SHIP it gives is recorded ---"
tkt 601
said "$A" "$FINDINGS" sess-601; said "$V" 'VERDICT: SHIP' sess-601
rc=0; out=$(driver_push_requires 601 2>&1) || rc=$?
want "the push requirement is met, not parked" "0" "$rc"
want "the gate's trailer is on the branch" "1" "$(trailer 601)"
want "the reviewer reviewed once" "1" "$(reviews)"
want "and was asked once more" "1" "$(asks)"
args=$(cat "$FIX/claude-args-attest-ui-gate-verdict.txt")
want_in "the ask resumes a session" '^--resume$' "$args"
want_in "the one that reviewed" '^sess-601$' "$args"
want_in "as the same reviewer" '^agent-harness:frontend-gate$' "$args"
ask=$(cat "$FIX/claude-stdin-attest-ui-gate-verdict.txt")
want_in "it asks for the verdict line" 'exactly one line' "$ask"
want_in "and for no second review" 'Do not review again' "$ask"
want_not_in "it is handed no diff to review" '```diff' "$ask"
want "the recorder reads the reviewer's line, then the findings it gave" "VERDICT: SHIP

$FINDINGS" "$(verdict_file 601)"
want_in "the run says it asked" "no VERDICT line — asking it once, in the same session" "$out"
want "the ask's spend is on the record" "0.2" "$(jq -r '.usage["attest-ui-gate-verdict"][0].cost' "$(driver_state_dir 601)/state.json")"
want_in "it ran as a driver step, so the Stop hooks stand down" "601:attest-ui-gate" "$(grep '^attest-ui-gate-verdict' "$FIX/claude-env.log" | tail -1)"

echo "--- asked, it says SPIT-BACK: never recorded as a pass ---"
tkt 602
said "$A" "$FINDINGS" sess-602; said "$V" '**VERDICT: SPIT-BACK** — the list does not scroll.' sess-602
rc=0; out=$(driver_push_requires 602 2>&1) || rc=$?
want "the requirement is refused" "$DRIVER_E_REFUSED" "$rc"
want "no trailer is written" "0" "$(trailer 602)"
want_in "in the recorder's own words" 'the reviewer said SPIT-BACK, not SHIP' "$out"
want "asked once" "1" "$(asks)"

echo "--- asked, and still no verdict line: parks as the reviewer's, after exactly one ask ---"
tkt 603
said "$A" "$FINDINGS" sess-603; said "$V" 'I think it is fine overall.' sess-603
rc=0; out=$(driver_push_requires 603 2>&1) || rc=$?
want "the requirement is refused" "$DRIVER_E_REFUSED" "$rc"
want "asked once, not in a loop" "1" "$(asks)"
want "reviewed once: no second review" "1" "$(reviews)"
want "the recorder is never handed an answer with no verdict" "0" "$(recorded)"
want "no trailer is written" "0" "$(trailer 603)"
want_in "the park says what happened" 'asked once more, in the same session, for that line alone and still gave none' "$(driver_state_get 603 park_note)"
want "the findings are kept as the reviewer gave them" "$FINDINGS" "$(verdict_file 603)"

echo "--- an answer that leads with its verdict is not asked again ---"
tkt 604
said "$A" "VERDICT: SHIP — nothing blocks.

$FINDINGS" sess-604; said "$V" 'VERDICT: SPIT-BACK' sess-604
rc=0; out=$(driver_push_requires 604 2>&1) || rc=$?
want "recorded" "0" "$rc"
want "with no second call" "0" "$(asks)"
want "and the answer handed on untouched" "VERDICT: SHIP — nothing blocks.

$FINDINGS" "$(verdict_file 604)"

echo "--- the recorder is handed the commit the driver gave the reviewer, never asked of the reviewer ---"
row '{"owed":$o,"agent":"agent-harness:frontend-gate","record":($w + " --sha {{SHA}}")}'
tkt 607
HEAD607=$(git -C "$FIX/wt607" rev-parse HEAD)
said "$A" "$FINDINGS" sess-607; said "$V" 'VERDICT: SHIP' sess-607
rc=0; out=$(driver_push_requires 607 2>&1) || rc=$?
want "recorded" "0" "$rc"
want "against the commit the reviewer was run on" "--sha $HEAD607" "$(cat "$FIX/recorder.args")"
want_not_in "the reviewer is not asked to echo a commit" 'commit' "$(cat "$FIX/claude-stdin-attest-ui-gate-verdict.txt")"
row '{"owed":$o,"agent":"agent-harness:frontend-gate","record":$w}'

echo "--- a session that left no id cannot be asked: parks, with no call ---"
tkt 605
said "$A" "$FINDINGS"; said "$V" 'VERDICT: SHIP' sess-605
rc=0; out=$(driver_push_requires 605 2>&1) || rc=$?
want "refused" "$DRIVER_E_REFUSED" "$rc"
want "no ask was made" "0" "$(asks)"
want "nothing recorded" "0" "$(trailer 605)"

echo "--- a project's own review command has no session to ask: the recorder decides, as before ---"
printf '#!/usr/bin/env sh\nprintf "%%s\\n" "no verdict here"\n' > "$FIX/reviewer"; chmod +x "$FIX/reviewer"
row '{"owed":$o,"review":$r,"record":$w}'
tkt 606
rc=0; out=$(driver_push_requires 606 2>&1) || rc=$?
want "refused" "$DRIVER_E_REFUSED" "$rc"
want "by the recorder" "1" "$(recorded)"
want "with no model call at all" "" "$(cat "$CLAUDE_LOG")"

suite_end "$FAILED"
