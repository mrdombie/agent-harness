#!/usr/bin/env bash
# polish-list.sh — one open list of small fixes per screen, in place of one ticket each.
#
#   polish-list.sh add <screen-slug> <text…>     append "- [ ] <text>" under "## Items" on the
#                                                screen's open list, opening the list when there
#                                                is none; the same text is never added twice
#   polish-list.sh items <issue|-> [--lend]      the items still free to take, one a line:
#                                                unticked and not reserved by a pull request;
#                                                --lend: only the first coordinator.polishListFull
#                                                (8), what one other change takes along
#   polish-list.sh count <issue|-> [ticket]      how many are free to take; with a ticket,
#                                                its own takes count too (its run resumes them)
#   polish-list.sh for-screen <screen-slug>      the open list's number, or nothing
#   polish-list.sh lends <issue> [<ticket>]      0 when another change may take its items;
#                                                1, saying why, when its own run holds it
#   polish-list.sh take <issue> <ticket> <text…> a builder fixed that item: marked
#                                                "(taken by #<ticket>)" so other runs skip it,
#                                                and recorded for the run; never ticked yet;
#                                                1 when the item is not free to take
#   polish-list.sh taken <ticket>                what that run took: <issue> \t <text>
#   polish-list.sh forget <ticket> [<issue> <text…>]  a fresh run lets go of what an earlier
#                                                run of the ticket took; with an item, only
#                                                that one leaves the record
#   polish-list.sh reserve [--ticket <t>] <issue> <pr> <text…>
#                                                "- [ ] <text> (in PR #<pr>)": other runs skip
#                                                it; --ticket may take over that run's take
#   polish-list.sh sweep [--dry-run]             every open list: an item whose PR merged is
#                                                ticked, one whose PR closed unmerged is free
#                                                again, one taken by a ticket now closed,
#                                                parked, waiting on the owner or stalled is
#                                                free again, and a list with nothing left closes
#
# `-` reads the issue body from stdin, so a caller holding bodies from one batched
# read (the coordinator) counts without asking GitHub again.
#
# An item is ticked only when the pull request that fixed it merges. Ticked during
# the build, an item whose PR never landed was marked done and lost; taken by two
# runs, it was fixed twice. So a run records what it took (take), ship reserves
# those items for its PR (reserve), and the coordinator's housekeeping settles them
# once the PR is merged or closed (sweep). A list closes only when it has no item
# left, never by a PR: its own PR says "Refs", not "Closes".
#
# POLISH IS MINOR BY DEFINITION (rules/standing-rules.md: Minor = polish; Major = a
# person misled or stuck, fixed in its own ticket). An item graded Critical or Major
# is never added: it is opened as its own ticket (P0 / P1, the screen's label) and
# add says so. One Major on a list was handed to a change on another screen, could
# not be deferred, and parked the run asking the PM.
#
# A list is an issue labelled labels.polishList (default polish-list) and
# <labels.screenPrefix><slug> (default screen:<slug>), opened as P3, ready, type:bug.
#
# WHY: of 1,000 tickets filed 8-18 Oct 2026, 380 were follow-ups from finished work,
# and 200 of the 206 still open were graded Minor. Each one became its own build,
# its own PR and its own picture for the owner: 34 of 79 open changes were polish.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../swarm" && pwd)/swarm-env.sh" || exit 1

die() { echo "polish-list: $*" >&2; exit 2; }
LOCK="$STATE_DIR/swarm/polish-list.lock"
TAKEN_DIR="$STATE_DIR/swarm/polish-taken"
LOCK_STALE_SEC=30
LOCK_WAIT_SEC=45
TOKEN="$$.$RANDOM.$(date +%s)"

