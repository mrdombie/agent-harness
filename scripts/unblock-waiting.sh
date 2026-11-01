#!/usr/bin/env bash
# unblock-waiting.sh — a ticket waiting on others goes back to ready the moment every one
# of them has landed. The one unblocker: coordinator housekeeping runs it every pass, and
# repair-watch's unblock section calls it only when no coordinator is live, so the two never
# both run.
#
#   unblock-waiting.sh [--dry-run]
#
# A waiting ticket is open and wears the blocked or the gated status (labels.blocked,
# labels.gated). Its blockers are the #numbers after "Blocked until" on the newest line
# saying so, in its comments or else its body (a split part's body says it; the PM writes
# "**PM answer:** Yes, it waits. Blocked until #14268, #14269 … merge."). A blocker has
# landed when it is closed as completed, or is a merged pull request; one closed as not
# planned has not, with one exception: a blocker CLOSED AS SPLIT stands for its parts, read
# from its "Split … into #…" comment, and is landed only once every part is (a part split
# again is read the same way, three levels deep). One closed unmerged for any other reason
# stays a blocker, and the waiting ticket gets one note for the PM. With every blocker
# landed the ticket is set ready, told so, and put on the coordinator's queue with --first,
# so it ranks first at its own priority. (Seen: #13581 was requeued when its blocker closed
# as split into four parts, none merged, and it parked asking.)
#
# Seen 2026-10-24: three parts of split tickets parked within 3 minutes asking "should I
# wait for part N?", and nothing in the coordinator would ever have released them.
#
# A WAIT NO PASS CAN EVER RELEASE IS SAID, NEVER HELD IN SILENCE (2026-10-29: the Holly 2.0
# chain stood ~12 hours; #16130 waited on split #16140, whose last part waited on #16130).
# Each is printed, noted once on the ticket where it names one, and sent to the PM's channel
# (coordinator-notify.sh, agent class): tickets that wait on each other, through split parts
# too, are a deadlock; a blocker closed unmerged and not as split (a pull request closed
# without merging included); a blocked ticket no line names a wait for. A blocked ticket
# also reads the older "Blocked on #N" and "Blocked by #N" forms; a gated one never does,
# since PM prose there names tickets it is not waiting on.
#
#   unblock-waiting.sh --repoint <A> <part…> [--dry-run]
# The split step's call: every waiting ticket whose newest wait names #A gets a new newest
# line naming A's parts in its place, so the wait reads as what it is.
# Exit: 0 done · 1 a read failed (nothing is released on a read that failed).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/toolkit-env.sh" || exit 1
declare -F gh_issues_batch >/dev/null 2>&1 || . "$SELF_DIR/gh-batch.sh" || exit 1
declare -F issue_status_set >/dev/null 2>&1 || . "$SELF_DIR/issue-status.sh" || exit 1
DRY=0; REPOINT=""; RPARTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --repoint) REPOINT="${2:?--repoint needs the split ticket}"; shift ;;
    *[!0-9]*|'') echo "unblock: unknown argument '$1'" >&2; exit 2 ;;
    *) RPARTS="${RPARTS:+$RPARTS }$1" ;;
  esac
  shift
done
GH="${SWARM_GH:-gh}"
QUEUE="${UNBLOCK_QUEUE:-$SELF_DIR/coordinator-queue.sh}"
NOTIFY="${UNBLOCK_NOTIFY:-$SELF_DIR/coordinator-notify.sh}"
tell_pm() { # <key> <line> — the PM's channel; once a key, and never on a dry run
  [ "$DRY" = 1 ] || bash "$NOTIFY" --class agent "$1" "$2" >/dev/null 2>&1 || true
}
note_once() { # <n> <marker> <body> — one comment on the ticket, looked for first
  local said
  [ "$DRY" = 1 ] && return 0
  said=$("$GH" issue view "$1" --repo "$REPO_SLUG" --json comments -q '.comments[].body' 2>/dev/null)
  grep -qF "<!-- unblock: $2 -->" <<<"$said" && return 0
  "$GH" issue comment "$1" --repo "$REPO_SLUG" --body "$3
<!-- unblock: $2 -->" >/dev/null 2>&1 || true
}

