#!/usr/bin/env bash
# steps/quick.sh — a ticket sized quick, made in one agent session.
#
#   driver_step_quick <ticket>
#     0   edited, committed, gates green: review and ship come next
#     35  bigger than its size: the run goes on along the full route from plan
#
# ONE SESSION, THEN THE DRIVER'S OWN CHECKS. The session edits and commits (it cannot
# push: ai-step's shim). The driver then reads the REAL diff, not the answer's list,
# and runs the same gates self-check runs (driver_step_self_check: gates.local under
# gates.localOnly, else the changed list, the changelog skip line, the push trial).
#
# THE FALLBACK KEEPS THE WORK. A diff past driver.quick.maxFiles, one touching a
# never-quick file (a new screen or page, any screen without the baseline route, a
# schema or migration, a lockfile) or red gates
# move the ticket up a size: the commits are kept at refs/driver/quick/<ticket>, the
# branch goes back to where it was cut, and the plan step is told where they are —
# so the full route's build proves its test red before the change, as it must.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-step.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tier.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/size.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/self-check.sh" || exit 1

# driver_quick_exceeds <ticket> <tree> <trunk> — prints why the branch's real diff is
# bigger than a quick change and returns 0; 1 when it fits.
driver_quick_exceeds() {
  local t="$1" wt="$2" trunk="$3" files n max never tier why base
  files=$(git -C "$wt" diff --name-only "$trunk"...HEAD 2>/dev/null | sed '/^$/d')
  n=$(printf '%s' "$files" | grep -c .)
  max=$(driver_quick_max_files)
  if [ "$n" -gt "$max" ]; then
    printf 'the change touches %s files, more than a quick change (%s): %s' "$n" "$max" "$(printf '%s' "$files" | head -5 | paste -sd, - | sed 's/,/, /g')"; return 0
  fi
  # Existing or new is read against the branch's own base: a screen file it adds is a new screen.
  base=$(git -C "$wt" merge-base "$trunk" HEAD 2>/dev/null)
  never=$(printf '%s\n' "$files" | DRIVER_SIZE_REPO="$wt" DRIVER_SIZE_REV="${base:-$trunk}" driver_quick_never | head -1)
  if [ -n "$never" ]; then printf 'the change touches %s — %s' "${never%%	*}" "${never#*	}"; return 0; fi
  IFS=$'\t' read -r tier why <<<"$(driver_change_tier "$t" "$wt" "$trunk")"
  # An existing screen on the baseline route stays quick: CI diffs it against its last approved shots.
  if [ "$tier" = screen ] && driver_tiers_on && [ "$(driver_screen_route "$t" | cut -f1)" != baseline ]; then
    printf 'the change is screen work: %s' "$why"; return 0
  fi
  return 1
}

# _driver_quick_upsize <ticket> <tree> <trunk> <why> — the work kept off the branch,
# the branch back at its cut, the size raised, and a brief for the full route.
_driver_quick_upsize() {
  local t="$1" wt="$2" trunk="$3" why="$4" base head ref="" brief rb n sz
  base=$(git -C "$wt" merge-base "$trunk" HEAD 2>/dev/null)
  head=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
  if [ -n "$base" ] && [ -n "$head" ] && [ "$base" != "$head" ]; then
    ref="refs/driver/quick/$t"
    git -C "$wt" update-ref "$ref" "$head" && git -C "$wt" reset -q --hard "$base" || {
      driver_say "✋ quick: the quick attempt could not be set aside at $ref, so the branch was left as it is."
      driver_state_set "$t" park_note "the quick attempt could not be set aside at $ref in $wt"
      return "$DRIVER_E_REFUSED"; }
  fi
  n=$(git -C "$wt" diff --name-only "$base" "$head" 2>/dev/null | grep -c .)
  sz=small; [ "$n" -le "$(_driver_size_small_max)" ] || sz=project
  printf '%s\n' "$why" | grep -qiE 'screen|page|schema|migration|prisma|\.sql' && sz=project
  driver_state_set "$t" route full
  driver_state_set "$t" size "$sz"
  driver_state_set "$t" size_reason "sized quick, then $why"
  driver_state_set "$t" quick_fallback "$why"
  brief="$(driver_state_dir "$t")/quick-fallback.md"
  rb=$(driver_state_get "$t" run_brief)
  {
    printf 'This ticket was sized quick and has moved to the full route: %s.\n' "$why"
    if [ -n "$ref" ]; then
      printf 'The quick attempt is kept off the branch at %s (%s). `git diff %s %s` shows it. The branch is back at %s, so the build can prove its test red before the change. Reuse what is right in that attempt; plan the whole change.\n' \
        "$ref" "$(printf '%s' "$head" | cut -c1-12)" "$(printf '%s' "$base" | cut -c1-12)" "$ref" "$(printf '%s' "$base" | cut -c1-12)"
    fi
    if [ -n "$rb" ] && [ -s "$rb" ] && [ "$rb" != "$brief" ]; then printf '\nThe brief this run came with:\n\n'; cat "$rb"; fi
  } > "$brief.tmp" && mv "$brief.tmp" "$brief"
  driver_state_set "$t" run_brief "$brief"
  driver_say "↑ size: #$t is bigger than a quick change — $why. Up to $sz, on the full route from plan${ref:+, the quick attempt kept at $ref}."
  return "$DRIVER_E_UPSIZE"
}

