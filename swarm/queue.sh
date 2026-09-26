#!/usr/bin/env bash
# queue.sh — ONE queue of tickets waiting for an agent, and the only way to put
# one there.
#
#   queue.sh add <ticket> [--brief FILE|-] [--budget N] [--programme P]
#                         [--front] [--reset]
#   queue.sh list [--programme P]        what is waiting, in the order it runs
#   queue.sh next [--programme P]        the ticket that runs next; nothing spawned
#   queue.sh remove <ticket>             take it out
#   queue.sh clear [--programme P]       empty it
#   queue.sh drain [--programme P] [--slots N]   spawn what fits under the cap
#
# WHY THIS EXISTS. Every ad-hoc launch used to be a shell script hand-written
# into /tmp: 58 of them on this machine on 2026-09-26, each one a copy of the
# same five lines — export a budget, release the claim, flip the label, set a
# brief, call the spawner detached. A copy cannot be fixed, ordered, or counted,
# and nothing could answer "what runs next" because the answer was "whatever
# somebody types". `add` takes those five lines as flags; `drain` runs them in
# order, under the cap.
#
# A brief is the CLAIM_EXTRA the launchers carried: free text handed to the agent
# on top of the ticket. It is copied into the queue's own directory at `add`
# time, so the caller's scratch file may vanish immediately.
#
# --reset repeats what a resume launcher did before spawning: release the claim
# and put the ticket back to ready. It fires at DRAIN time, not add time — the
# ticket keeps its claim while it waits its turn, so a peer cannot pick it up in
# the gap.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/swarm-env.sh" || exit 1

Q="$SWARM_DIR/queue.tsv"
BRIEFS="$SWARM_DIR/briefs"
mkdir -p "$BRIEFS"; [ -f "$Q" ] || : > "$Q"

# seq \t programme \t ticket \t budget \t flags \t brief \t added_at
COLS=7

die() { echo "queue: $*" >&2; exit 2; }
rows()      { awk -F'\t' 'NF>=3' "$Q" | sort -t $'\t' -k1,1n; }
rows_for()  { if [ -n "${1:-}" ]; then rows | awk -F'\t' -v p="$1" '$2==p'; else rows; fi; }
next_seq()  { local m; m=$(awk -F'\t' 'NF>=3{print $1}' "$Q" | sort -n | tail -1); printf '%s' "$(( ${m:-0} + 1 ))"; }
front_seq() { local m; m=$(awk -F'\t' 'NF>=3{print $1}' "$Q" | sort -n | head -1); printf '%s' "$(( ${m:-1} - 1 ))"; }
drop()      { local t="$1" tmp; tmp=$(mktemp); awk -F'\t' -v t="$t" '$3!=t' "$Q" > "$tmp" && mv "$tmp" "$Q"; }

cmd_add() {
  local t="" brief="" budget="$SWARM_BUDGET_USD" prog="" front=0 reset=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --brief)     brief="${2:?--brief needs a file or -}"; shift 2 ;;
      --budget)    budget="${2:?--budget needs a number}"; shift 2 ;;
      --programme) prog="${2:?--programme needs a name}"; shift 2 ;;
      --front)     front=1; shift ;;
      --reset)     reset=1; shift ;;
      -*)          die "unknown flag $1" ;;
      *)           t="$1"; shift ;;
    esac
  done
  [ -n "$t" ] || die "add needs a ticket number"
  case "$t" in *[!0-9]*) die "'$t' is not a ticket number" ;; esac

  local stored="-"
  if [ -n "$brief" ]; then
    stored="$BRIEFS/$t.md"
    if [ "$brief" = "-" ]; then cat > "$stored"
    else [ -f "$brief" ] || die "no brief file at '$brief'"; cp "$brief" "$stored"; fi
  fi

  # No programme given: ask the ticket. An unlabelled ticket queues under "" and
  # drains against the whole-machine cap rather than a programme's.
  [ -n "$prog" ] || prog=$(swarm_programme_of "$t")

  local seq
  if grep -q "$(printf '\t')$t$(printf '\t')" "$Q" 2>/dev/null; then
    # Already queued. Keep its place unless --front was asked for: re-adding a
    # ticket to change its brief must not send it to the back of the queue.
    seq=$(rows | awk -F'\t' -v t="$t" '$3==t{print $1; exit}')
    [ "$front" = 1 ] && seq=$(front_seq)
    [ "$stored" = "-" ] && stored=$(rows | awk -F'\t' -v t="$t" '$3==t{print $6; exit}')
    drop "$t"
  else
    [ "$front" = 1 ] && seq=$(front_seq) || seq=$(next_seq)
  fi

  local flags="-"; [ "$reset" = 1 ] && flags="reset"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$seq" "$prog" "$t" "$budget" "$flags" "$stored" "$(swarm_stamp)" >> "$Q"
  echo "queued #$t${prog:+ (${prog})} at position $(rows_for "$prog" | awk -F'\t' -v t="$t" '$3==t{print NR; exit}')"
}

