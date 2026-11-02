#!/usr/bin/env bash
# review-metrics.test.sh — the review's before and after, from the driver's own records
# and the finding tickets: findings per PR, rounds to pass, and finding tickets filed per
# day, each split at the day the new review landed.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/review-metrics.sh"
SB=$(mktemp -d "${TMPDIR:-/tmp}/review-metrics-XXXXXX"); on_exit_keep_status 'rm -rf "$SB"'
FAILED=0
want() { if [ "$2" = "$3" ]; then echo "OK       $1"; else echo "MISMATCH $1 — wanted '$2', got '$3'"; FAILED=1; fi; }
D="$SB/driver"

# rec <ticket> <started> <reviews> <skipped> <done-ship 0|1> <pr> — one run record
rec() {
  mkdir -p "$D/$1/steps"
  jq -n --arg s "$2" --argjson r "$3" --argjson k "$4" --argjson sh "$5" --arg pr "$6" \
    '{ticket: "x", started_at: $s, pr: $pr, counters: {review: $r, review_skipped: $k},
      done: (["start","review"] + (if $sh == 1 then ["ship"] else [] end))}' > "$D/$1/state.json"
}
finding() { printf '{"id":"%s","file":"a","line":1,"grade":"%s","summary":"s","reason":"r","fix":"f"}' "$1" "$2"; }

# Before the split (old review): findings read off review.json (nits left out) + the deferred list.
rec 1 2026-10-31T10:00:00Z 1 0 1 101
printf '{"verdict":"SHIP","findings":[%s,%s]}\n' "$(finding a major)" "$(finding b nit)" > "$D/1/steps/review.json"
printf '{"id":"c"}\n{"id":"d"}\n' > "$D/1/steps/review.deferred.jsonl"          # 3 findings, 1 round
rec 2 2026-11-01T10:00:00Z 2 0 1 102
printf '{"verdict":"SHIP","findings":[%s]}\n' "$(finding e minor)" > "$D/2/steps/review.json"   # 1 finding, 2 rounds
rec 3 2026-11-02T10:00:00Z 1 1 1 103                                             # skipped: no model review
printf '{"verdict":"SHIP","findings":[]}\n' > "$D/3/steps/review.json"
rec 4 2026-11-02T11:00:00Z 1 0 0 ""                                              # no PR: not a reviewed PR
printf '{"verdict":"BLOCKED","findings":[%s]}\n' "$(finding f major)" > "$D/4/steps/review.json"
# After the split (panel review): the never-twice ledger is the record of what was posted.
rec 5 2026-11-03T10:00:00Z 1 0 1 105
printf '{"verdict":"SHIP","findings":[]}\n' > "$D/5/steps/review.json"
printf '{"key":"k1"}\n' > "$D/5/steps/review.posted.jsonl"                       # 1 finding, 1 round
rec 6 2026-11-04T10:00:00Z 1 0 1 106
printf '{"verdict":"SHIP","findings":[]}\n' > "$D/6/steps/review.json"           # 0 findings, 1 round

# Finding tickets: 6 over the 3 days before (2 a day), 1 over the 2 days after (0.5 a day).
cat > "$SB/tickets.json" <<'J'
[{"createdAt":"2026-10-31T01:00:00Z"},{"createdAt":"2026-10-31T02:00:00Z"},{"createdAt":"2026-10-31T03:00:00Z"},
 {"createdAt":"2026-11-01T01:00:00Z"},{"createdAt":"2026-11-02T01:00:00Z"},{"createdAt":"2026-11-02T05:00:00Z"},
 {"createdAt":"2026-11-03T01:00:00Z"}]
J

out=$(bash "$SUT" --driver-dir "$D" --split 2026-11-03 --tickets-json "$SB/tickets.json" --from 2026-10-31 --to 2026-11-04 --json 2>&1); rc=$?
want "exits 0"                                  0 "$rc"
j() { printf '%s' "$out" | jq -r "$1" 2>/dev/null; }
want "before: PRs reviewed by the model"        2   "$(j .before.prs)"
want "before: findings per PR"                  2   "$(j .before.findingsPerPr)"
want "before: rounds to pass"                   1.5 "$(j .before.roundsToPass)"
want "before: share passing in one round"       0.5 "$(j .before.oneRoundShare)"
want "before: finding tickets per day"          2   "$(j .before.ticketsPerDay)"
want "after: PRs reviewed by the model"         2   "$(j .after.prs)"
want "after: findings per PR"                   0.5 "$(j .after.findingsPerPr)"
want "after: rounds to pass"                    1   "$(j .after.roundsToPass)"
want "after: finding tickets per day"           0.5 "$(j .after.ticketsPerDay)"
want "the split is named"                       "2026-11-03" "$(j .split)"

