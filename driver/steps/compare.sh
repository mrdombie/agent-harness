#!/usr/bin/env bash
# steps/compare.sh — the renders, held beside what a person approved.
#
#   driver_step_compare <ticket>
#
# WHY IT EXISTS. `briefs/compare.md` and `briefs/schemas/compare.json` shipped and
# `briefs/facts.json` declared the step; there was no step file, nothing gathered
# its APPROVED or ROUTE facts, and `driver_state_get renders` was READ by the
# review step and SET by nothing — so a reviewer was told "(none)" on every screen
# ticket there has ever been. A screen ticket's pixel acceptance criterion could
# not be observed by the walk at all.
#
# THREE THINGS IT DECIDES, IN THIS ORDER, and each one is said out loud:
#
#   1. DOES THIS CHANGE TOUCH A SCREEN? The project says what a screen is —
#      `design.surfacePaths` in harness.json, the same globs its own gates use. A
#      change touching none is not a comparison this step can make, and saying so
#      is different from finding nothing.
#   2. CAN THIS RUN TAKE A RENDER? `design.render` is a project command that
#      prints one render per line. A project that names none has an absence the
#      review step is then told about verbatim — a reviewer reading "no renders
#      were taken and here is why" is in a different position from one reading
#      "(none)".
#   3. A DECLARED RENDERER THAT PRODUCED NOTHING IS A REFUSAL. That is the
#      measurement never being made, which is not the same as a screen that is
#      fine — the distinction the whole kit is built on.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-step.sh" || exit 1

# driver_surface_paths — the globs this project calls a screen. No default: the
# kit names no project's directories, and inventing one would answer "does this
# touch a screen" with a guess.
driver_surface_paths() {
  [ -n "${HARNESS_CFG:-}" ] && [ -f "$HARNESS_CFG" ] || return 0
  jq -r '(.design.surfacePaths // []) | .[] | select(type == "string")' "$HARNESS_CFG" 2>/dev/null
}

# driver_touched_surfaces <tree> <trunk> — the changed files matching those globs.
driver_touched_surfaces() { # <tree> <trunk>
  local wt="$1" trunk="$2" globs
  globs=$(driver_surface_paths | tr '\n' ' ')
  [ -n "$(printf '%s' "$globs" | tr -d ' ')" ] || return 0
  # shellcheck disable=SC2086
  git -C "$wt" diff --name-only "$trunk...HEAD" -- $globs 2>/dev/null
}

