#!/usr/bin/env bash
# size-rules.sh — the size step's mechanical read, with no model call and no run record.
#
#   . "$KIT_ROOT/driver/size-rules.sh"
#   driver_size_read <ticket> <title> <labels-csv> <body>   → "<size|undecided>\t<why>\t<files>"
#
# Sourced by steps/size.sh (the driver) and by the coordinator, which pre-sizes new
# tickets while over coordinator.openPrCap and starts the quick ones anyway. One copy
# of the rules: a coordinator that sized by rules of its own would start what the
# driver then calls bigger.
#
# Needs HARNESS_CFG, KIT_ROOT and, for the existing-screen test, MAIN_REPO and
# INTEGRATION_BRANCH.
[ -z "${_DRIVER_SIZE_RULES:-}" ] || return 0
_DRIVER_SIZE_RULES=1

DRIVER_QUICK_NEVER_DEFAULT='["*migrations/*", "*migration/*", "*.sql", "*.prisma", "*/prisma/*", "*schema.rb", "*alembic/*", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb", "Cargo.lock", "poetry.lock", "uv.lock", "Gemfile.lock", "go.sum", "composer.lock"]'
DRIVER_SIZE_SCHEMA_RE='(^|[^a-z])(schema change|data model|migration|migrate|prisma|alter table|create table|drop table|drop column|new (db |database )?(table|column)|add (a )?(db |database )?column)([^a-z]|$)'
DRIVER_SIZE_SCREEN_RE='(^|[^a-z])(new (screen|page|surface|route)|redesign)([^a-z]|$)'
DRIVER_SIZE_EXT='json|jsonc|md|mdx|ya?ml|toml|ts|tsx|js|jsx|mjs|cjs|sh|bash|py|rb|go|rs|css|scss|html|txt|sql|prisma|lock|lockb|env|ini|cfg|conf|swift|kt|java'
DRIVER_QUICK_NEVER_EFFORT_DEFAULT='["effort:M", "effort:L", "effort:XL"]'
DRIVER_QUICK_NEVER_LABELS_DEFAULT='["type:feature"]'
DRIVER_SIZE_CONFIG_RE='\.(json|jsonc|md|mdx|ya?ml|toml|txt|ini|cfg|conf|env)$|(^|/)\.env(\.[a-z]+)?$'

# THE SIZE ON A CHANGE (owner calls 2026-10-23 "small changes merged fast", 2026-10-24 "a
# finished build is never stranded for size"). At ship a branch past driver.split.maxFiles
# (20), counted two-dot against its merge base, ships with its size said on the PR. Lockfiles are
# not counted (driver.split.exclude replaces the list: globs, matched on the path or the
# file name). 0 turns the cap off. Seen: a "Batch … 2 fixes" PR at 200 files after 5 hours.
DRIVER_SPLIT_EXCLUDE_DEFAULT='["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb", "Cargo.lock", "poetry.lock", "uv.lock", "Gemfile.lock", "go.sum", "composer.lock"]'
# A FEATURE TICKET WRITES A FEATURE LIST (owner, 2026-11-02): a ticket wearing one of
# driver.split.featureLabels (default type:feature) whose plan has none is sent back once,
# then refused. The ticket builds whole, working through its list (owner, 2026-11-05); the plan
# splits only past driver.split.planMaxFiles distinct files (50; 0 never). Measured from our own
# clashes: 4 of 5 changes over 100 files clashed, about 20% at 20-100, 6% under 10. A plan can
# undercount (211 files once planned as 7), so maxFiles still names the real size at ship.
driver_split_feature_labels() {
  jq -r '(.driver.split.featureLabels // ["type:feature"]) | if type == "array" then .[] else empty end | select(type == "string" and length > 0)' \
    "$HARNESS_CFG" 2>/dev/null || printf 'type:feature\n'
}
driver_split_max() {
  local n; n=$(jq -r '.driver.split.maxFiles // 20' "$HARNESS_CFG" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=20 ;; esac; printf '%s' "$n"
}
driver_split_plan_max() {
  local n; n=$(jq -r '.driver.split.planMaxFiles // 50' "$HARNESS_CFG" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=50 ;; esac; printf '%s' "$n"
}
# driver_split_count <tree> <trunk ref> — the files the branch changes, less the excluded; 1 unread.
driver_split_count() {
  local wt="$1" trunk="$2" mb files pats f p n=0 skip
  mb=$(git -C "$wt" merge-base "$trunk" HEAD 2>/dev/null) || return 1
  files=$(git -C "$wt" diff --name-only "$mb" HEAD 2>/dev/null) || return 1
  pats=$(jq -r --argjson d "$DRIVER_SPLIT_EXCLUDE_DEFAULT" '(.driver.split.exclude // $d) | if type == "array" then .[] else empty end | strings' "$HARNESS_CFG" 2>/dev/null) \
    || pats=$(jq -r '.[]' <<<"$DRIVER_SPLIT_EXCLUDE_DEFAULT")
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    skip=0
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      # shellcheck disable=SC2254  # the pattern is a glob on purpose
      case "$f" in $p) skip=1; break ;; esac
      # shellcheck disable=SC2254
      case "${f##*/}" in $p) skip=1; break ;; esac
    done <<<"$pats"
    [ "$skip" = 1 ] || n=$((n+1))
  done <<<"$files"
  printf '%s' "$n"
}

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