# Every ticket a line names: "#A–#B", "#A-#B" and "#A–B" are each number between (an en dash read as
# two ends released #14315 with two blockers open, 2026-10-24); a range over 50 is read as its ends.
TICKETS_JQ='def tickets: [scan("#([0-9]+)(?:[ ]*[–—-][ ]*#?([0-9]+))?")
    | (.[0] | tonumber) as $a | (if .[1] == null then $a else (.[1] | tonumber) end) as $z
    | if $z > $a and $z - $a <= 50 then range($a; $z + 1) else $a, $z end | tostring] | unique;'
# The waiting tickets, each as "<n>\t<blockers…>" from its newest wait line: "Blocked until",
# and on a blocked ticket "Blocked on #N" / "Blocked by #N" too. A blocked ticket naming no
# wait comes back as "<n>\t?", unless a line says it "waits for #N" (follow-up.sh's to lift).
read_waiting() { # <label> <1 when it is the blocked label>
  "$GH" issue list --repo "$REPO_SLUG" --label "$1" --state open --limit 200 --json number,body,comments 2>/dev/null \
  | jq -r --argjson bl "${2:-0}" "$TICKETS_JQ"'
      (if $bl == 1 then "blocked until|blocked (on|by) *#[0-9]" else "blocked until" end) as $re
      | .[]? | .number as $n
      | [(.body // ""), ((.comments // [])[]? | .body // "")] as $texts
      | ($texts | map(split("\n")[] | select(test($re; "i"))) | last // "") as $l
      | ($l | sub("(?i).*blocked (until|on|by)"; "") | tickets | map(select(. != ($n | tostring))) | join(" ")) as $b
      | if $b != "" then "\($n)\t\($b)"
        elif $bl == 1 and ($texts | map(test("waits for #[0-9]"; "i")) | any | not) then "\($n)\t?"
        else empty end'
}
held=""
for lab in "${LBL_BLOCKED:-}" "${LBL_GATED:-}"; do
  [ -n "$lab" ] || continue
  out=$(read_waiting "$lab" "$([ "$lab" = "${LBL_BLOCKED:-}" ] && echo 1 || echo 0)") || { echo "unblock: the $lab tickets could not be read"; exit 1; }
  held="$held$out"$'\n'
done
held=$(printf '%s\n' "$held" | awk -F'\t' 'NF == 2 && !seen[$1]++')
[ -n "$held" ] || exit 0

# --repoint: the split step's call, before any state is read.
if [ -n "$REPOINT" ]; then
  [ -n "$RPARTS" ] || { echo "unblock: --repoint $REPOINT names no parts" >&2; exit 2; }
  while IFS=$'\t' read -r n bl; do
    case " $bl " in *" $REPOINT "*) ;; *) continue ;; esac
    new=$(printf '%s\n' $bl | awk -v a="$REPOINT" -v p="$RPARTS" '$0 == a { n = split(p, q, " "); for (i = 1; i <= n; i++) print q[i]; next } { print }' \
          | awk '!s[$0]++' | sed 's/^/#/' | paste -sd, - | sed 's/,/, /g')
    if [ "$DRY" = 1 ]; then echo "would repoint #$n — #$REPOINT is now #${RPARTS// / #}"; continue; fi
    "$GH" issue comment "$n" --repo "$REPO_SLUG" --body "Blocked until $new merge: #$REPOINT was split into #${RPARTS// /, #} and closed without merging, so this ticket now waits on its parts." >/dev/null 2>&1 \
      || { echo "unblock: #$n could not be re-pointed — the unblocker still reads #$REPOINT's parts"; continue; }
    echo "repointed #$n — #$REPOINT is now #${RPARTS// / #}"
  done <<< "$held"
  exit 0
fi

while IFS=$'\t' read -r n bl; do
  [ "$bl" = "?" ] || continue
  echo "waits: #$n — blocked, but no \"Blocked until #…\" line names what on (the PM decides)"
  tell_pm "wait-unnamed:$n" "#$n is blocked, but no \"Blocked until #…\" line names what it waits on, so nothing will ever release it."
done <<< "$held"
held=$(printf '%s\n' "$held" | awk -F'\t' '$2 != "?"')
[ -n "$held" ] || exit 0
all=$(printf '%s\n' "$held" | cut -f2 | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -un)
# shellcheck disable=SC2086  # a list of numbers, split on purpose
states=$(gh_issues_batch $all 2>/dev/null) && jq -e 'type == "object"' >/dev/null 2>&1 <<<"$states" \
  || { echo "unblock: the blockers' states could not be read"; exit 1; }
# A blocker closed as not planned: its split comment's parts, or nothing. Read once each.
SPLITS=""   # <n> \t <parts…>  ("-" when it was not a split)
parts_of() { # <n>
  local hit c
  hit=$(awk -F'\t' -v n="$1" '$1 == n { print $2; f = 1; exit } END { exit !f }' <<<"$SPLITS") && { [ "$hit" = - ] || printf '%s' "$hit"; return 0; }
  c=$("$GH" issue view "$1" --repo "$REPO_SLUG" --json comments 2>/dev/null) || return 1
  hit=$(jq -r "$TICKETS_JQ"'[.comments[]?.body // "" | split("\n")[] | select(test("split[^#]* into #"; "i"))] | last // ""
               | sub("(?i)^.*?split[^#]* into"; "") | tickets | join(" ")' <<<"$c" 2>/dev/null)
  SPLITS="$SPLITS$1"$'\t'"${hit:--}"$'\n'
  printf '%s' "$hit"
}
# landed <n> [depth] — 0 landed · 1 still open · 2 closed unmerged, not as split (the PM's).
# Each open ticket it found (a split's open parts in its place) is added to LEAVES.
LEAVES=""
landed() {
  local b="$1" d="${2:-0}" st rs parts p r worst=0 ps
  st=$(jq -r --arg b "$b" '.[$b].state // ""' <<<"$states"); rs=$(jq -r --arg b "$b" '.[$b].stateReason // ""' <<<"$states")
  if [ -z "$st" ]; then
    ps=$(gh_issues_batch "$b" 2>/dev/null) && states=$(jq -c --argjson p "$ps" '. + $p' <<<"$states")
    st=$(jq -r --arg b "$b" '.[$b].state // ""' <<<"$states"); rs=$(jq -r --arg b "$b" '.[$b].stateReason // ""' <<<"$states")
  fi
  case "$st:$rs" in
    MERGED:*) return 0 ;;
    CLOSED:NOT_PLANNED)
      [ "$d" -lt 3 ] || return 1
      parts=$(parts_of "$b") || return 1
      [ -n "$parts" ] || return 2
      for p in $parts; do
        landed "$p" $((d + 1)); r=$?
        [ "$r" -eq 0 ] || { [ "$r" -gt "$worst" ] && worst=$r; [ "$worst" -lt 1 ] && worst=1; }
      done
      return "$worst" ;;
    CLOSED:)   # no reason: a pull request, read as merged only if it was (an issue always has one)
      [ "$("$GH" api "repos/$REPO_SLUG/pulls/$b" -q '.merged_at // "unmerged"' 2>/dev/null)" = unmerged ] && return 2
      return 0 ;;
    CLOSED:*) return 0 ;;
    *) LEAVES="$LEAVES $b"; return 1 ;;
  esac
}
EDGES=""   # <waiter> <open ticket it waits on>, split parts in their parent's place
while IFS=$'\t' read -r n bl; do
  [ -n "${n:-}" ] || continue
  open=""; unmerged=""
  for b in $bl; do
    LEAVES=""; landed "$b"; r=$?
    for l in $LEAVES; do EDGES="$EDGES$n $l"$'\n'; done
    case $r in
      0) ;;
      2) unmerged="$unmerged #$b" ;;
      *) parts=$(printf '%s\n' $LEAVES | grep -vx "$b" | sort -un | sed 's/^/#/' | paste -sd' ' -)
         if [ -n "$parts" ]; then
           [ "${parts#* }" = "$parts" ] && w="part" || w="parts"
           open="$open #$b (its $w $parts)"
         else open="$open #$b"; fi ;;
    esac
  done
  if [ -n "$unmerged" ]; then
    echo "waits: #$n — closed unmerged, not as split:$unmerged (the PM decides)"
    # One note for the PM, not one a pass: the marker is looked for on the ticket first.
    note_once "$n" "unmerged$unmerged" "**Still waiting:**$unmerged closed without merging and not as a split, so this ticket stays waiting. The PM decides whether it still needs it."
    tell_pm "wait-unmerged:$n:$(printf '%s\n' $unmerged | tr -d '#' | paste -sd, -)" "#$n waits on$unmerged, closed without merging and not as a split, so nothing will ever release it."
    continue
  fi
  if [ -n "$open" ]; then echo "waits: #$n — still open:$open"; continue; fi
  if [ "$DRY" = 1 ]; then echo "would unblock #$n — every blocker landed (#${bl// /, #})"; continue; fi
  issue_status_set "$n" "$LBL_READY" >/dev/null 2>&1 || { echo "unblock: #$n could not be set $LBL_READY"; continue; }
  "$GH" issue comment "$n" --repo "$REPO_SLUG" --body "**Unblocked:** every ticket it waited for has landed (#${bl// /, #}). Back on the queue, first at its priority." >/dev/null 2>&1 || true
  bash "$QUEUE" add "$n" --first >/dev/null 2>&1 || echo "unblock: #$n could not be queued — the next seed finds it ready"
  echo "unblocked #$n"
