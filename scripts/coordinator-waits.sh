#!/usr/bin/env bash
# coordinator-waits.sh — a run that ended waiting on a human is not re-picked
# until that wait changes. Sourced by coordinator-tick.sh after coordinator-env.sh.
#
# Measured 2026-10-16, ~35h: 96 of 139 runs went to 32 tickets run more than once
# (one eight times); many ended "waiting on your sign-off" or "no question tool"
# and were picked up again the next tick to say the same thing.
#
#   waits.tsv   <ticket> \t <run-id> \t <ended ISO> \t <reason> \t <snapshot>
#
# The snapshot is taken in the tick that sees the run end: the ticket's labels
# (less the claim lifecycle ones reconcile-claims.sh flips by itself) and its
# open PR's head, labels, red and clash state. The wait is over when the snapshot
# differs, or when a comment newer than the run's end is on the ticket or its PR
# (less the ones the kit itself posts). Then the record goes and the ticket is
# spawnable again. A later run of the ticket replaces the record either way.

COORD_WAITS="$COORD_DIR/waits.tsv"
# Bodies the kit posts by itself after a run ends: none of them is a human answering.
COORD_WAIT_MACHINE='^(\*\*(Claim released|Shipped)|Left the merge lane)'

# coord_wait_reason <log> — 0, printing why, when the run's last word says it stopped for a human.
# The status table's "Waiting for" row decides when there is one; otherwise only a
# phrase that says this run itself stopped to ask.
coord_wait_reason() {
  local txt row v ap="[’']"
  txt=$(grep '"type":"result"' "$1" 2>/dev/null | tail -1 | jq -r '.result // empty' 2>/dev/null)
  [ -n "$txt" ] || return 1
  row=$(printf '%s\n' "$txt" | grep -iE '^\|[[:space:]]*\**[[:space:]]*waiting (for|on)[[:space:]]*\**[[:space:]]*\|' | head -1)
  if [ -n "$row" ]; then
    v=$(printf '%s' "$row" | awk -F'|' '{print $3}' | sed 's/\*\*//g;s/^[[:space:]]*//;s/[[:space:]]*$//')
    # A person named: "approval-line fix to merge" names none, "no sign-off from you" names one to say no.
    printf '%s' "$v" | grep -qiE "(^|[^[:alnum:]])(you|your|dom|dom${ap}s|owner)([^[:alnum:]]|$)" || return 1
    printf '%s' "$v" | grep -qiE "(no|without) [a-z -]{0,20}(from|by) (you|dom)|without (you|your|dom)|nothing from (you|dom)" && return 1
    printf 'waiting for: %s' "$v" | tr '\t\n' '  ' | cut -c1-160; return 0
  fi
  v=$(printf '%s\n' "$txt" | grep -oiE "no question tool|question tool (is not|isn${ap}t|doesn${ap}t|does not|wasn${ap}t) (available|exist)|no way to ask|(can${ap}t|cannot|couldn${ap}t|could not) put (the|this|that|a) (choice|question)|stopped until you (reply|answer|decide|pick|sign)|until you (reply|answer)|when you (reply|answer)|waiting on your (sign-?off|pick|answer|approval|reply|call|decision)" | head -1)
  [ -n "$v" ] || return 1
  printf 'said: %s' "$v" | cut -c1-160
}

coord_wait_clear() { # <ticket>
  [ -f "$COORD_WAITS" ] || return 0
  awk -F'\t' -v t="$1" '$1 != t' "$COORD_WAITS" > "$COORD_WAITS.$$" && mv -f "$COORD_WAITS.$$" "$COORD_WAITS"
}
coord_wait_note() { # <ticket> <run-id> <ended ISO> <reason> — snapshot left for coord_wait_snap_pending
  coord_wait_clear "$1"
  printf '%s\t%s\t%s\t%s\t\n' "$1" "$2" "$3" "$(printf '%s' "$4" | tr '\t\n' '  ')" >> "$COORD_WAITS"
}
coord_wait_record() { # <ticket> — its line, or nothing
  [ -f "$COORD_WAITS" ] || return 1
  awk -F'\t' -v t="$1" '$1 == t { l = $0 } END { if (l == "") exit 1; print l }' "$COORD_WAITS"
}