# driver_quick_never_effort — the effort labels never quick, one a line:
# driver.quick.neverEffort, or effort:M, effort:L and effort:XL.
driver_quick_never_effort() {
  jq -r --argjson d "$DRIVER_QUICK_NEVER_EFFORT_DEFAULT" \
    '(.driver.quick.neverEffort // $d) | if type == "array" then .[] else empty end | select(type == "string" and length > 0)' \
    "$HARNESS_CFG" 2>/dev/null || jq -r '.[]' <<<"$DRIVER_QUICK_NEVER_EFFORT_DEFAULT"
}

# driver_quick_never_labels — the ticket labels never quick, one a line:
# driver.quick.neverLabels, or type:feature.
driver_quick_never_labels() {
  jq -r --argjson d "$DRIVER_QUICK_NEVER_LABELS_DEFAULT" \
    '(.driver.quick.neverLabels // $d) | if type == "array" then .[] else empty end | select(type == "string" and length > 0)' \
    "$HARNESS_CFG" 2>/dev/null || jq -r '.[]' <<<"$DRIVER_QUICK_NEVER_LABELS_DEFAULT"
}

# driver_repo_self — this project's repo name, lower case, owner dropped: the config's
# `repo`, else REPO_SLUG. Empty when neither is set.
driver_repo_self() {
  local r; r=$(jq -r '.repo // empty' "${HARNESS_CFG:-/dev/null}" 2>/dev/null)
  [ -n "$r" ] || r="${REPO_SLUG:-}"
  r="${r##*/}"; printf '%s' "$r" | tr '[:upper:]' '[:lower:]'
}
# driver_repo_own — the repos this project builds, lower case, one a line: its own and
# each of `sisterRepos` (a sister's tickets ship to its clone beside this one).
driver_repo_own() {
  local s; s=$(driver_repo_self); [ -n "$s" ] || return 0
  { printf '%s\n' "$s"
    jq -r '(.sisterRepos // []) | if type == "array" then .[] else empty end | select(type == "string")' "${HARNESS_CFG:-/dev/null}" 2>/dev/null \
      | sed -E 's#.*/##' | tr '[:upper:]' '[:lower:]'; } | sed '/^$/d' | awk '!s[$0]++'
}

