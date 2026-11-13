#!/usr/bin/env bash
# develop-red.test.sh — the trunk-red filer reads the forge twice a pass, not twice a row,
# waits out a spent search limit, and leaves no covered row in develop-red.tsv. Only a
# check the trunk's live rules require files a ticket; any other is counted for the week.
#
# 2026-10-27: 22 rows sat pending and every coordinator tick searched once or twice for
# each, 44 searches against GitHub's 30 a minute. Refused, each row stayed, and the next
# tick searched again.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
unset PR_RED_REQ_FILE PR_RED_REQ_CACHE   # a coordinator's live required-checks cache is no case's input
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
PENDING="$STATE/swarm/develop-red.tsv"; LEDGER="$STATE/swarm/develop-red-filed.tsv"
A=aaaaaaa000000000000000000000000000000000; B=bbbbbbb000000000000000000000000000000000
mkdir -p "$REPO/src"; : > "$REPO/src/x.test.ts"; git -C "$REPO" add src/x.test.ts

# The forge: the open-ticket search answers $FIX/open.json, the all-markers search
# $FIX/markers.json (fails while $FIX/markers.fail exists); a create numbers from 901.
# develop's rules answer $FIX/rules.json (fail while $FIX/rules.fail exists). CI's check runs on
# any commit answer $FIX/ci.json (none ran when absent; fail while $FIX/ci.fail exists). A
# --paginate read of them (the red legs') answers $FIX/runs.json instead (fail while
# $FIX/runs.fail exists; also gets the second page $FIX/runs.2.json), a job's log $FIX/log.<id>.
cat > "$BIN/fgh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/fgh.log"
case "$*" in
  *--paginate*"/check-runs"*) [ -f "$FIX/runs.fail" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
                             cat "$FIX/runs.json" 2>/dev/null || echo '{"total_count":0,"check_runs":[]}'
                             cat "$FIX/runs.2.json" 2>/dev/null; exit 0 ;;
  *"/check-runs"*) [ -f "$FIX/ci.fail" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
                   cat "$FIX/ci.json" 2>/dev/null || echo '{"total_count":0,"check_runs":[]}'; exit 0 ;;
  *"rules/branches/develop"*) [ -f "$FIX/rules.fail" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
                              cat "$FIX/rules.json"; exit 0 ;;
  *"protection/required_status_checks"*) echo '{"message":"Branch not protected"}'; exit 1 ;;
  *"-X GET search/issues"*"is:open"*) cat "$FIX/open.json" 2>/dev/null || echo '{"total_count":0,"items":[]}'; exit 0 ;;
  *"-X GET search/issues"*) [ -f "$FIX/markers.fail" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
                            cat "$FIX/markers.json" 2>/dev/null || echo '{"total_count":0,"items":[]}'; exit 0 ;;
  *"actions/jobs/"*"/logs"*) a="$*"; id=${a#*actions/jobs/}; id=${id%%/*}
                             [ -f "$FIX/log.$id" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
                             cat "$FIX/log.$id"; exit 0 ;;
  *"/comments -X POST"*) [ -z "${FGH_APPEND:-}" ] || printf '%s\n' "$FGH_APPEND" >> "$PENDING"; exit 0 ;;
  *"repos/acme/widgets/issues -X POST"*) [ -z "${FGH_APPEND:-}" ] || printf '%s\n' "$FGH_APPEND" >> "$PENDING"
    n=$(( $(cat "$FIX/fgh.next" 2>/dev/null || echo 900) + 1 )); echo "$n" > "$FIX/fgh.next"; echo "$n"; exit 0 ;;
