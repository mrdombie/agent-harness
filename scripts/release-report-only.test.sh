#!/usr/bin/env bash
# release-report-only.test.sh — a check listed in release.nonBlockingChecks, with
# findings, ends its run green with a warning while release.done is false, and red
# once it is true; an unlisted check, or a missing config, is red either way.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/release-report-only.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

FAILED=0
want() { if [ "$2" = "$3" ]; then printf 'OK       %s\n' "$1"; else printf "MISMATCH %s — wanted '%s', got '%s'\n" "$1" "$2" "$3"; FAILED=1; fi; }
want_in() { if grep -qE -- "$2" <<<"$3"; then printf 'OK       %s\n' "$1"; else printf 'MISMATCH %s — no /%s/ in: %s\n' "$1" "$2" "$(printf '%s' "$3" | tr '\n' '|')"; FAILED=1; fi; }
want_not_in() { if grep -qE -- "$2" <<<"$3"; then printf 'MISMATCH %s — found /%s/\n' "$1" "$2"; FAILED=1; else printf 'OK       %s\n' "$1"; fi; }

LISTED='["Lesson / Every fix ships a lesson", "Widths and contrast on changed routes"]'
cfg() { jq -n --argjson l "$LISTED" --argjson d "$1" '{release: {nonBlockingChecks: $l, done: $d}}' > "$T/cfg.json"; }
findings() { echo "lesson: missing ## Lesson"; return "${1:-1}"; }
export -f findings

run() { # <check name> <args…> → "rc=<n>" then output; summary in $T/summary
  : > "$T/summary"
  local out rc
  out=$(GITHUB_STEP_SUMMARY="$T/summary" bash "$SUT" "$T/cfg.json" "$@" 2>&1); rc=$?
  printf 'rc=%s\n%s' "$rc" "$out"
}

echo "--- release not done: a listed check with findings warns and passes ---"
cfg false
out=$(run "Every fix ships a lesson" -- bash -c 'findings 1')
want_in "the run passes"                     '^rc=0' "$out"
want_in "the warning is annotated"           '^::warning title=Every fix ships a lesson' "$out"
want_in "the findings still reach the log"   'missing ## Lesson' "$out"
want_in "the findings are in the summary"    'missing ## Lesson' "$(cat "$T/summary")"
echo "/feed scrolls sideways at 375" > "$T/findings.txt"
out=$(run "Widths and contrast on changed routes" --failed "$T/findings.txt")
want_in "--failed: a listed check passes"    '^rc=0' "$out"
want_in "--failed: the findings file is summarised" 'scrolls sideways' "$(cat "$T/summary")"
out=$(run "every fix ships a LESSON" -- bash -c 'findings 2')
want_in "case does not matter; exit 2 is a finding too" '^rc=0' "$out"
out=$(run "Every fix ships a lesson" -- true)
want_in "a clean check passes"               '^rc=0' "$out"
want_not_in "a clean check warns nothing"    '::warning' "$out"

echo "--- release done: the same check fails as before ---"
cfg true
out=$(run "Every fix ships a lesson" -- bash -c 'findings 1')
want_in "the run fails with the check's own code" '^rc=1' "$out"
want_not_in "no warning stands in for it"    '::warning' "$out"
out=$(run "Every fix ships a lesson" -- bash -c 'findings 2')
want_in "exit 2 passes through"              '^rc=2' "$out"
out=$(run "Widths and contrast on changed routes" --failed)
want_in "--failed fails"                     '^rc=1' "$out"

echo "--- not listed, or no config: blocks ---"
cfg false
out=$(run "Code gates" -- bash -c 'findings 1')
want_in "an unlisted check fails"            '^rc=1' "$out"
out=$(run "ships a lesson" -- bash -c 'findings 1')
want_in "a name that only ends a listed one fails" '^rc=1' "$out"
rm -f "$T/cfg.json"
out=$(run "Every fix ships a lesson" -- bash -c 'findings 1')
want_in "a missing config blocks"            '^rc=1' "$out"
printf 'not json' > "$T/cfg.json"
out=$(run "Every fix ships a lesson" -- bash -c 'findings 1')
want_in "an unreadable config blocks"        '^rc=1' "$out"
jq -n '{release: {nonBlockingChecks: ["Every fix ships a lesson"]}}' > "$T/cfg.json"
out=$(run "Every fix ships a lesson" -- bash -c 'findings 1')
want_in "done absent reads as not done"      '^rc=0' "$out"

echo "--- usage ---"
out=$(run "Every fix ships a lesson" --)
want_in "no command is a usage error"        '^rc=2' "$out"

echo "--- the lesson seat goes through it ---"
seat=$(sed -n '/A fix names its guard/,$p' "$HERE/../.github/workflows/lesson.yml")
want_in "lesson.yml takes the kit's release-report-only.sh" '^ *report=kit/scripts/release-report-only\.sh$' "$seat"
want_in "lesson.yml runs the judge through it" 'bash "\$report" "\$cfg" "Every fix ships a lesson" -- ' "$seat"
want_in "lesson.yml reads the config at the base"  'show "HEAD\^1:\.claude/harness\.json"' "$seat"

[ "$FAILED" -eq 0 ] && echo "all release-report-only cases passed" || { echo "release-report-only: FAILURES"; exit 1; }
