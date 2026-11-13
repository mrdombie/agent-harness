#!/usr/bin/env bash
# plan-outside-note.test.sh — what a plan leaves out is a ticket item by its id (`item`), or
# plain words about something that is not a ticket item (`note`). Prose in `item` was
# refused by the contract, asked for again, answered the same way and parked: 65 refusals
# in the driver logs to 2026-11-12, 48 of the 56 tickets having no items to name at all.
# Now the driver moves the prose to `note` itself and the plan goes on, with no second
# call. Only an id marks a ticket item as left out; any other fault in the answer is
# asked for once more and then parks, as before.
# The briefs, the contract and the validator are the ones that ship; only the model is stubbed.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
fix_real_briefs
. "$HERE/../state.sh" || exit 1
KIT="$FIX/kit"

ITEMS='## The change
1. the list is renamed

## Acceptance criteria
- [ ] the new name shows on the page
- [ ] a shot of the page is in the pull request'
PROSE="The same rename in the other folders"

ticket() { # <n> <body>
  fix_issue "$1" OPEN "status:claimed"
  jq --arg b "$2" '.body = $b' "$FIX/gh/issue-$1.json" > "$FIX/i.json" && mv "$FIX/i.json" "$FIX/gh/issue-$1.json"
  driver_state_init "$1" --worktree "$REPO"
}
plan() { # <covers JSON> <outside JSON> — one behaviour, one task, the contract's shape
  jq -nc --argjson c "$1" --argjson o "$2" '{step:"plan",skills:["superpowers:writing-plans"],status:"planned",designSource:"ticket-body",
    premise:{verdict:"still-true",evidence:"a.sh:1"},
    features:[{id:"F1",behaviour:"a person sees the new name",steps:["open the page"],test:"f1.test.sh",passes:false,covers:$c}],
    tasks:[{item:"F1",title:"rename it",files:[{path:"f1.sh",action:"modify"}],tests:[{file:"f1.test.sh",behaviour:"b",redWhen:"r"}]}],
    outside:$o}'
}
step() { # <ticket> <answer> — the plan step from ${SUT_KIT:-the kit}, its briefs and contract with it
  local kit="${SUT_KIT:-$ROOT}"
  fix_ai plan "$2" superpowers:writing-plans
  : > "$CLAUDE_LOG"; : > "$GH_LOG"; R_RC=0
  R_OUT=$(DRIVER_BRIEFS="$kit/briefs" DRIVER_SCHEMAS="$kit/briefs/schemas" DRIVER_VALIDATE="$kit/briefs/validate.sh" \
    bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT
      . "$1/driver/driver-env.sh" && . "$1/driver/steps/plan.sh" && driver_step_plan "$2"' _ "$kit" "$1" 2>&1) || R_RC=$?
  R_CALLS=$(grep -c '^plan$' "$CLAUDE_LOG")
  R="rc=$R_RC calls=$R_CALLS"
}
kept() { jq -c "$2" "$(driver_state_dir "$1")/steps/plan.json" 2>/dev/null; } # <ticket> <jq>
N=600
next() { N=$((N + 1)); ticket "$N" "${1:-$ITEMS}"; }

# Each case leaves R (the exit and the number of model calls), R_OUT and N.
case_prose() { next; step "$N" "$(plan '["C1","A1"]' "$(jq -nc --arg p "$PROSE" '[{item:"A2",why:"taken in CI"},{item:$p,why:"each is its own later change"}]')")"; }
case_no_items() { next "No list here, only a paragraph."; step "$N" "$(plan '[]' "$(jq -nc --arg p "$PROSE" '[{item:$p,why:"later"}]')")"; }
case_prose_for_an_item() { next; step "$N" "$(plan '["C1","A1"]' '[{"item":"the shot in the pull request","why":"taken in CI"}]')"; }
case_neither() { next; step "$N" "$(plan '["C1","A1","A2"]' '[{"why":"no reason to name it"}]')"; }
case_other_fault() { next; step "$N" "$(plan '["C1","A1","A2"]' "$(jq -nc --arg p "$PROSE" '[{item:$p,why:"later"}]')" | jq -c '.tasks[0].item = "fix"')"; }

echo "--- prose in a left-out entry: kept as a note, the plan goes on, nothing asked again ---"
case_prose
want "the plan is accepted on the first answer"        "rc=0 calls=1" "$R"
want_in "  the run says what it did, in one line"      'plan: 1 left-out entry named no ticket item id — kept as a note, not asked again' "$R_OUT"
want "  the prose is the entry's note, its why kept"   "{\"why\":\"each is its own later change\",\"note\":\"$PROSE\"}" "$(kept "$N" '.outside[1]')"
want "  the entry with an id is untouched"             '{"item":"A2","why":"taken in CI"}' "$(kept "$N" '.outside[0]')"
want "  nothing is left to park on"                    "" "$(driver_state_get "$N" park_note)"
LIST="$(driver_state_dir "$N")/features.json"
want "  the list kept for the build carries both"      "A2|$PROSE" "$(jq -r '[.outside[] | .item // .note] | join("|")' "$LIST")"
want_in "  and a person reads both on the ticket"      "Left out, with why:.*- A2: taken in CI.*- $PROSE: each is its own later change" "$(tr '\n' ' ' < "$GH_LOG")"

echo "--- an id still marks its ticket item as left out; a note marks none ---"
. "$HERE/../ticket-parts.sh" || exit 1
printf '%s\n' "$ITEMS" > "$FIX/body.md"
jq '.items |= map(.passes = true)' "$LIST" > "$FIX/passing.json"
out=$(ticket_parts_check "$REPO" "$FIX/body.md" "$N" "$FIX/passing.json" | grep '^item'); want "self-check: A2, named by id, is not owed" "" "$out"
jq '.outside |= map(select(has("note")))' "$FIX/passing.json" > "$FIX/note-only.json"
out=$(ticket_parts_check "$REPO" "$FIX/body.md" "$N" "$FIX/note-only.json" | grep '^item')
want_in "self-check: with only the note, A2 is owed"   'A2 .*maps to no feature list item' "$out"
case_prose_for_an_item
want "prose standing in for a ticket item: sent back once, then refused" "rc=$DRIVER_E_REFUSED calls=2" "$R"
want_in "  told which item, by its id"                 'A2 \(“a shot of the page is in the pull request”\) is in no item.s covers and not in outside' "$(cat "$FIX/claude-stdin-plan.txt")"
want_not_in "  never as an answer the driver cannot read" 'does not match briefs/schemas' "$R_OUT"
next; step "$N" "$(plan '["C1","A1","A9"]' '[{"item":"A2","why":"taken in CI"}]')"
want "an id the ticket does not have is still refused" "rc=$DRIVER_E_REFUSED calls=2" "$R"
want_in "  by name"                                    'F1 covers A9, which the ticket does not have' "$R_OUT"

echo "--- a ticket with no items at all: what it leaves out is a note ---"
case_no_items
want "the plan is accepted on the first answer"        "rc=0 calls=1" "$R"
want "  the prose is a note"                           "\"$PROSE\"" "$(kept "$N" '.outside[0].note')"
want_in "  the planner was told so"                    'Ticket items: \(none — .*anything left out is a `note` in `outside`' "$(cat "$FIX/claude-stdin-plan.txt")"

echo "--- any other fault is asked for once more, then parks, as before ---"
case_other_fault
want "a task item off the contract: one re-ask, then the shape park" "rc=$DRIVER_E_SCHEMA calls=2" "$R"
want_in "  the park names that fault"                  '/tasks/0/item' "$(driver_state_get "$N" park_note)"
want_not_in "  and not the note, which was settled"    '/outside/' "$(driver_state_get "$N" park_note)"
case_neither
want "an entry naming nothing is refused"              "rc=$DRIVER_E_SCHEMA calls=2" "$R"
next; step "$N" "$(plan '["C1","A1","A2"]' '[{"item":"","why":"w"}]')"
want "an empty item is not made a note"                "rc=$DRIVER_E_SCHEMA calls=2" "$R"
next; step "$N" "$(plan '["C1","A1"]' '[{"item":"A2","note":"and the shot after it","why":"taken in CI"}]')"
want "an id with a note beside it is accepted as it is" "rc=0 calls=1 A2" "$R $(kept "$N" '.outside[0].item' | tr -d '"')"

echo "--- the model is offered both, and the brief says which is which ---"
SENT="$FIX/claude-schema-plan.json"
want "the schema sent names item, note and why"        "item,note,why" "$(jq -r '.properties.outside.items.properties | keys | join(",")' "$SENT")"
want "  and requires only why, so either may be given" "why" "$(jq -r '.properties.outside.items.required | join(",")' "$SENT")"
want "  with no keyword the API refuses"               "null" "$(jq -r '.properties.outside.items.anyOf // "null"' "$SENT")"
want_in "the brief shows one of each"                  '\{"item": "A3", .*\{"note": "' "$(tr '\n' ' ' < "$ROOT/briefs/plan.md")"
rc=0; bash "$ROOT/briefs/return-fields.sh" --check plan >/dev/null 2>&1 || rc=$?
want "  and names only fields the contract has"        "0" "$rc"

echo "--- planted: each of these is what holds it ---"
kit_copy() { rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$ROOT/driver" "$ROOT/scripts" "$ROOT/swarm" "$ROOT/shared" "$ROOT/briefs" "$KIT/"; }
plant() { # <label> <file under the kit> <exact text to delete>
  kit_copy
  python3 - "$KIT/$2" "$3" <<'PY' || { bad "plant ($1) did not land"; return 1; }
import sys
p, old = sys.argv[1], sys.argv[2]
s = open(p).read()
if s.count(old) != 1: sys.exit(1)
open(p, "w").write(s.replace(old, ""))
PY
  return 0
}
kit_copy
SUT_KIT="$KIT" case_prose; want "the unplanted copy: prose is a note, one call" "rc=0 calls=1" "$R"
plant "the driver moves the prose" driver/ai-step.sh '        mv "$ans.norm" "$ans"
' && { SUT_KIT="$KIT" case_prose; want "planted (nothing moved): refused, asked again, parked" "rc=$DRIVER_E_SCHEMA calls=2" "$R"; }
plant "the contract has a note" briefs/schemas/plan.json '          "note": {
            "description": "In plain words, something left out that is not one of the ticket'"'"'s listed items. It marks no ticket item as left out.",
            "type": "string",
            "minLength": 1
          },
' && { SUT_KIT="$KIT" case_no_items; want "planted (no note in the contract): prose parks again" "rc=$DRIVER_E_SCHEMA calls=2" "$R"; }
plant "an entry names an item or a note" briefs/schemas/plan.json '        "anyOf": [
          {
            "required": [
              "item"
            ]
          },
          {
            "required": [
              "note"
            ]
          }
        ],
' && { SUT_KIT="$KIT" case_neither; want "planted (neither required): an entry naming nothing passes" "rc=0 calls=1" "$R"; }
plant "an id in outside names its item" driver/feature-list.sh ' + [(.outside // [])[] | .item // empty]' \
  && { SUT_KIT="$KIT" case_prose; want "planted (outside ids unread): A2 is owed and the plan is refused" "rc=$DRIVER_E_REFUSED calls=2" "$R"; }
plant "the comment lists what is left out" driver/feature-list.sh '    + (if ((.outside // []) | length) > 0 then "\n\nLeft out, with why:\n" + ([.outside[] | "- " + (.item // .note // "?") + ": " + (.why // "")] | join("\n")) else "" end)
' && { SUT_KIT="$KIT" case_prose; want "planted (no left-out lines): the ticket comment shows none" "0" "$(grep -c 'Left out, with why' "$GH_LOG")"; }

suite_end "$FAILED"
