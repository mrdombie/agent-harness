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
unset PR_RED_REQ_FILE PR_RED_REQ_CACHE  # a host's cached required checks would answer for the fake rules
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
PENDING="$STATE/swarm/develop-red.tsv"; LEDGER="$STATE/swarm/develop-red-filed.tsv"
A=aaaaaaa000000000000000000000000000000000; B=bbbbbbb000000000000000000000000000000000

# The forge: the open-ticket search answers $FIX/open.json, the all-markers search
# $FIX/markers.json (fails while $FIX/markers.fail exists); a create numbers from 901.
# develop's rules answer $FIX/rules.json (fail while $FIX/rules.fail exists). A commit's
# check runs answer $FIX/runs.json (fail while $FIX/runs.fail exists), a job's log $FIX/log.<id>.
cat > "$BIN/fgh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/fgh.log"
case "$*" in
  *"rules/branches/develop"*) [ -f "$FIX/rules.fail" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
                              cat "$FIX/rules.json"; exit 0 ;;
  *"protection/required_status_checks"*) echo '{"message":"Branch not protected"}'; exit 1 ;;
  *"-X GET search/issues"*"is:open"*) cat "$FIX/open.json" 2>/dev/null || echo '{"total_count":0,"items":[]}'; exit 0 ;;
  *"-X GET search/issues"*) [ -f "$FIX/markers.fail" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
                            cat "$FIX/markers.json" 2>/dev/null || echo '{"total_count":0,"items":[]}'; exit 0 ;;
  *"commits/"*"/check-runs"*) [ -f "$FIX/runs.fail" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
                             cat "$FIX/runs.json" 2>/dev/null || echo '{"total_count":0,"check_runs":[]}'; exit 0 ;;
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
  rm -f "$FIX"/open.json "$FIX"/markers.json "$FIX"/markers.fail "$FIX"/rules.fail "$FIX"/fgh.next "$STATE/swarm/gh-backoff"*
  rm -f "$FIX"/runs.json "$FIX"/runs.fail "$FIX"/log.*
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
want "a check required by name reads no check runs" "0" "$(grep -c 'check-runs' "$FIX/fgh.log" | tr -d ' ')"
fresh "$A	lint:x,test:unit	626		26"; requires "Typecheck + Unit tests"; leg_runs
run
want "two checks at one commit: check runs read once" "1" "$(grep -c 'commits/'"$A"'/check-runs' "$FIX/fgh.log" | tr -d ' ')"
want "each failing leg's log once"             "1 1" "$(grep -c 'actions/jobs/12/logs' "$FIX/fgh.log" | tr -d ' ') $(grep -c 'actions/jobs/13/logs' "$FIX/fgh.log" | tr -d ' ')"
want "no passing leg's, no other suite's"      "0 0 0" "$(grep -c 'actions/jobs/14/logs' "$FIX/fgh.log" | tr -d ' ') $(grep -c 'actions/jobs/15/logs' "$FIX/fgh.log" | tr -d ' ') $(grep -c 'actions/jobs/11/logs' "$FIX/fgh.log" | tr -d ' ')"
want_in "test:unit filed, lint:x only counted" 'title=develop is red: test:unit \(develop@aaaaaaa\)' "$(cat "$FIX/fgh.log")"
want "lint:x is counted"                       "lint:x" "$(cut -f2 "$COUNT")"

echo "--- the check runs or a leg's log unreadable: unknown, nothing filed, counted or ledgered ---"
for broken in runs.fail log.12; do
  fresh "$B	chk-b	627		27" "$A	lint:all	628		28" "$A	check:mock-drift	629		29"; requires chk-b "Typecheck + Unit tests"; leg_runs
  case $broken in runs.fail) touch "$FIX/runs.fail" ;; *) rm -f "$FIX/$broken" ;; esac
  cp "$PENDING" "$FIX/before"
  run
  want "$broken: nothing created"              "0" "$(creates)"
  want "$broken: nothing counted"              "" "$(cat "$COUNT")"
  want "$broken: nothing ledgered"             "" "$(cat "$LEDGER")"
  want "$broken: develop-red.tsv is untouched" "same" "$(cmp -s "$FIX/before" "$PENDING" && echo same || echo changed)"
  want_in "$broken: it is unknown"             '^unknown — the checks on aaaaaaa could not be read — 3 row\(s\) not filed this pass$' "$R"
  want "$broken: the pass is not done"         "1" "$R_RC"
done

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
plant "a red summary's legs make their scripts required" 'required_leg_check "$sha" "$c" && return 0' '' \
  && { SUT="$KIT"; case_leg; unset SUT; R="creates=$(creates)"; want "planted (no leg lookup): lint:all files nothing" "creates=0" "$R"; }

suite_end "$FAILED"
