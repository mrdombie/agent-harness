#!/usr/bin/env bash
# coordinator-compare.sh — the shadow tick's log beside the real loop's run
# records for one window, and every place the two disagree.
#
#   coordinator-compare.sh                         the last 12 hours
#   coordinator-compare.sh --since <ISO> [--until <ISO>] [--grace-min 15]
#
# Agreement, either way round, within the grace:
#   the shadow would have started #n  ↔  the loop started #n
#   the loop started #n               ↔  the shadow started it, or named it next
# Everything else is listed. The judgements the shadow would have asked for are
# listed too: the loop keeps no structured record of its own to hold them against.
# Exit 0 with no disagreements, 1 with any, 2 on a usage error.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/coordinator-env.sh" || exit 1

NOW=$(swarm_now); SINCE=$(( NOW - 12 * 3600 )); UNTIL=$NOW; GRACE=15
while [ $# -gt 0 ]; do
  case "$1" in
    --since)     SINCE=$(swarm_epoch "${2:?--since needs an ISO time}") || exit 2; shift 2 ;;
    --until)     UNTIL=$(swarm_epoch "${2:?--until needs an ISO time}") || exit 2; shift 2 ;;
    --grace-min) GRACE="${2:?}"; shift 2 ;;
    -h|--help)   sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           echo "compare: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
G=$(( GRACE * 60 ))
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# epoch \t ticket — what the shadow would have started
awk -F'\t' '$2=="would" && $3=="spawn"{print $1 "\t" $4}' "$COORD_ACTIONS" 2>/dev/null \
  | while IFS=$'\t' read -r at n; do e=$(swarm_epoch "$at"); [ "$e" -ge "$SINCE" ] && [ "$e" -le "$UNTIL" ] && printf '%s\t%s\n' "$e" "$n"; done \
  > "$TMP/shadow"
# epoch \t next-ticket — what each shadow tick would have taken next
awk -F'\t' '$2=="plan"{n=$5; sub(/.*next=/,"",n); if (n!="") print $1 "\t" n}' "$COORD_ACTIONS" 2>/dev/null \
  | while IFS=$'\t' read -r at n; do printf '%s\t%s\n' "$(swarm_epoch "$at")" "$n"; done > "$TMP/next"
# epoch \t ticket \t run id — what the real loop started
for j in "$RUNS_DIR"/claim-*.json; do
  [ -f "$j" ] || continue
  jq -r '[(.started_at // ""), (.ticket // ""), (.run_id // "")] | @tsv' "$j" 2>/dev/null
done | while IFS=$'\t' read -r at n rid; do
  [ -n "$at" ] && [ -n "$n" ] || continue
  e=$(swarm_epoch "$at") || continue
  [ "$e" -ge "$SINCE" ] && [ "$e" -le "$UNTIL" ] && printf '%s\t%s\t%s\n' "$e" "$n" "$rid"
done | sort -n > "$TMP/real"

near() { # <file> <epoch> <ticket> — a row for this ticket within the grace
  awk -F'\t' -v e="$2" -v n="$3" -v g="$G" '$2==n && $1>=e-g && $1<=e+g{f=1} END{exit !f}' "$1"
}
named_next() { # <epoch> <ticket> — the last shadow tick before e named it next
  awk -F'\t' -v e="$1" -v g="$G" '$1<=e && $1>=e-g{last=$2} END{print last}' "$TMP/next" | grep -qx -- "$2"
}

DIS=0
echo "## Shadow vs the loop — $(swarm_iso "$SINCE") to $(swarm_iso "$UNTIL") (grace ${GRACE} min)"
echo
printf '| Measure | Count |\n|---|---|\n'
printf '| Shadow would have started | %s |\n' "$(grep -c . "$TMP/shadow")"
printf '| The loop started | %s |\n' "$(grep -c . "$TMP/real")"
printf '| Shadow ticks | %s |\n' "$(awk -F'\t' '$2=="plan"{print $1}' "$COORD_ACTIONS" 2>/dev/null \
  | while read -r at; do e=$(swarm_epoch "$at"); [ "$e" -ge "$SINCE" ] && [ "$e" -le "$UNTIL" ] && echo "$e"; done | grep -c .)"
echo

echo "### Shadow would have started; the loop did not"
echo
printf '| When | Ticket |\n|---|---|\n' > "$TMP/a"
while IFS=$'\t' read -r e n; do
  [ -n "${n:-}" ] || continue
  near "$TMP/real" "$e" "$n" && continue
  printf '| %s | #%s |\n' "$(swarm_iso "$e")" "$n" >> "$TMP/a"; DIS=$((DIS+1))
done < "$TMP/shadow"
if [ "$(grep -c . "$TMP/a")" -gt 2 ]; then cat "$TMP/a"; else echo "None."; fi
echo

echo "### The loop started; the shadow would not have"
echo
printf '| When | Ticket | Run |\n|---|---|---|\n' > "$TMP/b"
while IFS=$'\t' read -r e n rid; do
  [ -n "${n:-}" ] || continue
  near "$TMP/shadow" "$e" "$n" && continue
  named_next "$e" "$n" && continue
  printf '| %s | #%s | %s |\n' "$(swarm_iso "$e")" "$n" "$rid" >> "$TMP/b"; DIS=$((DIS+1))
done < "$TMP/real"
if [ "$(grep -c . "$TMP/b")" -gt 2 ]; then cat "$TMP/b"; else echo "None."; fi
echo

echo "### Judgements the shadow would have asked for"
echo
awk -F'\t' '$2=="would" && $3=="judge"' "$COORD_ACTIONS" 2>/dev/null \
  | while IFS=$'\t' read -r at _ _ id detail; do
      e=$(swarm_epoch "$at"); [ "$e" -ge "$SINCE" ] && [ "$e" -le "$UNTIL" ] || continue
      printf '| %s | %s | %s |\n' "$at" "$id" "$detail"
    done > "$TMP/j"
if [ -s "$TMP/j" ]; then printf '| When | Event | What |\n|---|---|---|\n'; cat "$TMP/j"; else echo "None."; fi
echo
echo "Disagreements: $DIS"
[ "$DIS" -eq 0 ]
