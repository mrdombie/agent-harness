#!/usr/bin/env bash
# sweep-queue.test.sh — a pre-existing review finding is the nightly sweep's, never the
# builder's and never a ticket's. The review step hands it here; the queue keeps each
# defect once however many reviews raise it, and the sweep reads it back.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/sweep-queue.sh"
SB=$(mktemp -d "${TMPDIR:-/tmp}/sweep-queue-XXXXXX"); on_exit_keep_status 'rm -rf "$SB"'
FAILED=0
want() { if [ "$2" = "$3" ]; then echo "OK       $1"; else echo "MISMATCH $1 — wanted '$2', got '$3'"; FAILED=1; fi; }
want_in() { if printf '%s' "$3" | grep -qF -- "$2"; then echo "OK       $1"; else echo "MISMATCH $1 — no '$2' in: $3"; FAILED=1; fi; }
export SWEEP_QUEUE="$SB/q/pre-existing.jsonl"

two='[{"id":"p1","file":"src/a.ts","line":3,"grade":"major","tag":"pre-existing","summary":"The reader drops a 500 as an empty page.","reason":"r","fix":"f"},
      {"id":"p2","file":"src/b.ts","line":9,"grade":"minor","tag":"pre-existing","class":"a failed read shown as empty","instances":["src/b.ts:9","src/c.ts:4"],"summary":"s","reason":"r","fix":"f"}]'

echo "--- add: each finding is one line, naming the ticket and round that found it ---"
rc=0; out=$(printf '%s' "$two" | bash "$SUT" add 101 1 2>&1) || rc=$?
want "add exits 0"                       0 "$rc"
want "two lines queued"                  2 "$(wc -l < "$SWEEP_QUEUE" | tr -d ' ')"
want "the ticket is on each"             "101 101" "$(jq -r .ticket "$SWEEP_QUEUE" | tr '\n' ' ' | sed 's/ $//')"
want "the round is kept"                 "1" "$(jq -r .round "$SWEEP_QUEUE" | sort -u)"
want "the class and its instances ride"  "src/b.ts:9 src/c.ts:4" "$(jq -r 'select(.class) | .instances | join(" ")' "$SWEEP_QUEUE")"
want_in "and it says what it did"        "2 queued" "$out"

echo "--- the same defect from another ticket, reworded only in case and punctuation, is queued once ---"
again='[{"id":"x","file":"src/a.ts","line":40,"grade":"major","tag":"pre-existing","summary":"the reader drops a 500 as an EMPTY page","reason":"r","fix":"f"},
        {"id":"y","file":"src/z.ts","line":1,"grade":"minor","tag":"pre-existing","class":"A failed read shown as empty.","summary":"other words","reason":"r","fix":"f"}]'
out=$(printf '%s' "$again" | bash "$SUT" add 202 2 2>&1)
want "still two lines"                   2 "$(wc -l < "$SWEEP_QUEUE" | tr -d ' ')"
want_in "and the repeat is said"         "2 already queued" "$out"
want "count reads it"                    2 "$(bash "$SUT" count)"
want "list is the queue"                 "$(cat "$SWEEP_QUEUE")" "$(bash "$SUT" list)"

echo "--- a JSONL stream is read as well as an array ---"
printf '%s\n' '{"id":"j","file":"src/j.ts","line":1,"grade":"minor","summary":"another one","reason":"r","fix":"f"}' \
  | bash "$SUT" add 303 1 >/dev/null 2>&1
want "three lines"                       3 "$(bash "$SUT" count)"

echo "--- key: one fingerprint, shared with the review step's never-twice ledger ---"
k1=$(printf '%s' '{"file":"./src/a.ts","summary":"The reader drops a 500 as an empty page."}' | bash "$SUT" key)
k2=$(printf '%s' '{"file":"src/a.ts","line":99,"summary":"the reader  drops a 500, as an empty page"}' | bash "$SUT" key)
want "line, case, spacing and punctuation do not change it" "$k1" "$k2"
k3=$(printf '%s' '{"file":"src/q.ts","class":"A failed read shown as empty","summary":"zzz"}' | bash "$SUT" key)
want "a class is keyed on the class alone" "class|a failed read shown as empty" "$k3"

echo "--- refusals ---"
rc=0; printf 'not json' | bash "$SUT" add 404 1 >/dev/null 2>&1 || rc=$?
want "input that is not JSON is a 2"     2 "$rc"
want "and nothing was written"           3 "$(bash "$SUT" count)"
rc=0; printf '[]' | bash "$SUT" add x 1 >/dev/null 2>&1 || rc=$?
want "a ticket that is not a number is a 2" 2 "$rc"
rc=0; bash "$SUT" nonsense >/dev/null 2>&1 || rc=$?
want "an unknown command is a 2"         2 "$rc"
rc=0; out=$(env -u SWEEP_QUEUE HARNESS_STATE_DIR= HARNESS_CFG=/nonexistent bash "$SUT" count 2>&1) || rc=$?
want "no queue path is a 2, never a silent count of 0" 2 "$rc"

suite_end "$FAILED"
