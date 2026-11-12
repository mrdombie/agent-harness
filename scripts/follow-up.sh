#!/usr/bin/env bash
# follow-up.sh — merge first, fix after: a review finding that does not hold the change
# becomes its own ticket once the change has MERGED, ready and first in the queue.
#
# SWITCHED OFF (the owner, 2026-11-02: the review's 3-voter vote replaces finding tickets).
# `file` and `settle` file nothing: a finding is dropped, and a held one is dropped when its
# PR merges. `settle` still lets an already-filed follow-up go once its parent merges.
#
#   follow-up.sh file <ticket> <pr> <findings.jsonl>
#     one JSON object a line: {id, grade, file, line, summary, reason, fix, round}
#   follow-up.sh settle [--dry-run]     the merge pass (coordinator housekeeping)
#   exit 0 every finding filed, held or dropped · 1 one or more could not be · 2 usage
#
# The owner's ruling, 2026-10-22 (release.mergeFirst, release-checks.sh): until the
# release a Critical alone blocks, and is fixed in the change, never filed. A Major is filed at labels.priority.major (P1), a Minor
# no screen's polish list took at labels.priority.minor (P3); the review step already put
# a Minor on a screen file on that screen's list. A Major found on a ticket that wears
# release.followUpLabel is never filed (the owner, 2026-10-23: 26 of 187 filed in a day were
# findings on a fix of a finding). Each ticket names the PR, the file:line and the finding.
#
# WORK IS FILED ONLY AGAINST CODE THAT HAS LANDED. A finding on a PR that has not merged
# is on that PR's fix list, not the trunk's: `file` HOLDS it — $STATE_DIR/swarm/follow-up-held/
# <pr>.jsonl, each line the finding with its ticket, PR and head — labels the PR
# release.followUpHeldLabel (default follow-ups-held) and lists the held findings in one
# comment on the PR, their data in its marker, so a pass on another host can file them.
# `settle` reads every held PR: merged, its findings are filed; closed unmerged, they are
# dropped; open, they wait. A PR whose state cannot be read is held, the cautious side.
# (23 Oct: three tickets filed from two open, red PRs were each built from develop, found
# nothing there to change, and parked.)
#
# A TICKET ALREADY FILED FOR AN OPEN PARENT WAITS FOR IT. `settle` reads the open
# fix-after-merge tickets; one whose parent (its marker's pr=, else "PR #N") is open is set
# status blocked, "waits for #PR to merge"; once the parent merges, a blocked one this pass
# blocked, or one a comment says is blocked on or waits for the parent, goes back to ready
# and back on the queue at its priority. A parent closed unmerged blocks it for the PM to close.
# A ticket being built (claimed, in review) is left alone.
#
# ONE TICKET PER PR AND FINDING. The key is "<pr> <finding id>": a ledger on this host
# ($STATE_DIR/swarm/follow-ups.tsv) and a marker in the body, searched on the forge, so a
# resumed ship or another host files nothing twice. Then status ready (issue-status.sh)
# and `coordinator-queue.sh add`, never --front or --first: a follow-up ranks by its priority, after
# every other ticket at that priority (coord_queue_ordered). --front put 33 P3 findings above every P0. Each wears release.followUpLabel (default
# fix-after-merge, created if the repo lacks it): the clean-up after the release is one list. FOLLOW_UP_QUEUE=off skips the queue (tests).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/toolkit-env.sh" || exit 1

die() { echo "follow-up: $*" >&2; exit 2; }
CMD="${1:-}"
case "$CMD" in
  file) T="${2:-}"; PR="${3:-}"; F="${4:-}"
        case "$T$PR" in ''|*[!0-9]*) die "the ticket and the pull request are numbers" ;; esac
        [ -f "$F" ] || die "no findings file at $F" ;;
  settle) DRY=0; case "${2:-}" in --dry-run) DRY=1 ;; '') ;; *) die "usage: follow-up.sh settle [--dry-run]" ;; esac ;;
  *) die "usage: follow-up.sh file <ticket> <pr> <findings.jsonl> | settle [--dry-run]" ;;