esac
exit 0
SH
chmod +x "$BIN/fgh"
export PENDING
COUNT="$STATE/swarm/check-class-count.tsv"
requires() { # <context…> — what develop's live rules require
  printf '%s\n' "$@" | jq -R 'select(. != "")' | jq -sc '[{type: "pull_request"}, {type: "required_status_checks", parameters: {required_status_checks: map({context: .})}}]' > "$FIX/rules.json"
}
fresh() { # <rows…> — that develop-red.tsv, an empty ledger, a forge with nothing filed, chk-* required
  rm -f "$FIX"/ci.json "$FIX"/ci.fail "$FIX"/open.json "$FIX"/markers.json "$FIX"/markers.fail "$FIX"/rules.fail "$FIX"/fgh.next "$STATE/swarm/gh-backoff"*
  rm -f "$FIX"/runs.json "$FIX"/runs.2.json "$FIX"/runs.fail "$FIX"/log.*
  : > "$FIX/fgh.log"; : > "$LEDGER"; : > "$PENDING"; : > "$COUNT"; unset FGH_APPEND
  requires chk-a chk-b chk-z chk-q
  local r; for r in "$@"; do printf '%s\n' "$r" >> "$PENDING"; done
}
run() { # [dry] — R the output, R_RC the exit
  R_RC=0
  R=$(DEVELOP_RED_GH="$BIN/fgh" SWARM_GH="$BIN/fgh" DEVELOP_RED_QUEUE=off bash "${SUT:-$HERE}/develop-red.sh" file "$@" 2>&1) || R_RC=$?
}
searches() { grep -c 'search/issues' "$FIX/fgh.log" | tr -d ' '; }
creates() { grep -c 'repos/acme/widgets/issues -X POST' "$FIX/fgh.log" | tr -d ' '; }
comments() { grep -c '/comments -X POST' "$FIX/fgh.log" | tr -d ' '; }
ci() { # <name>=<status>[:<conclusion>]… — CI's check runs on the row's commit
  local a; for a in "$@"; do printf '%s\n' "$a"; done | jq -R 'split("=") | {name: .[0], status: (.[1] | split(":")[0]), conclusion: (.[1] | split(":")[1] // null)}' \
    | jq -sc '{total_count: length, check_runs: .}' > "$FIX/ci.json"
}
issue() { # <number> <state> <marker checks> <sha7> — one search hit
  printf '{"total_count":1,"items":[{"number":%s,"state":"%s","body":"x\\n<!-- develop-red: checks=%s sha=%s -->"}]}\n' "$1" "$2" "$3" "$4"
}

echo "--- the search limit spent: nothing searched, the rows wait, one line says so ---"
fresh "$A	chk-a	601		1" "$B	chk-b	602		2"; cp "$PENDING" "$FIX/before"
printf '%s\tsearch\tgh: API rate limit exceeded\n' $(( $(date +%s) + 600 )) > "$STATE/swarm/gh-backoff.search"
run
want "no search call"                          "0" "$(searches)"
want "develop-red.tsv is untouched"            "same" "$(cmp -s "$FIX/before" "$PENDING" && echo same || echo changed)"
want "one line"                                "1" "$(printf '%s\n' "$R" | grep -c .)"
want_in "naming the wait"                      "search limit is spent until [0-9]{2}:[0-9]{2}:[0-9]{2}Z .*2 pending" "$R"
want "and the pass is not done"                "1" "$R_RC"

echo "--- a row the ledger holds leaves develop-red.tsv ---"
fresh "$A	chk-a	601		1" "$B	chk-b	602		2"; printf '%s\tchk-a\t880\n' "$A" > "$LEDGER"
issue 880 open chk-a aaaaaaa > "$FIX/open.json"
run
want "the ledgered row is gone, the other covered too" "" "$(cat "$PENDING")"
fresh "$A	chk-a	601		1"; printf '%s\tchk-a\t880\n' "$A" > "$LEDGER"
run
want "only ledgered rows: nothing searched"    "0" "$(searches)"
want "and the file is emptied"                 "" "$(cat "$PENDING")"

echo "--- the open ticket on the same checks covers the row: ledgered, pruned, nothing posted ---"
fresh "$B	chk-a	603		3"; issue 880 open chk-a aaaaaaa > "$FIX/open.json"
run
want "one search: the open ticket's"           "1" "$(searches)"
want "nothing created"                         "0" "$(creates)"
want "nothing commented"                       "0" "$(comments)"
want "ledgered to it"                          "$B	chk-a	880" "$(cat "$LEDGER")"
want "and pruned"                              "" "$(cat "$PENDING")"

echo "--- the open ticket on another set: one comment there, no ticket ---"
fresh "$B	chk-a,chk-z	604		4" "$A	chk-a,chk-z	605		5"; issue 880 open chk-a aaaaaaa > "$FIX/open.json"
run
want "nothing created"                         "0" "$(creates)"
want "one comment for the new set, however many commits carry it" "1" "$(comments)"
want_in "on the open ticket"                   'issues/880/comments -X POST' "$(cat "$FIX/fgh.log")"
want "both ledgered to it"                     "880 880" "$(cut -f3 "$LEDGER" | tr '\n' ' ' | sed 's/ $//')"
want "and pruned"                              "" "$(cat "$PENDING")"

echo "--- no open ticket, a closed marker for checks and sha: already filed ---"
fresh "$A	chk-a	606		6"; issue 870 closed chk-a aaaaaaa > "$FIX/markers.json"
run
want "two searches"                            "2" "$(searches)"
want "nothing created"                         "0" "$(creates)"
want_in "it says whose"                        'is #870.s, already filed' "$R"
want "ledgered"                                "$A	chk-a	870" "$(cat "$LEDGER")"
fresh "$B	chk-a	607		7"; issue 870 closed chk-a aaaaaaa > "$FIX/markers.json"
run
want "a marker on another commit is not this row's: it is filed" "1" "$(creates)"