done <<< "$held"

# Deadlocks: waiting tickets that reach themselves through what they wait on. Each group
# (a strongly connected set) is said once, on every ticket in it.
if [ -n "$EDGES" ]; then
  waiters=$(printf '%s\n' "$held" | cut -f1)
  groups=$(printf '%s' "$EDGES" | awk -v W="$(printf '%s ' $waiters)" '
    BEGIN { n = split(W, w, " "); for (i = 1; i <= n; i++) isw[w[i]] = 1 }
    NF == 2 && isw[$1] && isw[$2] { e[$1] = e[$1] " " $2 }
    function reach(s,   q, h, t, x, k, m, i) {
      delete seen; h = 1; t = 0; m = split(e[s], k, " "); for (i = 1; i <= m; i++) q[++t] = k[i]
      while (h <= t) { x = q[h++]; if (x in seen) continue; seen[x] = 1; m = split(e[x], k, " "); for (i = 1; i <= m; i++) q[++t] = k[i] }
    }
    END {
      for (a in isw) { reach(a); for (b in seen) r[a, b] = 1 }
      for (a in isw) if (r[a, a]) {
        g = ""; for (b in isw) if (r[a, b] && r[b, a]) g = g " " b
        print g
      }
    }' | while read -r g; do printf '%s\n' $g | sort -n | paste -sd' ' -; done | sort -u)
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    tags="#${g// / #}"
    echo "deadlock: $tags — each waits on another, so none can start (the PM breaks it)"
    for m in $g; do
      note_once "$m" "deadlock $tags" "**Deadlocked:** $tags each wait on another (split parts counted as their parent), so none can start and no pass will ever release them. The PM breaks it: re-point or drop one of the waits."
    done
    tell_pm "wait-deadlock:${g// /,}" "Deadlock: $tags each wait on another, so none can start. Re-point or drop one of the waits."
  done <<< "$groups"
fi
exit 0
