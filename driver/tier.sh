#!/usr/bin/env bash
# tier.sh — THE PROCESS MATCHES THE CHANGE (the owner, 2026-10-20). Every build is
# tiered by the files its branch changes against the trunk, decided from the diff and
# never by a label, and the pull request says which tier it took:
#
#   screen   a file in the screen set (approval-kept.sh screens: design.surfacePaths
#            plus design.extraScreens), one design.screenOf maps, or a page that renders
#            a route. Unchanged: picture first, compare, CI evidence, the independent
#            design critic, the owner's sign-off hold.
#   backend  product code that draws nothing. The full build and review (round 1
#            Critical, Major and Minor; from round 2 Critical and Major), and no
#            compare, no evidence plan and no design-critic verdict owed.
#   tooling  only CI, docs and harness config (tiers.toolingPaths). One review round,
#            in which only Critical and Major block. No design steps.
#
# Tests, the push's house rules and the code review stay on every tier. The diff is
# read again at every step that asks, so a later push that touches a screen promotes
# the build to the screen tier — said once, and kept on the record (tier_promoted).
#
# A project that names no design.surfacePaths cannot tell a screen from anything else,
# so it is not tiered (every build is a screen build, as before), unless tiers.enabled
# says otherwise; tiers.enabled false turns tiering off.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/size-rules.sh" || exit 1

DRIVER_TOOLING_PATHS_DEFAULT='[".github/*", ".claude/*", ".husky/*", "docs/*", "*.md", ".changeset/*", "CHANGELOG*"]'

