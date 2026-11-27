#!/usr/bin/env bash
# touch-reports.test.sh — a project's report runs on a build that touches its paths, once
# per head of those paths and at most maxRuns times, commits its results, names them on
# the pull request, and never blocks: a red run still returns OK.
# Real git; run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
fixture_path REPO "$FIX"
. "$HERE/../touch-reports.sh" || exit 1
FAILED=0
want() { if [ "$2" = "$3" ]; then echo "OK       $1"; else echo "MISMATCH $1 — wanted '$2', got '$3'"; FAILED=$((FAILED+1)); fi; }

T=4242
# Outside the repo: the fixture tracks its config file, so an edit there rides along on a commit.
CFG="$FIX/harness.json"; cp "$REPO/.claude/harness.json" "$CFG"
RUNS="$FIX/report-runs"; : > "$RUNS"
# The report: counts its runs, writes a results file with one red, exits 1 (a red run).
cat > "$REPO/report.sh" <<SH
#!/usr/bin/env bash
echo run >> "$RUNS"
mkdir -p docs/evidence/$T
printf '{"passed":1,"total":2,"cases":[{"name":"a","pass":true},{"name":"b","pass":false}]}\n' > docs/evidence/$T/r.json
exit 1
SH
chmod +x "$REPO/report.sh"
mkdir -p "$REPO/holly" "$REPO/other"
echo base > "$REPO/holly/a.ts"; echo base > "$REPO/other/b.ts"
git -C "$REPO" add -A; git -C "$REPO" commit -qm base
git -C "$REPO" checkout -q -b "tkt-$T/x"
mkdir -p "$(driver_state_dir "$T")/steps"

with_report() {
  jq --arg run "bash $REPO/report.sh" '.reports = {onTouch: [{name: "Holly replay", paths: ["holly/"], run: $run,
      results: "docs/evidence/{ticket}/r.json", maxRuns: 2,
      summary: "\"\\(.passed) of \\(.total) pass\", (.cases[] | select(.pass | not) | \"red: \\(.name)\")"}]}' \
    "$CFG" > "$CFG.new" && mv "$CFG.new" "$CFG"
  export HARNESS_CFG="$CFG"   # the kit read a snapshot at load; this case's config is the edited file
}
edit() { echo "$2" >> "$REPO/$1"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "$1 $2"; }
runs() { wc -l < "$RUNS" | tr -d ' '; }

if suite_case "nothing configured: no report runs, no section"; then
  edit holly/a.ts one
  driver_touch_reports "$T" "$REPO"; rc=$?
  want "returns OK" 0 "$rc"
  want "the report never ran" 0 "$(runs)"
  want "the body has no section" "" "$(driver_touch_reports_section "$T")"
fi

with_report

if suite_case "a change outside its paths runs nothing"; then
  git -C "$REPO" checkout -q develop; git -C "$REPO" checkout -q -b "tkt-$T/y"
  edit other/b.ts one
  driver_touch_reports "$T" "$REPO"
  want "the report never ran" 0 "$(runs)"
  git -C "$REPO" checkout -q "tkt-$T/x"
fi

if suite_case "a change to its paths runs it, commits the results, names the red, and does not block"; then
  driver_touch_reports "$T" "$REPO"; rc=$?
  want "returns OK on a red run" 0 "$rc"
  want "ran once" 1 "$(runs)"
  want "the results file is committed" "chore(#$T): Holly replay report" "$(git -C "$REPO" log -1 --format=%s)"
  sec=$(driver_touch_reports_section "$T")
  case "$sec" in *"## Reports (not blocking)"*"exit 1"*"1 of 2 pass"*"red: b"*) got=yes ;; *) got="$sec" ;; esac
  want "the section names the exit, the score and the red" yes "$got"
fi

if suite_case "the same head of its paths is not run again"; then
  driver_touch_reports "$T" "$REPO"
  want "still one run" 1 "$(runs)"
fi

if suite_case "a new head of its paths runs again, up to maxRuns"; then
  edit holly/a.ts two
  driver_touch_reports "$T" "$REPO"
  want "a second run" 2 "$(runs)"
  edit holly/a.ts three
  driver_touch_reports "$T" "$REPO"
  want "no third run past maxRuns 2" 2 "$(runs)"
fi

suite_end "$FAILED"
