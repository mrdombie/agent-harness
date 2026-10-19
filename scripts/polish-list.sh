#!/usr/bin/env bash
# polish-list.sh — one open list of small fixes per screen, in place of one ticket each.
#
#   polish-list.sh add <screen-slug> <text…>   append "- [ ] <text>" under "## Items" on the
#                                              screen's open list, opening the list when there
#                                              is none; the same text is never added twice
#   polish-list.sh tick <issue> <text…>        mark that item done ("- [x]"); 1 when absent
#   polish-list.sh items <issue|->             the unticked items' text, one a line
#   polish-list.sh count <issue|->             how many are unticked
#   polish-list.sh for-screen <screen-slug>    the open list's number, or nothing
#
# `-` reads the issue body from stdin, so a caller holding bodies from one batched
# read (the coordinator) counts without asking GitHub again.
#
# A list is an issue labelled labels.polishList (default polish-list) and
# <labels.screenPrefix><slug> (default screen:<slug>), opened as P3, ready, type:bug.
# A builder on a ticket for that screen fixes its unticked items in the same change
# (briefs/build.md); the coordinator starts a list on its own only once it holds
# coordinator.polishListFull items, or when nothing else can start.
#
# WHY: of 1,000 tickets filed 8-18 Oct 2026, 380 were follow-ups from finished work,
# and 200 of the 206 still open were graded Minor. Each one became its own build,
# its own PR and its own picture for the owner: 34 of 79 open changes were polish.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../swarm" && pwd)/swarm-env.sh" || exit 1

die() { echo "polish-list: $*" >&2; exit 2; }
LOCK="$STATE_DIR/swarm/polish-list.lock"

# Two builders on one screen add at once: read, append, write would drop one item.
lock() {
  local i=0
  mkdir -p "$(dirname "$LOCK")" 2>/dev/null
  until mkdir "$LOCK" 2>/dev/null; do
    # A holder that died leaves the lock: older than a minute is nobody's.
    if [ $(( $(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || stat -f %m "$LOCK" 2>/dev/null || echo 0) )) -gt 60 ]; then
      rm -rf "$LOCK"; continue
    fi
    i=$((i+1)); [ "$i" -lt 100 ] || die "another add held the lock for 20s — nothing added"
    sleep 0.2
  done
  trap 'rm -rf "$LOCK"' EXIT
}

slug_ok() { case "$1" in ''|*[!a-z0-9-]*) return 1 ;; *) return 0 ;; esac; }
screen_name() { printf '%s' "$1" | tr '-' ' ' | awk '{ for (i = 1; i <= NF; i++) $i = toupper(substr($i, 1, 1)) substr($i, 2); print }'; }
one_line() { printf '%s' "$*" | tr '\n\t' '  ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]][[:space:]]*/ /g'; }

body_of() { # <issue|-> — the body, or 1 when it could not be read
  if [ "$1" = - ]; then cat; return 0; fi
  case "$1" in ''|*[!0-9]*) die "'$1' is not an issue number" ;; esac
  local j; j=$(swarm_gh issue view "$1" --repo "$REPO_SLUG" --json body 2>/dev/null) || return 1
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$j" || return 1
  jq -r '.body // ""' <<<"$j"
}

# The task lines under "## Items", up to the next heading. CRLF from the web editor too.
items_section() { tr -d '\r' | awk '/^##[ \t]/ { inside = ($0 ~ /^##[ \t]+Items[ \t]*$/); next } inside'; }
unticked() { items_section | sed -n 's/^[[:space:]]*[-*] \[ \] //p'; }

for_screen() { # <slug>
  slug_ok "$1" || die "a screen slug is lower-case letters, digits and dashes: '$1'"
  local out
  out=$(swarm_gh issue list --repo "$REPO_SLUG" --state open --label "$LBL_POLISH_LIST" \
          --label "$LBL_SCREEN_PREFIX$1" --limit 20 --json number 2>/dev/null) || return 2
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$out" || return 2
  jq -r 'map(.number) | sort | first // empty' <<<"$out"
}

