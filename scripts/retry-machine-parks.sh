#!/usr/bin/env bash
# retry-machine-parks.sh — a ticket parked by the machine, not by a question, is tried again
# once, fresh, on any host; the same failure twice goes to the PM.
#
#   retry-machine-parks.sh [--dry-run]
#
# A machine park is an open ticket wearing the parked status (labels.parked) whose newest
# park comment ("**Parked — <reason>.**") says "**Needs:** nothing from you", and which wears
# none of the labels a person's or the PM's park puts on (the PM-decision status, the hold,
# needs-human, the owner's decision). Seen 2026-10-24: 13 such tickets, some parked since
# 21 Oct and one a P0, on "start refused: could not create a worktree" and its kin; nothing
# ever tried them again, and the PM requeued them by hand.
#
# Once the park comment is MACHINE_PARK_RETRY_MIN (default 30) minutes old, the ticket is set
# ready, told so, and queued with --first (first at its own priority). The attempt is marked
# on the ticket itself — <!-- machine-park-retry: <reason key> --> in that comment — so every
# host reads the same count. When it parks again on the same reason (the key: the reason
# lowercased, paths, numbers and hashes taken out, so another host's path is the same failure), it is not retried: it gets the PM-decision marker
# and one comment naming both failures (<!-- machine-park-retry: reported <key> -->). A new
# reason is a new failure and gets its own one retry.
# Exit: 0 done · 1 the parked tickets could not be read.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/toolkit-env.sh" || exit 1
declare -F issue_status_set >/dev/null 2>&1 || . "$SELF_DIR/issue-status.sh" || exit 1
DRY=0; [ "${1:-}" = --dry-run ] && DRY=1
GH="${SWARM_GH:-gh}"
QUEUE="${MACHINE_PARK_QUEUE:-$SELF_DIR/coordinator-queue.sh}"
AFTER_MIN="${MACHINE_PARK_RETRY_MIN:-30}"
case "$AFTER_MIN" in ''|*[!0-9]*) AFTER_MIN=30 ;; esac
NOW="${MACHINE_PARK_NOW:-$(date -u +%s)}"
PM="${LBL_PM_DECISION:-status:pm-decision}"
[ -n "${LBL_PARKED:-}" ] || exit 0

list=$("$GH" issue list --repo "$REPO_SLUG" --label "$LBL_PARKED" --state open --limit 200 --json number,labels,comments 2>/dev/null) \
  && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$list" || { echo "machine parks: the parked tickets could not be read"; exit 1; }
people=$(printf '%s\n' "$PM" "${HOLD_LABEL:-}" "${LBL_NEEDS_HUMAN:-}" "${LBL_OWNER_DECISION:-}" | awk 'NF' | jq -R . | jq -sc .)

# One row a machine park: <n> \t <age min> \t <key> \t <reason> \t <state> \t <first reason>
# state: new (never retried for this key) · retried (retried, parked again on it) · waiting
# (retried after this park, not parked since) · reported.
rows=$(jq -r --argjson people "$people" --argjson now "$NOW" '
  def key: ascii_downcase | gsub("[^ ]*/[^ ]*"; "") | gsub("[0-9a-f]{7,40}"; "") | gsub("[0-9]+"; "") | gsub("[^a-z]+"; " ") | ltrimstr(" ") | rtrimstr(" ");
  def ts: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
  .[] | select([.labels[]?.name] | any(. as $l | $people | index($l)) | not)
  | .number as $n | [(.comments // []) | to_entries[] | .value + {i: .key}] as $cs
  | ([$cs[] | select((.body // "") | startswith("**Parked — "))] | last) as $p
  | select($p != null and (($p.body // "") | test("\\*\\*Needs:\\*\\* nothing from you")))
  | ($p.body | split("\n")[0] | sub("^\\*\\*Parked — "; "") | sub("\\.?\\*\\*$"; "")) as $why
  | ($why | key) as $k
  | ([$cs[] | select(.i > $p.i) | .body // "" | select(test("<!-- machine-park-retry: "))] | length) as $after
  | ([$cs[] | select(.i < $p.i) | .body // "" | select(contains("<!-- machine-park-retry: " + $k + " -->"))] | length) as $before
  | ([$cs[] | select(.i < $p.i) | select((.body // "") | contains("<!-- machine-park-retry: " + $k + " -->"))] | last) as $r
  | ([$cs[] | select(.i < ($r.i // -1)) | select((.body // "") | startswith("**Parked — "))] | last | .body // "" | (split("\n")[0] // "") | sub("^\\*\\*Parked — "; "") | sub("\\.?\\*\\*$"; "")) as $first
  | (if $after > 0 then "waiting" elif $before > 0 then "retried" else "new" end) as $st
  | [($n | tostring), ((($now - ($p.createdAt | ts)) / 60) | floor | tostring), $k, $why, $st, ($first // "")] | @tsv' <<<"$list" 2>/dev/null)

while IFS=$'\t' read -r n age k why st first; do
  [ -n "${n:-}" ] || continue
  case "$st" in
    waiting) continue ;;
    retried)
      if [ "$DRY" = 1 ]; then echo "would report #$n to the PM — parked twice on: $why"; continue; fi
      # The PM's marker beside the parked status, as the driver's own PM park sets it.
      issue_status_set "$n" "$LBL_PARKED" --also "$PM" >/dev/null 2>&1 || { echo "machine parks: #$n could not be marked $PM"; continue; }
      "$GH" issue comment "$n" --repo "$REPO_SLUG" --body "**The machine failed twice the same way, so this is not tried again.** It was parked on: ${first:-$why}, retried fresh once, and parked again on: $why. Nothing in the ticket is wrong that a retry would show; the PM looks at the cause (the host, its disk, its install, or the driver).
<!-- machine-park-retry: reported $k -->" >/dev/null 2>&1 || true
      echo "reported #$n to the PM — parked twice on: $why" ;;
    new)
      [ "${age:-0}" -ge "$AFTER_MIN" ] || { echo "waits: #$n — a machine park ${age} min old, retried at ${AFTER_MIN}"; continue; }
      if [ "$DRY" = 1 ]; then echo "would retry #$n — parked ${age} min ago by the machine: $why"; continue; fi
      issue_status_set "$n" "$LBL_READY" >/dev/null 2>&1 || { echo "machine parks: #$n could not be set $LBL_READY"; continue; }
      "$GH" issue comment "$n" --repo "$REPO_SLUG" --body "**Retried:** parked ${age} min ago by the machine, not by a question ($why). Back on the queue, first at its priority, for one fresh try on any host. The same failure again goes to the PM.
<!-- machine-park-retry: $k -->" >/dev/null 2>&1 || true
      bash "$QUEUE" add "$n" --first >/dev/null 2>&1 || echo "machine parks: #$n could not be queued — the next seed finds it ready"
      echo "retried #$n — parked ${age} min ago by the machine: $why" ;;
  esac
done <<< "$rows"
exit 0
