#!/usr/bin/env bash
# coordinator-compare.test.sh — the report agrees where the shadow and the loop
# made the same call, and lists every place they did not.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
CMP="$HERE/coordinator-compare.sh"
A="$STATE/coordinator/actions.log"
mkdir -p "$STATE/coordinator"
T0=$(swarm_epoch 2026-10-14T01:00:00Z)
at() { swarm_iso $(( T0 + $1 * 60 )); }   # minutes after 01:00
shadow_spawn() { printf '%s\twould\tspawn\t%s\tnew\n' "$(at "$1")" "$2" >> "$A"; }
shadow_plan()  { printf '%s\tplan\t-\t\tlive= slots=0 next=%s\n' "$(at "$1")" "$2" >> "$A"; }
real_start()   { printf '{"run_id":"claim-%s-r","ticket":"%s","started_at":"%s"}\n' "$2" "$2" "$(at "$1")" > "$STATE/runs/claim-$2-r$1.json"; }
cmp() { bash "$CMP" --since "$(at 0)" --until "$(at 600)" 2>&1; }

echo "--- the same call, minutes apart, is agreement ---"
: > "$A"; rm -f "$STATE/runs"/*
shadow_spawn 10 501; real_start 12 501
shadow_plan 20 502; real_start 22 502
out=$(cmp); rc=$?
want "nothing to report"                       "0" "$rc"
want_in "and it says so"                       'Disagreements: 0' "$out"
want_in "the counts are there"                 '\| The loop started \| 2 \|' "$out"

echo "--- a different call is listed, both ways round ---"
: > "$A"; rm -f "$STATE/runs"/*
shadow_spawn 10 501; real_start 12 777
shadow_spawn 100 503; real_start 200 503
out=$(cmp); rc=$?
want "disagreements exit 1"                    "1" "$rc"
want_in "the shadow's lone call is listed"     "\| $(at 10) \| #501 \|" "$out"
want_in "the loop's lone start is listed"      "\| $(at 12) \| #777 \| claim-777-r \|" "$out"
want_in "outside the grace is no match"        "\| $(at 100) \| #503 \|" "$out"
want_in "and counted"                          'Disagreements: 4' "$out"

echo "--- the window is the window ---"
: > "$A"; rm -f "$STATE/runs"/*
shadow_spawn 700 501
out=$(cmp)
want_in "a call after --until is not read"     'Disagreements: 0' "$out"

echo "--- the judgements the shadow would have asked for are shown ---"
printf '%s\twould\tjudge\tred-pr:41:abc\tred-pr: checks settled red\n' "$(at 30)" >> "$A"
out=$(cmp)
want_in "listed with what it was"              'red-pr:41:abc \| red-pr: checks settled red' "$out"

exit $FAILED
