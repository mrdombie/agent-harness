#!/usr/bin/env bash
# state.sh — the run record. One directory per ticket, holding the facts that
# have to survive the process that wrote them.
#
#   $DRIVER_DIR/<ticket>/state.json   ticket, branch, worktree, finished steps, counters
#   $DRIVER_DIR/<ticket>/steps/<s>.json  what that step answered
#   $DRIVER_DIR/<ticket>/steps/<s>.log   the transcript of an AI step
#   $DRIVER_DIR/<ticket>/log             the driver's own narration
#
# WHY A FILE AND NOT A VARIABLE. "Nothing is lost on a stop" is one of the seven
# guarantees, and a stop is exactly the case where the process holding the
# variable is gone. A resumed run reads this and skips what is already finished.
#
# `done` is a set, kept as a list because the order it was finished in is the
# order it ran: recording `start` twice must not make it look like two steps.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/driver-env.sh" || exit 1

driver_state_dir()  { printf '%s' "$DRIVER_DIR/$1"; }
_driver_state_file() { printf '%s' "$DRIVER_DIR/$1/state.json"; }

# driver_state_init <ticket> [--branch B] [--worktree W] [--repo R]
# Creating is idempotent: a resumed run calls this too, and must not erase the
# step list it is resuming from.
driver_state_init() {
  local t="${1:?driver_state_init: need a ticket}"; shift
  local branch="" worktree="" repo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --branch)   branch="${2:-}"; shift 2 ;;
      --worktree) worktree="${2:-}"; shift 2 ;;
      --repo)     repo="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  local d f; d=$(driver_state_dir "$t"); f=$(_driver_state_file "$t")
  mkdir -p "$d/steps"
  [ -f "$f" ] || jq -n --arg t "$t" --arg at "$(swarm_stamp)" \
    '{ticket:$t, branch:"", worktree:"", repo:"", step:"", done:[], counters:{}, started_at:$at, updated_at:$at}' > "$f"
  _driver_state_edit "$t" \
    --arg b "$branch" --arg w "$worktree" --arg r "$repo" \
    'if $b != "" then .branch = $b else . end
     | if $w != "" then .worktree = $w else . end
     | if $r != "" then .repo = $r else . end'
}

# _driver_state_edit <ticket> [jq args…] <filter> — one read-modify-write, always
# stamping updated_at, always through a temp file so a killed driver cannot leave
# a half-written record that reads as corrupt on resume.
_driver_state_edit() {
  local t="$1"; shift
  local f tmp; f=$(_driver_state_file "$t")
  [ -f "$f" ] || { mkdir -p "$(dirname "$f")"; jq -n --arg t "$t" --arg at "$(swarm_stamp)" \
      '{ticket:$t, branch:"", worktree:"", repo:"", step:"", done:[], counters:{}, started_at:$at, updated_at:$at}' > "$f"; }
  tmp="$f.tmp.$$"
  jq --arg _now "$(swarm_stamp)" "$@" "$f" > "$tmp" 2>/dev/null \
    && jq '.updated_at = $_now' --arg _now "$(swarm_stamp)" "$tmp" > "$tmp.2" 2>/dev/null \
    && mv "$tmp.2" "$f" && rm -f "$tmp"
}

# driver_state_get <ticket> <key-or-jq-expression> — empty for a ticket nobody
# started, which is what lets a caller ask about a ticket before it has a record.
# A bare key is a key: `ticket` and `done|join(",")` both read naturally, and the
# leading dot is added here rather than at 40 call sites.
driver_state_get() {
  local f e; f=$(_driver_state_file "$1")
  [ -f "$f" ] || { printf ''; return 0; }
  case "$2" in .*|\(*) e="$2" ;; *) e=".$2" ;; esac
  jq -r "(${e}) // \"\"" "$f" 2>/dev/null
}

driver_state_set() { _driver_state_edit "$1" --arg k "$2" --arg v "$3" '.[$k] = $v'; }

# Appending, never `unique_by`: that sorts, and the order a step finished in is
# the order it ran — which is what a resumed run prints back to the operator.
driver_state_done() {
  _driver_state_edit "$1" --arg s "$2" \
    '.done = (if ((.done // []) | index($s)) then .done else ((.done // []) + [$s]) end) | .step = $s'
}

driver_state_is_done() {
  local f; f=$(_driver_state_file "$1")
  [ -f "$f" ] || return 1
  jq -e --arg s "$2" '(.done // []) | index($s) != null' "$f" >/dev/null 2>&1
}

# driver_state_reopen <ticket> <step…> — forget those steps, keep the run.
#
# This is what a rework round is made of. A review that sends the work back does
# not mean the build never happened; it means the build, the self-check and the
# review have to happen AGAIN — so they have to leave the finished list, or the
# resumed walk skips the very steps the rework exists to repeat.
#
# It removes from the LIST rather than truncating it, because a step order is not
# a stack: `record` may already be finished when `build` reopens, and the walk
# decides what to run from the list, not from a high-water mark.
driver_state_reopen() {
  local t="${1:?driver_state_reopen: need a ticket}"; shift
  [ $# -gt 0 ] || return 0
  local list; list=$(printf '%s\n' "$@" | jq -R . | jq -sc .)
  # The root is bound before the walk: inside `select` the dot is the step
  # STRING, so an unbound `.done` there asks a string for its done list and
  # every step reads as never-finished.
  _driver_state_edit "$t" --argjson r "$list" '
    . as $root
    | ([$r[] | select((($root.done // []) | index(.)) != null)] | first) as $first
    | .done = ((.done // []) - $r)
    | if $first != null then .step = $first else . end'
}

driver_state_count() {
  local f; f=$(_driver_state_file "$1")
  [ -f "$f" ] || { printf '0'; return 0; }
  jq -r --arg k "$2" '(.counters[$k] // 0)' "$f" 2>/dev/null
}

driver_state_bump() { _driver_state_edit "$1" --arg k "$2" '.counters[$k] = ((.counters[$k] // 0) + 1)'; }

# driver_state_put <ticket> <step> <json> — what the step answered.
driver_state_put() {
  local d; d=$(driver_state_dir "$1"); mkdir -p "$d/steps"
  printf '%s\n' "$3" > "$d/steps/$2.json"
}
driver_state_read() {
  local d; d=$(driver_state_dir "$1")
  [ -f "$d/steps/$2.json" ] && cat "$d/steps/$2.json"
}
