#!/usr/bin/env bash
# steps/size.sh — how big is this ticket, read before anything is planned.
#
#   driver_step_size <ticket>
#
# THE PROCESS MATCHES THE CHANGE. A two-line config edit took 3 minutes by hand and
# was projected at ~30 through the driver, because every ticket walked nine steps and
# seven agent sessions. This step sizes the ticket from what it says, and only a
# ticket sized `quick` walks the short order (DRIVER_QUICK_STEPS): one session that
# edits and commits, the gates, one review, ship.
#
#   quick    one to driver.quick.maxFiles (3) named files, and the change is config,
#            copy or docs, or a small code edit the ticket states — on an existing
#            screen too, while the baseline route is on (no new route or screen file)
#   small    a few named files, no schema, no new screen
#   project  anything else: a schema or migration, a new screen, a design label, a
#            never-quick file, more files than small, or a ticket naming no file
#
# Mechanical first: labels, the body, the paths it names, a stated diff or snippet
# (size-rules.sh, which the coordinator also reads to start quick work over the cap).
# One short model call only when that read is undecided (named code files with no
# stated change, or a stated change naming no file), and it can only choose among
# the sizes the rules left open. The call fails, or is off: the full route.
#
# Only quick changes the route here; small and project both take the full order.
# The quick step reads the REAL diff after the edit and moves the ticket up a size,
# to the full route, when it is bigger than this said (steps/quick.sh).
#
# Settings, all optional, under driver.quick in harness.json:
#   enabled     false turns the quick route off (sizes are still read and logged)
#   maxFiles    the most files a quick change touches (3)
#   smallMaxFiles  the most named files a small one touches (8)
#   neverGlobs  more globs never quick, beside the defaults: schema and migration
#               files, lockfiles. A NEW screen file or page (design.surfacePaths,
#               design.extraScreens, app/**/page.*) is never quick, nor any screen
#               file without the baseline route; screen:new and screen:redesign never are
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-step.sh" || exit 1

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/size-rules.sh" || exit 1

# _driver_size_ask <ticket> <ticket text> <files> — the one short model call, for an
# undecided read. On Opus like every step: a small prompt, read-only tools, three
# turns. Prints "<size>\t<why>"; 1 when it gave no readable answer.
_driver_size_ask() {
  local t="$1" text="$2" files="$3" d wt prompt log schema ans size why max
  d=$(driver_state_dir "$t")/steps; mkdir -p "$d"
  prompt="$d/size.prompt"; log="$d/size.log"; schema="$d/size.schema.json"
  max=$(driver_quick_max_files)
  wt=$(driver_state_get "$t" worktree); [ -n "$wt" ] && [ -d "$wt" ] || wt="$MAIN_REPO"
  printf '%s' '{"type":"object","additionalProperties":false,"required":["size","reason"],"properties":{"size":{"enum":["quick","small","project"]},"reason":{"type":"string","minLength":1}}}' > "$schema"
  {
    printf 'Size this ticket for an automated build. Answer JSON only.\n\n'
    printf -- '- quick: the change touches 1 to %s files, and is config, copy, docs, or one small code edit whose change the ticket states exactly enough to make without a plan.\n' "$max"
    printf -- '- small: a few files, no schema or migration, no new screen.\n- project: anything else.\n\n'
    printf 'Unsure is the bigger size. You may read the files it names in the working tree; change nothing.\n'
    [ -z "$files" ] || printf 'Files it names: %s\n' "$files"
    printf '\n---\n%s\n' "$(printf '%s' "$text" | head -c 6000)"
  } > "$prompt"
  local -a args=(--strict-mcp-config --mcp-config '{"mcpServers":{}}' --tools Read Grep Glob --max-turns 3)
  ( cd "$wt" 2>/dev/null || cd /
    HARNESS_DRIVER_RUN="$t:size" "$DRIVER_CLAUDE" -p --output-format stream-json --verbose --name size \
      --permission-mode "$DRIVER_PERMISSION_MODE" "${args[@]}" --json-schema "$(cat "$schema")" \
      < "$prompt" > "$log" 2>"$log.err" ) || true
  driver_record_usage "$t" size "$log" "$prompt" >&2
  ans=$(driver_log_result "$log")
  size=$(printf '%s' "$ans" | jq -r '.size // empty' 2>/dev/null)
  why=$(printf '%s' "$ans" | jq -r '.reason // empty' 2>/dev/null | tr '\t\n' '  ' | cut -c1-200)
  case "$size" in quick|small|project) printf '%s\t%s\n' "$size" "${why:-no reason given}" ;; *) return 1 ;; esac
}

driver_step_size() { # <ticket>
  local t="${1:?driver_step_size: need a ticket}" j title labels body rd size why files by=rules route=full
  export DRIVER_TICKET="$t"
  # A record that already planned or built this ticket keeps its route: switching a
  # half-walked full build to the quick order would drop the work it has done.
  if driver_state_is_done "$t" plan || driver_state_is_done "$t" build; then
    driver_state_set "$t" route full
    [ -n "$(driver_state_get "$t" size)" ] || driver_state_set "$t" size project
    driver_state_set "$t" size_reason "already planned on the full route before it was sized"
    driver_say "   size: route=full size=$(driver_state_get "$t" size) — already planned on the full route"
    return "$DRIVER_OK"
  fi
  if ! j=$(driver_gh_read swarm_gh issue view "$t" --repo "$REPO_SLUG" --json title,labels,body 2>/dev/null) || [ -z "$j" ]; then
    size=project; why="the ticket could not be read, so its size is unknown"; files=""
  else
    title=$(printf '%s' "$j" | jq -r '.title // ""')
    labels=$(printf '%s' "$j" | jq -r '[.labels[]?.name] | join(",")')
    body=$(printf '%s' "$j" | jq -r '.body // ""')
    # The text it was sized from: a run started over the open-work cap that sizes bigger slips on it.
    driver_state_set "$t" size_body_hash "$(driver_size_body_hash "$body")"
    rd=$(driver_size_read "$t" "$title" "$labels" "$body")
    IFS=$'\t' read -r size why files <<<"$rd"
    if [ "$size" = undecided ]; then
      if ! driver_quick_on; then
        size=project; why="$why; the quick route is off, so no size call was made"
      else
        local asked rc=0
        asked=$(_driver_size_ask "$t" "$title
$body" "$files") || rc=$?
        if driver_usage_wall "$t" size "$(driver_state_dir "$t")/steps/size.log"; then return "$DRIVER_E_USAGE"; fi
        if [ "$rc" -eq 0 ]; then
          by=model; size=${asked%%	*}; why="$why; the size call: ${asked#*	}"
        else
          size=project; why="$why, and the size call gave no readable answer"
        fi
      fi
    fi
  fi
  if [ "$size" = quick ] && driver_quick_on; then route=quick; fi
  [ "$size" != quick ] || driver_quick_on || why="$why; the quick route is off (driver.quick.enabled false)"
  driver_state_set "$t" size "$size"
  driver_state_set "$t" size_reason "$why"
  driver_state_set "$t" size_by "$by"
  driver_state_set "$t" size_files "$files"
  driver_state_set "$t" route "$route"
  driver_say "   size: route=$route size=$size ($by) — $why"
  return "$DRIVER_OK"
}
