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
#            copy or docs, or a small code edit the ticket states
#   small    a few named files, no schema, no new screen
#   project  anything else: a schema or migration, a new screen, a design label, a
#            never-quick file, more files than small, or a ticket naming no file
#
# Mechanical first: labels, the body, the paths it names, a stated diff or snippet.
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
#   neverGlobs  more globs never quick, beside the defaults: this project's screen
#               files (design.surfacePaths, design.extraScreens), schema and
#               migration files, lockfiles
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-step.sh" || exit 1

DRIVER_QUICK_NEVER_DEFAULT='["*migrations/*", "*migration/*", "*.sql", "*.prisma", "*/prisma/*", "*schema.rb", "*alembic/*", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb", "Cargo.lock", "poetry.lock", "uv.lock", "Gemfile.lock", "go.sum", "composer.lock"]'
DRIVER_SIZE_SCHEMA_RE='(^|[^a-z])(schema change|data model|migration|migrate|prisma|alter table|create table|drop table|drop column|new (db |database )?(table|column)|add (a )?(db |database )?column)([^a-z]|$)'
DRIVER_SIZE_SCREEN_RE='(^|[^a-z])(new (screen|page|surface|route)|redesign)([^a-z]|$)'
DRIVER_SIZE_EXT='json|jsonc|md|mdx|ya?ml|toml|ts|tsx|js|jsx|mjs|cjs|sh|bash|py|rb|go|rs|css|scss|html|txt|sql|prisma|lock|lockb|env|ini|cfg|conf|swift|kt|java'
DRIVER_SIZE_CONFIG_RE='\.(json|jsonc|md|mdx|ya?ml|toml|txt|ini|cfg|conf|env)$|(^|/)\.env(\.[a-z]+)?$'

# `== false`, not `// true`: jq's alternative treats false as absent, so `// true` reads it as on.
driver_quick_on() { [ "$(jq -r 'if .driver.quick.enabled == false then "off" else "on" end' "$HARNESS_CFG" 2>/dev/null)" != off ]; }
driver_quick_max_files() {
  local n; n=$(jq -r '.driver.quick.maxFiles // 3' "$HARNESS_CFG" 2>/dev/null)
  case "$n" in ''|*[!0-9]*|0) n=3 ;; esac; printf '%s' "$n"
}
_driver_size_small_max() {
  local n; n=$(jq -r '.driver.quick.smallMaxFiles // 8' "$HARNESS_CFG" 2>/dev/null)
  case "$n" in ''|*[!0-9]*|0) n=8 ;; esac; printf '%s' "$n"
}

# _driver_size_globs — the never-quick globs as a JSON list: the defaults plus
# driver.quick.neverGlobs. Screen files are asked of approval-kept.sh, not globbed here.
_driver_size_globs() {
  jq -c --argjson d "$DRIVER_QUICK_NEVER_DEFAULT" \
    '$d + [(.driver.quick.neverGlobs // [])[]? | select(type == "string" and length > 0)]' "$HARNESS_CFG" 2>/dev/null \
    || printf '%s' "$DRIVER_QUICK_NEVER_DEFAULT"
}

# driver_quick_never <paths on stdin> — prints "<path>\t<why>" for each path that is
# never quick: a screen file, a page, or one of the never-quick globs.
driver_quick_never() {
  local files f p hit pats screens
  files=$(sed '/^$/d')
  [ -n "$files" ] || return 0
  # Asked only of a project that names its screens: with no design.surfacePaths the
  # screen set is every file, and a config edit would read as screen work.
  screens=""
  if [ "$(jq -r '(.design.surfacePaths // []) | if type == "array" then length else 0 end' "$HARNESS_CFG" 2>/dev/null)" != 0 ]; then
    screens=$(printf '%s\n' "$files" | HARNESS_CFG="$HARNESS_CFG" bash "${DRIVER_APPROVAL_KEPT:-$KIT_ROOT/scripts/approval-kept.sh}" screens 2>/dev/null | sed '/^$/d')
  fi
  pats=$(_driver_size_globs | jq -r '.[]' 2>/dev/null)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if printf '%s\n' "$screens" | grep -qxF -- "$f"; then printf '%s\ta screen file\n' "$f"; continue; fi
    if printf '%s\n' "$f" | grep -qE '(^|/)app/(.*/)?page\.(t|j)sx?$'; then printf '%s\ta page\n' "$f"; continue; fi
    hit=""
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      p="${p//\*\*/*}"
      # shellcheck disable=SC2053
      if [[ "$f" == $p ]] || [[ "$f" == */$p ]]; then hit="$p"; break; fi
    done <<<"$pats"
    [ -z "$hit" ] || printf '%s\tnever quick (%s)\n' "$f" "$hit"
  done <<<"$files"
}