# Two writers on one list at once: read, change, write would drop one change. A
# holder that died leaves the lock: older than LOCK_STALE_SEC is nobody's, and a
# waiter outlasts that age, so it breaks a dead lock rather than giving up first.
# Only the lock this process took is removed on exit: a waiter that broke a stale
# lock must not have it removed by the slow holder that left it.
lock() {
  local start; start=$(date +%s)
  mkdir -p "$(dirname "$LOCK")" 2>/dev/null
  until mkdir "$LOCK" 2>/dev/null; do
    if [ $(( $(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || stat -f %m "$LOCK" 2>/dev/null || echo 0) )) -gt "$LOCK_STALE_SEC" ]; then
      rm -rf "$LOCK"; continue
    fi
    [ $(( $(date +%s) - start )) -lt "$LOCK_WAIT_SEC" ] || die "another writer held the lock for ${LOCK_WAIT_SEC}s — nothing changed"
    sleep 0.2
  done
  printf '%s\n' "$TOKEN" > "$LOCK/owner"
  trap unlock EXIT
}
unlock() { [ "$(cat "$LOCK/owner" 2>/dev/null)" = "$TOKEN" ] && rm -rf "$LOCK"; return 0; }

slug_ok() { case "$1" in ''|*[!a-z0-9-]*) return 1 ;; *) return 0 ;; esac; }
num_ok()  { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
screen_name() { printf '%s' "$1" | tr '-' ' ' | awk '{ for (i = 1; i <= NF; i++) $i = toupper(substr($i, 1, 1)) substr($i, 2); print }'; }
one_line() { printf '%s' "$*" | tr '\n\t' '  ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]][[:space:]]*/ /g'; }

body_of() { # <issue|-> — the body, or 1 when it could not be read
  if [ "$1" = - ]; then cat; return 0; fi
  num_ok "$1" || die "'$1' is not an issue number"
  local j; j=$(swarm_gh issue view "$1" --repo "$REPO_SLUG" --json body 2>/dev/null) || return 1
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$j" || return 1
  jq -r '.body // ""' <<<"$j"
}
write_body() { # <issue> — the new body on stdin
  swarm_gh issue edit "$1" --repo "$REPO_SLUG" --body-file - >/dev/null 2>&1
}

# Every task line under "## Items", up to the next heading, as
# <state x|space> \t <mark> \t <text>: the mark is empty (free), a PR number
# ("(in PR #N)") or t<ticket> ("(taken by #N)"). CRLF from the web editor too.
ITEMS_AWK='
  /^##[ \t]/ { inside = ($0 ~ /^##[ \t]+Items[ \t]*$/); next }
  inside && match($0, /^[ \t]*[-*] \[[ xX]\] /) {
    st = (substr($0, RSTART + RLENGTH - 3, 1) == " ") ? " " : "x"
    text = substr($0, RSTART + RLENGTH); pr = ""
    if (match(text, / \(in PR #[0-9]+\)$/)) { pr = substr(text, RSTART + 9, RLENGTH - 10); text = substr(text, 1, RSTART - 1) }
    else if (match(text, / \(taken by #[0-9]+\)$/)) { pr = "t" substr(text, RSTART + 12, RLENGTH - 13); text = substr(text, 1, RSTART - 1) }
    print st "\t" pr "\t" text
  }'
all_items() { tr -d '\r' | awk "$ITEMS_AWK"; }
free_items() { all_items | awk -F'\t' '$1 == " " && $2 == "" { print $3 }'; }

# set_item <text> <state x|space> <mark> — rewrites that item's line; 1 when absent.
# The mark: empty (free), <pr> ("(in PR #pr)"), or t<ticket> ("(taken by #ticket)").
set_item() {
  tr -d '\r' | ITEM="$1" ST="$2" PR="$3" awk '
    /^##[ \t]/ { inside = ($0 ~ /^##[ \t]+Items[ \t]*$/) }
    inside && !done && match($0, /^[ \t]*[-*] \[[ xX]\] /) {
      lead = substr($0, 1, RSTART - 1); text = substr($0, RSTART + RLENGTH)
      sub(/ \((in PR|taken by) #[0-9]+\)$/, "", text)
      if (text == ENVIRON["ITEM"]) {
        m = ENVIRON["PR"]
        mark = (m == "") ? "" : (m ~ /^t/) ? " (taken by #" substr(m, 2) ")" : " (in PR #" m ")"
        $0 = lead "- [" ENVIRON["ST"] "] " text mark; done = 1
      }
    }
    { print }
    END { exit !done }'
}

# The list is looked up through the issues endpoint by label, never search, which
# lags a few seconds behind a new issue. A list this machine opened is also kept on
# disk, so an add seconds after the one that opened it finds it even if GitHub has
# not listed it yet. Both are read under the lock add takes around find-or-create.
LISTS_DIR="$STATE_DIR/swarm/polish-lists/${REPO_SLUG//\//_}"
for_screen() { # <slug>
  slug_ok "$1" || die "a screen slug is lower-case letters, digits and dashes: '$1'"
  local out labels mine have
  labels=$(jq -rn --arg a "$LBL_POLISH_LIST" --arg b "$LBL_SCREEN_PREFIX$1" '[$a, $b] | map(@uri) | join(",")')
  out=$(swarm_gh api "repos/$REPO_SLUG/issues?state=open&labels=$labels&per_page=50" 2>/dev/null) || return 2
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$out" || return 2
  out=$(jq -r '.[] | select(.pull_request | not) | .number' <<<"$out")
  mine=$(cat "$LISTS_DIR/$1" 2>/dev/null)
  if num_ok "$mine" && ! grep -qx -- "$mine" <<<"$out"; then
    # Still open and still this screen's list: read directly, which does not lag.
    have=$(swarm_gh issue view "$mine" --repo "$REPO_SLUG" --json state,labels 2>/dev/null)
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$have"; then
      out=$(printf '%s\n%s' "$out" "$mine")  # unreadable: a second list is worse than a stale number
    elif jq -e --arg a "$LBL_POLISH_LIST" --arg b "$LBL_SCREEN_PREFIX$1" \
           '.state == "OPEN" and ([.labels[].name] | index($a) and index($b))' >/dev/null 2>&1 <<<"$have"; then
      out=$(printf '%s\n%s' "$out" "$mine")
    fi
  fi
  printf '%s\n' "$out" | awk 'NF' | sort -n | head -1
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
          --body "Small fixes for the $name screen, graded Minor. A ticket for this screen fixes the free ones in its own change; each is ticked when the pull request that fixed it merges, and the list closes when nothing is left on it.

## Items
" 2>/dev/null) || die "could not open a polish list for $slug"
  n=$(printf '%s' "$url" | grep -oE '[0-9]+$')
  [ -n "$n" ] || die "opening a polish list for $slug answered '$url'"
  mkdir -p "$LISTS_DIR" 2>/dev/null && printf '%s\n' "$n" > "$LISTS_DIR/$slug"
  printf '%s' "$n"
}

# grade_of <text> — the grade the item names at its start ("[Major] …", "Major · …"), or
# nothing. The same reading as screen-findings.sh, so what it would hand on as a Major
# is what is refused here.
grade_of() {
  printf '%s\n' "$1" | awk '{ s = tolower($0)
    if (match(s, /^[[:space:]*]*\[?(critical|major|minor|nit)\]?[^a-z0-9]+/)) { w = substr(s, RSTART, RLENGTH); gsub(/[^a-z]/, "", w); print w } }'
}

# own_ticket <slug> <grade> <text> — a Critical or Major opened as a ticket of its own,
# once: an open one for the screen with the same title is reused.
own_ticket() {
  local slug="$1" g="$2" text="$3" title pri open n url
  title="$(screen_name "$slug"): $(printf '%s' "$text" | sed -E 's/^[[:space:]*]*\[?[A-Za-z]+\]?[^A-Za-z0-9]+//' | cut -c1-110)"
  pri=P1; [ "$g" = critical ] && pri=P0
  open=$(swarm_gh api "repos/$REPO_SLUG/issues?state=open&labels=$(jq -rn --arg l "$LBL_SCREEN_PREFIX$slug" '$l | @uri')&per_page=100" 2>/dev/null) \
    || die "the open tickets for $slug could not be read — nothing added"
  n=$(jq -r --arg t "$title" 'if type == "array" then .[] | select(.pull_request | not) | select(.title == $t) | .number else empty end' <<<"$open" 2>/dev/null | head -1)
  if [ -z "$n" ]; then
    swarm_gh label create "$LBL_SCREEN_PREFIX$slug" --repo "$REPO_SLUG" --color EDEDED >/dev/null 2>&1 || true
    url=$(swarm_gh issue create --repo "$REPO_SLUG" --title "$title" \
            --label "$pri" --label type:bug --label "$LBL_SCREEN_PREFIX$slug" ${LBL_DRAFTING:+--label "$LBL_DRAFTING"} \
            --body "$text

Graded $g, so it is not polish: polish is Minor by definition, and a $g is fixed in a ticket of its own. Opened by polish-list.sh add in place of an item on the $(screen_name "$slug") polish list." 2>/dev/null) \
      || die "could not open a ticket for a $g on $slug — nothing added"
    n=$(printf '%s' "$url" | grep -oE '[0-9]+$')
    [ -n "$n" ] || die "opening a ticket for a $g on $slug answered '$url'"
  fi
  echo "#$n: graded $g, so not polish — its own ticket ($pri), not an item on the list: $text"
}

add() { # <slug> <text…>
  local slug="${1:-}" text n body new g
  shift || true
  slug_ok "$slug" || die "usage: polish-list.sh add <screen-slug> <text…>"
  text=$(one_line "$*"); [ -n "$text" ] || die "nothing to add"
  lock
  g=$(grade_of "$text")
  case "$g" in critical|major) own_ticket "$slug" "$g" "$text"; return ;; esac
  n=$(for_screen "$slug") || die "the open polish lists could not be read — nothing added"
  [ -n "$n" ] || n=$(open_list "$slug") || exit 2
  body=$(body_of "$n") || die "#$n could not be read — nothing added"
  # Idempotent on the item's text: ticked, reserved or free, it is already on the list.
  if printf '%s\n' "$body" | all_items | cut -f3 | grep -xF -- "$text" >/dev/null; then
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
  printf '%s\n' "$new" | write_body "$n" || die "#$n could not be written — nothing added"
  echo "#$n: added $text"
}

take() { # <issue> <ticket> <text…>
  local n="${1:-}" t="${2:-}" text body new f cur
  shift 2 2>/dev/null || true
  num_ok "$n" && num_ok "$t" || die "usage: polish-list.sh take <issue> <ticket> <text…>"
  text=$(one_line "$*"); [ -n "$text" ] || die "usage: polish-list.sh take <issue> <ticket> <text…>"
  lock
  body=$(body_of "$n") || die "#$n could not be read"
  cur=$(printf '%s\n' "$body" | all_items | awk -F'\t' -v x="$text" '$3 == x { print $1 "\t" $2; exit }')
  case "$cur" in
    " 	t$t") ;;
    " 	")    new=$(printf '%s\n' "$body" | set_item "$text" " " "t$t") || return 1
              printf '%s\n' "$new" | write_body "$n" || die "#$n could not be written" ;;
    *) echo "#$n has no free item: $text (ticked, taken by another run or PR, or not on the list)" >&2; return 1 ;;
  esac
  # Marked on the list at once, so a second run on the screen skips it.
  mkdir -p "$TAKEN_DIR"; f="$TAKEN_DIR/$t.tsv"
  grep -qxF -- "$n	$text" "$f" 2>/dev/null || printf '%s\t%s\n' "$n" "$text" >> "$f"
  echo "#$n: taken for #$t — ticked when its pull request merges: $text"
}

# forget <ticket> [<issue> <text…>] — a run starting fresh lets go of everything an
# earlier run of the ticket took and never reserved for a PR; with an item, only
# that one leaves the record (ship, once it is reserved).
forget() {
  local t="${1:-}" f n item body new
  num_ok "$t" || die "usage: polish-list.sh forget <ticket> [<issue> <text…>]"
  f="$TAKEN_DIR/$t.tsv"; [ -f "$f" ] || return 0
  if [ $# -ge 3 ]; then
    n="$2"; shift 2; item=$(one_line "$*")
    grep -vxF -- "$n	$item" "$f" > "$f.t"; mv -f "$f.t" "$f"; [ -s "$f" ] || rm -f "$f"; return 0
  fi
  lock
  for n in $(cut -f1 "$f" | sort -un); do
    body=$(body_of "$n") || { echo "polish-list: #$n could not be read — its items taken by #$t stay marked" >&2; continue; }
    new="$body"
    while IFS=$'\t' read -r _ item; do
      [ -n "$item" ] || continue
      printf '%s\n' "$new" | all_items | awk -F'\t' -v x="$item" -v m="t$t" '$3 == x && $2 == m { f = 1 } END { exit !f }' \
        && new=$(printf '%s\n' "$new" | set_item "$item" " " "")
    done <<<"$(awk -F'\t' -v n="$n" '$1 == n' "$f")"
    [ "$new" = "$body" ] || printf '%s\n' "$new" | write_body "$n" || echo "polish-list: #$n could not be written" >&2
  done
  rm -f "$f"
  echo "#$t: let go of what an earlier run took"
}

reserve() { # [--ticket <t>] <issue> <pr> <text…>
  local tk="" n pr text body new cur
  [ "${1:-}" = --ticket ] && { tk="${2:-}"; shift 2; }
  n="${1:-}"; pr="${2:-}"
  shift 2 2>/dev/null || true
  num_ok "$n" && num_ok "$pr" || die "usage: polish-list.sh reserve <issue> <pr> <text…>"
  text=$(one_line "$*"); [ -n "$text" ] || die "usage: polish-list.sh reserve <issue> <pr> <text…>"
  lock
  body=$(body_of "$n") || die "#$n could not be read"
  cur=$(printf '%s\n' "$body" | all_items | awk -F'\t' -v t="$text" '$3 == t { print $1 "\t" $2; exit }')
  case "$cur" in
    " 	$pr") echo "#$n: already reserved for PR #$pr: $text"; return 0 ;;
    " 	")    ;;
    " 	t$tk") [ -n "$tk" ] || { echo "#$n: not free to reserve for PR #$pr: $text" >&2; return 1; } ;;
    *) echo "#$n: not free to reserve for PR #$pr: $text (${cur:-not on the list})" >&2; return 1 ;;
  esac
  new=$(printf '%s\n' "$body" | set_item "$text" " " "$pr") || return 1
  printf '%s\n' "$new" | write_body "$n" || die "#$n could not be written"
  echo "#$n: reserved for PR #$pr: $text"
}

# lends <issue> [<ticket>] — A LIST ITS OWN RUN HOLDS LENDS NONE (claimed or in review):
# an item taken by another change then raced the list's own run for it. The ticket
# itself is the list: it lends to itself. A FULL LIST STILL LENDS: it is never started
# as a batch of its own while other work can start (owner call 2026-10-22), so its items
# leave only by riding along, coordinator.polishListFull of them a change (items --lend).
LIST_FULL="${COORDINATOR_POLISH_LIST_FULL:-$(swarm_opt coordinator.polishListFull 8)}"
case "$LIST_FULL" in ''|0|*[!0-9]*) LIST_FULL=8 ;; esac
lends() {
  local n="${1:-}" t="${2:-}" j l free
  num_ok "$n" || die "usage: polish-list.sh lends <issue> [<ticket>]"
  [ "$n" = "$t" ] && return 0
  j=$(swarm_gh issue view "$n" --repo "$REPO_SLUG" --json body,labels 2>/dev/null) || return 2
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$j" || return 2
  for l in "${LBL_CLAIMED:-}" "${LBL_IN_REVIEW:-}"; do
    [ -n "$l" ] && jq -e --arg l "$l" '[.labels[]?.name] | index($l)' >/dev/null 2>&1 <<<"$j" \
      && { echo "#$n ships alone: its own run holds it ($l)"; return 1; }
  done
  return 0
}

# take_stalled <ticket> <states json> — why a ticket's takes should go back, or 1.
# A take must not hide an item while its run is parked, waits on the owner, or has
# stopped: no live run and the ticket untouched for polishList.takeStaleHours (24).
TAKE_STALE_H="${POLISH_TAKE_STALE_HOURS:-$(swarm_opt polishList.takeStaleHours 24)}"
case "$TAKE_STALE_H" in ''|*[!0-9]*) TAKE_STALE_H=24 ;; esac
take_stalled() {
  local t="$1" ls l at
  ls=$(jq -r --arg t "$t" '.[$t].labels[]? // empty' <<<"$2")
  for l in "$LBL_PARKED" "$LBL_OWNER_DECISION" "$LBL_NEEDS_HUMAN" "$HOLD_LABEL"; do
    [ -n "$l" ] && printf '%s\n' "$ls" | grep -qxF -- "$l" && { printf 'is waiting (%s)' "$l"; return 0; }
  done
  swarm_ticket_live "$t" && return 1
  at=$(jq -r --arg t "$t" '.[$t].updatedAt // empty' <<<"$2"); [ -n "$at" ] || return 1
  at=$(swarm_epoch "$at" 2>/dev/null); case "$at" in ''|*[!0-9]*) return 1 ;; esac
  [ $(( $(swarm_now) - at )) -ge $(( TAKE_STALE_H * 3600 )) ] || return 1
  printf 'has no live run and no change in %sh' "$TAKE_STALE_H"
}