esac
GH="${FOLLOW_UP_GH:-gh}"
declare -F gh_read >/dev/null 2>&1 || . "$SELF_DIR/gh-batch.sh" || exit 1
LEDGER="${FOLLOW_UP_LEDGER:-$STATE_DIR/swarm/follow-ups.tsv}"
HELD_DIR="${FOLLOW_UP_HELD_DIR:-$STATE_DIR/swarm/follow-up-held}"
BLOCKED_LEDGER="${FOLLOW_UP_BLOCKED_LEDGER:-$STATE_DIR/swarm/follow-up-blocked.tsv}"
PARENTS="${FOLLOW_UP_PARENTS:-$STATE_DIR/swarm/follow-up-parents.tsv}"
mkdir -p "$(dirname "$LEDGER")" "$HELD_DIR" "$(dirname "$BLOCKED_LEDGER")" "$(dirname "$PARENTS")" 2>/dev/null
# Every follow-up wears one label, so the clean-up after the release is one list.
FU_LABEL=$(toolkit_cfg release.followUpLabel 2>/dev/null); FU_LABEL="${FU_LABEL:-fix-after-merge}"
HELD_LABEL=$(toolkit_cfg release.followUpHeldLabel 2>/dev/null); HELD_LABEL="${HELD_LABEL:-follow-ups-held}"
FU_VIA=""
uri() { jq -rn --arg l "$1" '$l | @uri'; }
queue() { # <args…> — the coordinator's queue, unless switched off
  [ "${FOLLOW_UP_QUEUE:-on}" != off ] || return 0
  bash "${FOLLOW_UP_QUEUE_CMD:-$SELF_DIR/coordinator-queue.sh}" "$@" >/dev/null 2>&1
}

# pr_state <pr> — "merged|open|closed<TAB>head" from the forge. Non-zero: unreadable.
pr_state() {
  SWARM_GH="$GH" gh_read "whether PR #$1 merged" api "repos/$REPO_SLUG/pulls/$1" \
    -q '[(if .merged_at then "merged" elif .state == "open" then "open" else "closed" end), (.head.sha // "?")] | @tsv'
}

# is_rebuild <pr> <ticket> — 0 when the PR was closed to rebuild fresh: the ticket's work is kept
# at refs/stale/<ticket>/…, or a comment on the PR says so. 1 not; 2 unreadable.
is_rebuild() {
  local refs said
  refs=$(SWARM_GH="$GH" gh_read "ticket #$2's stale refs" api "repos/$REPO_SLUG/git/matching-refs/stale/$2/" -q '.[].ref') || return 2
  [ -z "$refs" ] || return 0
  said=$(SWARM_GH="$GH" gh_read "PR #$1's comments" api --paginate "repos/$REPO_SLUG/issues/$1/comments?per_page=100" \
           -q '.[] | .body // "" | select(test("closed to rebuild fresh"; "i")) | "y"') || return 2
  [ -n "$said" ]
}

if [ "$CMD" = file ]; then
  echo "$(grep -c . "$F") finding(s) of PR #$PR dropped, not filed: finding tickets are switched off"
  exit 0
fi

# ---- settle: the merge pass ---------------------------------------------------
rc=0
say_do() { if [ "$DRY" -eq 1 ]; then echo "would $1"; return 1; fi; return 0; }

# The open PRs, from the copy the tick shares (gh_open_prs): an open parent costs no read.
if open_prs=$(SWARM_GH="$GH" gh_open_prs 2>/dev/null | jq -r '.[].number' 2>/dev/null) && [ -n "$open_prs" ]; then OPEN_KNOWN=1
else OPEN_KNOWN=0; open_prs=""; fi
cached() { awk -v k="$1" '$1 == k { print $2; exit }' "$PARENTS" 2>/dev/null; }

# parent_state <pr> [ticket] — merged|open|closed|rebuild. Every state but open is remembered.
# A closed PR is "rebuild" when it was closed to rebuild fresh; without a ticket that is
# not asked, and the answer is not remembered.
parent_state() {
  local s row r
  if [ "$OPEN_KNOWN" = 1 ] && printf '%s\n' "$open_prs" | grep -qx "$1"; then printf open; return 0; fi
  s=$(cached "$1"); [ -z "$s" ] || { printf '%s' "$s"; return 0; }
  row=$(pr_state "$1" 2>/dev/null) || return 1
  s="${row%%$'\t'*}"
  if [ "$s" = closed ]; then
    [ -n "${2:-}" ] || { printf closed; return 0; }
    is_rebuild "$1" "$2"; r=$?
    [ "$r" -ne 2 ] || return 1
    [ "$r" -ne 0 ] || s=rebuild
  fi
  case "$s" in merged|closed|rebuild) printf '%s %s\n' "$1" "$s" >> "$PARENTS" ;; esac
  printf '%s' "$s"
}