open_list() { # <slug> — opens the screen's list, prints its number
  local slug="$1" name url n
  name=$(screen_name "$slug")
  # Labels the kit names: made once if the project has none yet.
  swarm_gh label create "$LBL_POLISH_LIST" --repo "$REPO_SLUG" --color C5DEF5 \
    --description "One list of small fixes for a screen" >/dev/null 2>&1 || true
  swarm_gh label create "$LBL_SCREEN_PREFIX$slug" --repo "$REPO_SLUG" --color EDEDED >/dev/null 2>&1 || true
  url=$(swarm_gh issue create --repo "$REPO_SLUG" --title "Polish list: $name" \
          --label "$LBL_POLISH_LIST" --label "$LBL_SCREEN_PREFIX$slug" --label P3 \
          --label "$LBL_READY" --label type:bug \
          --body "Small fixes for the $name screen, graded Minor. A ticket for this screen fixes the unticked ones in its own change and ticks them; the list ships on its own only once it is full.

## Items
" 2>/dev/null) || die "could not open a polish list for $slug"
  n=$(printf '%s' "$url" | grep -oE '[0-9]+$')
  [ -n "$n" ] || die "opening a polish list for $slug answered '$url'"
  printf '%s' "$n"
}

add() { # <slug> <text…>
  local slug="${1:-}" text n body new
  shift || true
  slug_ok "$slug" || die "usage: polish-list.sh add <screen-slug> <text…>"
  text=$(one_line "$*"); [ -n "$text" ] || die "nothing to add"
  lock
  n=$(for_screen "$slug") || die "the open polish lists could not be read — nothing added"
  [ -n "$n" ] || n=$(open_list "$slug") || exit 2
  body=$(body_of "$n") || die "#$n could not be read — nothing added"
  # Idempotent on the item's text: ticked or not, it is already on the list.
  if printf '%s\n' "$body" | items_section | sed -n 's/^[[:space:]]*[-*] \[[ xX]\] //p' | grep -qxF -- "$text"; then
    echo "#$n already lists: $text"; return 0
  fi
  new=$(printf '%s\n' "$body" | tr -d '\r' | ITEM="- [ ] $text" awk '
    { line[++n] = $0 }
    /^##[ \t]+Items[ \t]*$/ { at = n }
    at && n > at && /^##[ \t]/ && !end { end = n }
    END {
      if (!at) { for (i = 1; i <= n; i++) print line[i]; print ""; print "## Items"; print ENVIRON["ITEM"]; exit }
      last = at; stop = end ? end - 1 : n
      for (i = at + 1; i <= stop; i++) if (line[i] ~ /[^ \t]/) last = i
      for (i = 1; i <= n; i++) { print line[i]; if (i == last) print ENVIRON["ITEM"] }
    }')
  printf '%s\n' "$new" | swarm_gh issue edit "$n" --repo "$REPO_SLUG" --body-file - >/dev/null 2>&1 \
    || die "#$n could not be written — nothing added"
  echo "#$n: added $text"
}

tick() { # <issue> <text…>
  local n="${1:-}" text body new
  shift || true
  text=$(one_line "$*"); [ -n "$text" ] || die "usage: polish-list.sh tick <issue> <text…>"
  lock
  body=$(body_of "$n") || die "#$n could not be read"
  new=$(printf '%s\n' "$body" | tr -d '\r' | ITEM="$text" awk '
    /^##[ \t]/ { inside = ($0 ~ /^##[ \t]+Items[ \t]*$/) }
    inside && !done { s = $0; sub(/^[ \t]*[-*] \[ \] /, "", s)
      if (s != $0 && s == ENVIRON["ITEM"]) { sub(/\[ \]/, "[x]"); done = 1 } }
    { print }
    END { exit !done }') || { echo "#$n has no unticked item: $text" >&2; return 1; }
  printf '%s\n' "$new" | swarm_gh issue edit "$n" --repo "$REPO_SLUG" --body-file - >/dev/null 2>&1 \
    || die "#$n could not be written"
  echo "#$n: ticked $text"
}

case "${1:-}" in
  add)        shift; add "$@" ;;
  tick)       shift; tick "$@" ;;
  items)      body=$(body_of "${2:?usage: polish-list.sh items <issue|->}") || die "#$2 could not be read"
              printf '%s\n' "$body" | unticked ;;
  count)      body=$(body_of "${2:?usage: polish-list.sh count <issue|->}") || die "#$2 could not be read"
              printf '%s\n' "$body" | unticked | grep -c . || true ;;
  for-screen) shift; for_screen "${1:-}" || die "the open polish lists could not be read" ;;
  -h|--help|"") sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *)          die "unknown command '$1'" ;;
esac
