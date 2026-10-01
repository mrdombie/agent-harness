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
  jq -r '(.design.surfacePaths // []) | .[] | select(type == "string" and (test("^\\s*$") | not))' "$HARNESS_CFG" 2>/dev/null
}

# driver_touched_surfaces <tree> <trunk> — the changed files matching those globs.
# `set -f` FIRST, and it is the whole point of the function. A pathspec has to
# reach git UNEXPANDED: unquoted, the shell glob-expands it against the DRIVER'S
# OWN cwd, which is a checkout of this project. Measured there, `packages/ui/**`
# became six top-level entries — so `packages/ui/src/Button.tsx` matched nothing,
# compare said "this change touches no screen", and the reviewer was told there
# was no screen to judge. That is the exact failure this step exists to end, put
# back by a missing pair of characters. Word splitting is still wanted, so it is
# `set -f`, not quoting.
driver_touched_surfaces() { # <tree> <trunk>
  local wt="$1" trunk="$2" globs out
  globs=$(driver_surface_paths | tr '\n' ' ')
  [ -n "$(printf '%s' "$globs" | tr -d ' ')" ] || return 0
  # Entries are git pathspecs, magic included (`:(exclude)**/*.test.ts`). A list of
  # ONLY excludes means "every other file" to git — every change a screen change —
  # so it is refused rather than read.
  if ! driver_surface_paths | grep -qvE '^:(\(([^)]*,)?exclude[,)]|[/!^]*[!^])'; then
    driver_say "✋ compare: design.surfacePaths holds only exclude pathspecs, which git reads as every other file — name what a screen IS, then exclude from it." >&2
    return 2
  fi
  set -f
  # shellcheck disable=SC2086
  out=$(git -C "$wt" diff --name-only "$trunk...HEAD" -- $globs 2>/dev/null)
  set +f
  printf '%s' "$out"
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

  touched=$(driver_touched_surfaces "$wt" "$trunk") || {
    driver_state_set "$t" park_note "design.surfacePaths holds only exclude pathspecs, which git reads as every other file"
    return "$DRIVER_E_REFUSED"; }
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

  # A PLAN THAT CLAIMS A PICTURE AND NAMES NONE is checked before anything is
  # rendered: only a person (or a re-plan) can answer it, so resuming would refuse again.
  if [ -z "$(driver_state_get "$t" design_ref | tr -d '[:space:]')" ] && [ "$(driver_state_get "$t" design_source)" = "approved-picture" ]; then
    driver_say "✋ compare: the plan says this change has an approved picture and names none, so there is nothing to compare against and skipping would hide it."
    driver_state_set "$t" park_note "the plan claimed designSource=approved-picture and named no picture — re-run the plan step or name the picture"
    driver_state_set "$t" park_cause person
    return "$DRIVER_E_REFUSED"
  fi

  # ONE RENDER PER LINE: name<TAB>path<TAB>theme<TAB>route. The command is the
  # project's; the shape is the kit's, because the compare contract needs those
  # four things and a free-form blob would be a second parser per project.
  # THE STATES THE PLAN NAMED, handed to the renderer as JSON in DRIVER_RENDER_STATES
  # so it captures the state the change shows in, not only a page's standard ones.
  # A project whose renderer takes setup steps (design.renderSteps) and a plan that
  # named none for a screen change is refused: pictures that miss the change prove
  # nothing, and the plan step is the one that can say which state shows it.
  local states; states=$(driver_state_get "$t" screen_states); [ -n "$states" ] || states="[]"
  if [ -n "$(driver_opt design.renderSteps "")" ] && [ "$(printf '%s' "$states" | jq 'length' 2>/dev/null)" = "0" ]; then
    driver_say "✋ compare: this change touches a screen and the plan named no screen state that shows it, so a render would photograph the page and not the change."
    driver_state_set "$t" park_note "the plan named no screenStates for a change that touches a screen ($(printf '%s\n' "$touched" | head -3 | tr '\n' ' ')) — re-run the plan step so it names the state that shows the change"
    return "$DRIVER_E_REFUSED"
  fi

  local pass=1
  while : ; do
    out=$( ( cd "$wt" && export DRIVER_RENDER_STATES="$states" && driver_bounded "$DRIVER_CMD_TIMEOUT" "$cmd" ) 2>&1 ); rc=$?
    if [ "$rc" -eq 124 ]; then
      driver_say "✋ compare: the render command did not return within ${DRIVER_CMD_TIMEOUT}s — $cmd"
      driver_state_set "$t" park_note "this project's design.render command did not return within ${DRIVER_CMD_TIMEOUT}s: $cmd"
      return "$DRIVER_E_TIMEOUT"
    fi
    # EXIT 3 IS "THIS RENDERER KNOWS NO SCREEN HERE", not a failure: the change
    # touches the project's surface paths but none of the screens its renderer can
    # capture. Recorded loudly, exactly as a project with no renderer is — and a
    # reviewer that cannot judge without pictures (`needsRenders`) then refuses
    # by name rather than judging nothing.
    if [ "$rc" -eq 3 ]; then
      driver_state_set "$t" renders \
        "(none — this project's design.render command says this change touches no screen it can capture, so NOBODY OBSERVED THIS SCREEN: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300))"
      driver_say "⚠ compare: the render command knows no screen this change touches (exit 3), so no render was taken — said in those words to the reviewer and the pull request."
      return "$DRIVER_OK"
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
    driver_say "   compare: $n render(s) taken${pass:+ (pass $pass)}"

    # NO APPROVED PICTURE, NO PARITY CHECK. A debugged or ticket-body change has no
    # picture to hold the renders beside, and asked to compare anyway the step listed
    # "no approved picture exists" as a difference that stands — which parks every
    # such ticket for a person, whatever the renders show (trial 3 rerun, 2026-10-01).
    # The renders are kept: the review step and any reviewer that judges pictures
    # (`needsRenders`) read them against the ticket and the design law.
    local ref; ref=$(driver_state_get "$t" design_ref | tr -d '[:space:]')
    if [ -z "$ref" ]; then
      driver_say "   compare: no approved picture for this change (designSource=$(driver_state_get "$t" design_source)), so there is nothing to compare the renders against — they go to review as taken."
      return "$DRIVER_OK"
    fi

    # What was approved. The plan answered it — `approved-picture` plus its reference
    # is the pair this whole step exists to hold the renders against — and the design
    # fact is the project's own record of where approvals live.
    approved="Approved picture: $(driver_state_get "$t" design_ref)
  Recorded by the plan step as designSource=$(driver_state_get "$t" design_source)."
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
    local unfixed nfixed
    unfixed=$(jq -r '[.differences[]? | select(.fixed == false) | "\(.what) — \(.reason)"] | join("; ")' \
      "$(driver_state_dir "$t")/steps/compare.json" 2>/dev/null)
    if [ -n "$unfixed" ]; then
      driver_say "✋ compare: the renders differ from what was approved and the differences stand — $unfixed"
      driver_state_set "$t" park_note "the renders differ from the approved design and the differences were not fixed: $unfixed. Only a person sanctions a deviation, so this is not the driver's to walk past."
      # A PERSON, NOT THE DRIVER. A driver-caused park leaves the ticket resumable
      # and unattended, and this one is the single refusal in the walk that must not
      # be: resuming re-runs this step, and an answer of `fixed: true` next time is
      # an agent sanctioning its own deviation from a design somebody approved.
      driver_state_set "$t" park_cause person
      return "$DRIVER_E_REFUSED"
    fi

    # A DIFFERENCE THE STEP FIXED IS A CHANGE THE RENDERS ABOVE DO NOT SHOW. The
    # renders were taken before the agent edited anything, so `fixed: true` leaves
    # this step's own evidence describing the code before its fix — and those renders
    # are what the review step and the pull request body carry.
    #
    # The edit itself IS checked: this step runs before the gates and before the
    # review, which is why it moved there. So the answer is not a rework — it is one
    # more pass of THIS step: render again, compare again, and require the second
    # pass to report nothing further to fix. A step still editing on its second pass
    # is a step that will edit on its third, so that parks.
    nfixed=$(jq -r '[.differences[]? | select(.fixed == true)] | length' \
      "$(driver_state_dir "$t")/steps/compare.json" 2>/dev/null)
    if [ "${nfixed:-0}" -eq 0 ]; then break; fi
    if [ "$pass" -ge 2 ]; then
      driver_say "✋ compare: $nfixed difference(s) were fixed again on pass $pass, so every render this run has taken is of code the step then changed. Nothing here has been observed."
      driver_state_set "$t" park_note "the compare step fixed differences on two passes running, so no render this run took describes the code as it stands"
      return "$DRIVER_E_REFUSED"
    fi
    driver_say "   compare: $nfixed difference(s) were fixed in this step, so those renders are of the code before it — rendering again."
    pass=2
  done

  driver_say "   compare: parity against $(jq -r '.approved.ref // "the approved design"' "$(driver_state_dir "$t")/steps/compare.json" 2>/dev/null), from $n render(s)"
  return "$DRIVER_OK"
}
