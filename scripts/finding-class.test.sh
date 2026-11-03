#!/usr/bin/env bash
# finding-class.test.sh — a review-finding class seen once raises no notice; seen twice,
# on any change or machine, exactly one, to the PM's channel; seen three times, still one.
# The weekly count prints each class and red check, and a class that did not fall after
# its source fix says so. No brief, skill or rule asks a builder for a lesson. Each rule
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

export FINDING_CLASS_LEDGER="$FIX/fc/finding-classes.jsonl" FINDING_CLASS_NOTIFY="$BIN/notify" FINDING_CLASS_HOST=mac DEVELOP_RED_COUNT="$FIX/check-class-count.tsv"
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
  *) cat > /dev/null ;;
esac
SH
chmod +x "$BIN/fgh"

SUT="$HERE/finding-class.sh"
fresh() { # a host with nothing seen, nothing told, no tally
  rm -rf "$FIX/fc"; mkdir -p "$FIX/fc"; export FINDING_CLASS_SHARE=off
  rm -f "$FIX/notices" "$FIX/tally.json" "$FIX/fgh.log" "$DEVELOP_RED_COUNT"; unset FINDING_CLASS_NOW
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
want_in "on the PM's channel, keyed by the class" '^--class agent finding-class:failure-shown-as-empty ' "$nl"
want_in "naming its instances, PR and file:line" 'PR #501 src/a\.tsx:12.*PR #502 src/b\.ts:40' "$nl"
want_in "and a proposed source fix" 'Fix it at the source: a kit component' "$nl"
want_in "never a test on the next change" 'Not a test on the next change' "$nl"

echo "--- seen three times: still one ---"
want "three sightings, still one notice" "1" "$(case_thrice "$SUT")"

echo "--- the same finding still standing in a later round is one sighting, not a repeat ---"
fresh; rec "$SUT" 101 501 src/a.tsx:12; rec "$SUT" 101 501 src/a.tsx:14
want "one sighting" "1" "$(grep -c . "$FINDING_CLASS_LEDGER")"
want "no notice" "0" "$(n_of)"

echo "--- no class named: the file-and-summary key still repeats ---"
fresh; rec "$SUT" 101 501 src/a.sh:3 ""; rec "$SUT" 102 502 src/a.sh:9 ""
want "the same defect in the same file on two changes is one notice" "1" "$(n_of)"
want_in "proposing a lint rule for code" 'a lint rule or a write-time check' "$(cat "$FIX/notices")"

echo "--- any machine: one sighting here and one on another host is seen twice ---"
case_cross() { # <sut>
  fresh; export FINDING_CLASS_SHARE=on
  jq -nc '[{id: 9001, body: ("<!-- finding-classes:v1 host=yomato -->\nx\n\n```json\n" + ([{id: "900|failure-shown-as-empty|src/z.tsx", at: 1, week: "2026-W44", key: "failure-shown-as-empty", ticket: "900", pr: "990", file: "src/z.tsx", line: 3, host: "yomato"}] | tojson) + "\n```")}]' > "$FIX/tally.json"
  rec "$1" 101 501 src/a.tsx:12; n_of
}
want "the other host's sighting counts: one notice" "1" "$(case_cross "$SUT")"
want_in "naming the other host's instance" 'PR #990 src/z\.tsx:3 \(yomato\)' "$(cat "$FIX/notices")"
want_in "the notice is posted on the tally for every host" 'issues/77/comments --input' "$(cat "$FIX/fgh.log")"
want_in "and this host's sightings are published there" 'POST repos/acme/widgets/issues/77/comments' "$(cat "$FIX/fgh.log")"
echo "--- a notice another host posted is not raised again ---"
fresh; export FINDING_CLASS_SHARE=on
jq -nc '[{id: 9001, body: ("<!-- finding-classes:v1 host=yomato -->\n```json\n" + ([{id: "900|failure-shown-as-empty|src/z.tsx", at: 1, week: "2026-W44", key: "failure-shown-as-empty", ticket: "900", pr: "990", file: "src/z.tsx", line: 3, host: "yomato"}] | tojson) + "\n```")},
         {id: 9002, body: "**Seen again.** x\n\n<!-- finding-class-notice: failure-shown-as-empty -->"}]' > "$FIX/tally.json"
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
if p=$(plant once-notifies 's/select\(length >= 2\)/select(length >= 1)/'); then
  [ "$(case_once "$p")" != 0 ] && ok "planted: a notice on the first sighting → the once case goes red" || bad "planted: a first-sighting notice, and the once case did not see it"
fi
if p=$(plant no-notice 's/if ! bash "\$NOTIFY" --class agent "finding-class:\$k" "\$line" >\/dev\/null 2>&1; then/if false; then/'); then
  [ "$(case_twice "$p")" != 1 ] && ok "planted: the notice call gone → the twice case goes red" || bad "planted: the notice call gone, and the twice case did not see it"
fi
if p=$(plant notice-every-time 's/printf \x27%s\\n\x27 "\$k" >> "\$NOTICED"/:/'); then
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
mkdir -p "$FIX/plant-kit/briefs" && printf 'Every fix ships a lesson: add a guard test.\n' > "$FIX/plant-kit/briefs/build.md"
[ -n "$(lesson_asks "$FIX/plant-kit")" ] && ok "planted: a brief asking for a lesson → the grep case goes red" || bad "planted: a brief asks for a lesson, and the grep case did not see it"

suite_end "$FAILED"
