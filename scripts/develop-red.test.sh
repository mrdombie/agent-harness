#!/usr/bin/env bash
# develop-red.test.sh — the trunk-red filer reads the forge twice a pass, not twice a row,
# waits out a spent search limit, and leaves no covered row in develop-red.tsv.
#
# 2026-10-27: 22 rows sat pending and every coordinator tick searched once or twice for
# each, 44 searches against GitHub's 30 a minute. Refused, each row stayed, and the next
# tick searched again.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
PENDING="$STATE/swarm/develop-red.tsv"; LEDGER="$STATE/swarm/develop-red-filed.tsv"
A=aaaaaaa000000000000000000000000000000000; B=bbbbbbb000000000000000000000000000000000

# The forge: the open-ticket search answers $FIX/open.json, the all-markers search
# $FIX/markers.json (fails while $FIX/markers.fail exists); a create numbers from 901.
cat > "$BIN/fgh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/fgh.log"
case "$*" in
  *"-X GET search/issues"*"is:open"*) cat "$FIX/open.json" 2>/dev/null || echo '{"total_count":0,"items":[]}'; exit 0 ;;
  *"-X GET search/issues"*) [ -f "$FIX/markers.fail" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
                            cat "$FIX/markers.json" 2>/dev/null || echo '{"total_count":0,"items":[]}'; exit 0 ;;
  *"/comments -X POST"*) [ -z "${FGH_APPEND:-}" ] || printf '%s\n' "$FGH_APPEND" >> "$PENDING"; exit 0 ;;
  *"repos/acme/widgets/issues -X POST"*) [ -z "${FGH_APPEND:-}" ] || printf '%s\n' "$FGH_APPEND" >> "$PENDING"
    n=$(( $(cat "$FIX/fgh.next" 2>/dev/null || echo 900) + 1 )); echo "$n" > "$FIX/fgh.next"; echo "$n"; exit 0 ;;
esac
exit 0
SH
chmod +x "$BIN/fgh"
export PENDING
fresh() { # <rows…> — that develop-red.tsv, an empty ledger, a forge with nothing filed
  rm -f "$FIX"/open.json "$FIX"/markers.json "$FIX"/markers.fail "$FIX"/fgh.next "$STATE/swarm/gh-backoff"*
  : > "$FIX/fgh.log"; : > "$LEDGER"; : > "$PENDING"; unset FGH_APPEND
  local r; for r in "$@"; do printf '%s\n' "$r" >> "$PENDING"; done
}
run() { # [dry] — R the output, R_RC the exit
  R_RC=0
  R=$(DEVELOP_RED_GH="$BIN/fgh" SWARM_GH="$BIN/fgh" DEVELOP_RED_QUEUE=off bash "$HERE/develop-red.sh" file "$@" 2>&1) || R_RC=$?
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

suite_end "$FAILED"