driver_step_quick() { # <ticket>
  local t="${1:?driver_step_quick: need a ticket}" wt branch trunk="" r rc ans dirty ahead why reds scrc
  export DRIVER_TICKET="$t"
  wt=$(driver_state_get "$t" worktree); branch=$(driver_state_get "$t" branch)
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    driver_say "✋ quick: there is no worktree on the record for #$t."
    return "$DRIVER_E_REFUSED"
  fi
  for r in "origin/$INTEGRATION_BRANCH" "$INTEGRATION_BRANCH"; do
    git -C "$wt" rev-parse --verify -q "$r" >/dev/null 2>&1 && { trunk="$r"; break; }
  done
  [ -n "$trunk" ] || { driver_say "✋ quick: no $INTEGRATION_BRANCH resolves in $wt."; return "$DRIVER_E_REFUSED"; }

  driver_fact_put "$t" quick SIZE "$(printf 'Sized %s by %s: %s\nFiles it named: %s\nA quick change touches at most %s files.' \
    "$(driver_state_get "$t" size)" "$(driver_state_get "$t" size_by)" "$(driver_state_get "$t" size_reason)" \
    "$(driver_state_get "$t" size_files | sed 's/,/, /g; s/^$/(none named)/')" "$(driver_quick_max_files)")"
  rc=0; driver_ai_step "$t" quick || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  ans="$(driver_state_dir "$t")/steps/quick.json"

  dirty=$(git -C "$wt" status --porcelain --untracked-files=no 2>/dev/null)
  if [ -n "$dirty" ]; then
    driver_say "✋ quick: the session left changes uncommitted — $(printf '%s' "$dirty" | awk '{print $NF}' | tr '\n' ' ')"
    driver_state_set "$t" park_note "the quick session left uncommitted changes in $wt: $(printf '%s' "$dirty" | awk '{print $NF}' | tr '\n' ' ')"
    return "$DRIVER_E_REFUSED"
  fi
  ahead=$(git -C "$wt" rev-list --count "$trunk..HEAD" 2>/dev/null)
  if [ "${ahead:-0}" -eq 0 ] 2>/dev/null; then
    driver_say "✋ quick: the session answered '$(jq -r '.status' "$ans")' and committed nothing."
    driver_state_set "$t" park_note "the quick session committed nothing on $branch"
    return "$DRIVER_E_REFUSED"
  fi
  if why=$(driver_quick_exceeds "$t" "$wt" "$trunk"); then
    _driver_quick_upsize "$t" "$wt" "$trunk" "$why"; return $?
  fi

  # The build answer of this run: self-check's changelog line and the review read it there.
  jq -c . "$ans" > "$(driver_state_dir "$t")/steps/build.all.json"
  reds=$(driver_state_count "$t" selfcheck_red)
  scrc=0; driver_step_self_check "$t" || scrc=$?
  if [ "$scrc" -ne 0 ] && [ "$(driver_state_count "$t" selfcheck_red)" -gt "${reds:-0}" ]; then
    why="its gates went red: $(driver_state_get "$t" park_note | cut -c1-300)"
    driver_state_set "$t" park_note ""
    _driver_quick_upsize "$t" "$wt" "$trunk" "$why"; return $?
  fi
  [ "$scrc" -eq 0 ] || return "$scrc"
  driver_state_set "$t" quick_head "$(git -C "$wt" rev-parse HEAD)"
  driver_say "   quick: $(jq -r '.summary // ""' "$ans" | cut -c1-200) — $(git -C "$wt" diff --name-only "$trunk"...HEAD | grep -c .) file(s), gates green"
  return "$DRIVER_OK"
}