# settle <n> <body> <states> — sets new, changed, left, done_n and said (the lines a
# sweep prints) for one list's body.
settle() {
  local n="$1" body="$2" states="$3" st mark text state why
  new="$body"; changed=0; said=""
  while IFS=$'\t' read -r st mark text; do
    [ "$st" = " " ] && [ -n "$mark" ] || continue
    state=$(jq -r --arg p "${mark#t}" '.[$p].state // empty' <<<"$states")
    case "$mark:$state" in
      t*:CLOSED|t*:MERGED)
        new=$(printf '%s\n' "$new" | set_item "$text" " " "") && changed=1 && said+="#$n: ${w}free again — #${mark#t} closed without a PR for it: $text"$'\n' ;;
      t*:OPEN)
        why=$(take_stalled "${mark#t}" "$states") || continue
        new=$(printf '%s\n' "$new" | set_item "$text" " " "") && changed=1 && said+="#$n: ${w}free again — #${mark#t} $why: $text"$'\n' ;;
      *:MERGED) new=$(printf '%s\n' "$new" | set_item "$text" x "$mark") && changed=1 && said+="#$n: ${w}ticked — PR #$mark merged: $text"$'\n' ;;
      *:CLOSED) new=$(printf '%s\n' "$new" | set_item "$text" " " "") && changed=1 && said+="#$n: ${w}free again — PR #$mark closed unmerged: $text"$'\n' ;;
    esac
  done <<<"$(printf '%s\n' "$body" | all_items)"
  left=$(printf '%s\n' "$new" | all_items | awk -F'\t' '$1 == " "' | grep -c .)
  done_n=$(printf '%s\n' "$new" | all_items | awk -F'\t' '$1 == "x"' | grep -c .)
}