# A REPO WITH A CLONE HERE IS BUILT HERE, IN THAT CLONE. The places kept for harness fixes
# stayed empty while every harness ticket, which names the harness repo, was refused as
# another repo's work. A repo:<name> ticket is this host's to build when a clone of <name>
# sits beside this project's own (or HARNESS_REPO_CLONES="<name>=<path> …" names one), its
# origin is that repo, and its trunk carries .claude/harness.json: the run is spawned in
# that clone and reads that config. With no such clone it is still another repo's.
# driver_repo_clone <name> — the clone's path, or fails.
driver_repo_clone() {
  local want dir="" pair url ref main="${MAIN_REPO:-${HARNESS_MAIN_REPO:-}}"
  want=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'); [ -n "$want" ] || return 1
  [ "$want" != "$(driver_repo_self)" ] || return 1
  for pair in ${HARNESS_REPO_CLONES:-}; do
    [ "$(printf '%s' "${pair%%=*}" | tr '[:upper:]' '[:lower:]')" = "$want" ] && dir="${pair#*=}"
  done
  if [ -z "$dir" ]; then [ -n "$main" ] || return 1; dir="$(dirname "$main")/$1"; fi
  dir="${dir/#\~/$HOME}"
  [ -d "$dir" ] || return 1
  url=$(git -C "$dir" config --get remote.origin.url 2>/dev/null) || return 1
  url="${url%/}"; url="${url%.git}"
  [ "$(printf '%s' "${url##*/}" | tr '[:upper:]' '[:lower:]')" = "$want" ] || return 1
  for ref in origin/HEAD origin/main origin/develop origin/master; do
    git -C "$dir" cat-file -e "$ref:.claude/harness.json" 2>/dev/null && { printf '%s' "$dir"; return 0; }
  done
  return 1
}
# driver_repo_clone_for <labels-csv> — the clone a ticket's repo:<name> label sends its
# run to; fails when its labels name none (no repo: label, or only this project's own).
driver_repo_clone_for() {
  local n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    driver_repo_clone "$n" && return 0
  done <<<"$(printf '%s' "${1:-}" | tr ',' '\n' | sed -nE 's/^[[:space:]]*[Rr][Ee][Pp][Oo]:[[:space:]]*//p' | sed -E 's#.*/##; s/[[:space:]]+$//')"
  return 1
}
# driver_repo_own_here — driver_repo_own, and each repo with a clone on this host
# (driver_repo_clone): those HARNESS_REPO_CLONES names and those beside this project's.
driver_repo_own_here() {
  local main="${MAIN_REPO:-${HARNESS_MAIN_REPO:-}}" d n p u
  { driver_repo_own
    { for p in ${HARNESS_REPO_CLONES:-}; do printf '%s\n' "${p%%=*}"; done
      # Only a directory whose origin carries its own name is asked further.
      [ -z "$main" ] || for d in "$(dirname "$main")"/*/; do
        [ -e "${d}.git" ] || [ -f "${d}HEAD" ] || continue
        d="${d%/}"; u=$(git -C "$d" config --get remote.origin.url 2>/dev/null) || continue
        u="${u%/}"; u="${u%.git}"; [ "${u##*/}" = "${d##*/}" ] || continue
        printf '%s\n' "${d##*/}"
      done; } | awk 'NF && !s[$0]++' | while IFS= read -r n; do
        driver_repo_clone "$n" >/dev/null && printf '%s\n' "$n" | tr '[:upper:]' '[:lower:]'
      done; } | sed '/^$/d' | awk '!s[$0]++'
}

# driver_repo_foreign <labels-csv> — prints the repo a repo:<name> label names and
# returns 0 when the ticket belongs to another repo: it carries a repo: label and none
# of them names a repo this project builds or has a clone of here (driver_repo_clone).
# Never sized, seeded or started here.
driver_repo_foreign() {
  local own want
  own=$(driver_repo_own); [ -n "$own" ] || return 1
  want=$(printf '%s' "$1" | tr ',' '\n' | sed -nE 's/^[[:space:]]*[Rr][Ee][Pp][Oo]:[[:space:]]*//p' \
    | sed -E 's#.*/##; s/[[:space:]]+$//' | tr '[:upper:]' '[:lower:]' | sed '/^$/d')
  [ -n "$want" ] || return 1
  printf '%s\n' "$want" | grep -qxF -f <(printf '%s\n' "$own") && return 1
  driver_repo_clone_for "$1" >/dev/null && return 1
  printf '%s' "$(printf '%s\n' "$want" | head -1)"
}

# _driver_size_globs — the never-quick globs as a JSON list: the defaults plus
# driver.quick.neverGlobs. Screen files are asked of approval-kept.sh, not globbed here.
_driver_size_globs() {
  jq -c --argjson d "$DRIVER_QUICK_NEVER_DEFAULT" \
    '$d + [(.driver.quick.neverGlobs // [])[]? | select(type == "string" and length > 0)]' "$HARNESS_CFG" 2>/dev/null \
    || printf '%s' "$DRIVER_QUICK_NEVER_DEFAULT"
}

# THE SCREEN ROUTE (the owner, 2026-10-21): pictures and the AI design review are for new
# or redesigned screens only. A ticket labelled one of design.baselineRoute.pictureLabels
# (screen:new, screen:redesign) takes the picture route: picture first, compare, the
# independent critic and sign-off, all unchanged. Any other screen build takes the
# baseline route: the project's CI diffs its shots against each route's last approved
# shots and decides the design status, so no picture is bound and no critic verdict is
# owed. Off unless design.baselineRoute.enabled is true; labels that cannot be read take
# the picture route. CI still sends a route with no approved shot to the picture route.
# MERGE FIRST (release.mergeFirst) turns it on: only a screen:new or screen:redesign ticket waits for a picture.
driver_baseline_route_on() {
  { command -v release_merge_first >/dev/null 2>&1 && release_merge_first; } && return 0
  [ "$(jq -r '.design.baselineRoute.enabled // false' "$HARNESS_CFG" 2>/dev/null)" = true ]
}
driver_picture_labels() { jq -r '(.design.baselineRoute.pictureLabels // ["screen:new", "screen:redesign"])[]' "$HARNESS_CFG" 2>/dev/null; }

# _driver_size_exists <path> — 0 when the path is on the trunk already (the main
# checkout's origin/<integration branch>): an existing screen or route, not a new one.
_driver_size_exists() {
  local repo="${MAIN_REPO:-}" rev="" r
  [ -n "$repo" ] && [ -d "$repo" ] || return 1
  for r in "origin/${INTEGRATION_BRANCH:-develop}" "${INTEGRATION_BRANCH:-develop}"; do
    git -C "$repo" rev-parse --verify -q "$r^{commit}" >/dev/null 2>&1 && { rev="$r"; break; }
  done
  [ -n "$rev" ] && git -C "$repo" cat-file -e "$rev:$1" 2>/dev/null
}

# driver_quick_never <paths on stdin> — prints "<path>\t<why>" for each path that is
# never quick: a NEW screen file or page (a new screen or route), a screen file while
# this project has no baseline route, or one of the never-quick globs. A screen file or
# page already on the trunk is an existing screen: quick when the baseline route is on,
# because CI diffs it against its last approved shots (the owner, 2026-10-22).
driver_quick_never() {
  local files f p hit pats screens baseline=""
  files=$(sed '/^$/d')
  [ -n "$files" ] || return 0
  driver_baseline_route_on && baseline=1
  # Asked only of a project that names its screens: with no design.surfacePaths the
  # screen set is every file, and a config edit would read as screen work.
  screens=""
  if [ "$(jq -r '(.design.surfacePaths // []) | if type == "array" then length else 0 end' "$HARNESS_CFG" 2>/dev/null)" != 0 ]; then
    screens=$(printf '%s\n' "$files" | HARNESS_CFG="$HARNESS_CFG" HARNESS_CFG_PATH="$HARNESS_CFG" bash "${DRIVER_APPROVAL_KEPT:-$KIT_ROOT/scripts/approval-kept.sh}" screens 2>/dev/null | sed '/^$/d')
  fi
  pats=$(_driver_size_globs | jq -r '.[]' 2>/dev/null)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if printf '%s\n' "$screens" | grep -qxF -- "$f"; then
      if [ -z "$baseline" ]; then printf '%s\ta screen file\n' "$f"; continue; fi
      _driver_size_exists "$f" || { printf '%s\ta new screen file\n' "$f"; continue; }
    elif printf '%s\n' "$f" | grep -qE '(^|/)app/(.*/)?page\.(t|j)sx?$'; then
      if [ -z "$baseline" ]; then printf '%s\ta page\n' "$f"; continue; fi
      _driver_size_exists "$f" || { printf '%s\ta new route\n' "$f"; continue; }
    fi
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
  local t="$1" title="$2" labels="$3" body="$4" text low l paths n never cfg max smax have gone note=""
  text="$title
$body"
  low=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')
  max=$(driver_quick_max_files); smax=$(_driver_size_small_max)
  if l=$(driver_repo_foreign "$labels"); then
    printf 'project\tit belongs to %s, not this project: it is never built here\t\n' "$l"; return 0
  fi
  # What the ticket is outranks what it mentions: an effort label is its owner's size.
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    case ",$labels," in *",$l,"*)
      case "$l" in *:M|*:m) printf 'small\tit carries %s: an effort that size is never quick\t\n' "$l" ;;
        *) printf 'project\tit carries %s: an effort that size is never quick\t\n' "$l" ;; esac
      return 0 ;;
    esac
  done <<<"$(driver_quick_never_effort)"
  # A feature's spec doc is often the only file it names, which reads as a docs edit.
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    case ",$labels," in *",$l,"*)
      printf 'small\tit carries %s: a ticket labelled so is never quick\t\n' "$l"; return 0 ;;
    esac
  done <<<"$(driver_quick_never_labels)"
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
  # Only a named file on the trunk counts toward quick: a file mentioned from elsewhere
  # (a scratchpad, another repo) says nothing of what the change touches here.
  have=$(printf '%s\n' "$paths" | while IFS= read -r l; do [ -z "$l" ] || ! _driver_size_exists "$l" || printf '%s\n' "$l"; done)
  if [ -z "$have" ]; then
    printf 'undecided\tnone of the files it names is on %s (%s), so they say nothing of its size\t%s\n' \
      "${INTEGRATION_BRANCH:-develop}" "$(printf '%s' "$paths" | paste -sd, - | sed 's/,/, /g')" "$(printf '%s' "$paths" | paste -sd, -)"; return 0
  fi
  gone=$(printf '%s\n' "$paths" | grep -vxF -f <(printf '%s\n' "$have") | sed '/^$/d')
  [ -z "$gone" ] || note="; not on ${INTEGRATION_BRANCH:-develop}, so not counted: $(printf '%s' "$gone" | paste -sd, - | sed 's/,/, /g')"
  paths="$have"; n=$(printf '%s' "$paths" | grep -c .)
  cfg=$(printf '%s\n' "$paths" | grep -cvE "$DRIVER_SIZE_CONFIG_RE")
  if [ "$cfg" -eq 0 ]; then
    printf 'quick\tit names %s config or docs file(s): %s%s\t%s\n' "$n" "$(printf '%s' "$paths" | paste -sd, - | sed 's/,/, /g')" "$note" "$(printf '%s' "$paths" | paste -sd, -)"; return 0
  fi
  if _driver_size_stated "$text"; then
    printf 'quick\tit names %s file(s) and states the change: %s%s\t%s\n' "$n" "$(printf '%s' "$paths" | paste -sd, - | sed 's/,/, /g')" "$note" "$(printf '%s' "$paths" | paste -sd, -)"; return 0
  fi
  printf 'undecided\tit names %s code file(s) and does not state the change\t%s\n' "$n" "$(printf '%s' "$paths" | paste -sd, -)"
}


