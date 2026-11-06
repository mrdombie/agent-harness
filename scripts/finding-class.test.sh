#!/usr/bin/env bash
# finding-class.test.sh — a review-finding class seen once raises no notice; seen twice,
# on any change or machine, exactly one, to the PM's channel; seen three times, still one.
# Two wordings of one rule are one class. A thrown-away change counts its checks and test
# files, and past their own limit they tell the PM once a week and start a line in
# agent-work.log. Old ledger rows read. The weekly count prints each class and red check,
# most first, and a class that did not fall after its source fix says so. No brief, skill or rule asks a builder for a lesson. Each rule
# has a plant: a copy of the script with that rule broken, which its case must catch.
# No model is called anywhere here, and the forge is a stub.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
FAILED=0
ok()  { echo "OK       $1"; }
bad() { echo "FAIL     $1"; FAILED=$((FAILED + 1)); }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — wanted [$2], got [$3]"; fi; }
want_in() { if printf '%s' "$3" | grep -qE -- "$2"; then ok "$1"; else bad "$1 — /$2/ not in: $(printf '%s' "$3" | head -c 400)"; fi; }

export FINDING_CLASS_LEDGER="$FIX/fc/finding-classes.jsonl" FINDING_CLASS_NOTIFY="$BIN/notify" FINDING_CLASS_HOST=mac DEVELOP_RED_COUNT="$FIX/check-class-count.tsv" COORDINATOR_SHADOW=0
WK_NOW=$(date -u +%G-W%V)
cat > "$BIN/notify" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/notices"
SH
chmod +x "$BIN/notify"
# The forge: the tally issue is #77 when $FIX/tally.json exists (its comments), none otherwise.
cat > "$BIN/fgh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/fgh.log"
case "$*" in
  *"issues?labels="*) if [ -f "$FIX/tally.json" ]; then echo '[{"number":77}]'; else echo '[]'; fi ;;
  *"issues/77/comments?per_page"*) cat "$FIX/tally.json" ;;
  *"-X POST repos/acme/widgets/issues "*) echo 77 ;;
  "run view "*) if [ -f "$FIX/job.log" ]; then cat "$FIX/job.log"; else exit 1; fi ;;
  *) cat > /dev/null ;;
esac
SH
chmod +x "$BIN/fgh"

SUT="$HERE/finding-class.sh"
fresh() { # a host with nothing seen, nothing told, no tally
  rm -rf "$FIX/fc"; mkdir -p "$FIX/fc"; export FINDING_CLASS_SHARE=off
  rm -f "$FIX/notices" "$FIX/tally.json" "$FIX/fgh.log" "$FIX/job.log" "$DEVELOP_RED_COUNT"; unset FINDING_CLASS_NOW
}
posted() { # <file> <path:line> <class> — one posted finding, as review.sh writes it
  local f="${2%%:*}" l="${2##*:}"
  jq -nc --arg f "$f" --argjson l "$l" --arg c "$3" '{key: "k", id: "F1", file: $f, line: $l, grade: "major", summary: "a failed read shows as empty", fix: 0} + (if $c == "" then {} else {class: $c} end)' > "$1"
}
rec() { # <sut> <ticket> <pr> <path:line> [class] — one change's review posted one finding
  posted "$FIX/fc/p-$2" "$4" "${5-failure shown as empty}"
  R=$(SWARM_GH="$BIN/fgh" bash "$1" record "$2" "$FIX/fc/p-$2" "$3" 2>&1)
}
notices() { grep -c . "$FIX/notices" 2>/dev/null | tr -d ' ' || echo 0; }
lines() { cat "$1" 2>/dev/null | grep -c .; }
n_of() { local n; n=$(grep -c . "$FIX/notices" 2>/dev/null); echo "${n:-0}"; }