# driver_tiers_on — 0 when this project tiers its builds.
driver_tiers_on() {
  local on
  on=$(jq -r 'if (.tiers.enabled | type) == "boolean" then (.tiers.enabled | tostring)
              elif ((.design.surfacePaths // []) | length) > 0 then "true" else "false" end' "$HARNESS_CFG" 2>/dev/null)
  [ "$on" = true ]
}

# driver_change_tier <ticket> <tree> <trunk> — prints "<tier>\t<why>" and records the
# tier on the ticket. Tiering off, or a diff that cannot be read: screen, the full process.
driver_change_tier() {
  local t="$1" wt="$2" trunk="$3" files screens mapped pages tooling rest tier why prev cmd
  if ! driver_tiers_on; then
    printf 'screen\tthis project does not tier its builds, so every build takes the full process\n'; return 0
  fi
  if [ -z "$trunk" ] || ! files=$(git -C "$wt" diff --name-only "$trunk"...HEAD 2>/dev/null); then
    tier=screen; why="the diff against $trunk could not be read, so the full process applies"
  else
    files=$(printf '%s\n' "$files" | sed '/^$/d')
    screens=$(printf '%s\n' "$files" | HARNESS_CFG="$HARNESS_CFG" bash "${DRIVER_APPROVAL_KEPT:-$KIT_ROOT/scripts/approval-kept.sh}" screens 2>/dev/null | sed '/^$/d')
    cmd=$(jq -r '.design.screenOf // ""' "$HARNESS_CFG" 2>/dev/null)
    mapped=""
    [ -z "$cmd" ] || [ -z "$files" ] || mapped=$(printf '%s\n' "$files" | ( cd "$wt" 2>/dev/null && sh -c "$cmd" ) 2>/dev/null | grep -E '^[a-z0-9-]+$')
    pages=$(printf '%s\n' "$files" | grep -E '(^|/)app/(.*/)?page\.(t|j)sx?$')
    if [ -n "$screens$mapped$pages" ]; then
      tier=screen
      why="it changes a screen: $(printf '%s\n' "$screens" "$pages" "$mapped" | sed '/^$/d' | awk '!s[$0]++' | head -3 | paste -sd',' - | sed 's/,/, /g')"
    else
      tooling=$(jq -c 'if (.tiers.toolingPaths | type) == "array" then .tiers.toolingPaths else null end' "$HARNESS_CFG" 2>/dev/null)
      [ -n "$tooling" ] && [ "$tooling" != null ] || tooling="$DRIVER_TOOLING_PATHS_DEFAULT"
      rest=$(printf '%s\n' "$files" | TP="$tooling" _driver_tier_not_tooling)
      if [ -z "$files" ]; then
        tier=backend; why="the branch changes no file yet, so the full review applies"
      elif [ -z "$rest" ]; then
        tier=tooling; why="every changed file is CI, docs or harness config"
      else
        tier=backend; why="it changes product code and no screen: $(printf '%s\n' "$rest" | head -3 | paste -sd',' - | sed 's/,/, /g')"
      fi
    fi
  fi
  prev=$(driver_state_get "$t" tier 2>/dev/null)
  if [ "$tier" = screen ] && [ -n "$prev" ] && [ "$prev" != screen ]; then
    driver_state_set "$t" tier_promoted "$prev" 2>/dev/null
    driver_say "↑ tier: #$t was a $prev build and now $why — promoted to the screen tier, with the full design process" >&2
  fi
  # Promotion never reverses within a run: once a screen build, always one.
  [ "$prev" = screen ] && [ "$tier" != screen ] && { tier=screen; why="an earlier push in this run changed a screen, so it stays a screen build"; }
  driver_state_set "$t" tier "$tier" 2>/dev/null
  printf '%s\t%s\n' "$tier" "$why"
}

# driver_is_screen_file <tree> <file> — 0 when the file is screen code, read the way
# driver_change_tier reads a diff: the screen set (approval-kept.sh screens), a page under
# app/, or one design.screenOf maps to a screen. Tests, docs, tooling and backend are not.
driver_is_screen_file() {
  local wt="${1:-}" f="${2:-}" cmd
  f=$(printf '%s' "$f" | sed 's#^\./##; s/:[0-9][0-9]*$//')
  [ -n "$f" ] || return 1
  printf '%s\n' "$f" | grep -qE '(^|/)app/(.*/)?page\.(t|j)sx?$' && return 0
  # With no design.surfacePaths every file is in the screen set: it tells nothing then.
  if [ "$(jq -r '((.design.surfacePaths // []) | length) > 0' "$HARNESS_CFG" 2>/dev/null)" = true ]; then
    [ -n "$(printf '%s\n' "$f" | HARNESS_CFG="$HARNESS_CFG" bash "${DRIVER_APPROVAL_KEPT:-$KIT_ROOT/scripts/approval-kept.sh}" screens 2>/dev/null | sed '/^$/d')" ] && return 0
  fi
  cmd=$(jq -r '.design.screenOf // ""' "$HARNESS_CFG" 2>/dev/null)
  [ -n "$cmd" ] && [ -n "$(printf '%s\n' "$f" | ( cd "${wt:-.}" 2>/dev/null && sh -c "$cmd" ) 2>/dev/null | grep -E '^[a-z0-9-]+$')" ] && return 0
  return 1
}

# Paths on stdin; the ones matching no tooling pattern on stdout. A pattern is a shell
# glob over the whole path, where * crosses directories.
_driver_tier_not_tooling() {
  local f p hit pats
  pats=$(printf '%s' "$TP" | jq -r '.[] | select(type == "string" and length > 0)' 2>/dev/null)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    hit=""
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      p="${p//\*\*/*}"
      # shellcheck disable=SC2053
      if [[ "$f" == $p ]] || [[ "$f" == */$p ]]; then hit=1; break; fi
    done <<<"$pats"
    [ -n "$hit" ] || printf '%s\n' "$f"
  done
}

# driver_tier_of <ticket> — the tier the record holds; screen when none was decided.
driver_tier_of() { local v; v=$(driver_state_get "$1" tier 2>/dev/null); printf '%s' "${v:-screen}"; }

# driver_baseline_route_on and driver_picture_labels live in size-rules.sh: the size
# step asks them too, of a screen file it would let through as an existing screen.

# driver_screen_route <ticket> — prints "<picture|baseline>\t<why>" and records the route.
driver_screen_route() {
  local t="$1" labels l route why
  if ! driver_baseline_route_on; then
    printf 'picture\tthis project has no baseline route, so every screen build takes the picture route\n'; return 0
  fi
  if ! labels=$(driver_gh_read swarm_gh issue view "$t" --repo "$REPO_SLUG" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null); then
    route=picture; why="#$t's labels could not be read, so the picture route applies"
  else
    route=baseline
    why="#$t is an existing screen (no $(driver_picture_labels | paste -sd/ -) label): CI diffs it against its last approved shots"
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      case ",$labels," in *",$l,"*) route=picture; why="#$t is labelled $l: picture first, the independent critic and sign-off"; break ;; esac
    done <<<"$(driver_picture_labels)"
  fi
  driver_state_set "$t" screen_route "$route" 2>/dev/null
  printf '%s\t%s\n' "$route" "$why"
}
