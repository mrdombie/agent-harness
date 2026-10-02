#!/usr/bin/env bash
# spec-names-api.sh — does a ticket body name an API the UI depends on?
#
# WHY: /finish's Gate 1 refuses a PR that ships UI without the API its ticket
# describes. It used to decide "the ticket describes an API" by grepping for the
# HEADING "## Backend contract" — the heading /claim's Gate 2 REQUIRES on every
# screen ticket. So a polish ticket that wrote "## Backend contract — None, no
# endpoint" to get past /claim was then refused by /finish for shipping UI
# without its (non-existent) API (origin project, 2026-10-02). The two gates came
# from one intervention on 2026-05-24 and contradicted each other whenever the
# contract was empty — or listed only routes that already EXISTED.
set -uo pipefail
SUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/spec-names-api.sh"
PASS=0; FAIL=0
yes() { if printf '%s\n' "$2" | bash "$SUT"; then PASS=$((PASS+1)); echo "  ok   — names an API: $1"; else FAIL=$((FAIL+1)); echo "  FAIL — should name an API: $1"; fi; }
no()  { if printf '%s\n' "$2" | bash "$SUT"; then FAIL=$((FAIL+1)); echo "  FAIL — should NOT name an API: $1"; else PASS=$((PASS+1)); echo "  ok   — names none: $1"; fi; }

no  "an empty contract"             $'## Backend contract\n\nNone. Presentational polish: no endpoint consumed, none added.'
no  "the API-contract heading alone" $'## API contract\nNothing new.'
no  "the word endpoint in prose"    'The card shows which endpoint failed, as text.'
no  "api inside another word"       'Rapid/slow toggle; therapist/ coach labels'
no  "an empty body"                 ''
yes "a route in the contract"       $'## Backend contract\n| GET /api/posts | to build |'
yes "a NET-NEW route"               $'## Backend contract\n- POST /api/leads/forget — NET-NEW'
yes "an api source path"            'Touches apps/api/src/app/api/posts/route.ts'
yes "a route mid-sentence"          'The UI reads /api/voice/beliefs on load.'
no  "a route marked EXISTS"         'None — GET /api/content/[postId]/variations (EXISTS)'
no  "a contract row marked EXISTS"  $'## Backend contract\n| GET /api/posts | EXISTS |\n| GET /api/voices | exists |'
yes "EXISTS beside a NET-NEW row"   $'| GET /api/posts | EXISTS |\n| POST /api/posts/pin | NET-NEW |'
yes "NET-NEW and EXISTS on one line" 'POST /api/x — NET-NEW (GET /api/x EXISTS)'
yes "a Next.js route file"          'Add src/app/api/leads/route.ts'

echo "--- /finish asks this script, not a heading grep ---"
FIN="$(dirname "$SUT")/../skills/finish/SKILL.md"
grep -q 'scripts/spec-names-api.sh' "$FIN" && { PASS=$((PASS+1)); echo "  ok   — Gate 1 calls it"; } || { FAIL=$((FAIL+1)); echo "  FAIL — Gate 1 does not call spec-names-api.sh"; }
grep -q '## Backend contract|## API contract' "$FIN" && { FAIL=$((FAIL+1)); echo "  FAIL — Gate 1 still keys on the heading"; } || { PASS=$((PASS+1)); echo "  ok   — no heading grep left"; }

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