echo "--- two new sets, nothing open: one ticket, the second set a comment on it ---"
fresh "$A	chk-a	608		8" "$B	chk-b	609		9"
run
want "one create"                              "1" "$(creates)"
want_in "the second set on the ticket just filed" 'issues/901/comments -X POST .*now on: chk-b' "$(cat "$FIX/fgh.log")"
want "both ledgered to it"                     "901 901" "$(cut -f3 "$LEDGER" | tr '\n' ' ' | sed 's/ $//')"
want "still two searches"                      "2" "$(searches)"

echo "--- the marker search fails: nothing filed, nothing posted, the rows stay ---"
fresh "$A	chk-a	610		10" "$B	chk-b	611		11"; cp "$PENDING" "$FIX/before"; touch "$FIX/markers.fail"
run
want "nothing created"                         "0" "$(creates)"
want "nothing commented"                       "0" "$(comments)"
want "develop-red.tsv is untouched"            "same" "$(cmp -s "$FIX/before" "$PENDING" && echo same || echo changed)"
want "one line"                                "1" "$(printf '%s\n' "$R" | grep -c .)"
want_in "it is unknown"                        '^unknown — ' "$R"
want "and the pass is not done"                "1" "$R_RC"

echo "--- dry: neither file is written ---"
fresh "$A	chk-a	612		12" "$B	chk-b	613		13"; printf '%s\tchk-a\t880\n' "$A" > "$LEDGER"
issue 870 closed chk-b bbbbbbb > "$FIX/markers.json"
cp "$PENDING" "$FIX/before"; cp "$LEDGER" "$FIX/ledger.before"
run dry
want "develop-red.tsv is untouched"            "same" "$(cmp -s "$FIX/before" "$PENDING" && echo same || echo changed)"
want "the ledger is untouched"                 "same" "$(cmp -s "$FIX/ledger.before" "$LEDGER" && echo same || echo changed)"
want "nothing created"                         "0" "$(creates)"

echo "--- a row a builder appends during the pass survives the prune ---"
fresh "$A	chk-a	614		14"; export FGH_APPEND="$B	chk-q	615		15"
run
unset FGH_APPEND
want "the filed row is gone, the new one kept" "$B	chk-q	615		15" "$(cat "$PENDING")"

echo "--- a red check develop does not require: counted for the week, no ticket, no search ---"
fresh "$A	check:clone-ratchet	616		16"
run
want "nothing created"                         "0" "$(creates)"
want "nothing searched"                        "0" "$(searches)"
want "one line on this week's count"           "$(date -u +%G-W%V)	check:clone-ratchet	aaaaaaa" "$(cat "$COUNT")"
want_in "it says so"                           'is not a check develop requires: counted for [0-9]{4}-W[0-9]{2}, no ticket' "$R"
want "ledgered as counted"                     "$A	check:clone-ratchet	-" "$(cat "$LEDGER")"
want "and pruned"                              "" "$(cat "$PENDING")"
want "the pass is done"                        "0" "$R_RC"
printf '%s\n' "$A	check:clone-ratchet	616		16" > "$PENDING"; : > "$LEDGER"
run
want "a second pass counts nothing twice"      "1" "$(grep -c . "$COUNT")"
want_in "the count command prints it"          '^1	check:clone-ratchet$' "$(bash "$HERE/develop-red.sh" count)"

echo "--- a required check red: filed, the non-required one beside it only counted ---"
fresh "$A	chk-a,check:composition	617		17"
run
want "one ticket"                              "1" "$(creates)"
want_in "for the required check alone"         'title=develop is red: chk-a \(develop@aaaaaaa\)' "$(cat "$FIX/fgh.log")"
want "the other is counted"                    "check:composition" "$(cut -f2 "$COUNT")"
want "the row's own set is ledgered"           "$A	chk-a,check:composition	901" "$(cat "$LEDGER")"
want "and pruned"                              "" "$(cat "$PENDING")"

echo "--- coordinator.requiredRuns: a test file the required suite runs files; a ratchet does not ---"
fresh "$A	src/x.test.ts	618		18" "$B	check:route-layering	619		19"
requires "Typecheck + Unit tests"
cp "$HARNESS_CFG_PATH" "$FIX/cfg.before"
jq '.coordinator.requiredRuns = {"typecheck + unit tests": ["typecheck", "*.test.ts"], "Not required": ["check:*"]}' "$FIX/cfg.before" > "$HARNESS_CFG_PATH"
run
cp "$FIX/cfg.before" "$HARNESS_CFG_PATH"
want "one ticket"                              "1" "$(creates)"
want_in "for the test file"                    'title=develop is red: src/x.test.ts' "$(cat "$FIX/fgh.log")"
want "a context develop does not require maps nothing" "check:route-layering" "$(cut -f2 "$COUNT")"