echo "--- the plain report says each figure in words ---"
txt=$(bash "$SUT" --driver-dir "$D" --split 2026-11-03 --tickets-json "$SB/tickets.json" --from 2026-10-31 --to 2026-11-04 2>&1)
printf '%s' "$txt" | grep -q 'findings per PR' && echo "OK       names findings per PR" || { echo "MISMATCH no findings per PR line: $txt"; FAILED=1; }
printf '%s' "$txt" | grep -q 'rounds to pass' && echo "OK       names rounds to pass" || { echo "MISMATCH no rounds line"; FAILED=1; }
printf '%s' "$txt" | grep -q 'finding tickets filed per day' && echo "OK       names tickets per day" || { echo "MISMATCH no tickets line"; FAILED=1; }

echo "--- from GitHub: one search a day, each day once, ending on the last day ---"
# Measured 2026-11-02: BSD date's -v1d SETS the day of the month to 1, so "the next day"
# went back to the 1st and the loop searched one day forever, into the rate limit.
cat > "$SB/gh" <<'SH'
#!/usr/bin/env bash
d=""; for a; do case "$a" in created:*) d=${a#created:} ;; esac; done
echo "$d" >> "$GH_CALLS"
[ "$(grep -c . "$GH_CALLS")" -le 50 ] || { echo "runaway" >&2; exit 1; }
case "$d" in 2026-11-02) echo '[{"createdAt":"2026-11-02T01:00:00Z"},{"createdAt":"2026-11-02T02:00:00Z"}]' ;; *) echo '[]' ;; esac
SH
chmod +x "$SB/gh"; export GH_CALLS="$SB/gh.calls"; : > "$GH_CALLS"
out=$(REVIEW_METRICS_GH="$SB/gh" bash "$SUT" --driver-dir "$D" --split 2026-11-03 --repo o/r --from 2026-10-31 --to 2026-11-04 --json 2>&1); rc=$?
want "exits 0"                                  0 "$rc"
want "each day searched once, in order"         "2026-10-31 2026-11-01 2026-11-02 2026-11-03 2026-11-04" "$(tr '\n' ' ' < "$GH_CALLS" | sed 's/ $//')"
want "the tickets it found are counted"         2 "$(j .before.findingTickets)"
: > "$GH_CALLS"
REVIEW_METRICS_GH="$SB/gh" bash "$SUT" --driver-dir "$D" --split 2026-03-01 --repo o/r --from 2026-02-27 --to 2026-03-01 --json >/dev/null 2>&1
want "a month end is crossed"                   "2026-02-27 2026-02-28 2026-03-01" "$(tr '\n' ' ' < "$GH_CALLS" | sed 's/ $//')"
rc=0; REVIEW_METRICS_GH="$SB/gh" bash "$SUT" --driver-dir "$D" --split 2026-03-01 --repo o/r --from 2024-01-01 --to 2026-03-01 >/dev/null 2>&1 || rc=$?
want "a window over 400 days is refused before any search" 2 "$rc"

echo "--- refusals ---"
rc=0; bash "$SUT" --driver-dir "$SB/none" --split 2026-11-03 --tickets-json "$SB/tickets.json" >/dev/null 2>&1 || rc=$?
want "a driver dir that is not there is a 2, never a row of zeros" 2 "$rc"
printf 'nope' > "$SB/bad.json"
rc=0; bash "$SUT" --driver-dir "$D" --split 2026-11-03 --tickets-json "$SB/bad.json" >/dev/null 2>&1 || rc=$?
want "a tickets file that is not JSON is a 2" 2 "$rc"
rc=0; bash "$SUT" --driver-dir "$D" --tickets-json "$SB/tickets.json" >/dev/null 2>&1 || rc=$?
want "no split is a 2" 2 "$rc"

suite_end "$FAILED"