# _driver_size_paths <text> — the file paths a ticket names, one per line: a token
# with a known extension, URLs stripped first.
_driver_size_paths() {
  printf '%s\n' "$1" | sed -E 's#[a-z]+://[^[:space:])>]*##g' \
    | grep -oE "[A-Za-z0-9_./@-]*[A-Za-z0-9_-]\.($DRIVER_SIZE_EXT)([^A-Za-z0-9_]|$)" \
    | sed -E 's/[^A-Za-z0-9_]$//; s#^\./##' | grep -vE '^[0-9.]+$' | awk 'NF && !s[$0]++'
}

# _driver_size_stated <text> — 0 when the ticket states the change: a fenced block
# (a diff or a snippet), or a "set/change/replace/rename/bump … to/with …" line.
_driver_size_stated() {
  printf '%s\n' "$1" | grep -qE '^[[:space:]]*```' && return 0
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' \
    | grep -qE '(^|[^a-z])(set|change|replace|rename|bump|swap|move)[^a-z][^.]{0,120}[^a-z](to|with|from)[^a-z]'
}

# driver_size_read <ticket> <title> <labels-csv> <body> — the mechanical read, as
# "<size|undecided>\t<why>\t<files, comma-separated>".
driver_size_read() {
  local t="$1" title="$2" labels="$3" body="$4" text low l paths n never cfg max smax
  text="$title
$body"
  low=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')
  max=$(driver_quick_max_files); smax=$(_driver_size_small_max)
  for l in needs:design screen:new screen:redesign $(jq -r '(.design.baselineRoute.pictureLabels // [])[]' "$HARNESS_CFG" 2>/dev/null); do
    case ",$labels," in *",$l,"*) printf 'project\tit carries %s, which is screen work\t\n' "$l"; return 0 ;; esac
  done
  case ",$labels," in *",schema,"*|*",migration,"*|*",type:schema,"*|*",area:schema,"*)
    printf 'project\tits labels name a schema change: a schema ticket is never quick\t\n'; return 0 ;; esac
  if printf '%s' "$low" | grep -qE "$DRIVER_SIZE_SCHEMA_RE"; then
    printf 'project\tit names a schema, data-model or migration change: a schema ticket is never quick\t\n'; return 0
  fi
  if printf '%s' "$low" | grep -qE "$DRIVER_SIZE_SCREEN_RE"; then
    printf 'project\tit names a new or redesigned screen\t\n'; return 0
  fi
  paths=$(_driver_size_paths "$text")
  n=$(printf '%s' "$paths" | grep -c .)
  never=$(printf '%s\n' "$paths" | driver_quick_never | head -1)
  if [ -n "$never" ]; then
    printf 'project\tit names %s — %s\t%s\n' "${never%%	*}" "${never#*	}" "$(printf '%s' "$paths" | paste -sd, -)"; return 0
  fi
  if [ "$n" -eq 0 ]; then
    if _driver_size_stated "$text"; then printf 'undecided\tit states a change and names no file\t\n'
    else printf 'project\tit names no file and states no change, so its size cannot be read\t\n'; fi
    return 0
  fi
  if [ "$n" -gt "$max" ]; then
    if [ "$n" -le "$smax" ]; then printf 'small\tit names %s files, more than a quick change (%s)\t%s\n' "$n" "$max" "$(printf '%s' "$paths" | paste -sd, -)"
    else printf 'project\tit names %s files\t%s\n' "$n" "$(printf '%s' "$paths" | paste -sd, -)"; fi
    return 0
  fi
  cfg=$(printf '%s\n' "$paths" | grep -cvE "$DRIVER_SIZE_CONFIG_RE")
  if [ "$cfg" -eq 0 ]; then
    printf 'quick\tit names %s config or docs file(s): %s\t%s\n' "$n" "$(printf '%s' "$paths" | paste -sd, - | sed 's/,/, /g')" "$(printf '%s' "$paths" | paste -sd, -)"; return 0
  fi
  if _driver_size_stated "$text"; then
    printf 'quick\tit names %s file(s) and states the change: %s\t%s\n' "$n" "$(printf '%s' "$paths" | paste -sd, - | sed 's/,/, /g')" "$(printf '%s' "$paths" | paste -sd, -)"; return 0
  fi
  printf 'undecided\tit names %s code file(s) and does not state the change\t%s\n' "$n" "$(printf '%s' "$paths" | paste -sd, -)"
}

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