echo "--- the rules unreadable: unknown, nothing filed or counted, the rows wait ---"
fresh "$A	chk-a	620		20" "$B	check:mock-drift	621		21"; cp "$PENDING" "$FIX/before"; touch "$FIX/rules.fail"
run
want "nothing created"                         "0" "$(creates)"
want "nothing counted"                         "" "$(cat "$COUNT")"
want "develop-red.tsv is untouched"            "same" "$(cmp -s "$FIX/before" "$PENDING" && echo same || echo changed)"
want_in "it is unknown"                        '^unknown — the checks develop requires could not be read' "$R"
want "and the pass is not done"                "1" "$R_RC"

echo "--- a red required summary whose failing leg ran lint:all: filed ---"
leg_runs() { # the summary (11) and its legs in suite 7: 12, 13 failed, 14 passed; 15 failed in suite 8
  cat > "$FIX/runs.json" <<'JSON'
{"total_count":5,"check_runs":[
 {"id":11,"name":"Typecheck + Unit tests","conclusion":"failure","check_suite":{"id":7}},
 {"id":12,"name":"Lint + Typecheck","conclusion":"failure","check_suite":{"id":7}},
 {"id":13,"name":"Unit","conclusion":"failure","check_suite":{"id":7}},
 {"id":14,"name":"Build","conclusion":"success","check_suite":{"id":7}},
 {"id":15,"name":"Other","conclusion":"failure","check_suite":{"id":8}}]}
JSON
  printf '%s\n' '2026-11-07T05:39:59.1000000Z ##[group]Run actions/checkout@v4' \
    '2026-11-07T05:40:00.1234567Z ##[group]Run npm run lint:all' '2026-11-07T05:40:09Z lint:all failed' > "$FIX/log.12"
  printf '%s\n' '2026-11-07T05:40:00Z ##[group]Run npm run test:unit' > "$FIX/log.13"
  printf '%s\n' '2026-11-07T05:40:00Z ##[group]Run npm run lint:x' > "$FIX/log.14"
  printf '%s\n' '2026-11-07T05:40:00Z ##[group]Run npm run lint:x' > "$FIX/log.15"
}
case_leg() { fresh "$A	lint:all	624		24"; requires "Typecheck + Unit tests"; leg_runs; run; }
case_leg
want "one create"                              "1" "$(creates)"
want_in "titled for the script"                'title=develop is red: lint:all \(develop@aaaaaaa\)' "$(cat "$FIX/fgh.log")"
want "nothing counted"                         "" "$(cat "$COUNT")"
want "ledgered to it"                          "$A	lint:all	901" "$(cat "$LEDGER")"
want "the pass is done"                        "0" "$R_RC"

echo "--- the legs are read once a commit, and not for a row required by name ---"
fresh "$A	chk-a	625		25"; leg_runs
run
want "a check required by name reads no leg's check runs" "0" "$(grep -c -- '--paginate.*check-runs' "$FIX/fgh.log" | tr -d ' ')"
fresh "$A	lint:x,test:unit	626		26"; requires "Typecheck + Unit tests"; leg_runs
run
want "two checks at one commit: the legs' check runs read once" "1" "$(grep -c -- '--paginate.*commits/'"$A"'/check-runs' "$FIX/fgh.log" | tr -d ' ')"
want "each failing leg's log once"             "1 1" "$(grep -c 'actions/jobs/12/logs' "$FIX/fgh.log" | tr -d ' ') $(grep -c 'actions/jobs/13/logs' "$FIX/fgh.log" | tr -d ' ')"
want "no passing leg's, no other suite's"      "0 0 0" "$(grep -c 'actions/jobs/14/logs' "$FIX/fgh.log" | tr -d ' ') $(grep -c 'actions/jobs/15/logs' "$FIX/fgh.log" | tr -d ' ') $(grep -c 'actions/jobs/11/logs' "$FIX/fgh.log" | tr -d ' ')"
want_in "test:unit filed, lint:x only counted" 'title=develop is red: test:unit \(develop@aaaaaaa\)' "$(cat "$FIX/fgh.log")"
want "lint:x is counted"                       "lint:x" "$(cut -f2 "$COUNT")"