# ---- the pre-size cache and the slip ledger ---------------------------------------
# The coordinator sizes a ticket once per text: a row per ticket, keyed by the hash of
# its title, its labels (status:* aside, which the run itself moves) and its body. A run
# it started over the cap that the driver then sizes bigger leaves a slip keyed by the
# body's hash, and that body is never pre-sized quick again: without it the requeued
# ticket would be started over the cap on the next tick, and slip, for ever.
driver_size_cache_dir() { printf '%s' "${DRIVER_SIZE_CACHE_DIR:-${STATE_DIR:-${TMPDIR:-/tmp}}/size-cache}"; }

# driver_size_key <title> <labels-csv> <body> — the cache key.
driver_size_key() {
  printf '%s\n%s\n%s' "$1" "$(printf '%s' "$2" | tr ',' '\n' | grep -v '^status:' | sed '/^$/d' | sort -u | paste -sd, -)" "$3" \
    | git hash-object --stdin 2>/dev/null
}
driver_size_body_hash() { printf '%s' "$1" | git hash-object --stdin 2>/dev/null; }

# driver_size_cache_row <ticket> — "<key>\t<updatedAt>\t<body-hash>\t<size>\t<why>", 1 when none.
driver_size_cache_row() {
  local f; f="$(driver_size_cache_dir)/$1"
  [ -s "$f" ] || return 1
  head -1 "$f"
}
# driver_size_cache_put <ticket> <key> <updatedAt> <body-hash> <size> <why> — one row a
# ticket: a new text replaces it.
driver_size_cache_put() {
  local d; d=$(driver_size_cache_dir); mkdir -p "$d" 2>/dev/null || return 1
  printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "$(printf '%s' "$6" | tr '\t\n' '  ' | cut -c1-300)" > "$d/$1.$$" && mv -f "$d/$1.$$" "$d/$1"
}
# driver_size_slip_put <ticket> <body-hash> <why> / driver_size_slipped <ticket> <body-hash>
driver_size_slip_put() {
  local d; d=$(driver_size_cache_dir); mkdir -p "$d" 2>/dev/null || return 1
  [ -n "$2" ] || return 1
  printf '%s\t%s\n' "$2" "$(printf '%s' "${3:-}" | tr '\t\n' '  ' | cut -c1-300)" > "$d/$1.slip"
}
driver_size_slipped() { [ -n "$2" ] && [ "$(cut -f1 "$(driver_size_cache_dir)/$1.slip" 2>/dev/null)" = "$2" ]; }