cmd_list() {
  local prog="${1:-}" n=0
  while IFS=$'\t' read -r seq p t budget flags brief added; do
    # An empty queue is one empty line through `read`, not zero iterations, so
    # without this guard `list` printed a phantom row and never said "empty".
    [ -n "${t:-}" ] || continue
    n=$((n+1))
    printf '%2d. #%-7s %-18s $%-4s %-6s %s\n' "$n" "$t" "${p:--}" "$budget" \
      "$([ "$flags" = "-" ] && echo "" || echo "$flags")" \
      "$([ "$brief" = "-" ] && echo "no brief" || echo "brief: $(basename "$brief")")"
  done <<< "$(rows_for "$prog")"
  [ "$n" -gt 0 ] || echo "the queue is empty${prog:+ for $prog}"
}

cmd_next() { rows_for "${1:-}" | awk -F'\t' 'NR==1{print $3}'; }

cmd_drain() {
  local prog="" slots="" launched=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --programme) prog="${2:?}"; shift 2 ;;
      --slots)     slots="${2:?}"; shift 2 ;;
      *)           die "unknown argument $1" ;;
    esac
  done
  if [ -z "$slots" ]; then
    local live; live=$(swarm_live_count "$prog")
    slots=$(( SWARM_CAP - live ))
    [ "$slots" -gt 0 ] || { echo "no free slots ($live running${prog:+ on $prog}, cap $SWARM_CAP)"; return 0; }
  fi

  while IFS=$'\t' read -r seq p t budget flags brief added; do
    [ -n "${t:-}" ] || continue
    [ "$launched" -lt "$slots" ] || break
    swarm_spawnable "$t" || continue
    if [ "$flags" = "reset" ]; then
      bash "$CL" release "$t" >/dev/null 2>&1 || true
      swarm_gh issue edit "$t" --repo "$REPO_SLUG" \
        --remove-label "$LBL_IN_REVIEW" --add-label "$LBL_READY" >/dev/null 2>&1 || true
    fi
    if swarm_spawn "$t" "$([ "$brief" = "-" ] && echo "" || echo "$brief")" "$budget"; then
      drop "$t"; launched=$((launched+1)); echo "→ spawned #$t"
    else
      echo "  #$t spawn failed — left in the queue"
    fi
  done <<< "$(rows_for "$prog")"
  echo "launched $launched of $slots free slot(s)${prog:+ on $prog}"
}

case "${1:-}" in
  add)    shift; cmd_add "$@" ;;
  list)   shift; [ "${1:-}" = "--programme" ] && cmd_list "${2:-}" || cmd_list "" ;;
  next)   shift; [ "${1:-}" = "--programme" ] && cmd_next "${2:-}" || cmd_next "" ;;
  remove) shift; [ -n "${1:-}" ] || die "remove needs a ticket"; drop "$1"; echo "removed #$1" ;;
  clear)  shift
          if [ "${1:-}" = "--programme" ] && [ -n "${2:-}" ]; then
            tmp=$(mktemp); awk -F'\t' -v p="$2" '$2!=p' "$Q" > "$tmp" && mv "$tmp" "$Q"
            echo "cleared the queue for $2"
          else : > "$Q"; echo "cleared the queue"; fi ;;
  drain)  shift; cmd_drain "$@" ;;
  -h|--help|"") sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *)      die "unknown command '$1'" ;;
esac