# plant <name> <perl substitution> — a copy of the script with one rule broken, beside the
# kit's other scripts. Refuses (and fails the suite) when the substitution matched nothing.
plant() {
  local d="$FIX/plant-$1"
  rm -rf "$d"; mkdir -p "$d"; ln -s "$HERE"/* "$d"/; rm -f "$d/finding-class.sh"
  perl -0pe "$2" "$SUT" > "$d/finding-class.sh"
  if cmp -s "$SUT" "$d/finding-class.sh"; then bad "plant $1: the substitution matched nothing"; return 1; fi
  printf '%s' "$d/finding-class.sh"
}

# --- the cases, each a function so a plant can run it against a broken copy -------------
case_once() { # <sut> — prints the number of notices after one sighting
  fresh; rec "$1" 101 501 src/a.tsx:12; n_of
}
case_twice() { fresh; rec "$1" 101 501 src/a.tsx:12; rec "$1" 102 502 src/b.ts:40; n_of; }
case_thrice() { fresh; rec "$1" 101 501 src/a.tsx:12; rec "$1" 102 502 src/b.ts:40; rec "$1" 103 503 src/c.ts:7; n_of; }

echo "--- the key: the review's own class as a sweep-shaped slug, else file and summary ---"
want "a class is its slug" "failure-shown-as-empty" "$(echo '{"class":"Failure shown as EMPTY!","file":"a.ts"}' | bash "$SUT" key)"
want "no class: file and the summary's words" "src/a.ts|the save is dropped on retry" \
  "$(echo '{"file":"./src/a.ts:12","summary":"The save is dropped, on retry."}' | bash "$SUT" key)"
want_in "the slug is the code sweep's key shape" '^[a-z0-9][a-z0-9-]{2,59}$' "$(echo '{"class":"a dead control on a card"}' | bash "$SUT" key)"

echo "--- seen once: no notice ---"
want "one sighting raises no notice" "0" "$(case_once "$SUT")"
want "and it is on the ledger" "1" "$(grep -c . "$FINDING_CLASS_LEDGER")"

echo "--- seen twice, on two changes: exactly one notice, to the PM's channel ---"
want "two sightings raise one notice" "1" "$(case_twice "$SUT")"
nl=$(cat "$FIX/notices")
want_in "on the PM's channel, keyed by the class and week" '^--class agent finding-class:failure-shown-as-empty@[0-9]+-W[0-9]+ ' "$nl"
want_in "naming its instances, PR and file:line" 'PR #501 src/a\.tsx:12.*PR #502 src/b\.ts:40' "$nl"
want_in "and a proposed source fix" 'Fix it at the source: a kit component' "$nl"
want_in "never a test on the next change" 'Not a test on the next change' "$nl"

echo "--- seen three times: still one ---"
want "three sightings, still one notice" "1" "$(case_thrice "$SUT")"

echo "--- review.classNoticeAt sets the count: at 3, two sightings tell no one and three tell the PM once ---"
CFG="$REPO/.claude/harness.json"; cp "$CFG" "$FIX/cfg.base"
cfg_review() { jq --argjson r "$1" '.review = $r' "$FIX/cfg.base" > "$CFG"; }
case_at3() { # <sut> — notices after two sightings, then after three, with the setting at 3
  cfg_review '{"classNoticeAt": 3}'
  fresh; rec "$1" 101 501 src/a.tsx:12; rec "$1" 102 502 src/b.ts:40; printf '%s ' "$(n_of)"
  rec "$1" 103 503 src/c.ts:7; n_of
  cp "$FIX/cfg.base" "$CFG"
}
want "at 3: none at two sightings, one at three" "0 1" "$(case_at3 "$SUT")"
cfg_review '{"classNoticeAt": "lots"}'
fresh; rec "$SUT" 101 501 src/a.tsx:12; rec "$SUT" 102 502 src/b.ts:40
want "a value that is not a count falls back to 2" "1" "$(n_of)"
want_in "and says so" "review.classNoticeAt is 'lots'" "$R"
cp "$FIX/cfg.base" "$CFG"

echo "--- the same finding still standing in a later round is one sighting, not a repeat ---"
fresh; rec "$SUT" 101 501 src/a.tsx:12; rec "$SUT" 101 501 src/a.tsx:14
want "one sighting" "1" "$(grep -c . "$FINDING_CLASS_LEDGER")"
want "no notice" "0" "$(n_of)"

echo "--- no class named: the file-and-summary key still repeats ---"
fresh; rec "$SUT" 101 501 src/a.sh:3 ""; rec "$SUT" 102 502 src/a.sh:9 ""
want "the same defect in the same file on two changes is one notice" "1" "$(n_of)"
want_in "proposing a lint rule for code" 'a lint rule or a write-time check' "$(cat "$FIX/notices")"

echo "--- two wordings of one rule: one class, one notice ---"
worded() { # <file> <path> <summary> <class> — a finding as the review returns it now
  jq -nc --arg f "$2" --arg s "$3" --arg c "$4" '{key: "k", id: "F1", file: $f, line: 3, grade: "major", rule: "failure-shown-as-success", class: $c, summary: $s, fix: 0}' > "$1"
}
case_rule() { # <sut> — notices after two differently worded findings under one rule
  fresh
  worded "$FIX/fc/w1" src/queue.tsx "The queue shows empty when its read fails" "failed read shown as empty"
  worded "$FIX/fc/w2" api/save.ts "A save the server refused reads as saved" "refused write reported as saved"
  SWARM_GH="$BIN/fgh" bash "$1" record 201 "$FIX/fc/w1" 601 >/dev/null 2>&1
  SWARM_GH="$BIN/fgh" bash "$1" record 202 "$FIX/fc/w2" 602 >/dev/null 2>&1
  n_of
}
want "two wordings of one rule are one notice" "1" "$(case_rule "$SUT")"
want "and one class on the ledger" "failure-shown-as-success" "$(jq -r .key "$FINDING_CLASS_LEDGER" | sort -u)"
want "both on the ledger, each with its rule" "2" "$(jq -r 'select(.rule == "failure-shown-as-success") | .id' "$FINDING_CLASS_LEDGER" | grep -c .)"
want "a rule is its own key" "dead-or-unwired" "$(echo '{"rule":"dead-or-unwired","class":"a dead save button","file":"a.ts"}' | bash "$SUT" key)"
want "other falls to the class" "a-dead-save-button" "$(echo '{"rule":"other","class":"a dead save button","file":"a.ts"}' | bash "$SUT" key)"
fresh; posted "$FIX/fc/p" src/a.ts:1 "" ; jq -c '. + {rule: "dead-or-unwired", id: "F1"}' "$FIX/fc/p" > "$FIX/fc/p2"; jq -c '. + {file: "src/b.ts", id: "F2"}' "$FIX/fc/p2" >> "$FIX/fc/p2"
SWARM_GH="$BIN/fgh" bash "$SUT" record 203 "$FIX/fc/p2" 603 >/dev/null 2>&1
want "one rule twice on one change tells no one: it counts changes" "0" "$(n_of)"
want "the never-twice key ignores the rule, so a second real finding is still raised" "2" \
  "$(jq -n -r "$(cat "$HERE/finding-key.jq")"' [{rule: "dead-or-unwired", file: "a.ts", summary: "one"}, {rule: "dead-or-unwired", file: "b.ts", summary: "two"}] | map(finding_key) | unique | length')"

echo "--- old rows read: no rule, no kind, a bare told key ---"
fresh
printf '%s\n' '{"id":"9|old-slug|a.ts","at":1,"week":"2026-W40","key":"old-slug","class":"old slug","ticket":"9","pr":"","file":"a.ts","line":1,"grade":"major","summary":"s","host":"mac"}' \
  '{"id":"10|a.ts|two words","at":2,"week":"2026-W40","key":"a.ts|two words","class":null,"ticket":"10","pr":"","file":"a.ts","line":1,"grade":"minor","summary":"s","host":"mac"}' > "$FINDING_CLASS_LEDGER"
printf 'old-slug\n' > "${FINDING_CLASS_LEDGER%.jsonl}.noticed"
rec "$SUT" 11 511 src/a.tsx:1 "old slug"; rc=$?
want "a record over old rows finishes" "0" "$rc"
want "old rows from past weeks are not this week's count" "0" "$(n_of)"
want_in "weekly reads them" '^old-slug +review' "$(FINDING_CLASS_NOW=$(date +%s) bash "$SUT" weekly --weeks 80 2>&1 | grep '^old-slug')"
rec "$SUT" 12 512 src/b.tsx:1 "old slug"
want "a bare told key from before weeks does not silence this week" "1" "$(n_of)"
fresh; printf '%s\n' '{"file":"x.ts","line":1,"summary":"the save is dropped"}' > "$FIX/fc/o"
SWARM_GH="$BIN/fgh" bash "$SUT" record 13 "$FIX/fc/o" 1 >/dev/null 2>&1; SWARM_GH="$BIN/fgh" bash "$SUT" record 14 "$FIX/fc/o" 2 >/dev/null 2>&1
want_in "a key with spaces has none in its log token" ' finding-class:x\.ts\|the-save-is-dropped seen 2 times' "$(cat "$FIX/notices")"

echo "--- a thrown-away change: a check sighting at once, its test files on the next pass ---"
fresh
out=$(SWARM_GH=/nonexistent bash "$SUT" check-failed 301 701 "Unit tests 1/1" 9901 2>&1); rc=$?
want "check-failed needs no network" "0" "$rc"
want "one check sighting, spaces out of the class" "check:Unit-tests-1/1" "$(jq -r .key "$FINDING_CLASS_LEDGER")"
SWARM_GH="$BIN/fgh" bash "$SUT" check-failed 301 701 "Unit tests 1/1" 9901 >/dev/null 2>&1
want "the same check on the same PR is one sighting" "1" "$(grep -c . "$FINDING_CLASS_LEDGER")"
printf 'Unit tests\tRun\t2026-11-06T09:21:33Z \033[41m FAIL \033[49m apps/web/src/a.test.ts > one > fails\nUnit tests\tRun\t2026 FAIL apps/web/src/a.test.ts > two\nnoise scripts/ok.test.ts passed\nFAIL scripts/tool.test.sh\n' > "$FIX/job.log"
SWARM_GH="$BIN/fgh" bash "$SUT" pass >/dev/null 2>&1
want "each failing file once, nothing that passed" "test:apps/web/src/a.test.ts test:scripts/tool.test.sh" "$(jq -r 'select(.key | startswith("test:")) | .key' "$FINDING_CLASS_LEDGER" | tr '\n' ' ' | sed 's/ $//')"
want "the log queue is empty after" "" "$(cat "${FINDING_CLASS_LEDGER%.jsonl}.logs.tsv" 2>/dev/null)"
want "and no test notice below the limit" "0" "$(n_of)"

echo "--- logs are capped a pass, and one unreadable three times is dropped ---"
fresh; cfg_review '{}'; jq '.findingClasses = {logsPerPass: 2}' "$FIX/cfg.base" > "$CFG"
for i in 1 2 3; do SWARM_GH="$BIN/fgh" bash "$SUT" check-failed "30$i" "70$i" unit "990$i" >/dev/null 2>&1; done
printf 'FAIL a.test.ts\n' > "$FIX/job.log"
: > "$FIX/fgh.log"; SWARM_GH="$BIN/fgh" bash "$SUT" pass >/dev/null 2>&1
want "two logs read this pass" "2" "$(grep -c '^run view' "$FIX/fgh.log")"
want "the third waits" "1" "$(grep -c . "${FINDING_CLASS_LEDGER%.jsonl}.logs.tsv")"
rm -f "$FIX/job.log"
for i in 1 2 3; do SWARM_GH="$BIN/fgh" bash "$SUT" pass >/dev/null 2>&1; done
want "unreadable three times: dropped" "0" "$(lines "${FINDING_CLASS_LEDGER%.jsonl}.logs.tsv")"
cp "$FIX/cfg.base" "$CFG"

echo "--- the limit: checks and tests tell the PM once a week, and the log line starts finding-class: ---"
AW="$STATE/coordinator/agent-work.log"
sights() { # <sut> <from> <to> <check> — that many changes thrown away with it red
  local i; for ((i = $2; i <= $3; i++)); do SWARM_GH="$BIN/fgh" bash "$1" check-failed "$i" "$i" "$4" >/dev/null 2>&1; done
}
case_limit() { # <sut> — log lines after 4 sightings, 5, 6, then next week's 4 and 5
  fresh; rm -f "$AW" "$STATE"/coordinator/notified.*.keys
  export FINDING_CLASS_NOTIFY="$KIT/scripts/coordinator-notify.sh"
  export FINDING_CLASS_NOW=$NOW
  sights "$1" 401 404 typecheck; SWARM_GH="$BIN/fgh" bash "$1" pass >/dev/null 2>&1; printf '%s ' "$(lines "$AW")"
  sights "$1" 405 405 typecheck; SWARM_GH="$BIN/fgh" bash "$1" pass >/dev/null 2>&1; printf '%s ' "$(lines "$AW")"
  sights "$1" 406 406 typecheck; SWARM_GH="$BIN/fgh" bash "$1" pass >/dev/null 2>&1; printf '%s ' "$(lines "$AW")"
  export FINDING_CLASS_NOW=$((NOW + W))
  sights "$1" 411 414 typecheck; SWARM_GH="$BIN/fgh" bash "$1" pass >/dev/null 2>&1; printf '%s ' "$(lines "$AW")"
  sights "$1" 415 415 typecheck; SWARM_GH="$BIN/fgh" bash "$1" pass >/dev/null 2>&1; lines "$AW"
  export FINDING_CLASS_NOTIFY="$BIN/notify"; unset FINDING_CLASS_NOW
}
W=604800; NOW=1793793600
want "none at 4, one at 5, still one at 6; next week none at 4, one more at 5" "0 1 1 1 2" "$(case_limit "$SUT")"
line1=$(head -1 "$AW")
want_in "the line starts finding-class:, then the class and count" '^finding-class:check:typecheck seen 5 times in 2026-W45 ' "$line1"
want_in "with a proposed source fix" 'Fix it at the source: find what these changes keep missing' "$line1"
want "the PM's watcher reads the class" "finding-class:check:typecheck" "$(printf '%s' "$line1" | grep -oE 'finding-class:[^ ]+' | head -1)"
want "no ticket is filed" "" "$(grep -E 'issues( |$)' "$FIX/fgh.log" 2>/dev/null | grep -v 'comments\|labels=')"
fresh; rm -f "$AW" "$STATE"/coordinator/notified.*.keys; cfg_review '{"checkClassNoticeAt": 3}'
sights "$SUT" 421 423 lint; SWARM_GH="$BIN/fgh" bash "$SUT" pass >/dev/null 2>&1
want "review.checkClassNoticeAt sets the limit" "1" "$(n_of)"
cp "$FIX/cfg.base" "$CFG"

echo "--- develop's red checks cross the limit too ---"
fresh; for i in 1 2 3 4 5 6; do printf '%s\tcheck:mock-drift\tsha%s\n' "$WK_NOW" "$i" >> "$DEVELOP_RED_COUNT"; done
SWARM_GH="$BIN/fgh" bash "$SUT" pass >/dev/null 2>&1
want_in "the red check tells the PM" 'finding-class:check:check:mock-drift seen 6 times' "$(cat "$FIX/notices")"

echo "--- in shadow nothing is told or marked, and the next live pass tells it ---"
fresh; sights "$SUT" 431 435 typecheck
COORDINATOR_SHADOW=1 SWARM_GH="$BIN/fgh" bash "$SUT" pass >/dev/null 2>&1
want "shadow tells no one" "0" "$(n_of)"
want "and marks nothing" "" "$(cat "${FINDING_CLASS_LEDGER%.jsonl}.noticed")"
SWARM_GH="$BIN/fgh" bash "$SUT" pass >/dev/null 2>&1
want "the live pass tells once" "1" "$(n_of)"

echo "--- a pass with nothing new reads nothing from GitHub ---"
export FINDING_CLASS_SHARE=on; printf '[]' > "$FIX/tally.json"
SWARM_GH="$BIN/fgh" bash "$SUT" pass >/dev/null 2>&1; : > "$FIX/fgh.log"
SWARM_GH="$BIN/fgh" bash "$SUT" pass >/dev/null 2>&1
want "no call" "" "$(cat "$FIX/fgh.log")"
export FINDING_CLASS_SHARE=off

echo "--- the weekly count: most first, and the new kinds ---"
fresh; export FINDING_CLASS_NOW=$NOW
sights "$SUT" 441 443 typecheck
SWARM_GH="$BIN/fgh" bash "$SUT" check-failed 451 751 unit 9951 >/dev/null 2>&1
printf 'FAIL apps/x.test.ts\n' > "$FIX/job.log"; SWARM_GH="$BIN/fgh" bash "$SUT" pass >/dev/null 2>&1
rec "$SUT" 461 761 src/a.ts:1 "a dead control"
wk2=$(SWARM_GH="$BIN/fgh" bash "$SUT" weekly 2>&1); unset FINDING_CLASS_NOW
want_in "a test class reads kind test" '^test:apps/x\.test\.ts +test ' "$(printf '%s\n' "$wk2" | grep '^test:')"
want_in "a thrown-away check reads kind check" '^check:typecheck +check ' "$(printf '%s\n' "$wk2" | grep '^check:typecheck')"
want "the largest first" "check:typecheck" "$(printf '%s\n' "$wk2" | sed -n 3p | awk '{print $1}')"

echo "--- any machine: one sighting here and one on another host is seen twice ---"
case_cross() { # <sut>
  fresh; export FINDING_CLASS_SHARE=on
  jq -nc --arg wk "$WK_NOW" '[{id: 9001, body: ("<!-- finding-classes:v1 host=yomato -->\nx\n\n```json\n" + ([{id: "900|failure-shown-as-empty|src/z.tsx", at: 1, week: $wk, key: "failure-shown-as-empty", ticket: "900", pr: "990", file: "src/z.tsx", line: 3, host: "yomato"}] | tojson) + "\n```")}]' > "$FIX/tally.json"
  rec "$1" 101 501 src/a.tsx:12; n_of
}
want "the other host's sighting counts: one notice" "1" "$(case_cross "$SUT")"
want_in "naming the other host's instance" 'PR #990 src/z\.tsx:3 \(yomato\)' "$(cat "$FIX/notices")"
want_in "the notice is posted on the tally for every host" 'issues/77/comments --input' "$(cat "$FIX/fgh.log")"
want_in "and this host's sightings are published there" 'POST repos/acme/widgets/issues/77/comments' "$(cat "$FIX/fgh.log")"
echo "--- a notice another host posted is not raised again ---"
fresh; export FINDING_CLASS_SHARE=on
jq -nc --arg wk "$WK_NOW" '[{id: 9001, body: ("<!-- finding-classes:v1 host=yomato -->\n```json\n" + ([{id: "900|failure-shown-as-empty|src/z.tsx", at: 1, week: $wk, key: "failure-shown-as-empty", ticket: "900", pr: "990", file: "src/z.tsx", line: 3, host: "yomato"}] | tojson) + "\n```")},
         {id: 9002, body: ("**Seen again.** x\n\n<!-- finding-class-notice: failure-shown-as-empty@" + $wk + " -->")}]' > "$FIX/tally.json"
rec "$SUT" 101 501 src/a.tsx:12
want "told once, by the other host" "0" "$(n_of)"
echo "--- an unreadable tally: said, and this host counts alone ---"
fresh; export FINDING_CLASS_SHARE=on; printf 'not json' > "$FIX/tally.json"
rec "$SUT" 101 501 src/a.tsx:12
want_in "it says the count is this host's only" 'unknown — the shared tally could not be read' "$R"

echo "--- the weekly count: one command, review classes and red checks, and not falling ---"
# A Wednesday noon, so no case straddles a week's edge: 2026-11-04, in 2026-W45.
W=604800; NOW=1793793600
case_weekly() { # <sut> — prints the weekly table
  fresh
  FINDING_CLASS_NOW=$((NOW - 2 * W)) rec "$1" 101 501 src/a.tsx:12
  FINDING_CLASS_NOW=$((NOW - 2 * W)) rec "$1" 102 502 src/b.ts:40
  FINDING_CLASS_NOW=$((NOW - W - 3600)) bash "$1" fixed failure-shown-as-empty "the kit's QueryState component" >/dev/null
  FINDING_CLASS_NOW=$((NOW - W + 60)) rec "$1" 103 503 src/c.tsx:7
  FINDING_CLASS_NOW=$((NOW - W + 120)) rec "$1" 104 504 src/d.tsx:7
  FINDING_CLASS_NOW=$((NOW - W + 180)) rec "$1" 105 505 src/e.tsx:7
  FINDING_CLASS_NOW=$((NOW)) rec "$1" 106 506 src/x.ts:1 "a dead control"
  printf '2026-W45\tTypecheck\taaaaaaa\n2026-W45\tTypecheck\tbbbbbbb\n' > "$DEVELOP_RED_COUNT"
  FINDING_CLASS_NOW=$NOW SWARM_GH="$BIN/fgh" bash "$1" weekly 2>&1
}
wk=$(case_weekly "$SUT")
echo "$wk"
want_in "a header naming the last four weeks" "^class +kind +2026-W42 +2026-W43 +2026-W44 +2026-W45 " "$wk"
want_in "the review class, counted by week" "^failure-shown-as-empty +review +[0-9]+ +2 +3 +0 " "$(printf '%s\n' "$wk" | grep '^failure-shown')"
want_in "a red check from develop-red's count, in the same table" "^check:Typecheck +check +0 +0 +0 +2 " "$(printf '%s\n' "$wk" | grep '^check:')"
want_in "the class that rose after its fix reads not falling" "NOT FALLING \(2 in the 7 days before, 3 after\)" "$(printf '%s\n' "$wk" | grep '^failure-shown')"
want_in "a class with no fix recorded carries none" "^a-dead-control +review .* —$" "$(printf '%s\n' "$wk" | grep '^a-dead-control')"

echo "--- no brief, skill, rule, shared instruction or template asks a builder for a lesson ---"
lesson_asks() { # <kit root> — every line that asks for a lesson
  grep -rniE "lesson" "$1/briefs" "$1/skills" "$1/rules" "$1/shared" "$1/agents" "$1/templates" "$1/hooks" 2>/dev/null \
    | grep -vE '\.test\.sh:' || true
}
want "none, anywhere the builder reads" "" "$(lesson_asks "$KIT")"
want "and the lesson check is gone" "gone" "$( [ -e "$KIT/scripts/check-lesson.sh" ] || [ -e "$KIT/templates/pull-request-lesson.md" ] || [ -e "$KIT/.github/workflows/lesson.yml" ] || [ -e "$KIT/.github/workflows/kit-lesson.yml" ] || echo gone)"

echo "--- plants: each rule broken, its case catches it ---"
if p=$(plant once-notifies 's/select\(\$n >= \(if \$mech then \$chk else \$at end\)\)/select(\$n >= 1)/'); then
  [ "$(case_once "$p")" != 0 ] && ok "planted: a notice on the first sighting → the once case goes red" || bad "planted: a first-sighting notice, and the once case did not see it"
fi
if p=$(plant no-notice 's/if ! bash "\$NOTIFY" --class agent "finding-class:\$k\@\$wk" "\$line" >\/dev\/null 2>&1; then/if false; then/'); then
  [ "$(case_twice "$p")" != 1 ] && ok "planted: the notice call gone → the twice case goes red" || bad "planted: the notice call gone, and the twice case did not see it"
fi
if p=$(plant notice-every-time 's/printf \x27%s\\n\x27 "\$k\@\$wk" >> "\$NOTICED"/:/'); then
  # With the told list never written, each record past the second tells the PM again.
  [ "$(case_thrice "$p")" != 1 ] && ok "planted: the told list never written → the thrice case goes red" || bad "planted: the told list never written, and the thrice case did not see it"
fi
if p=$(plant no-other-hosts "s/\[ \"\\\$share\" = 1 \] && printf '%s\\\\n' \"\\\$tally\" \| jq -c 'select\(.s\) \| .s'; \} \| jq -s -c 'unique_by/true; } | jq -s -c 'unique_by/"); then
  [ "$(case_cross "$p")" != 1 ] && ok "planted: other hosts' sightings ignored → the any-machine case goes red" || bad "planted: other hosts ignored, and the any-machine case did not see it"
fi
if p=$(plant no-weekly-rows 's/for \(i = 1; i <= n; i\+\+\) \{\n        k = keys\[i\]/for (i = 1; i <= 0; i++) {\n        k = keys[i]/'); then
  printf '%s\n' "$(case_weekly "$p")" | grep -q '^failure-shown-as-empty' && bad "planted: the class rows dropped, and the weekly case did not see it" || ok "planted: the class rows dropped → the weekly case goes red"
fi
if p=$(plant no-not-falling 's/st = "fixed " fd ": NOT FALLING/st = "fixed " fd ": falling/'); then
  printf '%s\n' "$(case_weekly "$p")" | grep -q 'NOT FALLING' && bad "planted: not falling never said, and the weekly case did not see it" || ok "planted: not falling never said → the weekly case goes red"
fi
if p=$(plant notice-at-fixed 's/NOTICE_AT=\$\(fc_limit review.classNoticeAt 2\)/NOTICE_AT=2/'); then
  [ "$(case_at3 "$p")" != "0 1" ] && ok "planted: the setting ignored, 2 hard-coded → the classNoticeAt case goes red" || bad "planted: the setting ignored, and the classNoticeAt case did not see it"
fi
# The grouping removed: a class key that does not read the rule, in a copy of the key file.
pk="$FIX/plant-key"; rm -rf "$pk"; mkdir -p "$pk"; ln -s "$HERE"/* "$pk"/; rm -f "$pk/finding-key.jq"
perl -0pe 's/if \(\$r \| length\) > 0 and \$r != "other" then \$r\n\s+elif/if/' "$HERE/finding-key.jq" > "$pk/finding-key.jq"
if cmp -s "$HERE/finding-key.jq" "$pk/finding-key.jq"; then bad "plant no-rule-key: the substitution matched nothing"
else [ "$(case_rule "$pk/finding-class.sh")" != 1 ] && ok "planted: the key ignores the rule → the two-wordings case goes red" || bad "planted: the key ignores the rule, and the two-wordings case did not see it"; fi
if p=$(plant no-week-window 's/\[\.\[\] \| select\(\.week == \$wk\)\] as \$rows/. as \$rows/'); then
  [ "$(case_limit "$p")" != "0 1 1 1 2" ] && ok "planted: no weekly window → the limit case goes red" || bad "planted: no weekly window, and the limit case did not see it"
fi
if p=$(plant check-limit-review 's/if \$mech then \$chk else \$at end/\$at/'); then
  [ "$(case_limit "$p")" != "0 1 1 1 2" ] && ok "planted: checks on the review limit → the limit case goes red" || bad "planted: checks on the review limit, and the limit case did not see it"
fi
if p=$(plant no-log-line 's/"\$NOTIFY" --class agent/true --class agent/'); then
  [ "$(case_limit "$p")" != "0 1 1 1 2" ] && ok "planted: the notify call gone → the limit case goes red" || bad "planted: the notify call gone, and the limit case did not see it"
fi
mkdir -p "$FIX/plant-kit/briefs" && printf 'Every fix ships a lesson: add a guard test.\n' > "$FIX/plant-kit/briefs/build.md"
[ -n "$(lesson_asks "$FIX/plant-kit")" ] && ok "planted: a brief asking for a lesson → the grep case goes red" || bad "planted: a brief asks for a lesson, and the grep case did not see it"

suite_end "$FAILED"
