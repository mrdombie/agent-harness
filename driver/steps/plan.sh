#!/usr/bin/env bash
# steps/plan.sh — the AI writes the plan; the driver decides whether it is one it
# can enforce, and puts it where the next reader will find it.
#
#   driver_step_plan <ticket>
#
# Two checks, both from the approved design's guarantee table:
#
#   NO NEW TABLE WITHOUT AN APPROVED DESIGN SPEC. A plan that changes the schema
#   must name the reviewed data model it is changing it to. A database change
#   invented inside a ticket is the one kind of mistake a later ticket cannot
#   undo cheaply, so this refuses rather than asks.
#
#   A PLAN WITH NO TESTS IS NOT A PLAN THIS DRIVER CAN ENFORCE. Every guarantee
#   downstream is built on the build step proving a test red then green. A plan
#   that names none has removed the only thing the driver can check.
#
# And one piece of bookkeeping: the plan is posted as a comment on the ticket,
# never committed into the product repo as a per-ticket document. The comment
# outlives the worktree, which the document would not.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-step.sh" || exit 1

driver_step_plan() { # <ticket>
  local t="${1:?driver_step_plan: need a ticket}"
  local rc ans schema spec ntests
  export DRIVER_TICKET="$t"

  rc=0; driver_ai_step "$t" plan || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  ans="$(driver_state_dir "$t")/steps/plan.json"

  # THE KEYS ARE THE CONTRACT'S KEYS. This read four names briefs/schemas/plan.json
  # does not have — `.schema_change`, `.data_model_spec`, `.tests` and `.files` — and
  # the contract is `additionalProperties: false`, so an answer carrying them was
  # refused by the validator and an answer meeting the contract was refused here.
  # Measured on the 2026-09-27 trial: the kit's own valid example and both real
  # plans all validated, all read `.tests` as length 0, and all three parked on
  # "it names no test". Tests and files live under each task; the schema flag and
  # its model are declared properties, and the contract now carries the rule as
  # well, so the two cannot drift apart again.
  schema=$(jq -r '.schemaChange // false' "$ans")
  spec=$(jq -r '.dataModelSpec // ""' "$ans")
  if [ "$schema" = "true" ] && [ -z "$spec" ]; then
    driver_say "✋ plan: it changes the schema and names no approved data model. A database change comes from a reviewed model, never from inside a ticket."
    return "$DRIVER_E_REFUSED"
  fi

  ntests=$(jq -r '[.tasks[]?.tests[]?] | length' "$ans")
  if [ "${ntests:-0}" -eq 0 ]; then
    driver_say "✋ plan: it names no test. Every guarantee after this one is the build step proving a test red then green; a plan with no test has nothing to prove."
    return "$DRIVER_E_REFUSED"
  fi

  # THE BINDING PICTURE IS READ ON THIS MACHINE, or the run goes back on the queue.
  # A designRef that is a path where the picture was drawn finds nothing on any other
  # machine; the ticket's "Picture for any machine" comment carries the file, which is
  # fetched, checked against its sha256 and committed into the tree. None reachable is
  # nobody's question: requeued with the reason, never parked, never asked.
  local dref dwt dout drc=0 derr
  dref=$(jq -r '.designRef // ""' "$ans")
  dwt=$(driver_state_get "$t" worktree)
  if [ -n "$(printf '%s' "$dref" | tr -d '[:space:]')" ] && [ -n "$dwt" ] && [ -d "$dwt" ]; then
    derr="$(driver_state_dir "$t")/steps/picture-fetch.err"
    dout=$(bash "$KIT_ROOT/scripts/picture-fetch.sh" "$t" "$dref" "$dwt" 2>"$derr") || drc=$?
    if [ "$drc" -ne 0 ]; then
      driver_say "⏳ plan: the approved picture could not be read on this machine — $(tail -1 "$derr" 2>/dev/null | sed 's/^picture-fetch: //'). Back on the queue until it is published, not parked."
      driver_state_set "$t" park_note "the approved picture is not readable on this machine: $(tail -1 "$derr" 2>/dev/null | sed 's/^picture-fetch: //')"
      return "$DRIVER_E_REQUEUE"
    fi
    if [ "$dout" != "$dref" ]; then
      if ! { git -C "$dwt" add -- "$dout" && git -C "$dwt" commit -q --no-verify -m "chore(design): the approved picture for #$t, from its published copy" -- "$dout"; } >/dev/null 2>&1; then
        driver_say "✋ plan: the approved picture was fetched to $dout and could not be committed."
        driver_state_set "$t" park_note "the approved picture was fetched to $dout in $dwt and could not be committed"
        return "$DRIVER_E_REFUSED"
      fi
      driver_say "   plan: $(tail -1 "$derr" 2>/dev/null | sed 's/^picture-fetch: //'), committed"
      jq --arg r "$dout" '.designRef = $r' "$ans" > "$ans.tmp" && mv "$ans.tmp" "$ans"
    fi
  fi

  # Where the design goes. On the ticket, not into the repo: the comment outlives
  # the worktree and is what the next reader — or the next agent — opens.
  swarm_gh issue comment "$t" --repo "$REPO_SLUG" --body "$(
    printf '**Plan** (driver step 2 of 7)\n\n```json\n%s\n```\n' "$(cat "$ans")"
  )" >/dev/null 2>&1 || true

  # The ticket stood in for brainstorming — an unattended agent never calls it,
  # because it waits on a person. Say which, rather than leaving it to be guessed.
  # THE PLAN SAYS WHICH. `designSource` is a required property of the contract with
  # three values, and writing a constant here threw away the only one of the three
  # the driver cannot work out for itself — a bug ticket whose plan followed a
  # reproduction is `debugged`, and /finish cross-checks that against the spec gate.
  driver_state_set "$t" design_source "$(jq -r '.designSource // "ticket-body"' "$ans")"
  # AND WHAT IT POINTS AT. `approved-picture` is the value this project's process
  # turns on — a design a person approved before the build — and the compare step
  # holds the renders against exactly this reference. The contract requires the two
  # together, so reading one without the other is how they come apart.
  driver_state_set "$t" design_ref "$(jq -r '.designRef // ""' "$ans")"
  # The screen states the change shows in, for the renderer to capture exactly.
  driver_state_set "$t" screen_states "$(jq -c '.screenStates // []' "$ans")"
  driver_state_set "$t" screen_change "$(jq -r '.screenChange // ""' "$ans")"
  # REPO SETTINGS ARE THE PM'S, AFTER THE MERGE. A build changed the live develop
  # ruleset from inside a step (2026-10-20); the step's gh now refuses that, and a
  # plan that needs one hands it on here instead of leaving a build to try.
  local pm
  pm=$(jq -r '(.pmAfterMerge // [])[] | "- " + .' "$ans" 2>/dev/null)
  driver_state_set "$t" pm_after_merge "$pm"
  if [ -n "$pm" ]; then
    swarm_gh issue comment "$t" --repo "$REPO_SLUG" --body "$(
      printf '**PM step after merge** — repository settings this ticket needs. A build never changes them; the PM makes these once the pull request has merged.

%s
' "$pm"
    )" >/dev/null 2>&1 || true
    driver_say "   plan: $(printf '%s
' "$pm" | grep -c .) repo-settings change(s) handed to the PM for after the merge"
  fi
  driver_say "   plan: $(jq -r '[.tasks[]?] | length' "$ans") task(s), $(jq -r '[.tasks[]?.files[]?] | length' "$ans") file(s), $ntests test(s); posted on #$t"
  return "$DRIVER_OK"
}