# sweep — settles every reservation on every open list from its PR's state, in one
# read of the lists and one batched read of the PRs they name: the calls do not grow
# with the lists. Only a list it will write or close is read again first.
sweep() {
  local dry=0 w="" lists nums states n body new changed left done_n said
  [ "${1:-}" = --dry-run ] && { dry=1; w="would be "; }
  lock
  lists=$(swarm_gh issue list --repo "$REPO_SLUG" --state open --label "$LBL_POLISH_LIST" --limit 1000 \
            --json number,body,labels 2>/dev/null) || die "the open polish lists could not be read"
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$lists" || die "the open polish lists could not be read"
  # Every PR and every taking ticket named on any list, in one batched read.
  nums=$(jq -r '.[].body // ""' <<<"$lists" | all_items | awk -F'\t' '$1 == " " && $2 != "" { sub(/^t/, "", $2); print $2 }' | sort -un | tr '\n' ' ')
  states="{}"
  # shellcheck disable=SC2086  # a list of numbers, split on purpose
  if [ -n "${nums// /}" ]; then states=$(gh_issues_batch $nums 2>/dev/null) || states="{}"; fi
  for n in $(jq -r '.[].number' <<<"$lists"); do
    body=$(jq -r --argjson n "$n" '.[] | select(.number == $n) | .body // ""' <<<"$lists")
    settle "$n" "$body" "$states"
    [ "$changed" = 1 ] || { [ "$left" -eq 0 ] && [ "$done_n" -gt 0 ]; } || continue
    # Read again just before the write: an edit since the list read is kept.
    body=$(body_of "$n") || { echo "#$n could not be read — next pass" >&2; continue; }
    settle "$n" "$body" "$states"
    printf '%s' "$said"
    [ "$dry" = 1 ] && { [ "$left" -gt 0 ] || [ "$done_n" -eq 0 ] || echo "#$n: would be closed — every item is done"; continue; }
    if [ "$changed" = 1 ]; then printf '%s\n' "$new" | write_body "$n" || { echo "#$n could not be written" >&2; continue; }; fi
    if [ "$left" -eq 0 ] && [ "$done_n" -gt 0 ]; then
      swarm_gh issue close "$n" --repo "$REPO_SLUG" --comment "Every item on this list is fixed and merged." >/dev/null 2>&1 \
        && echo "#$n: closed — every item is done" || echo "#$n could not be closed" >&2
    fi
  done
}