echo "--- the check runs or a leg's log unreadable: that commit's rows wait, the others file ---"
for broken in runs.fail log.12; do
  fresh "$B	chk-b	627		27" "$A	lint:all	628		28" "$A	check:mock-drift	629		29"; requires chk-b "Typecheck + Unit tests"; leg_runs
  case $broken in runs.fail) touch "$FIX/runs.fail" ;; *) rm -f "$FIX/$broken" ;; esac
  grep "^$A" "$PENDING" > "$FIX/before"
  run
  want "$broken: the row required by name at bbbbbbb files" "1" "$(creates)"
  want_in "$broken: titled for chk-b"          'title=develop is red: chk-b \(develop@bbbbbbb\)' "$(cat "$FIX/fgh.log")"
  want "$broken: nothing counted"              "" "$(cat "$COUNT")"
  want "$broken: only bbbbbbb's row ledgered"  "$B	chk-b	901" "$(cat "$LEDGER")"
  want "$broken: aaaaaaa's rows wait in develop-red.tsv" "same" "$(cmp -s "$FIX/before" "$PENDING" && echo same || echo changed)"
  want_in "$broken: it is unknown"             '^unknown — the checks on aaaaaaa could not be read — 2 row\(s\) at it not filed this pass$' "$R"
  want "$broken: the pass is not done"         "1" "$R_RC"
done

echo "--- a leg's log never readable: a check required by name at that commit still files ---"
case_log_gone_row() { # one row: chk-a by name, lint:all only by a leg whose log is gone
  fresh "$A	chk-a,lint:all	633		33"; requires chk-a "Typecheck + Unit tests"; leg_runs; rm -f "$FIX/log.12"
  ci "chk-a=completed:failure" "lint:all=completed:failure"; run
}
case_log_gone_row
want "chk-a files"                             "1" "$(creates)"
want_in "titled for chk-a alone"               'title=develop is red: chk-a \(develop@aaaaaaa\)' "$(cat "$FIX/fgh.log")"
want "lint:all is not counted"                 "" "$(cat "$COUNT")"
want_in "lint:all is said to be unknown"       '^unknown — .*lint:all.* aaaaaaa' "$R"
fresh "$A	chk-a	634		34" "$A	lint:all	635		35"; requires chk-a "Typecheck + Unit tests"; leg_runs; rm -f "$FIX/log.12"
ci "chk-a=completed:failure" "lint:all=completed:failure"
grep 'lint:all' "$PENDING" > "$FIX/before"
run
want "two rows: chk-a's files"                 "1" "$(creates)"
want "only chk-a's row ledgered"               "$A	chk-a	901" "$(cat "$LEDGER")"
want "lint:all's row waits"                    "same" "$(grep 'lint:all' "$PENDING" | cmp -s "$FIX/before" - && echo same || echo changed)"
want_in "one row said to wait"                 '^unknown — the checks on aaaaaaa could not be read — 1 row\(s\) at it not filed this pass$' "$R"

echo "--- a multi-line run step: every line of it is a command the leg ran ---"
case_multiline() {
  fresh "$A	lint:all,check:after	630		30"; requires "Typecheck + Unit tests"; leg_runs
  printf '%s\n' '2026-11-07T05:40:00Z ##[group]Run npm ci' '2026-11-07T05:40:00Z npm run lint:all' \
    '2026-11-07T05:40:00Z shell: /usr/bin/bash -e {0}' '2026-11-07T05:40:00Z env:' '2026-11-07T05:40:00Z   CHK: check:after' \
    '2026-11-07T05:40:00Z ##[endgroup]' '2026-11-07T05:40:09Z npm run check:after' > "$FIX/log.12"
  run
}
case_multiline
want_in "lint:all on the run block's second line files" 'title=develop is red: lint:all \(develop@aaaaaaa\)' "$(cat "$FIX/fgh.log")"
want "check:after, outside the run block, is counted" "check:after" "$(cut -f2 "$COUNT")"

echo "--- the red summary on the second page of check runs: still found ---"
fresh "$A	lint:all	631		31"; requires "Typecheck + Unit tests"
printf '%s\n' '{"total_count":2,"check_runs":[{"id":42,"name":"Lint + Typecheck","conclusion":"failure","check_suite":{"id":7}}]}' > "$FIX/runs.json"
printf '%s\n' '{"total_count":2,"check_runs":[{"id":41,"name":"Typecheck + Unit tests","conclusion":"failure","check_suite":{"id":7}}]}' > "$FIX/runs.2.json"
printf '%s\n' '2026-11-07T05:40:00Z ##[group]Run npm run lint:all' > "$FIX/log.42"
run
want "one create"                              "1" "$(creates)"
want "nothing counted"                         "" "$(cat "$COUNT")"

