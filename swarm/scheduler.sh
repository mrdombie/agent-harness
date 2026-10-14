#!/usr/bin/env bash
# scheduler.sh — keep every programme's slots full without a session watching.
#
#   scheduler.sh                     one pass over every programme with work
#   scheduler.sh --programme widgets  one programme
#   scheduler.sh --explain            say what it would do, spawn nothing
#
# Run it on a timer (swarm/install.sh sets that up). One pass: work out how many
# agents each programme may still have, top its queue up from its ready tickets,
# and drain the queue to the cap.
#
# THE CAP IS PER PROGRAMME, and it is three. Eight agents at once on one
# programme kept every pull request clashing on the same files (2026-09-24), and
# an earlier run of eight went 4h43m with zero merges against a sequential
# baseline of three — the gates are CPU-bound, eight lints on ten cores took 17
# minutes each, and three agents died backgrounding captures under load 30.
# Three is where each agent's gates run at full speed. Two programmes may run
# three each: they do not share files.
#
# There are four reasons to hold, and each one is logged so a silent pass can be
# told from a pass that decided not to act:
#   the machine's load is above the ceiling
#   the plan's usage limit was hit and its reset time has not passed
#   the live view cannot be reached — which counts as busy, never as room
#   the programme already has its cap running
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/swarm-env.sh" || exit 1

LOG="$SWARM_LOGS/scheduler.log"
QUEUE="$(dirname "${BASH_SOURCE[0]}")/queue.sh"
EXPLAIN=0; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --programme) ONLY="${2:?--programme needs a name}"; shift 2 ;;
    --explain)   EXPLAIN=1; shift ;;
    -h|--help)   sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           echo "scheduler: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
say() { echo "$*"; [ "$EXPLAIN" = 1 ] || swarm_log "$LOG" "$*"; }

# ---- the machine ------------------------------------------------------------
LOAD=$(swarm_load)
if [ "$LOAD" -gt "$SWARM_MAX_LOAD" ]; then
  say "load $LOAD above $SWARM_MAX_LOAD — holding"; exit 0
fi

# The plan's usage limit: swarm_usage_hold in swarm-env.sh reads it.
if HOLD_UNTIL=$(swarm_usage_hold); then
  say "usage limit — holding until $HOLD_UNTIL"; exit 0
fi

# ---- which programmes -------------------------------------------------------
# Every programme with a ticket in the queue or a ready ticket of its own. A
# programme is never enumerated in the kit: the labels on the open issues are the
# list, so a new programme needs no change here.
programmes() {
  if [ -n "$ONLY" ]; then printf '%s\n' "$ONLY"; return; fi
  { awk -F'\t' 'NF>=3 && $2!=""{print $2}' "$SWARM_DIR/queue.tsv" 2>/dev/null
    swarm_gh issue list --repo "$REPO_SLUG" --state open --label "$LBL_READY" --limit 500 \
      --json labels -q "[.[].labels[].name | select(startswith(\"$SWARM_PROGRAMME_PREFIX\"))] | unique | .[]" 2>/dev/null \
      | sed "s/^$SWARM_PROGRAMME_PREFIX//"
  } | awk 'NF && !seen[$0]++'
}

# ---- a programme's candidate tickets, in the order they should run ----------
# claimable-issues.sh is the ONE definition of what may be picked up — the same
# one /claim reads — so this intersects with it rather than re-deriving it. A
# ticket held by a live claim, an epic without its run-ready label, or an
# in-review ticket waiting on a person is already absent from that list.
candidates() { # <programme>
  local p="$1" members claimable
  members=$(swarm_gh issue list --repo "$REPO_SLUG" --state open \
              --label "${SWARM_PROGRAMME_PREFIX}$p" --limit 500 \
              --json number -q '.[].number' 2>/dev/null | sort -u)
  [ -n "$members" ] || return 0
  claimable=$(bash "$KIT_ROOT/scripts/claimable-issues.sh" 2>/dev/null | awk -F'\t' '{print $1}')
  # Order is claimable-issues' own: priority first, then number. Preserve it.
  printf '%s\n' "$claimable" | while read -r n; do
    [ -n "$n" ] || continue
    grep -qx "$n" <<<"$members" && printf '%s\n' "$n"
  done
}

# A waves file, when a programme has one, says which tickets are safe to run
# TOGETHER: a wave is a group sharing no source file, so two tickets in one wave
# cannot fight at merge and two in different waves might. The scheduler never
# starts a ticket from a later wave, and advances only when the current one has
# nothing left to start.
wave_file()    { printf '%s' "$SWARM_DIR/$1/waves.json"; }
wave_current() { # <programme>
  local f="$SWARM_DIR/$1/wave.current"
  [ -f "$f" ] || { mkdir -p "$(dirname "$f")"; echo 1 > "$f"; }
  cat "$f"
}
wave_tickets() { # <programme> <wave>
  jq -r --argjson w "$2" '.[$w-1][]? | tostring' "$(wave_file "$1")" 2>/dev/null
}
wave_total()   { jq -r 'length' "$(wave_file "$1")" 2>/dev/null; }

top_up() { # <programme>
  local p="$1" wf t added=0 pool
  wf=$(wave_file "$p")
  if [ -f "$wf" ]; then
    pool=$(wave_tickets "$p" "$(wave_current "$p")")
  else
    pool=$(candidates "$p")
  fi
  while read -r t; do
    [ -n "$t" ] || continue
    grep -q "$(printf '\t')$t$(printf '\t')" "$SWARM_DIR/queue.tsv" 2>/dev/null && continue
    bash "$QUEUE" add "$t" --programme "$p" >/dev/null 2>&1 && added=$((added+1))
  done <<< "$pool"
  [ "$added" -eq 0 ] || say "$p: queued $added ready ticket(s)"
}

# A wave is exhausted when nothing in it is spawnable any more: every ticket is
# closed, claimed, in review, or carries an open PR.
advance_wave() { # <programme>
  local p="$1" total cur t left=0
  [ -f "$(wave_file "$p")" ] || return 0
  total=$(wave_total "$p"); cur=$(wave_current "$p")
  [ -n "$total" ] && [ "$cur" -lt "$total" ] 2>/dev/null || return 0
  while read -r t; do
    [ -n "$t" ] || continue
    swarm_spawnable "$t" >/dev/null 2>&1 && left=$((left+1))
  done <<< "$(wave_tickets "$p" "$cur")"
  [ "$left" -eq 0 ] || return 0
  [ "$EXPLAIN" = 1 ] || echo $((cur+1)) > "$SWARM_DIR/$p/wave.current"
  say "$p: wave $cur exhausted → wave $((cur+1))"
}

# ---- the pass ---------------------------------------------------------------
for P in $(programmes); do
  LIVE=$(swarm_live_count "$P")
  SLOTS=$(( SWARM_CAP - LIVE ))
  if [ "$SLOTS" -le 0 ]; then
    say "$P: $LIVE agent(s) running (cap $SWARM_CAP) — holding"
    continue
  fi
  top_up "$P"
  if [ "$EXPLAIN" = 1 ]; then
    say "$P: $SLOTS free slot(s); next up: $(bash "$QUEUE" next --programme "$P" | tr '\n' ' ')"
  else
    OUT=$(bash "$QUEUE" drain --programme "$P" --slots "$SLOTS" 2>&1)
    printf '%s\n' "$OUT"
    say "$P: $(printf '%s' "$OUT" | grep -E '^launched' | tail -1)"
  fi
  advance_wave "$P"
done