case "${1:-}" in
  add)        shift; add "$@" ;;
  take)       shift; take "$@" ;;
  taken)      num_ok "${2:-}" || die "usage: polish-list.sh taken <ticket>"; cat "$TAKEN_DIR/$2.tsv" 2>/dev/null || true ;;
  reserve)    shift; reserve "$@" ;;
  forget)     shift; forget "$@" ;;
  sweep)      shift; sweep "$@" ;;
  items)      body=$(body_of "${2:?usage: polish-list.sh items <issue|-> [--lend]}") || die "#$2 could not be read"
              if [ "${3:-}" = --lend ]; then printf '%s\n' "$body" | free_items | head -n "$LIST_FULL"
              else printf '%s\n' "$body" | free_items; fi ;;
  count)      body=$(body_of "${2:?usage: polish-list.sh count <issue|-> [ticket]}") || die "#$2 could not be read"
              # With a ticket: what that ticket's own run may still work, its takes included.
              printf '%s\n' "$body" | all_items | awk -F'\t' -v m="t${3:-x}" '$1 == " " && ($2 == "" || $2 == m)' | grep -c . || true ;;
  for-screen) shift; for_screen "${1:-}" || die "the open polish lists could not be read" ;;
  lends)      shift; lends "$@" ;;
  -h|--help|"") sed -n '2,54p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *)          die "unknown command '$1'" ;;
esac
