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

no  "an empty contract"              $'## Backend contract\n\nNone. Presentational polish: no endpoint consumed, none added.'
no  "the API-contract heading alone"  $'## API contract\nNothing new.'
no  "the word endpoint in prose"      $'## Backend contract\nThe card shows which endpoint failed, as text.'
no  "api inside another word"         $'## Backend contract\nRapid/slow toggle; therapist/ coach labels'
no  "an empty body"                   ''
no  "a route marked EXISTS"           $'## Backend contract\nNone — GET /api/content/[postId]/variations (EXISTS)'
no  "contract rows marked EXISTS"     $'## Backend contract\n| GET /api/posts | EXISTS |\n| GET /api/voices | exists |'
no  "NET-NEW: none"                   $'## Backend contract\n| **NET-NEW** | none |'
no  "routes OUTSIDE the contract"     $'## Repro\nGET /api/posts returns 500\n## Verify\nnpx vitest run apps/api/src/lib\n## Backend contract\nNone.'
no  "an api lib path in a checklist"  $'## Acceptance criteria\n- [ ] apps/api/src/lib/feeds/packs.ts exports the pack\n## Backend contract\nNo endpoint.'
no  "a route with no contract at all" 'The UI reads /api/voice/beliefs on load.'
yes "a route still to build"          $'## Backend contract\n| GET /api/posts | to build |'
yes "a NET-NEW route"                 $'## Backend contract\n- POST /api/leads/forget — NET-NEW'
yes "a NET-NEW row with no route"     $'## Backend contract\n| Conversation-history read | GET | No HTTP endpoint today | **NET-NEW** — Phase-2 wiring |\n| GET /api/pulse/turns | EXISTS |'
yes "EXISTS beside a NET-NEW row"     $'## Backend contract\n| GET /api/posts | EXISTS |\n| POST /api/posts/pin | NET-NEW |'
yes "NET-NEW and EXISTS on one line"  $'## API contract\nPOST /api/x — NET-NEW (GET /api/x EXISTS)'
no  "EXISTS, unchanged"               $'## Backend contract\n| POST /api/media/presign | EXISTS | unchanged |'
no  "EXISTS, no signature change"     $'## Backend contract\n| GET /api/posts | EXISTS — no signature change |'
no  "EXISTS, do not modify it"        $'## Backend contract\n| GET /api/audit | EXISTS | Do not modify it |'
yes "EXISTS but extended"             $'## Backend contract\n| GET /api/drafts | EXISTS — extended with a voiceId filter |'
yes "a Next.js route file"            $'## Backend contract\nAdd src/app/api/leads/route.ts'
yes "a later section does not end it early" $'## Backend contract\n| GET /api/a | EXISTS |\n| POST /api/b | to build |\n## Out of scope\nNothing.'

echo "--- /finish asks this script, not a heading grep ---"
FIN="$(dirname "$SUT")/../skills/finish/SKILL.md"
grep -q 'scripts/spec-names-api.sh' "$FIN" && { PASS=$((PASS+1)); echo "  ok   — Gate 1 calls it"; } || { FAIL=$((FAIL+1)); echo "  FAIL — Gate 1 does not call spec-names-api.sh"; }
grep -q '## Backend contract|## API contract' "$FIN" && { FAIL=$((FAIL+1)); echo "  FAIL — Gate 1 still keys on the heading"; } || { PASS=$((PASS+1)); echo "  ok   — no heading grep left"; }

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
