#!/usr/bin/env bash
# finding-sections.test.sh — the PR names each review finding once: one the review
# deferred sits under the deferred section, never again under "answered".
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/review.sh" || exit 1
. "$HERE/../steps/ship.sh" || exit 1
export SWEEP_QUEUE="$FIX/sweep.jsonl"

post() { # <ticket> <finding-json> — on the posted ledger, as the review writes it
  jq -c "$(cat "$KIT_ROOT/scripts/finding-key.jq")"' {key: finding_key, id, file, line, grade, summary, round: 1, fix: 0}' <<<"$2" \
    >> "$(driver_state_dir "$1")/steps/review.posted.jsonl"
}
times() { printf '%s\n' "$2" | grep -cF -- "$1"; }

P1='{"id":"P1","file":"src/pay.js","line":12,"grade":"major","summary":"the total skips the tax"}'
M1='{"id":"M1","file":"elsewhere.js","line":2,"grade":"minor","summary":"a slip outside the change"}'
M2='{"id":"M2","file":"own.js","line":4,"grade":"minor","summary":"a slip inside the change","inChange":true}'

echo "--- a deferred finding is named once in the body, under the deferred section ---"
T=801; driver_state_init $T; S="$(driver_state_dir $T)/steps"; mkdir -p "$S"
post $T "$P1"; post $T "$M1"; post $T "$M2"
driver_finding_answer $T "$P1" fixed 0123456789abcdef
printf '{"verdict":"BLOCKED","findings":[%s,%s]}\n' "$M1" "$M2" > "$S/review.json"
_driver_review_defer $T "$S/review.json" 2 >/dev/null 2>&1
B=$(_driver_ship_findings_sections $T)
want_in "the deferred section is there"          '## Minor, deferred' "$B"
want_in "the answered section is there"          '## Review findings, answered' "$B"
want "the fixed finding is named once"           "1" "$(times 'the total skips the tax' "$B")"
want "the sweep deferral is named once"          "1" "$(times 'a slip outside the change' "$B")"
want "the dropped deferral is named once"        "1" "$(times 'a slip inside the change' "$B")"
want_not_in "and never as a closed answer"       'a slip .*: closed:' "$B"

echo "--- every finding deferred: the answered section adds nothing, so it is left out ---"
T=802; driver_state_init $T; S="$(driver_state_dir $T)/steps"; mkdir -p "$S"
post $T "$M2"
printf '{"verdict":"BLOCKED","findings":[%s]}\n' "$M2" > "$S/review.json"
_driver_review_defer $T "$S/review.json" 2 >/dev/null 2>&1
B=$(_driver_ship_findings_sections $T)
want "the deferral is named once"                "1" "$(times 'a slip inside the change' "$B")"
want_not_in "no empty answered section"          'Review findings, answered' "$B"

echo "--- no deferred section: a closed finding is still listed as answered ---"
T=803; driver_state_init $T; S="$(driver_state_dir $T)/steps"; mkdir -p "$S"
post $T "$P1"; driver_finding_answer $T "$P1" closed "proved on the PR description"
B=$(_driver_ship_findings_sections $T)
want_in "closed with its reason" 'the total skips the tax: closed: proved on the PR description' "$B"

suite_end "$FAILED"
