#!/usr/bin/env bash
# panel-report.test.sh — the report counts from the files, and the gate is honest.
set -u; cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d); fail=0
ok(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
row(){ printf 'screens\t%s\t%s\tC%s\t%s\t\t%s\t-\tQuestion %s\t\n' "$1" "$2" "$3" "$4" "$4" "$2"; }
hdr='panel\treviewer\tn\tcluster\tverdict_a\tverdict_b\tverdict\tticket\task\tevidence'
{ printf "$hdr\n"; for i in 1 2 3 4 5 6 7; do row A $i 1 ANSWERED; done; row A 8 2 PARTIAL; row A 9 2 MISSING; row A 10 2 NOT_ECHO; } > "$T/scores.tsv"
{ printf "$hdr\n"; for i in 1 2 3; do row A $i 1 ANSWERED; done; for i in 4 5 6 7 8 9 10; do row A $i 2 MISSING; done; } > "$T/scores-before.tsv"
printf '# Sample · Screen review\n' > "$T/subject.md"
out=$(python3 scripts/panel-report.py "$T" --bar 70)
ok "70% at a 70 bar passes"        '[[ "$out" == *"screens: 70%"*"PASS"* ]]'
ok "the page shows before → after" 'grep -q "30% → <b>70%</b>" "$T/report.html"'
ok "an older verdict name still counts as not in scope" 'grep -q "<b>1</b><span>not this area" "$T/report.html"'
out2=$(python3 scripts/panel-report.py "$T" --bar 80)
ok "70% at an 80 bar stops the build" '[[ "$out2" == *"STOP"* ]] && grep -q "Stops the build" "$T/report.html"'
ok "the one missing question is listed" 'grep -q "Question 9" "$T/report.html"'
rm -rf "$T"; exit $fail