echo "--- a glob in a run line is a word, not the coordinator's files ---"
fresh "$A	lint:all	632		32"; requires "Typecheck + Unit tests"; leg_runs
printf '%s\n' '2026-11-07T05:40:00Z ##[group]Run npm run lint:*' > "$FIX/log.12"
mkdir -p "$FIX/cwd"; : > "$FIX/cwd/lint:all"; cd "$FIX/cwd" || exit 1
run
cd "$HERE" || exit 1
want "lint:* matches no check: nothing created" "0" "$(creates)"
want "lint:all is counted"                     "lint:all" "$(cut -f2 "$COUNT")"

echo "--- only a red summary and its own legs make a check required ---"
runs_json() { # <summary conclusion> <summary suite> <leg suite> — summary 31, leg 32 failed
  printf '{"total_count":2,"check_runs":[{"id":31,"name":"Typecheck + Unit tests","conclusion":"%s","check_suite":{"id":%s}},{"id":32,"name":"Lint + Typecheck","conclusion":"failure","check_suite":{"id":%s}}]}\n' "$1" "$2" "$3" > "$FIX/runs.json"
}
leg_log() { printf '2026-11-07T05:40:00Z ##[group]Run %s\n' "$1" > "$FIX/log.32"; }
case_green_summary() { fresh "$A	check:clone-ratchet	625		25"; requires "Typecheck + Unit tests"; runs_json success 7 7; leg_log "npm run check:clone-ratchet"; run; }
case_other_suite() { fresh "$A	lint:all	626		26"; requires "Typecheck + Unit tests"; runs_json failure 7 8; leg_log "npm run lint:all"; run; }
case_unnamed() { fresh "$A	lint:all	627		27"; requires "Typecheck + Unit tests"; runs_json failure 7 7; leg_log "npm run typecheck"; run; }
case_runs_502() { fresh "$A	lint:all	628		28"; requires "Typecheck + Unit tests"; touch "$FIX/runs.fail"; cp "$PENDING" "$FIX/before"; run; }
case_green_summary
want "summary green, another check red: nothing created" "0" "$(creates)"
want "check:clone-ratchet is counted"          "check:clone-ratchet" "$(cut -f2 "$COUNT")"
case_other_suite
want "the red leg in another suite: nothing created" "0" "$(creates)"
want "lint:all is counted"                     "lint:all" "$(cut -f2 "$COUNT")"
case_unnamed
want "the leg ran no lint:all: nothing created" "0" "$(creates)"
want "lint:all is counted"                     "lint:all" "$(cut -f2 "$COUNT")"
case_runs_502
want_in "check runs 502: it is unknown"        '^unknown — ' "$R"
want "check runs 502: the pass is not done"    "1" "$R_RC"
want "check runs 502: develop-red.tsv is untouched" "same" "$(cmp -s "$FIX/before" "$PENDING" && echo same || echo changed)"
want "check runs 502: nothing counted"         "" "$(cat "$COUNT")"
want "check runs 502: nothing ledgered"        "" "$(cat "$LEDGER")"

echo "--- a check named by a builder's worktree path: filed under the tracked file, no host path reaches the forge ---"
HOSTP="Users/someone/proj-wt/sh-1-abc/src/x.test.ts"
fresh "$A	$HOSTP	624		24"; requires src/x.test.ts
run
want "one ticket"                              "1" "$(creates)"
want_in "titled by the repo-relative name"     'title=develop is red: src/x\.test\.ts \(develop@aaaaaaa\)' "$(cat "$FIX/fgh.log")"
want "no host path in title, body or marker"   "0" "$(grep -cE 'Users/|proj-wt' "$FIX/fgh.log" | tr -d ' ')"
want "the row's own set is ledgered"           "$A	$HOSTP	901" "$(cat "$LEDGER")"
want "and pruned"                              "" "$(cat "$PENDING")"
# C: a commit on another branch adds lib/new.test.ts, which this checkout does not have.
C=$(cd "$REPO" && export GIT_INDEX_FILE="$FIX/side.index" && git read-tree --empty \
  && git update-index --add --cacheinfo "100644,$(git hash-object -w /dev/null),lib/new.test.ts" \
  && git -c user.email=t@e.invalid -c user.name=T commit-tree -m "test: new" "$(git write-tree)")
