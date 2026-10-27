#!/usr/bin/env bash
# release-batch-children.test.sh — a batch's held child goes back to ready once its
# batch is closed by any route, and stays held while the batch is open.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
S="$HERE/release-batch-children.sh"
cat > "$BIN/queue" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FIX/queue.log"
SH
chmod +x "$BIN/queue"; export RELEASE_BATCH_QUEUE="$BIN/queue"
child() { # <n> <body> <comment…> — an open child held as batched
  local n="$1" b="$2"; shift 2
  jq -n --argjson n "$n" --arg b "$b" '{number:$n, state:"OPEN", title:"Ticket \($n)", labels:[{name:"status:batched"},{name:"P1"}], body:$b,
    comments:[$ARGS.positional[] | {body:.}]}' --args "$@" > "$FIX/gh/issue-$n.json"
}
listing() { # <n…>
  local f; for f in "$@"; do cat "$FIX/gh/issue-$f.json"; done | jq -s '[.[] | {number, body, comments}]' > "$FIX/gh/issue-list-status:batched.json"
}
batch() { jq -n --argjson n "$1" --arg s "$2" --arg r "${3:-}" '{number:$n, state:$s, stateReason:$r, title:"Batch", labels:[]}' > "$FIX/gh/issue-$1.json"; }
run() { : > "$FIX/queue.log"; : > "$GH_LOG"; bash "$S" "$@" 2>&1; }
log() { tr '\n' ' ' < "$GH_LOG"; }

echo "--- a batch closed without a merge strands nobody ---"
# The Voices batch was closed not planned with seven children still batched.
child 13184 "spec" "Built in batch #13468. One PR builds this with the other fixes on the same screen; it is not picked on its own (status:batched)."
child 12598 "spec" "Built in batch #13468."
child 2001 "spec" "Built in batch #3000."
listing 13184 12598 2001
batch 13468 CLOSED NOT_PLANNED; batch 3000 OPEN
out=$(run)
want_in "the closed batch's child is released"     '^released #13184 — batch #13468 is closed$' "$out"
want_in "  and its sibling"                         '^released #12598 — batch #13468 is closed$' "$out"
want_in "  relabelled ready, batched dropped"       'issue edit 13184 .*--remove-label status:batched.*--add-label status:ready|issue edit 13184 .*--add-label status:ready.*--remove-label status:batched' "$(log)"
want_in "  told why"                                'issue comment 13184 .*Released from its batch.*batch #13468 is closed' "$(log)"
want_in "  queued first at its priority"           'add 13184 --first' "$(cat "$FIX/queue.log")"
want_not_in "an open batch's child stays held"     '#2001' "$out"
want "  untouched"                                  "0" "$(grep -c '2001' "$GH_LOG")"

echo "--- merged in full, closed by hand, or never named: all released ---"
child 2101 "spec" "Built in batch #3100."; batch 3100 CLOSED COMPLETED
child 2102 "Part of the batch ticket #3200's run." ; batch 3200 CLOSED COMPLETED
child 2103 "spec, with no batch anywhere"
child 2104 "spec" "Built in batch #3999."; rm -f "$FIX/gh/issue-3999.json"
listing 2101 2102 2103 2104
out=$(run)
want_in "a batch merged in full"        '^released #2101 — batch #3100 is closed$' "$out"
want_in "read from the body too"        '^released #2102 — batch #3200 is closed$' "$out"
want_in "a child naming no batch"       '^released #2103 — it names no batch$' "$out"
want_in "a batch that cannot be found"  '^released #2104 — batch #3999 could not be found$' "$out"

echo "--- the newest mention decides: moved into a batch that is still open ---"
child 2201 "spec" "Built in batch #3300." "Moved: built in batch #3301 now."
batch 3300 CLOSED NOT_PLANNED; batch 3301 OPEN
listing 2201
want "held while the newer batch is open" "" "$(run)"

echo "--- --check is the guard: it names the stranded and fails, and flags nothing correct ---"
child 2301 "spec" "Built in batch #3400."; batch 3400 CLOSED NOT_PLANNED
listing 2301 2001
out=$(run --check); rc=$?
want "a stranded child fails the check"   "1" "$rc"
want_in "  naming it"                      '^stranded: #2301 — batch #3400 is closed, so nothing builds it$' "$out"
want "  and changes nothing"               "0" "$(grep -cE 'issue (edit|comment|close)' "$GH_LOG")"
listing 2001
out=$(run --check); rc=$?
want "a child of an open batch passes"    "0 " "$rc $out"

echo "--- --dry-run says, and does nothing ---"
listing 2301
out=$(run --dry-run)
want_in "it says what it would do"         '^would release #2301 to status:ready — batch #3400 is closed$' "$out"
want "  and writes nothing"                "0" "$(grep -cE 'issue (edit|comment|close)' "$GH_LOG")"

echo "--- a read that fails releases nothing ---"
listing 2301; rm -f "$FIX/gh/issue-3400.json"
cat > "$BIN/gh-fail" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = "api graphql" ] && exit 1
exec "$REAL_GH" "$@"
SH
chmod +x "$BIN/gh-fail"
out=$(REAL_GH="$(command -v gh)" SWARM_GH="$BIN/gh-fail" bash "$S" 2>&1); rc=$?
want "an unreadable batch state is exit 1" "1" "$rc"
want_not_in "  and nobody is released"      '^released' "$out"

echo "--- coordinator housekeeping runs it every pass ---"
HK="$HERE/coordinator-housekeeping.sh"
want_in "housekeeping names the script" 'COORDINATOR_RELEASE_BATCH:-\$SELF_DIR/release-batch-children\.sh' "$(cat "$HK")"
want_in "and runs it dry in shadow"     'bash "\$RELEASE_BATCH" --dry-run' "$(cat "$HK")"

suite_end "$FAILED"