# rebuilt <ticket> <old pr> — the ticket's next PR: one naming it that merged after the old PR
# closed, or nothing yet. 1 unreadable. (A PR for the ticket that merged earlier is not its rebuild.)
rebuilt() {
  local n at
  n=$(cached "t$1"); [ -z "$n" ] || { printf '%s' "$n"; return 0; }
  at=$(cached "c$2")
  if [ -z "$at" ]; then
    at=$(SWARM_GH="$GH" gh_read "when PR #$2 closed" api "repos/$REPO_SLUG/pulls/$2" -q '.closed_at // empty') || return 1
    [ -n "$at" ] || return 1
    printf 'c%s %s\n' "$2" "$at" >> "$PARENTS"
  fi
  n=$(SWARM_GH="$GH" gh_read "ticket #$1's merged PRs" api -X GET search/issues \
        -f q="repo:$REPO_SLUG is:pr is:merged merged:>$at $1 in:title,body" \
        -q '[.items[] | select(.number != '"$2"')
             | select(((.title // "") + " " + (.body // "")) | test("#'"$1"'([^0-9]|$)")) | .number] | max // empty') || return 1
  [ -z "$n" ] || printf 't%s %s\n' "$1" "$n" >> "$PARENTS"
  printf '%s' "$n"
}

# 1. The held findings. Their PRs: this host's state, and every PR wearing the held label.
# ONE REQUEST READS BOTH LISTS: the PRs wearing the held label and the open follow-ups, two
# searches in one GraphQL query; past 100 follow-ups a page more asks only for them.
LISTS=$(mktemp "${TMPDIR:-/tmp}/follow-up-lists.XXXXXX") || { echo "follow-up: no temp file — nothing settled this pass"; exit 1; }
trap 'rm -f "$LISTS"' EXIT
KIDS_Q="repo:$REPO_SLUG is:issue is:open label:\"$FU_LABEL\""
KID_FIELDS='pageInfo{hasNextPage endCursor} nodes{... on Issue{number body labels(first:50){nodes{name}}}}'
lists_ok=1; forge=""; after=""; page=0
while :; do
  page=$((page + 1))
  if [ "$page" -eq 1 ]; then
    body=$(SWARM_GH="$GH" gh_read "the held PRs and the open follow-ups" api graphql \
             -f query='query($held:String!,$kids:String!){held:search(query:$held,type:ISSUE,first:100){nodes{... on PullRequest{number}}} kids:search(query:$kids,type:ISSUE,first:100){'"$KID_FIELDS"'}}' \
             -f held="repo:$REPO_SLUG is:pr label:\"$HELD_LABEL\"" -f kids="$KIDS_Q") || { lists_ok=0; break; }
    forge=$(jq -r '.data.held.nodes[]?.number // empty' <<<"$body" 2>/dev/null)
  else
    body=$(SWARM_GH="$GH" gh_read "the open follow-ups, page $page" api graphql \
             -f query='query($kids:String!,$after:String!){kids:search(query:$kids,type:ISSUE,first:100,after:$after){'"$KID_FIELDS"'}}' \
             -f kids="$KIDS_Q" -f after="$after") || { lists_ok=0; break; }
  fi
  jq -c '.data.kids.nodes[]? | select(.number != null) | {number, body, labels: [.labels.nodes[]?]}' <<<"$body" >> "$LISTS" 2>/dev/null \
    || { lists_ok=0; break; }
  jq -e '.data.kids.pageInfo.hasNextPage == true' >/dev/null 2>&1 <<<"$body" || break
  after=$(jq -r '.data.kids.pageInfo.endCursor // empty' <<<"$body")
  [ -n "$after" ] && [ "$page" -lt 20 ] || { lists_ok=0; break; }
done

held=$(cd "$HELD_DIR" 2>/dev/null && ls -- *.jsonl 2>/dev/null | sed -n 's/^\([0-9][0-9]*\)\.jsonl$/\1/p')
if [ "$lists_ok" = 1 ]; then
  held=$(printf '%s\n%s\n' "$held" "$forge")
else
  echo "the PRs labelled $HELD_LABEL could not be read; only this host's held findings are settled"; rc=1
fi
for pr in $(printf '%s\n' "$held" | grep -E '^[0-9]+$' | sort -un); do
  hf="$HELD_DIR/$pr.jsonl"
  ticket=$(jq -r '.ticket // empty' "$hf" 2>/dev/null | head -1)
  st=$(parent_state "$pr" "$ticket") || { echo "unknown — whether PR #$pr merged could not be read; its findings stay held"; rc=1; continue; }
  [ "$st" != open ] || continue
  if [ ! -s "$hf" ]; then
    # Held on another host: the data is in the PR's fix-list comment.
    data=$(SWARM_GH="$GH" gh_read "PR #$pr's held findings" api --paginate "repos/$REPO_SLUG/issues/$pr/comments?per_page=100" \
             -q '.[] | .body // "" | capture("<!-- follow-up-held: pr=[0-9]+ head=[^ ]* data=(?<d>[A-Za-z0-9+/=]*) -->").d') \
      || { echo "unknown — PR #$pr is $st and its held findings could not be read; next pass"; rc=1; continue; }
    data=$(printf '%s\n' "$data" | sed '/^$/d' | tail -1)
    [ -n "$data" ] || echo "PR #$pr is $st and wears $HELD_LABEL, but no held findings were found on it"
    [ -z "$data" ] || printf '%s' "$data" | base64 --decode > "$hf" 2>/dev/null \
      || { echo "PR #$pr's held findings could not be decoded; next pass"; rm -f "$hf"; rc=1; continue; }
    ticket=$(jq -r '.ticket // empty' "$hf" 2>/dev/null | head -1)
    if [ "$st" = closed ] && [ -n "$ticket" ]; then
      st=$(parent_state "$pr" "$ticket") || { echo "unknown — whether PR #$pr was closed to rebuild could not be read; its findings stay held"; rc=1; continue; }
    fi
  fi
  FU_VIA=""
  if [ "$st" = rebuild ]; then
    # Closed to rebuild fresh: they wait for the ticket's next PR, and file when it merges.
    FU_VIA=$(rebuilt "$ticket" "$pr") || { echo "unknown — whether ticket #$ticket's next PR merged could not be read; PR #$pr's findings stay held"; rc=1; continue; }
    [ -n "$FU_VIA" ] || continue
  fi
  case "$st" in
    merged|rebuild)
      if [ -s "$hf" ]; then
        say_do "drop $(grep -c . "$hf") held finding(s) of PR #$pr, which merged${FU_VIA:+ as its rebuild #$FU_VIA}" || continue
        echo "PR #$pr merged: its held findings are dropped, not filed — finding tickets are switched off"
      else
        say_do "take $HELD_LABEL off PR #$pr" || continue
      fi
      ;;
    closed)
      say_do "drop the $( [ -s "$hf" ] && grep -c . "$hf" || echo 0) held finding(s) of PR #$pr, which closed unmerged" || continue
      echo "PR #$pr closed without merging: its held findings are dropped, not filed" ;;
  esac
  rm -f "$hf"
  if printf '%s\n' "$forge" | grep -qx "$pr"; then
    "$GH" api "repos/$REPO_SLUG/issues/$pr/labels/$(uri "$HELD_LABEL")" -X DELETE >/dev/null 2>&1 \
      || { echo "the $HELD_LABEL label could not be taken off PR #$pr"; rc=1; }
  fi
done

# 2. The follow-ups already filed: one of an open parent waits for it.
blocked_by_us() { awk -v n="$1" -v p="$2" '$1 == n && $2 == p { f = 1 } END { exit !f }' "$BLOCKED_LEDGER" 2>/dev/null; }
said_blocked_on() { # <ticket> <pr> [parent ticket] — a comment says it is blocked on, or waits for, either
  local c re="#$2"
  [ -z "${3:-}" ] || re="#($2|$3)"
  c=$(SWARM_GH="$GH" gh_read "#$1's comments" api --paginate "repos/${ISSUE_REF:-$REPO_SLUG}/issues/$1/comments?per_page=100" \
        -q '.[] | .body // "" | select(test("(block|wait)[^\\n]{0,40}'"$re"'([^0-9]|$)"; "i")) | "y"' 2>/dev/null) || return 2
  [ -n "$c" ]
}
[ "$lists_ok" = 1 ] || { echo "the open $FU_LABEL tickets could not be read; none is blocked or unblocked this pass"; exit 1; }
kids=$(jq -r '[(.number | tostring), ([.labels[].name] | join(",")),
                ((.body // "") | ((capture("follow-up: pr=(?<p>[0-9]+)") | .p) // (capture("PR #(?<p>[0-9]+)") | .p) // "-")),
                ((.body // "") | ((capture("\\(ticket #(?<t>[0-9]+)\\)") | .t) // "-"))] | @tsv' "$LISTS") \
  || { echo "the open $FU_LABEL tickets could not be parsed; none is blocked or unblocked this pass"; exit 1; }
while IFS=$'\t' read -r n labels p pt; do
  # A follow-up that names no parent PR (filed by hand, naming a ticket) is not this pass's.
  case "$n" in ''|*[!0-9]*) continue ;; esac
  case "$p" in ''|*[!0-9]*) continue ;; esac
  case "$pt" in ''|*[!0-9]*) pt="" ;; esac
  case ",$labels," in *",$LBL_CLAIMED,"*|*",$LBL_IN_REVIEW,"*) continue ;; esac
  st=$(parent_state "$p" "$pt") || { echo "unknown — whether #$n's parent PR #$p merged could not be read"; rc=1; continue; }
  merged_as="$p"
  if [ "$st" = rebuild ]; then
    m=$(rebuilt "$pt" "$p") || { echo "unknown — whether ticket #$pt's next PR merged could not be read; #$n is left as it is"; rc=1; continue; }
    if [ -n "$m" ]; then st=merged; merged_as="$m"; fi
  fi
  is_blocked=0; case ",$labels," in *",$LBL_BLOCKED,"*) is_blocked=1 ;; esac
  case "$st" in
    open|closed|rebuild)
      [ "$is_blocked" -eq 0 ] || continue
      ! blocked_by_us "$n" "$p" || continue   # this pass blocked it; the list it came from lags
      say_do "set #$n $LBL_BLOCKED — its parent PR #$p is $st, not merged" || continue
      case "$st" in
        open) note="Blocked: waits for #$p to merge. This finding is on code in PR #$p, which has not merged, so $INTEGRATION_BRANCH has nothing to fix yet. The merge pass sets it back to ready when #$p merges." ;;
        rebuild) note="Blocked: waits for ticket #$pt's next PR to merge. PR #$p was closed to rebuild fresh, so the code this finding is on has not landed. The merge pass sets it back to ready when the rebuild merges." ;;
        *) note="Blocked: PR #$p closed without merging, so the code this finding is on never landed. Close this ticket, or rehome it — the PM's call." ;;
      esac
      issue_status_set "$n" "$LBL_BLOCKED" >/dev/null 2>&1 || { echo "#$n could not be set $LBL_BLOCKED"; rc=1; continue; }
      printf '%s %s\n' "$n" "$p" >> "$BLOCKED_LEDGER"
      SWARM_GH="$GH" gh_call issue comment "$n" --repo "$REPO_SLUG" --body "$note" >/dev/null 2>&1 || echo "#$n is blocked; its comment could not be posted"
      queue remove "$n" || true
      echo "blocked #$n — parent PR #$p is $st" ;;
    merged)
      [ "$is_blocked" -eq 1 ] || continue
      if ! blocked_by_us "$n" "$p"; then
        said_blocked_on "$n" "$p" "$pt"; r=$?
        [ "$r" -eq 2 ] && { echo "unknown — #$n's comments could not be read; it stays blocked"; rc=1; continue; }
        [ "$r" -eq 0 ] || continue   # blocked on something else: not this pass's to lift
      fi
      say_do "set #$n back to $LBL_READY — its parent PR #$merged_as merged" || continue
      issue_status_set "$n" "$LBL_READY" >/dev/null 2>&1 || { echo "#$n could not be set $LBL_READY"; rc=1; continue; }
      [ -f "$BLOCKED_LEDGER" ] && { awk -v n="$n" -v p="$p" '!($1 == n && $2 == p)' "$BLOCKED_LEDGER" > "$BLOCKED_LEDGER.t" && mv "$BLOCKED_LEDGER.t" "$BLOCKED_LEDGER"; }
      SWARM_GH="$GH" gh_call issue comment "$n" --repo "$REPO_SLUG" \
        --body "Unblocked: #$merged_as merged to $INTEGRATION_BRANCH, so the code this finding is on has landed. Ready to build as its own small change." >/dev/null 2>&1 \
        || echo "#$n is ready; its comment could not be posted"
      queue add "$n" --note "follow-up of PR #$p, merged as #$merged_as" || true
      echo "unblocked #$n — #$merged_as merged" ;;
  esac
done <<<"$kids"
exit "$rc"