# The ticket's state a human would move: labels less the claim lifecycle, and its PR.
# Its PR is on <prefix><ticket>… or on <ticket>/… alone: a run names its branch either way.
coord_wait_snapshot() { # <ticket> <labels, comma-joined> — uses $PRS
  local t="$1" labs pr
  labs=$(printf '%s' "$2" | tr ',' '\n' \
    | awk -v a="${LBL_CLAIMED:-}" -v b="${LBL_READY:-}" -v c="${LBL_IN_REVIEW:-}" -v d="${LBL_PARTIAL:-}" \
        'NF && $0 != a && $0 != b && $0 != c && $0 != d' | sort -u | paste -sd, -)
  pr=$(printf '%s' "${PRS:-[]}" | jq -r --arg pre "$BRANCH_PREFIX" --arg t "$t" --argjson nb "$(release_nonblocking_json 2>/dev/null || echo "[]")" "$BRANCH_TICKET_JQ$RELEASE_NB_JQ"'
    [ .[] | select(.headRefName | branch_is_ticket($pre; $t)) ] | first // empty
    | ((.statusCheckRollup // []) | newest_runs | map(select(release_nb($nb) | not))) as $c
    | ($c | map(select((.status // "COMPLETED") != "COMPLETED")) | length) as $p
    | ($c | map(select((.conclusion // .state // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))) | length) as $f
    | "pr=\(.number)@\(.headRefOid) prlabels=\([.labels[]?.name] | sort | join(",")) red=\(if $p == 0 and $f > 0 then 1 else 0 end) clash=\(if .mergeStateStatus == "DIRTY" then 1 else 0 end)"' 2>/dev/null)
  printf 'labels=%s %s' "$labs" "${pr:-pr=none}"
}

# The tick's batched read ($ISSUES, scripts/gh-batch.sh's shape) answers first; a
# ticket it does not hold is asked about on its own.
coord_issue_cached() { # <ticket> — 0 when $ISSUES holds it
  [ -n "${ISSUES:-}" ] && jq -e --arg n "$1" 'has($n)' >/dev/null 2>&1 <<<"$ISSUES"
}
coord_issue_meta() { # <ticket> — "<STATE> <label,label…>", or nothing when unreadable
  if coord_issue_cached "$1"; then
    jq -r --arg n "$1" '.[$n] | .state + " " + (.labels | join(","))' <<<"$ISSUES"; return
  fi
  swarm_gh issue view "$1" --repo "$REPO_SLUG" --json state,labels \
    -q '.state+" "+([.labels[].name]|join(","))' 2>/dev/null
}
coord_issue_labels() { # <ticket> — comma-joined, or fails when it could not be read
  if coord_issue_cached "$1"; then jq -r --arg n "$1" '.[$n].labels | join(",")' <<<"$ISSUES"; return; fi
  local j; j=$(swarm_gh issue view "$1" --repo "$REPO_SLUG" --json state,labels 2>/dev/null) || return 1
  [ -n "$j" ] || return 1
  printf '%s' "$j" | jq -r '[.labels[]?.name] | join(",")'
}

# Every record still without a snapshot gets one; run once $PRS is read.
coord_wait_snap_pending() {
  [ -s "$COORD_WAITS" ] || return 0
  local t rid at why snap labs out=""
  while IFS=$'\t' read -r t rid at why snap; do
    [ -n "${t:-}" ] || continue
    if [ -z "$snap" ] && labs=$(coord_issue_labels "$t"); then snap=$(coord_wait_snapshot "$t" "$labs"); fi
    out="$out$t"$'\t'"$rid"$'\t'"$at"$'\t'"$why"$'\t'"$snap"$'\n'
  done < "$COORD_WAITS"
  printf '%s' "$out" > "$COORD_WAITS.$$" && mv -f "$COORD_WAITS.$$" "$COORD_WAITS"
}

# Comments on the ticket and its PR newer than <ISO>, less the kit's own.
# A ticket or PR the tick's batched reads show untouched since <ISO> has no new
# comment to read, so it is not asked for its comments: once per wait per tick
# otherwise, on the token every builder shares.
coord_wait_new_comments() { # <ticket> <ISO>
  local t="$1" at="$2" n=0 m pr up
  up=""; coord_issue_cached "$t" && up=$(jq -r --arg n "$t" '.[$n].updatedAt // empty' <<<"$ISSUES")
  if [ -z "$up" ] || [ -z "$at" ] || [[ "$up" > "$at" ]]; then
    n=$(swarm_gh issue view "$t" --repo "$REPO_SLUG" --json comments 2>/dev/null \
        | jq --arg at "$at" --arg mach "$COORD_WAIT_MACHINE" \
            '[.comments[]? | select(.createdAt > $at) | select((.body // "") | test($mach) | not)] | length' 2>/dev/null)
  fi
  pr=$(printf '%s' "${PRS:-[]}" | jq -r --arg pre "$BRANCH_PREFIX" --arg t "$t" --arg at "$at" \
        "$BRANCH_TICKET_JQ"'[.[] | select(.headRefName | branch_is_ticket($pre; $t))
          | select((.updatedAt // "") == "" or $at == "" or .updatedAt > $at) | .number] | first // empty' 2>/dev/null)
  m=0
  if [ -n "$pr" ]; then
    m=$(swarm_gh pr view "$pr" --repo "$REPO_SLUG" --json comments 2>/dev/null \
        | jq --arg at "$at" --arg mach "$COORD_WAIT_MACHINE" \
            '[.comments[]? | select(.createdAt > $at) | select((.body // "") | test($mach) | not)] | length' 2>/dev/null)
  fi
  printf '%s' $(( ${n:-0} + ${m:-0} ))
}

# coord_wait_holds <ticket> <labels, comma-joined> — 0, printing why, while the
# ticket waits on a human and nothing has moved; 1 (record gone) once something has.
coord_wait_holds() {
  local t="$1" rec rid at why snap now c
  rec=$(coord_wait_record "$t") || return 1
  IFS=$'\t' read -r _ rid at why snap <<< "$rec"
  now=$(coord_wait_snapshot "$t" "$2")
  if [ -z "$snap" ]; then
    # Seen first here: this reading is the baseline.
    coord_wait_note "$t" "$rid" "$at" "$why"
    awk -F'\t' -v OFS='\t' -v t="$t" -v s="$now" '$1 == t { $5 = s } 1' "$COORD_WAITS" > "$COORD_WAITS.$$" && mv -f "$COORD_WAITS.$$" "$COORD_WAITS"
    snap="$now"
  fi
  if [ "$now" != "$snap" ]; then
    coord_wait_clear "$t"
    swarm_log "$COORD_LOG" "wait over: #$t — changed since run $rid ended: [$snap] -> [$now]"
    return 1
  fi
  c=$(coord_wait_new_comments "$t" "$at")
  if [ "${c:-0}" -gt 0 ] 2>/dev/null; then
    coord_wait_clear "$t"
    swarm_log "$COORD_LOG" "wait over: #$t — $c new comment(s) since run $rid ended"
    return 1
  fi
  printf 'waiting on a human since run %s ended %s (%s) — nothing has changed: a label, a commit, a comment or a red check releases it' "$rid" "$at" "$why"
}