fresh "$C	Users/someone/proj-wt/sh-1-abc/lib/gone.test.ts	625		25"; requires lib/gone.test.ts
run
want "a host path no tracked file ends with: nothing created" "0" "$(creates)"
want "nothing searched"                        "0" "$(searches)"
want "and no host path counted"                "" "$(cat "$COUNT")"
want "ledgered as not filed"                   "$C	Users/someone/proj-wt/sh-1-abc/lib/gone.test.ts	-" "$(cat "$LEDGER")"
want "no host path in anything sent"           "0" "$(grep -cE 'Users/|proj-wt' "$FIX/fgh.log" | tr -d ' ')"
echo "--- a test file added at the red's commit, not in this checkout: named from that commit's tree ---"
fresh "$C	Users/someone/proj-wt/sh-1-abc/lib/new.test.ts	627		27"; requires lib/new.test.ts
run
want "one ticket"                              "1" "$(creates)"
want_in "titled by the file the red's commit tracks" 'title=develop is red: lib/new\.test\.ts \(develop@' "$(cat "$FIX/fgh.log")"
echo "--- an unplaceable path at a commit this clone does not have: the row waits, never ledgered ---"
fresh "$A	Users/someone/proj-wt/sh-1-abc/lib/gone.test.ts	628		28"; requires lib/gone.test.ts
run
want "nothing created"                         "0" "$(creates)"
want "nothing ledgered"                        "" "$(cat "$LEDGER")"
want "the row is kept"                         "$A	Users/someone/proj-wt/sh-1-abc/lib/gone.test.ts	628		28" "$(cat "$PENDING")"
fresh "$B	chk-a,$HOSTP	626		26"; requires chk-a src/x.test.ts; issue 880 open chk-a aaaaaaa > "$FIX/open.json"
run
want "the open ticket takes a comment"         "1" "$(comments)"
want_in "naming the tracked file"              'now on: chk-a, src/x\.test\.ts\.' "$(cat "$FIX/fgh.log")"
want "with no host path"                       "0" "$(grep -cE 'Users/|proj-wt' "$FIX/fgh.log" | tr -d ' ')"

echo "--- a required check whose name has a slash, not a path: filed under that name ---"
fresh "$A	lint/web	633		33"; requires lint/web
run
want "one ticket"                              "1" "$(creates)"
want_in "titled by the check's own name"       'title=develop is red: lint/web \(develop@aaaaaaa\)' "$(cat "$FIX/fgh.log")"
want "the row's own set is ledgered"           "$A	lint/web	901" "$(cat "$LEDGER")"

echo "--- CI on the row's commit fails other checks: the ticket names what CI reports ---"
fresh "$A	test:api	627		27"; requires test:api "Code gates" Lint
ci "Code gates=completed:failure" "Lint=completed:failure" "Build=completed:success"
run
want "one ticket"                              "1" "$(creates)"
want_in "titled by CI's failing checks"        'title=develop is red: Code gates, Lint \(develop@aaaaaaa\)' "$(cat "$FIX/fgh.log")"
want_in "the body says what the pre-push named" 'pre-push named `test:api`' "$(cat "$FIX/fgh.log")"
want "CI's commit was read"                    "1" "$(grep -c "commits/$A/check-runs" "$FIX/fgh.log" | tr -d ' ')"
want "the row's own set is ledgered"           "$A	test:api	901" "$(cat "$LEDGER")"
body=$(grep 'issues -X POST' "$FIX/fgh.log" | sed -n 's/.*body=\(.*\) -f labels.*/\1/p' | head -1)
grep -q . <<<"$body" || body=$(tr '\n' ' ' < "$FIX/fgh.log")
mk=$(grep -oE 'develop-red: checks=[^ ]+ sha=[0-9a-f]+' <<<"$body" | head -1)
fresh "$B	test:api	628		28"; requires test:api "Code gates" Lint
ci "Code gates=completed:failure" "Lint=completed:failure"
jq -nc --arg b "x <!-- $mk -->" '{total_count: 1, items: [{number: 901, state: "open", body: $b}]}' > "$FIX/open.json"
run
want "the same CI red on a newer commit is the open ticket's: nothing created" "0" "$(creates)"
want "and nothing commented"                   "0" "$(comments)"

echo "--- CI still running on the commit: nothing filed, the row kept ---"
fresh "$A	test:api	629		$(date +%s)"; requires test:api Lint; cp "$PENDING" "$FIX/before"
ci "Lint=in_progress" "Code gates=completed:failure"
run
want "nothing created"                         "0" "$(creates)"
want "nothing searched"                        "0" "$(searches)"
want "the row is kept"                         "same" "$(cmp -s "$FIX/before" "$PENDING" && echo same || echo changed)"
want "nothing ledgered"                        "" "$(cat "$LEDGER")"
want_in "it says it waits for CI"              'CI is still running' "$R"

echo "--- CI stuck on the commit past the wait: the local set is filed, the body says CI had not finished ---"
fresh "$A	test:api	634		$(( $(date +%s) - 3 * 3600 ))"; requires test:api Lint
ci "Lint=queued" "Code gates=completed:failure"
run
want "one ticket"                              "1" "$(creates)"
want_in "for the local set"                    'title=develop is red: test:api \(develop@aaaaaaa\)' "$(cat "$FIX/fgh.log")"
want_in "the body says CI had not finished"    'CI had not finished on this commit after [0-9]+ min' "$(cat "$FIX/fgh.log")"
want "the row's own set is ledgered"           "$A	test:api	901" "$(cat "$LEDGER")"