driver_step_compare() { # <ticket>
  local t="${1:?driver_step_compare: need a ticket}"
  local wt trunk r touched cmd out rc lines n approved route rcs
  export DRIVER_TICKET="$t"
  wt=$(driver_state_get "$t" worktree); [ -n "$wt" ] || wt="$MAIN_REPO"
  trunk=""
  for r in "origin/$INTEGRATION_BRANCH" "$INTEGRATION_BRANCH"; do
    git -C "$wt" rev-parse --verify -q "$r" >/dev/null 2>&1 && { trunk="$r"; break; }
  done
  if [ -z "$trunk" ]; then
    driver_say "✋ compare: neither origin/$INTEGRATION_BRANCH nor $INTEGRATION_BRANCH resolves in $wt, so there is nothing to measure the change against."
    return "$DRIVER_E_REFUSED"
  fi

  if [ -z "$(driver_surface_paths)" ]; then
    driver_state_set "$t" renders \
      "(none — harness.json declares no design.surfacePaths, so this project has told the driver nothing about what a screen is and no comparison was attempted)"
    driver_say "   compare: harness.json declares no design.surfacePaths, so this run cannot tell a screen change from any other. Nothing was compared, and the review step is told so."
    return "$DRIVER_OK"
  fi

  touched=$(driver_touched_surfaces "$wt" "$trunk")
  if [ -z "$touched" ]; then
    driver_state_set "$t" renders \
      "(none — this change touches no file under this project's design.surfacePaths, so there is no screen to render)"
    driver_say "   compare: this change touches no screen, so there is nothing to hold beside a design."
    return "$DRIVER_OK"
  fi
  driver_say "   compare: $(printf '%s\n' "$touched" | grep -c .) screen file(s) in this change"

  cmd=$(driver_opt design.render "")
  if [ -z "$cmd" ]; then
    # LOUD, AND ON THE RECORD. The review step reads this exact string as its
    # RENDERS fact and the pull request body carries it, so "nobody looked at the
    # pixels" reaches a reader rather than sitting in a log on this machine.
    driver_state_set "$t" renders \
      "(none — this change touches $(printf '%s\n' "$touched" | grep -c .) screen file(s) and harness.json names no design.render command, so NOBODY OBSERVED THIS SCREEN. Judge no screen from renders that were never taken:
$(printf '%s\n' "$touched" | sed 's/^/  /'))"
    driver_say "⚠ compare: this change touches a screen and harness.json names no design.render command, so no render was taken. The reviewer and the pull request are told that in those words — an absence that is visible is not the same as a pass."
    return "$DRIVER_OK"
  fi

  # ONE RENDER PER LINE: name<TAB>path<TAB>theme<TAB>route. The command is the
  # project's; the shape is the kit's, because the compare contract needs those
  # four things and a free-form blob would be a second parser per project.
  out=$( ( cd "$wt" && driver_bounded "$DRIVER_CMD_TIMEOUT" "$cmd" ) 2>&1 ); rc=$?
  if [ "$rc" -eq 124 ]; then
    driver_say "✋ compare: the render command did not return within ${DRIVER_CMD_TIMEOUT}s — $cmd"
    driver_state_set "$t" park_note "this project's design.render command did not return within ${DRIVER_CMD_TIMEOUT}s: $cmd"
    return "$DRIVER_E_TIMEOUT"
  fi
  # AWK, NOT `grep -E '\t'`. POSIX ERE has no `\t` escape — BSD grep reads it as a
  # literal `t`, so the pattern matched nothing, every render line was discarded and
  # a renderer that worked perfectly was reported as producing none.
  lines=$(printf '%s\n' "$out" | awk -F'\t' 'NF >= 3 && $1 != "" && $2 != "" && ($3 == "light" || $3 == "dark")')
  n=$(printf '%s\n' "$lines" | grep -c . || true)
  if [ "$rc" -ne 0 ] || [ "${n:-0}" -eq 0 ]; then
    driver_say "✋ compare: this project's design.render command exited $rc and produced $n render(s) — $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
    driver_state_set "$t" park_note "this project's design.render command ('$cmd') exited $rc and produced $n render line(s), so the screen was never observed. A measurement that could not be made is not a screen that is fine."
    return "$DRIVER_E_REFUSED"
  fi
  driver_state_set "$t" renders "$lines"
  driver_say "   compare: $n render(s) taken"

  # What was approved. The plan answered it — `approved-picture` plus its reference
  # is the pair this whole step exists to hold the renders against — and the design
  # fact is the project's own record of where approvals live.
  approved=$(driver_state_get "$t" design_ref)
  if [ -n "$approved" ]; then
    approved="Approved picture: $approved
Recorded by the plan step as designSource=$(driver_state_get "$t" design_source)."
  else
    approved="The plan answered designSource=$(driver_state_get "$t" design_source) and named no approved picture, so there is no picture to compare against — judge the renders against the ticket and this project's design law instead, and say in a difference that no picture was approved.

$(driver_fact_design "$t")"
  fi
  route=$(printf '%s\n' "$lines" | awk -F'\t' '{print $4}' | grep -v '^$' | sort -u | tr '\n' ' ')
  [ -n "$(printf '%s' "$route" | tr -d ' ')" ] \
    || route="(the render command named no route on any line — its fourth field is the route each render came from)"

  driver_fact_put "$t" compare APPROVED "$approved"
  driver_fact_put "$t" compare RENDERS  "$lines"
  driver_fact_put "$t" compare ROUTE    "$route"

  rcs=0; driver_ai_step "$t" compare || rcs=$?
  [ "$rcs" -eq 0 ] || return "$rcs"

  # A DIFFERENCE THAT STANDS IS NOT THIS STEP'S TO SANCTION. The contract already
  # requires a reason on one; the driver refuses to walk past it, because only a
  # person sanctions a deviation from an approved design.
  local unfixed
  unfixed=$(jq -r '[.differences[]? | select(.fixed == false) | "\(.what) — \(.reason)"] | join("; ")' \
    "$(driver_state_dir "$t")/steps/compare.json" 2>/dev/null)
  if [ -n "$unfixed" ]; then
    driver_say "✋ compare: the renders differ from what was approved and the differences stand — $unfixed"
    driver_state_set "$t" park_note "the renders differ from the approved design and the differences were not fixed: $unfixed. Only a person sanctions a deviation."
    return "$DRIVER_E_REFUSED"
  fi
  driver_say "   compare: parity against $(jq -r '.approved.ref // "the approved design"' "$(driver_state_dir "$t")/steps/compare.json" 2>/dev/null), from $n render(s)"
  return "$DRIVER_OK"
}