echo "--- CI unreadable: nothing filed, the row kept, the pass not done ---"
fresh "$A	test:api	630		30"; requires test:api; cp "$PENDING" "$FIX/before"; touch "$FIX/ci.fail"
run
want "nothing created"                         "0" "$(creates)"
want "the row is kept"                         "same" "$(cmp -s "$FIX/before" "$PENDING" && echo same || echo changed)"
want_in "it is unknown"                        '^unknown — ' "$R"
want "and the pass is not done"                "1" "$R_RC"

echo "--- CI green on the commit: the local set is filed, as before ---"
fresh "$A	test:api	631		31"; requires test:api Lint
ci "Lint=completed:success" "Build=completed:skipped"
run
want "one ticket"                              "1" "$(creates)"
want_in "for the local set"                    'title=develop is red: test:api \(develop@aaaaaaa\)' "$(cat "$FIX/fgh.log")"

echo "--- CI fails the same checks: one ticket, unchanged ---"
fresh "$A	test:api	632		32"; requires test:api
ci "test:api=completed:failure"
run
want "one ticket"                              "1" "$(creates)"
want_in "for the same set"                     'title=develop is red: test:api \(develop@aaaaaaa\)' "$(cat "$FIX/fgh.log")"
want "the body names no other pre-push set"    "0" "$(grep -c 'pre-push named' "$FIX/fgh.log" | tr -d ' ')"

echo "--- plants: each rule out of a copy of the script, its case fails ---"
KIT="$FIX/kit"
plant() { # <label> <exact text> <replacement>
  rm -rf "$KIT"; mkdir -p "$KIT"; cp "$HERE"/*.sh "$KIT/"
  python3 -I -c 'import sys; p, a, b = sys.argv[1:4]; s = open(p).read(); n = s.count(a); open(p, "w").write(s.replace(a, b, 1)); sys.exit(0 if n == 1 else 1)' "$KIT/develop-red.sh" "$2" "$3" \
    || { want "plant landed: $1" "landed" "missed"; return 1; }
}
case_not_required() { fresh "$A	check:clone-ratchet	622		22"; SUT="$KIT" run; R="creates=$(creates) counted=$(grep -c . "$COUNT")"; }
case_required() { fresh "$A	chk-a	623		23"; SUT="$KIT" run; R="creates=$(creates)"; }
plant "a non-required check is only counted" '  jq -e --arg n "$lc" ' '  return 0; jq -e --arg n "$lc" ' \
  && { case_not_required; want "planted (every check required): the ratchet files a ticket" "creates=1 counted=0" "$R"; }
plant "a required check files" '  jq -e --arg n "$lc" ' '  return 1; jq -e --arg n "$lc" ' \
  && { case_required; want "planted (no check required): the required red files nothing" "creates=0" "$R"; }
plant "a red summary's legs make their scripts required" '  required_leg_check "$sha" "$c"' '  return 1' \
  && { SUT="$KIT"; case_leg; unset SUT; R="creates=$(creates)"; want "planted (no leg lookup): lint:all files nothing" "creates=0" "$R"; }
plant "a leg needs a red required summary" '[$f[] | . as $x | select(any($s[]; .check_suite.id == $x.check_suite.id and .id != $x.id)) | .id]' '[$f[] | .id]' \
  && { SUT="$KIT"; case_green_summary; unset SUT; R="creates=$(creates)"; want "planted (every failing run a leg): the ratchet files" "creates=1" "$R"; }
plant "legs share the summary's suite" '.check_suite.id == $x.check_suite.id and ' '' \
  && { SUT="$KIT"; case_other_suite; unset SUT; R="creates=$(creates)"; want "planted (no suite filter): lint:all files" "creates=1" "$R"; }
plant "a leg makes only the checks it ran required" 'for w in "${words[@]}"; do [ "$w" = "$2" ] && return 0; done' 'return 0' \
  && { SUT="$KIT"; case_unnamed; unset SUT; R="creates=$(creates)"; want "planted (any leg, any check): lint:all files" "creates=1" "$R"; }
plant "unreadable check runs are unknown" 'filter=latest" 2>/dev/null) || return 1' "filter=latest\" 2>/dev/null) || runs='{}'" \
  && { SUT="$KIT"; case_runs_502; unset SUT; R="rc=$R_RC ledger=$(cut -f3 "$LEDGER")"; want "planted (502 read as no summary): counted and ledgered" "rc=0 ledger=-" "$R"; }

suite_end "$FAILED"
